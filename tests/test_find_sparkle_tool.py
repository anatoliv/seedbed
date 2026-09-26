"""release.sh finds Sparkle's tools without dying silently on the way.

It used to run `find … "$HOME/Projects" … | head -1` under `set -euo pipefail`.
find exits non-zero when a directory it walks is unreadable or vanishes, even
after it has found the file, so the 0.1.18 release stopped straight after
"Using the only saved notarytool profile" with no error while worktrees were
being removed. `macos/Scripts/support/find-sparkle-tool.sh` does the search and
ignores find's status; only whether a path came back counts.

An unreadable directory stands in for a vanished one: find reports both the
same way, and only the first can be staged reliably in a test.
"""

from __future__ import annotations

import os
import subprocess
import tempfile
import unittest
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
HELPER = REPO / "macos" / "Scripts" / "support" / "find-sparkle-tool.sh"
RELEASE = REPO / "macos" / "Scripts" / "release.sh"


@unittest.skipUnless(HELPER.exists(), "find-sparkle-tool.sh is not in this checkout")
class TheSearchSurvivesWhatUsedToKillIt(unittest.TestCase):
    def setUp(self) -> None:
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        self.home = Path(tmp.name) / "home"
        self.work = Path(tmp.name) / "work"
        self.work.mkdir(parents=True)
        self.locked: list[Path] = []
        self.addCleanup(self.unlock)

    def unlock(self) -> None:
        for path in self.locked:
            path.chmod(0o755)

    def tool(self, root: Path, name: str = "generate_keys") -> Path:
        path = root / "artifacts" / "Sparkle" / "bin" / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text("#!/bin/sh\n")
        path.chmod(0o755)
        return path

    def lock(self, path: Path) -> None:
        path.mkdir(parents=True, exist_ok=True)
        path.chmod(0)
        self.locked.append(path)

    def run_bash(self, script: str) -> subprocess.CompletedProcess[str]:
        env = dict(os.environ, HOME=str(self.home))
        return subprocess.run(["bash", "-c", script], cwd=self.work, env=env,
                              capture_output=True, text=True, check=False)

    def test_an_unreadable_directory_does_not_end_a_strict_script(self) -> None:
        """The 0.1.18 failure, reproduced: strict mode, a directory find cannot read."""
        self.lock(self.home / "Library" / "Developer" / "AAA-locked")
        found = self.tool(self.home / "Library" / "Developer" / "ZZZ")
        result = self.run_bash(
            f'set -euo pipefail; GK="$("{HELPER}" generate_keys || true)"; echo "got=$GK"')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn(f"got={found}", result.stdout)

    def test_the_old_pipeline_really_did_die_here(self) -> None:
        """Guards the test above against passing for the wrong reason."""
        self.lock(self.home / "Library" / "Developer" / "AAA-locked")
        self.tool(self.home / "Library" / "Developer" / "ZZZ")
        result = self.run_bash(
            'set -euo pipefail; GK="$(find "$HOME/Library/Developer" -type f '
            '-name generate_keys -path "*Sparkle*" 2>/dev/null | head -1)"; echo reached')
        self.assertNotIn("reached", result.stdout)

    def test_this_packages_build_wins_over_other_apps_caches(self) -> None:
        self.tool(self.home / "Library" / "Developer" / "OtherApp")
        own = self.tool(self.work / ".build")
        result = self.run_bash(f'"{HELPER}" generate_keys')
        self.assertEqual(result.stdout.strip(), "./.build/" + str(own.relative_to(self.work / ".build")))

    def test_projects_is_searched_last_but_still_searched(self) -> None:
        found = self.tool(self.home / "Projects" / "someapp" / ".build", "generate_appcast")
        result = self.run_bash(f'"{HELPER}" generate_appcast')
        self.assertEqual(result.returncode, 0)
        self.assertEqual(result.stdout.strip(), str(found))

    def test_nothing_found_is_a_quiet_miss_the_caller_can_handle(self) -> None:
        self.home.mkdir()
        result = self.run_bash(
            f'set -euo pipefail; GA="$("{HELPER}" generate_appcast || true)"; echo "got=[$GA]"')
        self.assertIn("got=[]", result.stdout)

    def test_a_non_executable_match_is_skipped(self) -> None:
        path = self.tool(self.home / "Library" / "Developer" / "X")
        path.chmod(0o644)
        self.assertEqual(self.run_bash(f'"{HELPER}" generate_keys').returncode, 1)

    def test_only_sparkles_tools_can_be_asked_for(self) -> None:
        self.assertEqual(self.run_bash(f'"{HELPER}" rm').returncode, 64)


@unittest.skipUnless(RELEASE.exists(), "release.sh is not in this checkout")
class ReleaseUsesTheHelperForBothTools(unittest.TestCase):
    def setUp(self) -> None:
        self.source = RELEASE.read_text()

    def test_both_searches_go_through_the_helper(self) -> None:
        self.assertIn('GK_BIN="${GK_BIN:-$(Scripts/support/find-sparkle-tool.sh generate_keys || true)}"',
                      self.source)
        self.assertIn('GA_BIN="${GA_BIN:-$(Scripts/support/find-sparkle-tool.sh generate_appcast || true)}"',
                      self.source)

    def test_no_raw_find_over_projects_remains(self) -> None:
        self.assertNotIn('"$HOME/Projects" -type f', self.source)


if __name__ == "__main__":
    unittest.main()
