"""The design document names the complete current token surface."""

from __future__ import annotations

import re
import sys
import unittest
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
THEME = REPO / "macos" / "Sources" / "Seedbed" / "Theme.swift"
DOC = REPO / "docs" / "design" / "DESIGN_SYSTEM.md"

sys.path.insert(0, str(REPO / "macos" / "Scripts" / "support"))
import tokens as token_tool  # noqa: E402

GROUPS = (
    "Tokens", "Surface", "Fill", "FontScale", "Rounded", "Space",
    "Radius", "ChipPadding", "IconSize", "Elevation", "Motion",
    "Width", "Size",
)
UNGROUPED = ("searchInputBackground", "searchInputBorder")
COMPUTED = {"Width": ("paged",), "Size": ("info",)}


class DesignDocNamesEveryToken(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.theme = THEME.read_text()
        cls.doc = DOC.read_text()
        cls.spec = token_tool.spec(THEME)
        for group, members in COMPUTED.items():
            for member in members:
                pattern = rf"static var {member}[^\n]*\{{"
                if re.search(pattern, cls.theme):
                    cls.spec[group][member] = "<computed>"

    def test_both_files_are_where_this_test_thinks(self) -> None:
        self.assertTrue(THEME.exists())
        self.assertTrue(DOC.exists())

    def test_every_expected_group_was_parsed(self) -> None:
        for group in GROUPS:
            with self.subTest(group=group):
                self.assertIn(group, self.spec)
                self.assertTrue(self.spec[group])

    def test_every_token_in_code_is_named_in_the_document(self) -> None:
        missing = []
        for group in GROUPS:
            for member in self.spec[group]:
                label = member if group == "Tokens" else f"{group}.{member}"
                if f"`{label}`" not in self.doc:
                    missing.append(label)
        for member in UNGROUPED:
            if f"`{member}`" not in self.doc:
                missing.append(member)
        self.assertEqual(missing, [])

    def test_the_document_names_no_removed_group_token(self) -> None:
        stale = []
        for group, member in re.findall(r"`(\w+)\.(\w+)`", self.doc):
            if group in GROUPS and member not in self.spec[group]:
                stale.append(f"{group}.{member}")
        self.assertEqual(sorted(set(stale)), [])

    def test_source_of_truth_and_extraction_date_are_recorded(self) -> None:
        flat = " ".join(self.doc.split())
        self.assertIn("is the source of truth", flat)
        self.assertIn("the code is right and this document is stale", flat)
        self.assertRegex(self.doc, r"extracted from it on \*\*\d{4}-\d{2}-\d{2}\*\*")

    def test_reference_is_the_named_reference(self) -> None:
        self.assertIn("Reference", self.doc)
        self.assertIn("reference-tokens.json", self.doc)
        # The doc used to attribute the visual language to another project by
        # name. `tests/test_no_sibling_projects.py` now forbids that repo-wide,
        # so this only has to check the positive: the contract names itself.


if __name__ == "__main__":
    unittest.main()
