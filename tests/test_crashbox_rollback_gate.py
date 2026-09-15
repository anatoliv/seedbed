"""A Crashbox release must have a retained release to fall back to.

`docs/crashbox-pilot.md` opened with four conditions that had to hold before a
Crashbox build could be published, and nothing on the release path checked any
of them. So 0.1.9 shipped past one of the four, and the only thing that noticed
was a person re-reading the file the next day. A gate that only exists in prose
is enforced by whoever happens to re-read the prose.

Two of those four still bind. `tests/test_crashbox_symbol_gate.py` pins the
first: the declared dSYM must belong to the binary that ships. This pins the
other one. Crashbox is the provider being proved here, its failure modes are
still being found, and the documented response to a bad one is to restore the
previous release. That is only a plan while the artifact still exists:
re-pinning the appcast, the cask and the site at a version nobody can download
is not a rollback.

Presence is not enough, so stapling is checked too. Without a stapled ticket
the copy dragged out of the image has to reach Apple to be verified and fails
on a Mac that is offline or behind a filter, which is not the rollback anyone
wants during an incident.

The metadata and fail-closed cases exercise the helper with local hostile
fixtures. A positive end-to-end case requires a signed and notarized artifact,
so the tests also pin the macOS verification commands that the release path
runs against both layers of the retained DMG.
"""

from __future__ import annotations

import plistlib
import hashlib
import os
import re
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
RELEASE = REPO / "macos" / "Scripts" / "release.sh"
PILOT = REPO / "docs" / "crashbox-pilot.md"
CHECK_TARGET = REPO / "macos" / "Scripts" / "check-rollback-target.sh"
METADATA = REPO / "macos" / "Scripts" / "support" / "rollback_metadata.py"
SELECTOR = REPO / "macos" / "Scripts" / "support" / "select_rollback.py"
APP_SELECTOR = REPO / "macos" / "Scripts" / "support" / "select_rollback_app.py"
HEAD = subprocess.run(
    ["git", "rev-parse", "HEAD"], cwd=REPO, text=True, capture_output=True, check=True
).stdout.strip()

# Hosts, private addresses and tracker ids. docs/crashbox-pilot.md is NOT in the
# exclude list in Scripts/publish-repo.sh, so every word of it is published.
INTERNAL = re.compile(r"192\.168\.|(?:^|[^0-9.])10\.\d+\.\d+\.\d+|"
                      r"\b(?:web|ai|db|nas|dev|tm)-\d{2}\b|TBX-\d")


class ACrashboxReleaseKeepsSomethingToRollBackTo(unittest.TestCase):
    def setUp(self) -> None:
        self.source = RELEASE.read_text()

    def test_the_check_exists_and_is_scoped_to_a_crashbox_build(self) -> None:
        self.assertIn(
            "ROLLBACK_TAG=", self.source,
            "nothing on the release path asks whether a rollback target still "
            "exists, so the documented response to a Crashbox failure is an "
            "intention rather than an artifact")
        scope = self.source.rindex('if [[ "$REPORTING_PROVIDER" == "crashbox" ]]',
                                   0, self.source.index("ROLLBACK_TAG="))
        self.assertLess(
            scope, self.source.index("ROLLBACK_TAG="),
            "the rollback check is not inside a crashbox-only branch")

    def test_the_previous_release_is_found_by_tag_not_hard_coded(self) -> None:
        """A version pinned in the script is one that stops being the previous
        one on the next release, and a gate aimed at the wrong artifact passes
        forever."""
        self.assertIn("Scripts/support/select_rollback.py", self.source)

    def test_an_explicit_allowed_rollback_can_replace_the_previous_tag(self) -> None:
        self.assertIn('ROLLBACK_DMG="${SEEDBED_ROLLBACK_DMG:-}"', self.source)
        self.assertIn('ROLLBACK_VERSION="${SEEDBED_ROLLBACK_VERSION:-}"', self.source)
        self.assertIn('ROLLBACK_BUILD="${SEEDBED_ROLLBACK_BUILD:-}"', self.source)
        self.assertIn('ROLLBACK_COMMIT="${SEEDBED_ROLLBACK_COMMIT:-}"', self.source)
        self.assertIn("must be supplied together", self.source)

    def test_the_retained_artifact_provider_is_verified(self) -> None:
        self.assertIn("Scripts/check-rollback-target.sh", self.source)
        self.assertIn('"$ROLLBACK_DMG" "$ROLLBACK_VERSION" "$ROLLBACK_BUILD"', self.source)
        self.assertIn('"$ROLLBACK_COMMIT" "$IDENTITY"', self.source)

    def test_the_artifact_must_actually_be_on_disk(self) -> None:
        self.assertIn('if [[ ! -f "$ROLLBACK_DMG" ]]', self.source,
                      "nothing checks that the previous release's DMG is still "
                      "there")

    def test_presence_alone_does_not_satisfy_it(self) -> None:
        """An unstapled DMG is not a release anyone can install offline."""
        helper = CHECK_TARGET.read_text()
        self.assertIn('/usr/bin/xcrun stapler validate "$TARGET"', helper,
                      "a rollback target is accepted on presence alone, so an "
                      "unstapled or de-notarized DMG would pass")

    def test_both_failures_stop_the_release(self) -> None:
        for anchor in ('if [[ ! -f "$ROLLBACK_DMG" ]]',
                       'if ! Scripts/check-rollback-target.sh'):
            with self.subTest(anchor=anchor):
                branch = self.source[self.source.index(anchor):][:1400]
                self.assertIn("exit 1", branch,
                              "a missing or unusable rollback target must stop "
                              "the release; warning and continuing is the "
                              "fail-open shape this gate exists to remove")

    def test_it_refuses_before_the_build(self) -> None:
        """Learning about it after a build and two notarizations costs ten
        minutes, and a gate that expensive stops being run. Same argument the
        preflight half of check-release.sh is built on."""
        self.assertLess(
            self.source.index("ROLLBACK_TAG="),
            self.source.index("./Scripts/make-app.sh"),
            "the rollback check runs only after the build")

    def test_it_reads_the_dist_and_app_variables(self) -> None:
        """A second spelling of the artifact path is a second thing to keep in
        step with the first."""
        self.assertIn('"${DIST}/${APP_NAME}_${ROLLBACK_TAG#v}_"*.dmg', self.source)
        self.assertIn('"${#ROLLBACK_DMGS[@]}" -ne 1', self.source)


class RollbackFixture(unittest.TestCase):
    VERSION = "1.2.3"
    BUILD = "17"

    def setUp(self) -> None:
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.repo = self.root / "repo"
        (self.repo / "macos/Sources/Seedbed").mkdir(parents=True)
        (self.repo / "macos/Packaging").mkdir(parents=True)
        (self.repo / "macos/Sources/Seedbed/App.swift").write_text("struct App {}\n")
        (self.repo / "macos/Package.swift").write_text("// swift-tools-version: 6.0\n")
        with (self.repo / "macos/Packaging/Info.plist").open("wb") as handle:
            plistlib.dump({
                "CFBundleShortVersionString": self.VERSION,
                "CFBundleVersion": self.BUILD,
                "CFBundleExecutable": "Seedbed",
            }, handle)
        subprocess.run(["git", "init", "-q"], cwd=self.repo, check=True)
        subprocess.run(["git", "config", "user.name", "Test"], cwd=self.repo, check=True)
        subprocess.run(["git", "config", "user.email", "test@example.invalid"], cwd=self.repo, check=True)
        subprocess.run(["git", "add", "."], cwd=self.repo, check=True)
        subprocess.run(["git", "commit", "-qm", "fixture"], cwd=self.repo, check=True)
        subprocess.run(["git", "remote", "add", "origin", "example.invalid/repo"], cwd=self.repo, check=True)
        self.commit = subprocess.run(
            ["git", "rev-parse", "HEAD"], cwd=self.repo, check=True,
            text=True, capture_output=True,
        ).stdout.strip()

    def digest(self) -> str:
        paths = ["Package.swift", "Sources/Seedbed/App.swift"]
        lines = b"".join(
            f"{hashlib.sha256((self.repo / 'macos' / path).read_bytes()).hexdigest()}  {path}\n".encode()
            for path in paths
        )
        return f"sha256:{hashlib.sha256(lines).hexdigest()}"

    def artifact(self, **overrides: str) -> Path:
        contents = self.root / "Seedbed.app/Contents"
        executable = contents / "MacOS/Seedbed"
        executable.parent.mkdir(parents=True, exist_ok=True)
        executable.write_bytes(b"fixture executable")
        info = {
            "CFBundleIdentifier": "net.amnesia.seedbed",
            "CFBundleShortVersionString": self.VERSION,
            "CFBundleVersion": self.BUILD,
            "CFBundleExecutable": "Seedbed",
            "CrashReportingRelease": f"net.amnesia.seedbed@{self.commit}",
            "SeedbedSourceDigest": self.digest(),
            "CrashReportingProvider": "crashbox",
            "CrashReportingDSN": "https://public-key@ingest.crashbox.dev/12345",
            "CrashReportingEnvironment": "production",
            **overrides,
        }
        with (contents / "Info.plist").open("wb") as handle:
            plistlib.dump(info, handle)
        return contents.parent

    def metadata(self, app: Path, *expected: str) -> subprocess.CompletedProcess[str]:
        values = expected or (self.VERSION, self.BUILD, self.commit)
        return subprocess.run(
            [sys.executable, str(METADATA), str(self.repo), str(app), *values],
            text=True, capture_output=True, check=False,
        )


class ARollbackTargetCannotRestoreHostedSentry(RollbackFixture):
    def test_exact_crashbox_metadata_passes(self) -> None:
        self.assertEqual(0, self.metadata(self.artifact()).returncode)

    def test_a_hosted_destination_cannot_hide_under_the_crashbox_label(self) -> None:
        result = self.metadata(self.artifact(
            CrashReportingDSN="https://public@o1.ingest.sentry.io/12345"
        ))
        self.assertNotEqual(0, result.returncode)
        self.assertIn("canonical Crashbox DSN", result.stderr)

    def test_only_the_exact_canonical_crashbox_dsn_shape_passes(self) -> None:
        for dsn in (
            "http://public-key@ingest.crashbox.dev/12345",
            "https://public-key@crashbox." + "getvirtual" + "view.com/12345",
            "https://public-key@ingest.crashbox.dev/project-uuid",
            "https://public-key:secret@ingest.crashbox.dev/12345",
            "https://public-key@ingest.crashbox.dev:443/12345",
            "https://public-key@ingest.crashbox.dev/12345?query=1",
        ):
            with self.subTest(dsn=dsn):
                self.assertNotEqual(
                    0, self.metadata(self.artifact(CrashReportingDSN=dsn)).returncode
                )

    def test_hosted_and_unknown_provider_labels_are_refused(self) -> None:
        for provider in ("hosted-sentry", "other"):
            with self.subTest(provider=provider):
                self.assertNotEqual(
                    0,
                    self.metadata(self.artifact(CrashReportingProvider=provider)).returncode,
                )

    def test_disabled_means_no_dsn_or_environment(self) -> None:
        for key, value in (("CrashReportingDSN", "https://public@example.invalid/1"),
                           ("CrashReportingEnvironment", "production")):
            with self.subTest(key=key):
                overrides = {
                    "CrashReportingProvider": "",
                    "CrashReportingDSN": "",
                    "CrashReportingEnvironment": "",
                }
                overrides[key] = value
                app = self.artifact(**overrides)
                result = self.metadata(app)
                self.assertNotEqual(0, result.returncode)
                self.assertIn("retains reporting configuration", result.stderr)

    def test_version_and_build_must_match_the_commit_and_artifact(self) -> None:
        self.assertNotEqual(0, self.metadata(self.artifact(), "9.9.9", self.BUILD, self.commit).returncode)
        self.assertNotEqual(0, self.metadata(self.artifact(), self.VERSION, "999", self.commit).returncode)
        self.assertNotEqual(0, self.metadata(self.artifact(CFBundleVersion="999")).returncode)

    def test_source_digest_must_match_the_exact_commit(self) -> None:
        result = self.metadata(self.artifact(SeedbedSourceDigest="sha256:" + "0" * 64))
        self.assertNotEqual(0, result.returncode)
        self.assertIn("source digest", result.stderr)

    def test_bundle_and_release_namespace_are_exact(self) -> None:
        for overrides in (
            {"CFBundleIdentifier": "com.example.other"},
            {"CrashReportingRelease": f"com.example@{self.commit}"},
            {"CrashReportingRelease": "net.amnesia.seedbed@short"},
        ):
            with self.subTest(overrides=overrides):
                self.assertNotEqual(0, self.metadata(self.artifact(**overrides)).returncode)

    def test_unknown_expected_commit_is_refused(self) -> None:
        self.assertNotEqual(
            0,
            self.metadata(self.artifact(), self.VERSION, self.BUILD, "a" * 40).returncode,
        )

    def test_executable_must_be_contained_and_not_a_symlink(self) -> None:
        app = self.artifact(CFBundleExecutable="../elsewhere")
        self.assertNotEqual(0, self.metadata(app).returncode)
        app = self.artifact()
        executable = app / "Contents/MacOS/Seedbed"
        executable.unlink()
        executable.symlink_to("outside")
        self.assertNotEqual(0, self.metadata(app).returncode)

    def test_bundle_containment_rejects_symlinked_components(self) -> None:
        for component in ("Contents", "Contents/Info.plist", "Contents/MacOS"):
            with self.subTest(component=component):
                shutil.rmtree(self.root / "Seedbed.app", ignore_errors=True)
                app = self.artifact()
                target = app / component
                actual = target.with_name(target.name + ".actual")
                target.rename(actual)
                target.symlink_to(actual.name, target_is_directory=actual.is_dir())
                self.assertNotEqual(0, self.metadata(app).returncode)

    def test_packaging_rejects_a_hosted_dsn_named_as_crashbox(self) -> None:
        packaging = self.root / "packaging"
        packaging.mkdir()
        app = self.artifact()
        result = subprocess.run(
            [str(REPO / "macos/Scripts/configure-crash-reporting.sh"), str(app)],
            env={**os.environ, "SEEDBED_PACKAGING_DIR": str(packaging),
                 "SEEDBED_CRASHBOX_DSN": "https://public@o1.ingest.sentry.io/123",
                 "SEEDBED_BUILD_REF": self.commit},
            text=True, capture_output=True, check=False,
        )
        self.assertNotEqual(0, result.returncode)

    def test_the_outer_helper_binds_signer_and_universal_executable(self) -> None:
        source = CHECK_TARGET.read_text()
        self.assertIn('"$team" != "$EXPECTED_TEAM"', source)
        self.assertIn('/usr/bin/lipo "$EXECUTABLE" -verify_arch arm64 x86_64', source)
        self.assertIn('$SCRIPT_DIR/support/select_rollback_app.py', source)
        self.assertIn('/usr/bin/codesign --verify --strict "$TARGET"', source)
        self.assertIn('/usr/bin/codesign --verify --deep --strict "$APP"', source)
        self.assertIn('/usr/sbin/spctl --assess --type execute "$APP"', source)
        self.assertEqual(2, source.count("/usr/bin/xcrun stapler validate"))

    def test_malformed_expected_signer_refuses_before_artifact_checks(self) -> None:
        result = subprocess.run(
            [str(CHECK_TARGET), str(self.root / "missing.app"), self.VERSION,
             self.BUILD, self.commit, "Developer ID Application: Somebody"],
            text=True, capture_output=True, check=False,
        )
        self.assertNotEqual(0, result.returncode)
        self.assertIn("exact Developer ID Application identity", result.stderr)


class RollbackTagSelectionIsMeasured(RollbackFixture):
    def select(self, version: str = "2.0.0", *, first: bool = False) -> subprocess.CompletedProcess[str]:
        cask = self.root / "seedbed.rb"
        site = self.root / "index.html"
        command = [sys.executable, str(SELECTOR), str(self.repo), version, str(cask), str(site)]
        if first:
            command.append("--first-release")
        return subprocess.run(command, text=True, capture_output=True, check=False)

    def test_missing_history_refuses_without_explicit_first_release(self) -> None:
        self.assertNotEqual(0, self.select().returncode)
        self.assertEqual(0, self.select(first=True).returncode)

    def test_first_release_refuses_any_repository_pin(self) -> None:
        for path, text in ((self.root / "seedbed.rb", 'version "1.0.0"\n'),
                           (self.root / "index.html", 'Seedbed_1.0.0_aarch64.dmg')):
            with self.subTest(path=path.name):
                path.write_text(text)
                self.assertNotEqual(0, self.select(first=True).returncode)
                path.unlink()

    def test_first_release_refuses_any_release_tag(self) -> None:
        subprocess.run(["git", "tag", "v1.2.3"], cwd=self.repo, check=True)
        self.assertNotEqual(0, self.select(first=True).returncode)

    def test_previous_tag_is_selected_and_current_tag_is_exactly_excluded(self) -> None:
        subprocess.run(["git", "tag", "v1.2.3"], cwd=self.repo, check=True)
        subprocess.run(["git", "tag", "v1x2x3"], cwd=self.repo, check=True)
        result = self.select(version="1.2.3")
        self.assertEqual(0, result.returncode, result.stderr)
        self.assertEqual("v1x2x3", result.stdout.strip())

    def test_no_tags_remote_configuration_refuses(self) -> None:
        subprocess.run(
            ["git", "config", "remote.origin.tagOpt", "--no-tags"],
            cwd=self.repo, check=True,
        )
        self.assertNotEqual(0, self.select(first=True).returncode)


class MountedRollbackAppSelectionIsMeasured(unittest.TestCase):
    def setUp(self) -> None:
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)

    def select(self) -> subprocess.CompletedProcess[str]:
        return subprocess.run(
            [sys.executable, str(APP_SELECTOR), str(self.root)],
            text=True, capture_output=True, check=False,
        )

    def test_exact_seedbed_app_is_selected(self) -> None:
        (self.root / "Seedbed.app").mkdir()
        result = self.select()
        self.assertEqual(0, result.returncode, result.stderr)
        self.assertEqual(self.root / "Seedbed.app", Path(result.stdout.strip()))

    def test_hidden_second_app_is_ambiguity(self) -> None:
        (self.root / "Seedbed.app").mkdir()
        (self.root / ".Other.app").mkdir()
        self.assertNotEqual(0, self.select().returncode)

    def test_wrong_named_or_symlinked_app_is_refused(self) -> None:
        (self.root / "Other.app").mkdir()
        self.assertNotEqual(0, self.select().returncode)
        (self.root / "Other.app").rename(self.root / "actual")
        (self.root / "Seedbed.app").symlink_to("actual", target_is_directory=True)
        self.assertNotEqual(0, self.select().returncode)


class ThePilotDocumentIsHonestAndPublishable(unittest.TestCase):
    """docs/crashbox-pilot.md ships in the public snapshot.

    Scripts/publish-repo.sh excludes the plan, the design notes and the
    experiment transcripts from docs/, and does not exclude this file. So it
    travels, and it is held to the same rule site/ is: no internal hosts, no
    private addresses, no tracker ids.
    """

    def setUp(self) -> None:
        self.text = PILOT.read_text()

    def test_it_names_nothing_internal(self) -> None:
        hit = INTERNAL.search(self.text)
        self.assertIsNone(
            hit, f"docs/crashbox-pilot.md is published and names something "
                 f"internal: {hit and hit.group(0)}")

    def test_it_records_what_shipped_rather_than_forbidding_it(self) -> None:
        """The defect this file had was not a wrong rule, it was a rule that
        had been overtaken and said nothing about it. A reader has to be able
        to tell the two apart without going to the git log."""
        self.assertIn("0.1.9", self.text,
                      "the document does not mention the release that was cut "
                      "under it, so a reader cannot tell whether the gate is "
                      "live or historical")
        self.assertNotIn(
            "Do not install or publish the Crashbox build until all of these "
            "are true", self.text,
            "the unqualified prohibition is back, and a Crashbox build has "
            "already shipped; a rule the artifact contradicts teaches its "
            "reader to disbelieve the whole file")

    def test_it_points_at_the_checks_that_actually_run(self) -> None:
        for name in ("test_crashbox_symbol_gate.py",
                     "test_crashbox_rollback_gate.py"):
            with self.subTest(name=name):
                self.assertIn(
                    name, self.text,
                    "the document should name the test that pins each "
                    "surviving condition, so a reader can tell prose from a "
                    "gate")


if __name__ == "__main__":
    unittest.main()
