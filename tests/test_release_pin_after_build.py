"""The release gate accepts HEAD = build commit + the release pin, and no more.

release.sh builds at one commit, then rewrites Casks/seedbed.rb and
site/index.html, and tells the operator to commit those before tagging so the
tag contains its own pin. check-release.sh (which publish.sh re-runs) compared
the bundle's recorded commit with HEAD exactly, so following that instruction
made publish.sh refuse the release. 0.1.17 shipped only because publish ran
before the pin was committed, an order nothing documented.

`Scripts/support/pin_only_since.py` is the narrow way through, exercised here
against a throwaway repository.
"""

from __future__ import annotations

import subprocess
import tempfile
import unittest
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
HELPER = REPO / "macos" / "Scripts" / "support" / "pin_only_since.py"
GATE = REPO / "macos" / "Scripts" / "check-release.sh"


@unittest.skipUnless(HELPER.exists(), "pin_only_since.py is not in this checkout")
class OnlyThePinMayFollowTheBuild(unittest.TestCase):
    def setUp(self) -> None:
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        self.repo = Path(tmp.name)
        self.git("init", "-q", "-b", "main")
        self.git("config", "user.email", "test@example.invalid")
        self.git("config", "user.name", "test")
        self.git("config", "commit.gpgsign", "false")
        self.write("Casks/seedbed.rb", 'version "0.1.0,1"\n')
        self.write("site/index.html", "<a href=Seedbed_0.1.0_universal.dmg>\n")
        self.write("macos/Sources/Seedbed/App.swift", "// app\n")
        self.build = self.commit("build")

    def git(self, *args: str) -> str:
        return subprocess.run(["git", "-C", str(self.repo), *args], check=True,
                              capture_output=True, text=True).stdout.strip()

    def write(self, path: str, text: str) -> None:
        target = self.repo / path
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_text(text)

    def commit(self, message: str) -> str:
        self.git("add", "-A")
        self.git("commit", "-q", "-m", message)
        return self.git("rev-parse", "HEAD")

    def check(self, head: str, build: str | None = None) -> subprocess.CompletedProcess[str]:
        return subprocess.run(
            ["python3", str(HELPER), str(self.repo), build or self.build, head],
            capture_output=True, text=True, check=False)

    def pin(self) -> str:
        self.write("Casks/seedbed.rb", 'version "0.1.1,2"\n')
        self.write("site/index.html", "<a href=Seedbed_0.1.1_universal.dmg>\n")
        return self.commit("Point cask and site at 0.1.1")

    def test_the_build_commit_itself_passes(self) -> None:
        self.assertEqual(self.check(self.build).returncode, 0)

    def test_the_pin_committed_on_top_passes(self) -> None:
        """The case that used to refuse: the pin committed as release.sh says."""
        result = self.check(self.pin())
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_the_pin_merged_through_a_pr_passes(self) -> None:
        """How the pin actually lands here: a merge commit on main."""
        self.git("checkout", "-q", "-b", "release")
        self.pin()
        self.git("checkout", "-q", "main")
        self.git("merge", "-q", "--no-ff", "-m", "Merge release", "release")
        result = self.check(self.git("rev-parse", "HEAD"))
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_a_source_change_after_the_build_is_refused(self) -> None:
        self.pin()
        self.write("macos/Sources/Seedbed/App.swift", "// changed after the build\n")
        result = self.check(self.commit("sneak in a change"))
        self.assertEqual(result.returncode, 1)
        self.assertIn("macos/Sources/Seedbed/App.swift", result.stderr)

    def test_any_other_file_is_refused_too(self) -> None:
        self.write("README.md", "new\n")
        result = self.check(self.commit("docs"))
        self.assertEqual(result.returncode, 1)
        self.assertIn("README.md", result.stderr)

    def test_a_head_that_does_not_descend_from_the_build_is_refused(self) -> None:
        self.git("checkout", "-q", "--orphan", "elsewhere")
        self.write("Casks/seedbed.rb", 'version "9,9"\n')
        result = self.check(self.commit("unrelated"))
        self.assertEqual(result.returncode, 1)
        self.assertIn("does not descend", result.stderr)

    def test_a_build_commit_that_does_not_exist_is_refused(self) -> None:
        result = self.check(self.build, build="0" * 40)
        self.assertEqual(result.returncode, 1)


@unittest.skipUnless(GATE.exists(), "check-release.sh is not in this checkout")
class TheGateUsesIt(unittest.TestCase):
    def setUp(self) -> None:
        self.source = GATE.read_text()

    def test_the_head_check_consults_the_helper(self) -> None:
        self.assertIn("Scripts/support/pin_only_since.py", self.source)

    def test_the_reporting_check_expects_the_recorded_commit_not_head(self) -> None:
        """Otherwise the pin commit passes one check and fails the next."""
        self.assertIn('EXPECTED_RELEASE="net.amnesia.seedbed@$BUILD_COMMIT"', self.source)
        self.assertNotIn('EXPECTED_RELEASE="net.amnesia.seedbed@$(git rev-parse HEAD)"',
                         self.source)


if __name__ == "__main__":
    unittest.main()
