"""Printing the release summary must not RUN anything.

`release.sh` ends with `cat <<SUMMARY ... SUMMARY`. The delimiter is unquoted
because the text interpolates `$VERSION` and `$BUILD_NUM` — and in an unquoted
heredoc a backtick is not markup, it is command substitution.

This is not hypothetical. The 0.1.5 release on 2026-09-06 shipped with a line
reading ```brew install --cask seedbed` keeps offering the PREVIOUS release``,
written that way out of Markdown habit. The release ran it. The summary came out
interleaved with *"Downloading Homebrew API data"* and *"Searching for similarly
named casks"*, which is what a `brew install` prints, and the sentence itself was
mangled around the command's output. It was harmless only because the tap is not
published yet, so brew found nothing to install; once it is, a release would
install the app onto the release machine as a side effect of describing itself.

The general rule is worth stating because the next person will reach for
backticks too: **a message is data, and a heredoc that expands is code.** So the
summary may contain exactly the substitutions it is meant to, and nothing else.
"""

from __future__ import annotations

import re
import unittest
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
RELEASE = REPO / "macos" / "Scripts" / "release.sh"

#: `$(...)` calls the summary is allowed to make. Each is there to compute part
#: of the message and is listed so a new one is a deliberate act.
ALLOWED_SUBSTITUTIONS = {'$(basename "$DMG")'}


def summary_block(text: str) -> str:
    match = re.search(r"^cat <<(\w+)$\n(.*?)^\1$", text, re.M | re.S)
    if match is None:
        raise AssertionError(
            "release.sh no longer ends with a `cat <<DELIM ... DELIM` summary; "
            "this test is now blind and must be updated rather than deleted")
    return match.group(2)


class ReleaseSummaryIsInert(unittest.TestCase):
    def setUp(self) -> None:
        self.summary = summary_block(RELEASE.read_text())

    def test_the_block_was_actually_found(self) -> None:
        """A parse that finds nothing would pass every check below."""
        self.assertIn("Built:", self.summary,
                      "the parsed block does not look like the release summary")

    def test_no_backticks(self) -> None:
        """The exact 0.1.5 defect: Markdown habit meeting an unquoted heredoc."""
        offenders = [line for line in self.summary.splitlines() if "`" in line]
        self.assertEqual(
            offenders, [],
            "backticks in the summary heredoc are COMMAND SUBSTITUTION, not "
            f"formatting, and these lines would execute: {offenders}. Write the "
            "command as plain text, or quote the heredoc delimiter and give up "
            "the $VERSION interpolation.")

    def test_no_unexpected_command_substitution(self) -> None:
        found = set(re.findall(r"\$\([^)]*\)", self.summary))
        unexpected = sorted(found - ALLOWED_SUBSTITUTIONS)
        self.assertEqual(
            unexpected, [],
            f"the summary would run {unexpected}. Add it to "
            "ALLOWED_SUBSTITUTIONS if it is deliberate.")


if __name__ == "__main__":
    unittest.main()
