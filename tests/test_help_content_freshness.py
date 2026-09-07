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
    return len(path.read_text().split())


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
        self.assertIn(".frame(maxWidth: Tokens.Width.reading", self.info)
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
        self.assertIn('Text("Latest")', self.whats_new)
        self.assertIn(".seedbedCard(", self.whats_new)

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
        self.assertIn(".foregroundStyle(Tokens.accent)", section_header.group("body"))
        self.assertIn(
            ".foregroundStyle(index == 0 ? Tokens.accent : Color.primary)",
            self.whats_new,
        )


if __name__ == "__main__":
    unittest.main()
