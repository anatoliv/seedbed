"""The dSYM upload that `release.sh` refuses to ship without has a permitted route.

A Crashbox release has to name the artifact its dSYM went into and the UUIDs
the catalog recorded. Until `macos/Scripts/upload-dsym.sh` existed there was no
script for that upload, so a release lane improvised a remote copy and a remote
root shell, was rightly refused, and the upload had to be done by hand.

The script is operator tooling that `Scripts/publish-repo.sh` keeps out of the
public snapshot, and `tests/` is published, so every test that runs it skips
where it is absent. The tests drive it against fake `ssh`, `scp`, `dwarfdump`,
`lipo` and `codesign` on PATH: nothing here reaches a real host.
"""

from __future__ import annotations

import plistlib
import re
import shutil
import stat
import subprocess
import tempfile
import unittest
import zipfile
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
MACOS = REPO / "macos"
UPLOAD = MACOS / "Scripts" / "upload-dsym.sh"
RELEASE = MACOS / "Scripts" / "release.sh"
PUBLISH = REPO / "Scripts" / "publish-repo.sh"

PROJECT_ID = "f869c218-4e5e-4c4d-b93c-bff6b9f588df"
FINGERPRINT = "sha256:dad0a78961ed17ff0fdc778db48d5290cecc2eccd82f45d4b18fc264b02e4302"
ARTIFACT = "0b6f3c1e-7d2a-4c59-9e41-2f8a6b0c3d17"
RELEASE_ID = "net.amnesia.seedbed@" + "a" * 40
FAKE_DSN = "https://public-key@ingest.crashbox.dev/12345"
# Deliberately out of order: the script must sort them the way release.sh does.
ARM64 = "B7E2A0C4-1D3F-4A5B-8C6D-7E8F9A0B1C2D"
X86_64 = "3A4B5C6D-7E8F-4091-A2B3-C4D5E6F7A8B9"

STUB_SSH = r"""#!/bin/bash
# Records every remote command and answers the ones the uploader asks.
printf '%s\n' "$*" >> "$STATE/ssh.log"
cmd="${!#}"
case "$cmd" in
  *inspect-fingerprint*)
    printf '{"enabled":%s,"project_id":"%s","public_key_fingerprint":"%s","retention_days":90,"slug":"seedbed-macos"}\n' \
      "${STUB_ENABLED:-true}" "$STUB_PROJECT_ID" "$STUB_FINGERPRINT" ;;
  *mktemp*) echo /tmp/seedbed-dsym.Ab12Cd ;;
  *artifact-upload*)
    sha="$(cat "$STATE/sha")"
    [ -n "${STUB_RECEIPT_SHA:-}" ] && sha="$STUB_RECEIPT_SHA"
    release="$(printf '%s' "$cmd" | sed -E "s/.*--release '([^']+)'.*/\1/")"
    printf '{"artifact_id":"%s","project_id":"%s","release":"%s","sha256":"%s","state":"ready","type":"apple_dsym"}\n' \
      "$STUB_ARTIFACT" "$STUB_PROJECT_ID" "$release" "$sha" ;;
  readlink*) path="${cmd##* }"; echo "${path%/current}/releases/r1" ;;
  *.pyc*) echo "${STUB_PYC:-0}" ;;
  *) : ;;
esac
"""

STUB_SCP = r"""#!/bin/bash
printf '%s\n' "$*" >> "$STATE/scp.log"
src="${@: -2:1}"
cp "$src" "$STATE/uploaded.zip"
shasum -a 256 "$src" | awk '{print $1}' > "$STATE/sha"
"""

STUB_DWARFDUMP = r"""#!/bin/bash
target="${!#}"
if [ -n "${STUB_DSYM_MISMATCH:-}" ] && [[ "$target" == *.dSYM* ]]; then
  echo "UUID: FFFFFFFF-FFFF-4FFF-8FFF-FFFFFFFFFFFF (arm64) $target"
  echo "UUID: $STUB_X86 (x86_64) $target"
  exit 0
fi
echo "UUID: $STUB_ARM (arm64) $target"
echo "UUID: $STUB_X86 (x86_64) $target"
"""

STUB_LIPO = "#!/bin/bash\necho 'x86_64 arm64'\n"
STUB_CODESIGN = "#!/bin/bash\nexit 0\n"


def write_executable(path: Path, body: str) -> None:
    path.write_text(body)
    path.chmod(path.stat().st_mode | stat.S_IXUSR)


@unittest.skipUnless(
    UPLOAD.is_file(),
    "macos/Scripts/upload-dsym.sh is operator tooling, excluded from the public "
    "snapshot; these checks only apply where the script exists")
class UploadDsymAgainstAStubbedHost(unittest.TestCase):
    def setUp(self) -> None:
        self.tmp = Path(tempfile.mkdtemp(prefix="seedbed-upload-test."))
        self.addCleanup(shutil.rmtree, self.tmp, True)
        self.state = self.tmp / "state"
        self.state.mkdir()
        bin_dir = self.tmp / "bin"
        bin_dir.mkdir()
        for name, body in (("ssh", STUB_SSH), ("scp", STUB_SCP),
                           ("dwarfdump", STUB_DWARFDUMP), ("lipo", STUB_LIPO),
                           ("codesign", STUB_CODESIGN)):
            write_executable(bin_dir / name, body)

        self.app = self.tmp / "build" / "Seedbed.app"
        (self.app / "Contents" / "MacOS").mkdir(parents=True)
        (self.app / "Contents" / "MacOS" / "Seedbed").write_bytes(b"binary")
        with open(self.app / "Contents" / "Info.plist", "wb") as handle:
            plistlib.dump({
                "CFBundleIdentifier": "net.amnesia.seedbed",
                "CrashReportingProvider": "crashbox",
                "CrashReportingRelease": RELEASE_ID,
                "CrashReportingEnvironment": "production",
                "CrashReportingDSN": FAKE_DSN,
            }, handle)
        self.dsym = self.tmp / "Release" / "Seedbed.dSYM"
        dwarf = self.dsym / "Contents" / "Resources" / "DWARF" / "Seedbed"
        dwarf.parent.mkdir(parents=True)
        dwarf.write_bytes(b"dwarf")

        self.receipts = self.tmp / "receipts"
        self.env = {
            "PATH": f"{bin_dir}:/usr/bin:/bin:/usr/sbin:/sbin",
            "HOME": str(self.tmp),
            "TMPDIR": str(self.tmp),
            "STATE": str(self.state),
            "CRASHBOX_SSH_HOST": "crashbox-host.invalid",
            "CRASHBOX_RECEIPT_DIR": str(self.receipts),
            "STUB_PROJECT_ID": PROJECT_ID,
            "STUB_FINGERPRINT": FINGERPRINT,
            "STUB_ARTIFACT": ARTIFACT,
            "STUB_ARM": ARM64,
            "STUB_X86": X86_64,
        }

    def run_upload(self, *args: str, **env: str) -> subprocess.CompletedProcess:
        argv = list(args) or [str(self.app), str(self.dsym), "seedbed-macos"]
        return subprocess.run(["bash", str(UPLOAD), *argv], cwd=MACOS,
                              env={**self.env, **env}, capture_output=True,
                              text=True, timeout=60)

    def log(self, name: str) -> str:
        path = self.state / name
        return path.read_text() if path.exists() else ""

    def test_it_uploads_and_prints_what_release_sh_consumes(self) -> None:
        result = self.run_upload()
        self.assertEqual(result.returncode, 0, result.stderr)
        lines = result.stdout.splitlines()
        self.assertEqual(lines, [
            f"CRASHBOX_DSYM_ARTIFACT={ARTIFACT}",
            f'CRASHBOX_DSYM_UUIDS="{" ".join(sorted([ARM64, X86_64]))}"',
        ], "stdout must be exactly the two assignments, so it can be kept as-is")
        # The artifact id satisfies release.sh's own check, character for character.
        release = RELEASE.read_text()
        pattern = re.search(r'CRASHBOX_DSYM_ARTIFACT" =~ (\^\S+\$) ', release).group(1)
        self.assertRegex(ARTIFACT, pattern)

    def test_the_upload_runs_as_the_service_account_for_the_pinned_project(self) -> None:
        self.assertEqual(self.run_upload().returncode, 0)
        upload = [line for line in self.log("ssh.log").splitlines()
                  if "artifact-upload" in line]
        self.assertEqual(len(upload), 1, "exactly one upload per run")
        self.assertIn("systemd-run --uid=crashbox --gid=crashbox", upload[0])
        self.assertIn(f"--project '{PROJECT_ID}'", upload[0])
        self.assertIn(f"--release '{RELEASE_ID}'", upload[0])
        self.assertNotIn("sudo crashbox", upload[0])
        self.assertIn("-o BatchMode=yes", upload[0])

    def test_the_archive_is_the_dsym_alone_without_metadata_members(self) -> None:
        self.assertEqual(self.run_upload().returncode, 0)
        with zipfile.ZipFile(self.state / "uploaded.zip") as archive:
            names = archive.namelist()
        self.assertIn("Seedbed.dSYM/Contents/Resources/DWARF/Seedbed", names)
        self.assertTrue(all(n.startswith("Seedbed.dSYM/") for n in names), names)
        self.assertFalse(any(part.startswith("._") for n in names for part in n.split("/")))

    def test_the_receipt_is_kept_and_the_staging_area_removed(self) -> None:
        self.assertEqual(self.run_upload().returncode, 0)
        receipts = list(self.receipts.glob("dsym-*.json"))
        self.assertEqual(len(receipts), 1)
        self.assertIn(ARTIFACT, receipts[0].read_text())
        self.assertIn("rm -rf '/tmp/seedbed-dsym.Ab12Cd'", self.log("ssh.log"))

    def test_nothing_it_prints_carries_the_dsn(self) -> None:
        result = self.run_upload()
        self.assertEqual(result.returncode, 0)
        self.assertNotIn(FAKE_DSN, result.stdout + result.stderr)
        self.assertNotIn("public-key@", self.log("ssh.log") + self.log("scp.log"))

    def test_a_different_slug_is_refused_before_any_host_contact(self) -> None:
        result = self.run_upload(str(self.app), str(self.dsym), "seedbed-ios")
        self.assertEqual(result.returncode, 64)
        self.assertEqual(self.log("ssh.log"), "")

    def test_a_build_directory_is_refused(self) -> None:
        result = self.run_upload(str(self.app), str(self.dsym.parent), "seedbed-macos")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("not a build directory", result.stderr)
        self.assertEqual(self.log("ssh.log"), "")

    def test_a_dsym_from_another_build_is_refused_before_any_host_contact(self) -> None:
        result = self.run_upload(STUB_DSYM_MISMATCH="1")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("UUIDs differ", result.stderr)
        self.assertEqual(self.log("ssh.log"), "")
        self.assertEqual(result.stdout, "")

    def test_a_host_answering_for_another_project_is_refused(self) -> None:
        result = self.run_upload(STUB_FINGERPRINT="sha256:" + "0" * 64)
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.log("scp.log"), "", "nothing may be copied to the wrong project")
        self.assertEqual(result.stdout, "")

    def test_a_disabled_project_is_refused(self) -> None:
        result = self.run_upload(STUB_ENABLED="false")
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.log("scp.log"), "")

    def test_a_receipt_for_other_bytes_declares_nothing(self) -> None:
        result = self.run_upload(STUB_RECEIPT_SHA="f" * 64)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("digest is not this archive", result.stderr)
        self.assertEqual(result.stdout, "", "no value may be offered to release.sh")
        self.assertIn("rm -rf '/tmp/seedbed-dsym.Ab12Cd'", self.log("ssh.log"),
                      "the staging area must be removed on failure too")

    def test_bytecode_left_on_the_host_fails_the_run(self) -> None:
        result = self.run_upload(STUB_PYC="3")
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(result.stdout, "")


class TheRefusalNamesTheRoute(unittest.TestCase):
    """release.sh is published; the script it names is not. The refusal still
    has to say where the permitted route is, or the next lane improvises one."""

    def test_the_missing_artifact_refusal_names_the_script(self) -> None:
        source = RELEASE.read_text()
        start = source.index('if [[ -z "${CRASHBOX_DSYM_ARTIFACT:-}" || -z "${CRASHBOX_DSYM_UUIDS:-}" ]]')
        refusal = source[start:source.index("exit 1", start)]
        self.assertIn("Scripts/upload-dsym.sh", refusal)

    @unittest.skipUnless(PUBLISH.is_file(),
                         "Scripts/publish-repo.sh is private ops tooling, excluded "
                         "from the public snapshot")
    def test_the_script_is_kept_out_of_the_public_snapshot(self) -> None:
        source = PUBLISH.read_text()
        self.assertIn("--exclude='macos/Scripts/upload-dsym.sh'", source)
        self.assertIn('"$MIRROR"/macos/Scripts/upload-dsym.sh', source,
                      "an exclude without the purge leaves a previously published "
                      "copy on the mirror")


if __name__ == "__main__":
    unittest.main()
