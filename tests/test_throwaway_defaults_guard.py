"""Swift tests get isolated UserDefaults only through ThrowawayDefaults.

Until 2026-09-25 `MCPPortCollisionTests` minted `net.amnesia.seedbed.tests.<UUID>`
for every test and cleaned up with `removePersistentDomain(forName:)`. That
empties the domain and leaves the file, and `cfprefsd` writes an empty `{}`
plist back about ten seconds after the test process exits, so every run left
one plist per test in `~/Library/Preferences`: 18 of them by the time anyone
counted (the same pattern had reached 20,262 files in another app on this
machine before it was found here).

`macos/Tests/SeedbedTests/ThrowawayDefaults.swift` deletes the file at exit,
deletes it again after cfprefsd has rewritten it, and sweeps stale ones on first
use. It only works for suites it knows about, so this test refuses any other
way of making one:

- in the Swift tests, `UserDefaults(suiteName:` and `removePersistentDomain`
  appear only inside the helper;
- in the app sources, no suite name is built from a `UUID()`, since a
  production fallback that runs under XCTest leaks exactly the same way.
"""

from __future__ import annotations

import re
import unittest
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
TESTS = REPO / "macos" / "Tests"
SOURCES = REPO / "macos" / "Sources"
HELPER = TESTS / "SeedbedTests" / "ThrowawayDefaults.swift"

SUITE = re.compile(r"UserDefaults\(\s*suiteName\s*:")
CLEAR = re.compile(r"removePersistentDomain\s*\(")
UUID_SUITE = re.compile(r"suiteName\s*:[^)\n]*UUID\(\)")


def _swift_files(root: Path) -> list[Path]:
    return sorted(p for p in root.rglob("*.swift") if ".build" not in p.parts)


def _hits(files: list[Path], pattern: re.Pattern[str]) -> list[str]:
    found = []
    for path in files:
        for number, line in enumerate(path.read_text().splitlines(), 1):
            if pattern.search(line):
                found.append(f"{path.relative_to(REPO)}:{number}: {line.strip()}")
    return found


class SwiftTestDefaultsGoThroughTheHelper(unittest.TestCase):
    def setUp(self) -> None:
        if not TESTS.is_dir():
            self.skipTest("macos/Tests is not in this checkout")
        self.test_files = [p for p in _swift_files(TESTS) if p != HELPER]

    def test_the_helper_exists(self) -> None:
        self.assertTrue(HELPER.is_file(), f"{HELPER.relative_to(REPO)} is missing")

    def test_no_test_opens_a_suite_of_its_own(self) -> None:
        hits = _hits(self.test_files, SUITE)
        self.assertEqual(
            hits, [],
            "a test opened a UserDefaults suite directly, and its plist will "
            "outlive the run; use ThrowawayDefaults.make(\"label\") instead:\n"
            + "\n".join(hits))

    def test_no_test_clears_a_suite_by_hand(self) -> None:
        """removePersistentDomain is the cleanup that looks right and leaks."""
        hits = _hits(self.test_files, CLEAR)
        self.assertEqual(
            hits, [],
            "removePersistentDomain leaves the plist and cfprefsd rewrites it "
            "after exit; ThrowawayDefaults removes it for you:\n"
            + "\n".join(hits))

    def test_no_app_source_names_a_suite_with_a_uuid(self) -> None:
        if not SOURCES.is_dir():
            self.skipTest("macos/Sources is not in this checkout")
        hits = _hits(_swift_files(SOURCES), UUID_SUITE)
        self.assertEqual(
            hits, [],
            "a UUID-named suite in app code leaks one plist per call:\n"
            + "\n".join(hits))


if __name__ == "__main__":
    unittest.main()
