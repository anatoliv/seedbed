"""The tag a release writes must contain that release's own version pin.

`macos/Scripts/release.sh` computed its dirty-tree reading at step 0e, near the
top, and step 7 reused that value to decide whether to tag. In between, steps 5b
and 5c rewrite two tracked, version-pinned files — `Casks/seedbed.rb` (version +
sha256) and `site/index.html` (the download links). So on a tree that started
clean the variable still said "clean" at tagging time while both files sat
uncommitted, and the tag went on regardless.

Both shipped releases carry the previous version's cask because of it:

    git show v0.1.9:Casks/seedbed.rb   ->  version "0.1.8,9"
    git log --oneline -1 v0.1.9        ->  5eb48be (the tag)
    git log --oneline -1 -- Casks/seedbed.rb -> 22c0657, one commit LATER

`check-release.sh` states the attribution chain for everything shipped before
the bundle carried its own source record: the tag names a commit and the cask
commit records the sha256 of the bytes that were served. A tag written before
the cask commit breaks that chain — the sha256 lives one commit further on, and
nothing anywhere records that you have to look there. Crashbox's
`docs/client-estate.md` leans on that chain for its Cocoa rows.

The fix is to commit the version pin before anything tags it. Here the pin
cannot be computed until the DMG exists — the cask records its sha256 — so the
script cannot move the sync earlier. It refuses to tag instead, and prints the
commit-then-tag commands.

Two strengths, in the idiom of `test_notarization_wall_clock.py`. The structural
tests read the script: the stale variable must not be what step 7 consults. The
executable ones lift the tagging block out and run it against a real throwaway
repository, because a refusal that has never been seen to fire is not evidence
of anything — and because the bug being fixed was invisible to reading, which is
how it survived two releases.
"""

from __future__ import annotations

import re
import subprocess
import tempfile
import textwrap
import unittest
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
RELEASE = REPO / "macos" / "Scripts" / "release.sh"


def code(source: str) -> str:
    """The script with its comment lines removed.

    The comments above step 7 quote the old defect on purpose, so the words
    `DIRTY` and `v0.1.9` appear there and must not be mistaken for the shell
    actually consulting them.
    """
    return "\n".join(line for line in source.splitlines()
                     if not line.lstrip().startswith("#"))


def tagging_block(source: str) -> str:
    """The `if`/`elif`/`else` that decides whether to write the tag."""
    match = re.search(r"^TAG_TREE=.*?^fi$", source, re.M | re.S)
    if match is None:
        raise AssertionError(
            "the tagging step no longer starts with a TAG_TREE reading; this "
            "test is now blind and must be updated rather than deleted")
    return match.group(0)


class TheTagIsDecidedOnAFreshReading(unittest.TestCase):
    def setUp(self) -> None:
        self.source = RELEASE.read_text()
        self.code = code(self.source)

    def test_the_stale_variable_is_not_consulted_at_tagging_time(self) -> None:
        """The whole defect in one assertion."""
        block = tagging_block(self.code)
        self.assertNotIn(
            "$DIRTY", block,
            "step 7 is back to reading the step-0e DIRTY variable. That value "
            "was taken before steps 5b and 5c rewrote the cask and the site, so "
            "it says 'clean' while the pin the tag should contain is "
            "uncommitted — the shape that tagged v0.1.8 and v0.1.9 without "
            "their own cask")

    def test_the_reading_is_taken_after_the_syncs(self) -> None:
        """Order, not merely presence: a fresh read placed above the seds is
        the same stale value under a new name."""
        cask_sync = self.code.index("Scripts/sync-cask.sh")
        site_sync = self.code.index("Scripts/sync-site.sh")
        reading = self.code.index("TAG_TREE=")
        self.assertLess(cask_sync, reading,
                        "the tagging reading is taken before the cask sync")
        self.assertLess(site_sync, reading,
                        "the tagging reading is taken before the site sync")

    def test_the_reading_is_a_real_status_call(self) -> None:
        self.assertIn(
            'TAG_TREE="$(git status --porcelain 2>/dev/null)"', self.code,
            "TAG_TREE must be an actual git status; anything derived from an "
            "earlier variable inherits its staleness")

    def test_the_step_0e_reading_still_only_warns(self) -> None:
        """DIRTY keeps its one job. If it grows a second consumer, the trap is
        back regardless of what step 7 does."""
        self.assertEqual(
            self.code.count("$DIRTY"), 1,
            "DIRTY is read somewhere other than its own warning; it describes "
            "the tree before the syncs and nothing later may reuse it")

    def test_the_refusal_says_what_to_run_next(self) -> None:
        """A release path that stops without instructions is worse than one
        that never stopped: the artifacts are already built and notarized."""
        block = tagging_block(self.source)
        for fragment in ("git add Casks/seedbed.rb site/index.html",
                         "git commit -m",
                         "git tag -a v${VERSION}",
                         "git push origin v${VERSION}"):
            self.assertIn(
                fragment, block,
                f"the refusal does not tell the operator to run: {fragment}")


class TheTaggingBlockActuallyBehaves(unittest.TestCase):
    """Drive the extracted block against a real repository."""

    def run_block(self, dirty: bool) -> subprocess.CompletedProcess:
        block = tagging_block(RELEASE.read_text())
        with tempfile.TemporaryDirectory() as tmp:
            work = Path(tmp)
            script = work / "tag-step.sh"
            script.write_text(textwrap.dedent("""\
                set -uo pipefail
                VERSION=9.9.9
                BUILD_NUM=99
                """) + block + "\n")
            git = ["git", "-c", "user.email=t@t", "-c", "user.name=t"]
            subprocess.run(["git", "init", "-q", "-b", "main", str(work)],
                           check=True, capture_output=True)
            cask = work / "Casks"
            cask.mkdir()
            (cask / "seedbed.rb").write_text('  version "0.0.1,1"\n')
            subprocess.run(git + ["add", "-A"], cwd=work,
                           check=True, capture_output=True)
            subprocess.run(git + ["commit", "-qm", "seed"], cwd=work,
                           check=True, capture_output=True)
            if dirty:
                (cask / "seedbed.rb").write_text('  version "9.9.9,99"\n')
            result = subprocess.run(["bash", str(script)], cwd=work,
                                    capture_output=True, text=True)
            tags = subprocess.run(["git", "tag", "--list"], cwd=work,
                                  capture_output=True, text=True).stdout.split()
            result.tags = tags  # type: ignore[attr-defined]
            return result

    def test_a_pending_cask_pin_blocks_the_tag(self) -> None:
        """The exact v0.1.9 situation: the sync has run, nothing is committed."""
        result = self.run_block(dirty=True)
        self.assertEqual(
            result.tags, [],  # type: ignore[attr-defined]
            "v9.9.9 was tagged while the cask pinning it was uncommitted — the "
            "tag does not contain its own pin, which is the defect")
        self.assertIn("Not tagging", result.stdout)

    def test_the_refusal_names_the_uncommitted_file(self) -> None:
        """Listing the paths is what stops a blind `git add` of a tree that
        also has unrelated edits in it."""
        result = self.run_block(dirty=True)
        self.assertIn("Casks/seedbed.rb", result.stdout,
                      "the refusal does not say which files are uncommitted")

    def test_a_committed_pin_gets_its_tag(self) -> None:
        """The refusal must not be unconditional, or the operator's second step
        never writes a tag either."""
        result = self.run_block(dirty=False)
        self.assertEqual(
            result.tags, ["v9.9.9"],  # type: ignore[attr-defined]
            f"a clean tree was not tagged: {result.stdout} {result.stderr}")

    def test_the_block_survives_having_no_remote(self) -> None:
        """`git push origin` fails here, and the release is finished by then;
        it must report that rather than exit non-zero under `set -e`."""
        result = self.run_block(dirty=False)
        self.assertEqual(result.returncode, 0,
                         f"the tagging step exited {result.returncode}")
        self.assertIn("tagged locally", result.stdout)


if __name__ == "__main__":
    unittest.main()
