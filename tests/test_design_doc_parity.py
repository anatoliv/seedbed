"""`DESIGN_SYSTEM.md` must name every token that exists, and no token that does not.

The document's first rule is that `Theme.swift` is the source of truth and the
tables were extracted from it. **That rule was broken twice on the day the
document was written**, both times by a card landing new tokens hours later:

- One card added `Space.pane`, `Space.field`, `Width.list`,
  `Width.librarySidebar` and the whole `Tokens.Size` group. Caught by an audit.
- Another added `Size.settings` six minutes after the first fix was published.
  Caught by a second audit.

Both were found by a person reading two files side by side, which is not a thing
that scales or repeats. The document itself says so, in "Which artifact wins":
*a table nothing verifies goes stale in hours*. This is the verification.

It is a text comparison, not a semantic one. It cannot tell you the document
DESCRIBES a token correctly, only that the token is mentioned at all, and that
nothing is mentioned which no longer exists. That is deliberately the cheap half:
it is the half that failed twice, and it costs nothing to run.

`tests/test_theme_contrast.py` is the sibling that checks the colour VALUES.
Between them, a token cannot silently appear, disappear, or drift its contrast.
Nothing checks the space, width and size VALUES against the document's tables;
that gap is named in the document under "What is not in here yet".
"""

from __future__ import annotations

import re
import unittest
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
THEME = REPO / "macos" / "Sources" / "Seedbed" / "Theme.swift"
DOC = REPO / "docs" / "design" / "DESIGN_SYSTEM.md"

#: Token groups the document is expected to tabulate, as `enum <Name>` blocks
#: inside `Tokens`. `Motion` is included: it has a table too.
GROUPS = ("Radius", "CompactSize", "Space", "Width", "Size", "Motion", "OnTint")

#: Declarations that are machinery rather than design tokens, so the document
#: has no table row for them. Each one is listed with why, because an unexplained
#: exclusion here is how a real token goes missing.
NOT_TOKENS = {
    # The escape hatch that builds the OnTint pair, described in prose under
    # "The third rung" rather than tabulated as a value.
    "adaptive",
    # Row-action geometry lives in PromptRowActions.swift, not in Tokens, so
    # this test never sees it. Its own section in the document is therefore
    # UNGUARDED: `maxCount` and `gutter` were removed from the code on
    # 2026-09-05 and the document's table had to be corrected by
    # hand, because nothing here could notice. Named so the blind spot is a
    # known one.
    "button", "spacing",
    # A terse alias for `accent`, not a token in its own right.
    "promptAccent",
}


def theme_source() -> str:
    return THEME.read_text(encoding="utf-8")


def doc_source() -> str:
    return DOC.read_text(encoding="utf-8")


def group_members(source: str, group: str) -> set[str]:
    """Every `static let`/`static var` declared inside `enum <group> { ... }`."""
    match = re.search(rf"enum {group} \{{(.*?)\n    \}}", source, re.S)
    if not match:
        return set()
    return set(re.findall(r"static (?:let|var) (\w+)", match.group(1)))


def top_level_colours(source: str) -> set[str]:
    """The palette tokens declared directly on `Tokens`, not inside a group."""
    return set(re.findall(r"static let (\w+) = Color\(red:", source))


class DesignDocNamesEveryToken(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.theme = theme_source()
        cls.doc = doc_source()

    def test_both_files_are_where_this_test_thinks(self):
        """A moved file must fail loudly rather than make every check vacuous."""
        self.assertTrue(THEME.exists(), f"{THEME} is missing")
        self.assertTrue(DOC.exists(), f"{DOC} is missing")

    def test_the_groups_were_actually_found(self):
        """Guards against a parse that finds nothing and therefore passes.

        This is not hypothetical. The first version of the `OnTint` parser in
        `test_theme_contrast.py` silently missed one entry, and only a coverage
        assertion caught it.
        """
        for group in GROUPS:
            with self.subTest(group=group):
                self.assertTrue(
                    group_members(self.theme, group),
                    f"no members parsed out of `enum {group}`; the declaration "
                    "shape changed and this test is now blind to that group")
        self.assertTrue(top_level_colours(self.theme), "no colour tokens parsed")

    def test_every_token_in_the_code_is_named_in_the_document(self):
        """The failure that has happened twice: a card lands a token, the doc lags."""
        missing = []
        for group in GROUPS:
            for member in sorted(group_members(self.theme, group)):
                if member in NOT_TOKENS:
                    continue
                if f"`{group}.{member}`" not in self.doc:
                    missing.append(f"{group}.{member}")
        for colour in sorted(top_level_colours(self.theme)):
            if colour in NOT_TOKENS:
                continue
            if f"`{colour}`" not in self.doc:
                missing.append(colour)
        self.assertEqual(
            missing, [],
            "these tokens exist in Theme.swift and are not named in "
            f"DESIGN_SYSTEM.md: {missing}. Add them to the right table, with "
            "what each is FOR rather than what it is. If one is genuinely not a "
            "design token, add it to NOT_TOKENS with the reason.")

    def test_the_document_names_no_token_that_no_longer_exists(self):
        """The other direction: a removed token leaving a row behind.

        A document describing a token nobody can use is worse than one missing a
        token, because the reader has no way to tell.
        """
        stale = []
        for group, member in re.findall(r"`(\w+)\.(\w+)`", self.doc):
            if group not in GROUPS:
                continue
            if member not in group_members(self.theme, group):
                stale.append(f"{group}.{member}")
        self.assertEqual(
            sorted(set(stale)), [],
            f"DESIGN_SYSTEM.md names tokens that are not in Theme.swift: "
            f"{sorted(set(stale))}. The code wins; fix the document.")

    def test_the_source_of_truth_sentence_is_still_there(self):
        """The one sentence the whole document exists to carry.

        Matched against whitespace-collapsed text, because the document is
        hard-wrapped and a sentence that happens to break across two lines is
        still the sentence.
        """
        flat = " ".join(self.doc.split())
        self.assertIn("is the source of truth", flat)
        self.assertIn("the code is right and this document is stale", flat)

    def test_the_document_says_when_it_was_extracted(self):
        """A dateless table cannot be judged stale, which is the point of dating it."""
        self.assertRegex(
            self.doc, r"extracted from it on \*\*\d{4}-\d{2}-\d{2}\*\*",
            "the extraction date is missing or reworded; a table with no date "
            "cannot be told apart from one that was never checked")


if __name__ == "__main__":
    unittest.main()
