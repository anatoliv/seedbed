"""Hold Seedbed's shared visual vocabulary to Reference token-for-token.

Reference is the requested reference for Seedbed's design, typography, palette,
spacing, geometry, and motion. Its token snapshot is vendored so the public
Seedbed repository remains self-contained and source changes arrive as an
explicit, reviewable diff. Refresh it with
`macos/Scripts/refresh-reference-spec.sh`.
"""

from __future__ import annotations

import json
import re
import sys
import unittest
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
SPEC = REPO / "macos" / "Design" / "reference-tokens.json"
THEME = REPO / "macos" / "Sources" / "Seedbed" / "Theme.swift"
SOURCES = THEME.parent

sys.path.insert(0, str(REPO / "macos" / "Scripts" / "support"))
import tokens as token_tool  # noqa: E402

SHARED = (
    "Tokens", "Surface", "Fill", "FontScale", "Rounded", "Space",
    "Radius", "ChipPadding", "IconSize", "Elevation", "Motion",
)


def normalize(group: str, values: dict[str, str]) -> dict[str, str]:
    """Ignore only the product-qualified spelling of the accent alias."""
    if group != "Fill":
        return values
    return {key: value.replace("promptAccent", "referenceAccent")
            for key, value in values.items()}


class ReferenceParity(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.spec = json.loads(SPEC.read_text())
        cls.ours = token_tool.spec(THEME)

    def test_the_snapshot_covers_every_shared_group(self) -> None:
        self.assertEqual(set(self.spec), set(SHARED))

    def test_shared_groups_agree_token_for_token(self) -> None:
        for group in SHARED:
            with self.subTest(group=group):
                self.assertIn(group, self.ours, f"Seedbed has no {group} group")
                self.assertEqual(
                    normalize(group, self.ours[group]),
                    normalize(group, self.spec[group]),
                    f"{group} differs from Reference; match it or make the "
                    "product-specific reason explicit in this test",
                )

    def test_seedbed_has_no_parallel_compact_type_scale(self) -> None:
        self.assertNotIn("CompactSize", self.ours)
        offenders = []
        for source in sorted(SOURCES.rglob("*.swift")):
            for number, line in enumerate(source.read_text().splitlines(), 1):
                if "Tokens.CompactSize" in line or "Tokens.ReadingSize" in line:
                    offenders.append(f"{source.relative_to(REPO)}:{number}")
        self.assertEqual(offenders, [])

    def test_views_use_fixed_named_typography_roles(self) -> None:
        semantic_font = re.compile(
            r"\.font\(\.(?:largeTitle|title[23]?|headline|subheadline|body|"
            r"callout|footnote|caption2?)\b"
        )
        literal_text_size = re.compile(r"\.font\(\.system\(size:\s*\d")
        derived_mono = re.compile(
            r"Tokens\.FontScale\.[A-Za-z][A-Za-z0-9]*\.monospaced\(\)"
        )
        offenders = []
        for source in sorted(SOURCES.rglob("*.swift")):
            if source == THEME:
                continue
            for number, line in enumerate(source.read_text().splitlines(), 1):
                if (semantic_font.search(line) or literal_text_size.search(line)
                        or derived_mono.search(line)):
                    offenders.append(f"{source.relative_to(REPO)}:{number}")
        self.assertEqual(offenders, [])

    def test_shared_component_recipes_are_present(self) -> None:
        source = THEME.read_text()
        for recipe in ("SeedbedDivider", "SeedbedCard", "SeedbedChip",
                       "seedbedProminent", "searchInputBackground"):
            self.assertIn(recipe, source)

    def test_views_do_not_bypass_semantic_status_colors(self) -> None:
        raw_status_color = re.compile(
            r"Color\.(?:red|green|orange)|"
            r"foreground(?:Style|Color)\(\.(?:red|green|orange)\)|"
            r"(?:tint|fill)\(\.(?:red|green|orange)\)"
        )
        offenders = []
        for source in sorted(SOURCES.rglob("*.swift")):
            for number, line in enumerate(source.read_text().splitlines(), 1):
                if raw_status_color.search(line):
                    offenders.append(f"{source.relative_to(REPO)}:{number}")
        self.assertEqual(offenders, [])

    def test_views_use_the_shared_spacing_scale(self) -> None:
        raw_spacing = re.compile(
            r"\.padding\((?:\.[A-Za-z]+,\s*)?[2-9][0-9]*(?:\.[0-9]+)?\)|"
            r"spacing:\s*[2-9][0-9]*(?:\.[0-9]+)?"
        )
        token_arithmetic = re.compile(r"Tokens\.Space\.\w+\s*[+-]\s*[0-9]")
        offenders = []
        for source in sorted(SOURCES.rglob("*.swift")):
            for number, line in enumerate(source.read_text().splitlines(), 1):
                if raw_spacing.search(line) or token_arithmetic.search(line):
                    offenders.append(f"{source.relative_to(REPO)}:{number}")
        self.assertEqual(offenders, [])


if __name__ == "__main__":
    unittest.main()
