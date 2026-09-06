"""`publish-repo.sh` must refuse to publish a working tree it was not shown.

The script rsyncs the **working tree**, not `HEAD`. So whatever is on disk at
the moment it runs is what becomes public, and a public snapshot is fetched,
cached and mirrored by strangers within minutes with no way to recall it.

On 2026-09-06 a second agent session was editing this repo at the same time:
twelve files modified at 12:45 against a last commit of 09:55. A publish four
minutes earlier would have pushed that mid-edit state. Nothing in the script
required a clean tree — while `macos/Scripts/release.sh` already refuses a dirty
tree before tagging, for precisely the same reason. It was caught by a
`git status` run out of habit, which is not a control.

**This test is skipped in the public mirror, deliberately and visibly.**
`Scripts/publish-repo.sh` is private ops tooling and is excluded from the
snapshot, but `tests/` is published and the snapshot runs its own preflight. A
test that asserted the file exists would fail there — the same shape as a guard
aimed at a path that does not exist, one repository over. So absence is a skip
with a reason, and everything else is checked.
"""

from __future__ import annotations

import re
import unittest
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
PUBLISH = REPO / "Scripts" / "publish-repo.sh"


@unittest.skipUnless(
    PUBLISH.exists(),
    "Scripts/publish-repo.sh is private ops tooling, excluded from the public "
    "snapshot; this check only applies where the script exists")
class PublishRefusesADirtyTree(unittest.TestCase):
    def setUp(self) -> None:
        self.source = PUBLISH.read_text()

    def test_there_is_a_clean_tree_check(self) -> None:
        self.assertIn(
            "git -C \"$SRC\" status --porcelain", self.source,
            "nothing in publish-repo.sh inspects the working tree, so a "
            "concurrent edit would be published")

    def test_it_runs_before_the_rsync(self) -> None:
        """A check after the sync is a check that has already published."""
        sync = self.source.index("rsync -a --delete")
        checks = [m.start() for m in re.finditer(r"require_clean_tree ", self.source)]
        self.assertTrue(checks, "require_clean_tree is never called")
        self.assertTrue(
            any(pos < sync for pos in checks),
            "every clean-tree check happens after the rsync, by which point the "
            "snapshot already contains the uncommitted work")

    def test_it_is_checked_again_immediately_before_the_sync(self) -> None:
        """The gap between a start-up check and the rsync is the race.

        Another session writes during exactly that window, which is how this
        was found in the first place.
        """
        sync = self.source.index("rsync -a --delete")
        window = self.source[:sync]
        last_check = window.rfind("require_clean_tree ")
        self.assertGreater(last_check, -1)
        between = window[last_check:]
        self.assertLess(
            between.count("\n"), 4,
            "the last clean-tree check is not adjacent to the rsync; the lines "
            "between them are a window for a concurrent session to write")

    def test_the_override_exists_and_is_loud(self) -> None:
        """Refusing outright with no escape hatch gets the guard deleted."""
        self.assertIn("ALLOW_DIRTY", self.source)
        self.assertIn("WARNING: ALLOW_DIRTY=1", self.source,
                      "the override must announce itself; a silent one is "
                      "indistinguishable from no guard")

    def test_the_refusal_says_why_it_matters(self) -> None:
        self.assertIn("PUBLIC", self.source,
                      "the message must say the changes would go public, which "
                      "is the fact that makes this worth stopping for")


if __name__ == "__main__":
    unittest.main()
