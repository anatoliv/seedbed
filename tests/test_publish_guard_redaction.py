"""The publish guards say WHERE they matched, never WHAT.

Both publish scripts run in agent sessions, and everything they print is copied
into that session's transcript. Until 2026-09-26 every guard printed the line it
matched, so a guard that caught a real credential leaked it a second time, into
the transcript of whoever ran the publish. A live upload token reached a
transcript exactly that way on 2026-09-14.

So each guard is run here, for real, against a tree with one planted hit, and
must do three things: refuse, name `path:line`, and print no fragment of what
it matched. The code under test is read out of the scripts, not restated: the
publish-repo guards are the block between the secrets-guard heading and the
cask check, run against a temporary mirror, and publish-site runs whole under
DRY_RUN=1 with a stubbed curl.

Every planted value is assembled from fragments at runtime, so this file holds
nothing either script's guards, or `test_publish_guard_patterns.py`, would
refuse. All of them are fake.

The history purge's content verifier is held to the same rule: it names the
pattern and the blob sha, never a sample of the match. It is run here against a
throwaway repository, never a real one.

All three scripts are private ops tooling that the public snapshot excludes, so
these skip rather than fail where the scripts are absent: a test that reads a
private-only file unconditionally breaks the publish it protects.
"""

from __future__ import annotations

import os
import re
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
PUBLISH_REPO = ROOT / "Scripts" / "publish-repo.sh"
PUBLISH_SITE = ROOT / "Scripts" / "publish-site.sh"
STAMP_SITE_ASSETS = ROOT / "Scripts" / "stamp-site-assets.py"
PURGE_HISTORY = ROOT / "Scripts" / "purge-public-history.sh"

GUARDS_START = 'bold "==> Secrets guard"'
GUARDS_END = "# (e) The cask"

# A marker on the planted line itself, so the whole line leaking is caught even
# where the planted value alone would not be.
CANARY = "zq" + "xj-" + "line-" + "canary"


def fragments(value: str, width: int = 6) -> list[str]:
    """Every window of `width` characters: a partial echo is still a leak."""
    if len(value) <= width:
        return [value]
    return [value[i:i + width] for i in range(len(value) - width + 1)]


class Redaction:
    """Assertions shared by both scripts' tests."""

    def assert_redacted(self, result: subprocess.CompletedProcess[str],
                        secret: str, where: str, guard: str) -> None:
        output = result.stdout + result.stderr
        self.assertNotEqual(result.returncode, 0,
                            f"the guard did not refuse a planted hit\n{output}")
        self.assertIn(where, output, "the refusal does not say where the match is")
        self.assertIn(guard, result.stderr, "the refusal does not name the guard")
        for piece in fragments(secret) + [CANARY]:
            self.assertNotIn(piece, output,
                             "the guard printed part of what it matched")


@unittest.skipUnless(PUBLISH_REPO.is_file(),
                     "Scripts/publish-repo.sh is private ops tooling, excluded from "
                     "the public snapshot")
class PublishRepoGuardsRedact(Redaction, unittest.TestCase):
    def setUp(self) -> None:
        text = PUBLISH_REPO.read_text(encoding="utf-8")
        self.assertIn(GUARDS_START, text)
        self.assertIn(GUARDS_END, text)
        block = text[text.index(GUARDS_START):text.index(GUARDS_END)]
        helpers = [line for line in text.splitlines()
                   if re.match(r"^(bold|fail)\(\)", line)]
        self.assertEqual(len(helpers), 2, "bold() and fail() were not found")
        self.program = "\n".join(["set -euo pipefail", 'MIRROR="$1"', *helpers, block])
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        self.mirror = Path(tmp.name) / "mirror"
        (self.mirror / ".git").mkdir(parents=True)
        (self.mirror / "README.md").write_text("A prompt library.\n")

    def plant(self, rel: str, secret: str) -> str:
        path = self.mirror / rel
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(f"first line\nsecond line\nsee {secret} {CANARY}\n")
        return f"{rel}:3"

    def run_guards(self, **env: str) -> subprocess.CompletedProcess[str]:
        return subprocess.run(["bash", "-c", self.program, "guards", str(self.mirror)],
                              env={**os.environ, **env}, capture_output=True,
                              text=True, errors="replace", timeout=60, check=False)

    def test_a_clean_mirror_passes_every_guard(self) -> None:
        """Without this, a block that refuses everything would pass the rest."""
        result = self.run_guards()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_lan_address_guard(self) -> None:
        secret = "192." + "168." + "73.41"
        where = self.plant("docs/hosts.md", secret)
        self.assert_redacted(self.run_guards(), secret, where, "guard (a)")

    def test_token_and_key_guard(self) -> None:
        # Scanned everywhere, tests included, so plant one under tests/.
        cases = {
            "token": "gh" + "p_" + "Fk3w9QzLr2" + "Tn8Vx4Mb7Pd1Hs6Jc0Ya5",
            "dsn": "5e2a9c" + "0b7d41f3a8" + "@o" + "4242" + ".ingest." + "example.test/7",
            "key": "-----BEGIN " + "RSA PRIVATE" + " KEY-----",
        }
        for name, secret in cases.items():
            with self.subTest(shape=name):
                for old in self.mirror.rglob("planted.py"):
                    old.unlink()
                where = self.plant("tests/planted.py", secret)
                self.assert_redacted(self.run_guards(), secret, where, "guard (b)")

    def test_internal_name_and_tracker_id_guard(self) -> None:
        for secret in ("T" + "BX-" + "90817", "we" + "b-" + "09"):
            with self.subTest(secret=secret):
                where = self.plant("docs/notes.md", secret)
                self.assert_redacted(self.run_guards(), secret, where, "guard (c)")

    def test_a_hit_on_a_line_that_is_not_utf8_still_refuses(self) -> None:
        """Fail closed when the line number cannot be read back.

        In a UTF-8 locale `cut` exits on a Latin-1 byte and prints nothing. A
        helper that counted only the line numbers it printed then reported no
        hit, and the guard waved the snapshot through with the match in it.
        """
        secret = "T" + "BX-" + "31337"
        path = self.mirror / "docs" / "legacy.txt"
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(b"first line\ncaf\xe9 " + f"{secret} {CANARY}".encode() + b"\n")
        result = self.run_guards(LC_ALL="en_US.UTF-8", LANG="en_US.UTF-8")
        self.assert_redacted(result, secret, "docs/legacy.txt:2", "guard (c)")

    def test_a_hit_inside_a_binary_file_still_refuses(self) -> None:
        """A file grep takes for binary is scanned like any other.

        With `-I` the guards skipped any file holding a NUL byte, so a key
        planted after one passed the whole block and the snapshot went out
        with it. The report is still where, never what: a line number, not
        grep's "Binary file matches" notice and not the bytes around the hit.
        """
        cases = {
            "guard (b)": "AK" + "IA" + "Q7ZK4M2XW9" + "PB",
            "guard (c)": "/Us" + "ers/" + "planteduser",
        }
        for guard, secret in cases.items():
            with self.subTest(guard=guard):
                for old in self.mirror.rglob("blob.bin"):
                    old.unlink()
                path = self.mirror / "assets" / "blob.bin"
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_bytes(b"\x00\x01\x02header\n\x00"
                                 + f"{secret} {CANARY}".encode() + b"\x00\xff\n")
                result = self.run_guards()
                self.assert_redacted(result, secret, "assets/blob.bin:2", guard)
                self.assertNotIn("Binary file", result.stdout + result.stderr)

    def test_an_unreadable_file_or_directory_refuses(self) -> None:
        """A file the scan cannot read is not a file the scan passed.

        The listing grep ran inside a process substitution, which discards its
        exit status, so a file it could not open was simply absent from the
        list and every guard passed over it. Planted under tests/ so guard (a),
        which skips that tree, stays clean and guard (b) is the one to answer.
        """
        secret = "AK" + "IA" + "V6NB3J8XQ1" + "TZ"
        for shape in ("file", "directory"):
            with self.subTest(shape=shape):
                for old in self.mirror.rglob("locked*"):
                    old.chmod(0o755 if old.is_dir() else 0o644)
                    if old.is_dir():
                        shutil.rmtree(old)
                    else:
                        old.unlink()
                if shape == "file":
                    locked = self.mirror / "tests" / "locked.py"
                    locked.parent.mkdir(parents=True, exist_ok=True)
                    locked.write_text(f"see {secret} {CANARY}\n")
                    mode = 0o644
                else:
                    locked = self.mirror / "tests" / "locked"
                    locked.mkdir(parents=True)
                    (locked / "inner.py").write_text(f"see {secret} {CANARY}\n")
                    mode = 0o755
                locked.chmod(0o000)
                # Restored even if an assertion fails, so the temporary
                # directory can still be removed.
                self.addCleanup(lambda p=locked, m=mode: p.exists() and p.chmod(m))
                if os.access(locked, os.R_OK):
                    self.skipTest("mode 000 is still readable here (running as root?), "
                                  "so the scan cannot be made to fail")
                result = self.run_guards()
                locked.chmod(mode)
                output = result.stdout + result.stderr
                self.assertNotEqual(result.returncode, 0,
                                    "the guards passed a snapshot they could not read")
                self.assertIn("guard (b)", result.stderr, "the refusal does not name the guard")
                self.assertIn("grep exit 2", output, "the refusal does not say why")
                for piece in fragments(secret) + [CANARY]:
                    self.assertFalse(piece in output, "the guard printed part of the file")

    def test_excluded_file_reference_guard(self) -> None:
        secret = "docs/experi" + "ments/" + "run-73.md"
        where = self.plant("guide/intro.md", secret)
        self.assert_redacted(self.run_guards(), secret, where, "guard (d)")


CURL = "#!/bin/sh\nprintf 200\n"


@unittest.skipUnless(PUBLISH_SITE.is_file(),
                     "Scripts/publish-site.sh is private ops tooling, excluded from "
                     "the public snapshot")
class PublishSiteGuardRedacts(Redaction, unittest.TestCase):
    FILES = ("privacy.html", "404.html", "site.css", "supporters.json", "og.png", "favicon.svg",
             "favicon-32.png", "apple-touch-icon.png", "seedbed-mark.svg",
             "seedbed-app-icon.svg")

    def setUp(self) -> None:
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        self.root = Path(tmp.name)
        (self.root / "Scripts").mkdir()
        shutil.copy2(PUBLISH_SITE, self.root / "Scripts" / "publish-site.sh")
        shutil.copy2(STAMP_SITE_ASSETS, self.root / "Scripts" / "stamp-site-assets.py")
        self.site = self.root / "site"
        (self.site / "evidence").mkdir(parents=True)
        for name in self.FILES:
            (self.site / name).write_text("\n")
        (self.site / "index.html").write_text(
            '<a href="Seedbed_1.2.3_universal.dmg">Download</a>\n')
        (self.site / "evidence" / "index.html").write_text(
            "<p>one</p>\n<p>two</p>\n<p>three</p>\n<p>four</p>\n")
        bin_dir = self.root / "bin"
        bin_dir.mkdir()
        (bin_dir / "curl").write_text(CURL)
        (bin_dir / "curl").chmod(0o755)
        # A UTF-8 locale, as in a real terminal: the binary case depends on it.
        self.env = dict(os.environ, PATH=f"{bin_dir}:{os.environ['PATH']}",
                        DRY_RUN="1", SITE_BASE="https://site.example.test",
                        LC_ALL="en_US.UTF-8", LANG="en_US.UTF-8")

    def publish(self) -> subprocess.CompletedProcess[str]:
        return subprocess.run(["bash", str(self.root / "Scripts" / "publish-site.sh")],
                              env=self.env, capture_output=True, text=True,
                              errors="replace", timeout=60, check=False)

    def test_a_clean_site_passes(self) -> None:
        result = self.publish()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("nothing uploaded", result.stdout)

    def test_an_internal_name_in_a_page_is_reported_by_line_only(self) -> None:
        secret = "a" + "i-0" + "1.lan.example"
        page = self.site / "evidence" / "index.html"
        lines = page.read_text().splitlines()
        lines[3] = f"<p>ran on {secret} {CANARY}</p>"
        page.write_text("\n".join(lines) + "\n")
        self.assert_redacted(self.publish(), secret, "site/evidence/index.html:4",
                             "names something internal")

    def test_a_hit_on_a_line_that_is_not_utf8_still_refuses(self) -> None:
        """In a UTF-8 locale macOS grep does not match such a line at all."""
        secret = "T" + "BX-" + "4404"
        (self.site / "evidence" / "index.html").write_bytes(
            b"<p>one</p>\n<p>caf\xe9 " + f"{secret} {CANARY}".encode() + b"</p>\n")
        self.assert_redacted(self.publish(), secret, "site/evidence/index.html:2",
                             "names something internal")

    def test_an_internal_address_in_a_binary_is_reported_by_line_only(self) -> None:
        """Binaries are scanned too, and must not print a `matches` notice or bytes."""
        secret = "192." + "168." + "9.14"
        (self.site / "og.png").write_bytes(
            b"\x89PNG\r\n\x00\x01" + f"{secret} {CANARY}".encode() + b"\x00\xff")
        self.assert_redacted(self.publish(), secret, "site/og.png:2", "names something internal")



@unittest.skipUnless(PURGE_HISTORY.is_file(),
                     "Scripts/purge-public-history.sh is private ops tooling, excluded "
                     "from the public snapshot")
class PurgeHistoryVerifierRedacts(unittest.TestCase):
    """The blob-content verifier, run alone against a throwaway repository.

    Only the verifier's own Python is taken out of the script and run, with the
    temporary repository as its argument, so nothing clones, rewrites or pushes.
    """

    START = 'bold "==> Verifying (1/2): blob contents"'

    def setUp(self) -> None:
        text = PURGE_HISTORY.read_text(encoding="utf-8")
        self.assertIn(self.START, text)
        after = text[text.index(self.START):]
        body_start = after.index("<<'PYTHON'")
        body_start = after.index("\n", body_start) + 1
        self.verifier = after[body_start:after.index("\nPYTHON\n", body_start)]
        self.assertIn("rev-list", self.verifier, "the verifier was not found")
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        self.tmp = Path(tmp.name)
        self.fresh_repo("repo")

    def fresh_repo(self, name: str) -> None:
        """One repository per case, so one case's blob cannot answer another's."""
        self.repo = self.tmp / name
        self.repo.mkdir()
        self.git("init", "-q", "-b", "main")

    def git(self, *args: str) -> str:
        env = dict(os.environ, GIT_CONFIG_GLOBAL=os.devnull, GIT_CONFIG_NOSYSTEM="1")
        return subprocess.run(
            ["git", "-C", str(self.repo), "-c", "user.name=t", "-c",
             "user.email=t@example.test", "-c", "commit.gpgsign=false", *args],
            env=env, capture_output=True, text=True, check=True).stdout.strip()

    def commit(self, rel: str, body: str | bytes) -> str:
        path = self.repo / rel
        path.parent.mkdir(parents=True, exist_ok=True)
        if isinstance(body, bytes):
            path.write_bytes(body)
        else:
            path.write_text(body)
        self.git("add", rel)
        self.git("commit", "-q", "-m", "change")
        return self.git("rev-parse", f"HEAD:{rel}")

    def verify(self) -> subprocess.CompletedProcess[str]:
        return subprocess.run(["python3", "-", str(self.repo)], input=self.verifier,
                              capture_output=True, text=True, errors="replace",
                              timeout=60, check=False)

    def test_a_clean_history_passes(self) -> None:
        self.commit("README.md", "A prompt library.\n")
        result = self.verify()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_a_hit_in_history_names_pattern_and_blob_only(self) -> None:
        """Planted in a dead revision, so only the history carries it."""
        cases = {
            "credential": "AK" + "IA" + "R4TX8N2QW7" + "LM",
            "tracker-id": "T" + "BX-" + "60412",
        }
        for name, secret in cases.items():
            with self.subTest(pattern=name):
                self.fresh_repo(name)
                self.commit("README.md", "A prompt library.\n")
                sha = self.commit("docs/notes.md", f"see {secret} {CANARY}\n")
                self.commit("docs/notes.md", "nothing here now\n")
                result = self.verify()
                output = result.stdout + result.stderr
                self.assertNotEqual(result.returncode, 0,
                                    f"the verifier passed a planted hit\n{output}")
                self.assertIn(f"{name}: {sha}", output,
                              "the report does not name the pattern and blob")
                # assertFalse, not assertNotIn: a failure message must not
                # repeat the output it is refusing.
                for piece in fragments(secret) + [CANARY]:
                    self.assertFalse(piece in output,
                                     "the verifier printed part of what it matched")

    def test_a_hit_inside_a_binary_blob_in_history_is_reported(self) -> None:
        """A NUL byte does not excuse a blob from the scan.

        The verifier once skipped any blob with a NUL near its start, and the
        path scan only checks a fixed list of names, so a key stored after a
        NUL anywhere in history was certified clean. The report is still the
        pattern and the blob sha, never the bytes around the hit.
        """
        cases = {
            "credential": "AK" + "IA" + "W3PZ7K5QN2" + "RD",
            "tracker-id": "T" + "BX-" + "51923",
            "personal-path": "/Us" + "ers/" + "anat" + "oli",
        }
        for name, secret in cases.items():
            with self.subTest(pattern=name):
                self.fresh_repo(f"binary-{name}")
                self.commit("README.md", "A prompt library.\n")
                body = (b"\x89PNG\r\n\x1a\n\x00\x00\x00\x0d" + b"\x00" * 64
                        + f"{secret} {CANARY}".encode() + b"\x00\xff\xfe")
                sha = self.commit("assets/art.png", body)
                self.commit("assets/art.png", b"\x89PNG\r\n\x1a\n\x00\x00")
                result = self.verify()
                output = result.stdout + result.stderr
                self.assertNotEqual(result.returncode, 0,
                                    f"the verifier passed a hit in a binary\n{output}")
                self.assertIn(f"{name}: {sha}", output,
                              "the report does not name the pattern and blob")
                for piece in fragments(secret) + [CANARY]:
                    self.assertFalse(piece in output,
                                     "the verifier printed part of what it matched")

    def test_a_clean_binary_in_history_passes(self) -> None:
        """Scanning binaries must not refuse one that holds nothing."""
        self.commit("README.md", "A prompt library.\n")
        self.commit("assets/art.png", b"\x89PNG\r\n\x1a\n\x00\x01\x02\xff" * 32)
        result = self.verify()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)


if __name__ == "__main__":
    unittest.main()
