"""Keep the three reading surfaces accurate and on the Reference recipe."""

from __future__ import annotations

import re
import tomllib
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SOURCES = ROOT / "macos" / "Sources" / "Seedbed"
MANUAL = SOURCES / "Manual.swift"
INFO = SOURCES / "InfoWindow.swift"
THEME = SOURCES / "Theme.swift"
WHATS_NEW = SOURCES / "WhatsNew.swift"
MODELS = ROOT / "models.toml"
EXAMPLE_ID = "fix-bug-and-test"
NUMBER_WORDS = {
    0: "zero", 1: "one", 2: "two", 3: "three", 4: "four", 5: "five",
    6: "six", 7: "seven", 8: "eight", 9: "nine", 10: "ten",
}


def word_count(path: Path) -> int:
    """Words in the PROMPT, which is what a copy puts on the clipboard.

    This counted the whole file until 2026-09-07, provenance frontmatter and
    all, so the manual told the user a render was 205 words when copying it
    yields 182 — and the test protected the wrong number rather than catching
    it. The README already counted the body and said the whole file reports 23
    more, so the two documents disagreed by exactly that header.

    Verified against the real thing: `promptlib copy fix-bug-and-test --model
    claude-opus-5 | wc -w` is 182.
    """
    text = path.read_text(encoding="utf-8")
    parts = text.split("+++")
    body = "+++".join(parts[2:]) if len(parts) >= 3 else text
    return len(body.split())


class HelpContentFreshness(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.manual = MANUAL.read_text()
        cls.info = INFO.read_text()
        cls.theme = THEME.read_text()
        cls.whats_new = WHATS_NEW.read_text()

    def test_manual_names_the_current_model_inventory(self) -> None:
        models = tomllib.loads(MODELS.read_text())["models"]
        self.assertIn(f"Seedbed ships with {NUMBER_WORDS[len(models)]}.", self.manual)
        for model_id in models:
            self.assertIn(model_id, self.manual)

    def test_worked_example_names_its_current_targets(self) -> None:
        prompt = (ROOT / "prompts" / f"{EXAMPLE_ID}.md").read_text()
        target_line = re.search(r'^targets = \[(.+)\]$', prompt, re.MULTILINE)
        self.assertIsNotNone(target_line)
        target_ids = re.findall(r'"([^"]+)"', target_line.group(1))
        self.assertIn(f"This one targets {NUMBER_WORDS[len(target_ids)]}:", self.manual)
        for model_id in target_ids:
            model_name = tomllib.loads(MODELS.read_text())["models"][model_id]["name"]
            self.assertIn(model_name.split(" (", 1)[0], self.manual)

    def test_worked_example_counts_match_the_rendered_files(self) -> None:
        for model_id in ("claude-opus-5", "llama-3.3-70b"):
            render = ROOT / "rendered" / model_id / f"{EXAMPLE_ID}.md"
            count = word_count(render)
            self.assertRegex(self.manual, rf"{count} words")

    def test_help_pages_use_the_reference_reading_structure(self) -> None:
        self.assertIn("maxWidth: CGFloat = Tokens.Width.reading", self.info)
        self.assertIn(".frame(maxWidth: maxWidth", self.info)
        self.assertIn("Tokens.Width.releaseNotes", self.info)
        self.assertIn("subtitle: model.page.subtitle", self.info)
        self.assertIn("Tokens.FontScale.title", self.theme)
        self.assertIn("Tokens.FontScale.small", self.theme)
        self.assertIn("ManualPage(page: .help)", (SOURCES / "InfoWindows.swift").read_text())
        self.assertIn("ManualPage(page: .faq)", (SOURCES / "FAQ.swift").read_text())

    def test_release_notes_use_reference_semantics_and_mark_the_latest(self) -> None:
        improved = re.search(
            r"case \.improved:\s+return (Tokens\.\w+)", self.whats_new
        )
        self.assertIsNotNone(improved)
        self.assertEqual(improved.group(1), "Tokens.secondaryAccent")
        self.assertIn('Text("LATEST")', self.whats_new)
        self.assertIn(".background(Tokens.positive, in: Capsule())", self.whats_new)
        self.assertIn("Color.primary.opacity(0.04)", self.whats_new)
        self.assertIn(".strokeBorder(Color.primary.opacity(0.08))", self.whats_new)
        self.assertIn("Tokens.FontScale.sectionHeader.weight(.bold)", self.whats_new)
        self.assertIn("Tokens.FontScale.small", self.whats_new)
        self.assertNotIn("DefinitionRow(detail: change.text)", self.whats_new)

    def test_whats_new_is_visible_before_the_long_guide_index(self) -> None:
        whats_new = self.info.index("row(.whatsNew)")
        start_here = self.info.index('Section("Start here")')
        guide_index = self.info.index("ForEach(Guide.categories")
        self.assertLess(whats_new, start_here)
        self.assertLess(whats_new, guide_index)
        this_build = re.search(
            r'Section\("This build"\)\s*\{(?P<body>.*?)\n\s*\}',
            self.info,
            re.DOTALL,
        )
        self.assertIsNotNone(this_build)
        self.assertIn("row(.about)", this_build.group("body"))
        self.assertNotIn("whatsNew", this_build.group("body"))

    def test_reading_pages_keep_a_visible_seedbed_brand_layer(self) -> None:
        page_header = re.search(
            r"struct PageHeader<Content: View>: View \{(?P<body>.*?)\n\}",
            self.theme,
            re.DOTALL,
        )
        section_header = re.search(
            r"struct SectionHeader: View \{(?P<body>.*?)\n\}",
            self.theme,
            re.DOTALL,
        )
        self.assertIsNotNone(page_header)
        self.assertIsNotNone(section_header)
        self.assertIn("Image(systemName: symbol)", page_header.group("body"))
        self.assertIn(".foregroundStyle(Tokens.accent)", page_header.group("body"))
        self.assertIn(".foregroundStyle(.primary)", section_header.group("body"))
        self.assertIn("page == .whatsNew ? Tokens.accent : Color.primary", self.info)

    def test_info_geometry_matches_the_reference_help_canvas(self) -> None:
        for declaration in (
            "static let reading: CGFloat = 760",
            "static let releaseNotes: CGFloat = 680",
            "static let sidebar: CGFloat = 268",
            "static let info = CGSize(width: 1040, height: 660)",
            "static let infoMin = CGSize(width: 760, height: 420)",
            "static let rowHeight: CGFloat = 22",
            "static let releaseCardGap: CGFloat = 20",
        ):
            self.assertIn(declaration, self.theme)

    def test_help_and_faq_use_the_reference_reading_hierarchy(self) -> None:
        self.assertIn("? .system(size: 20, weight: .semibold", self.theme)
        self.assertIn("Tokens.FontScale.subtitle", self.theme)
        self.assertIn("Tokens.FontScale.transcript", self.theme)
        self.assertIn(".lineSpacing(4)", self.theme)
        info_windows = (SOURCES / "InfoWindows.swift").read_text()
        manual_page = re.search(
            r"struct ManualPage: View \{(?P<body>.*?)\n\}",
            info_windows,
            re.DOTALL,
        )
        self.assertIsNotNone(manual_page)
        self.assertNotIn("SeedbedDivider()", manual_page.group("body"))


if __name__ == "__main__":
    unittest.main()
