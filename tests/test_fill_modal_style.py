"""Keep prompt filling on the same crisp modal recipe as Reference."""

from __future__ import annotations

import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parent.parent
SOURCES = ROOT / "macos" / "Sources" / "Seedbed"


class FillModalStyleTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.hud = (SOURCES / "HUDView.swift").read_text()
        cls.fill = (SOURCES / "FillSheet.swift").read_text()
        cls.theme = (SOURCES / "Theme.swift").read_text()

    def test_fill_uses_an_in_window_modal_instead_of_native_sheet_chrome(self) -> None:
        self.assertIn("SeedbedModalOverlay", self.hud)
        self.assertNotIn(".sheet(item: $model.filling)", self.hud)
        self.assertIn("Color.black.opacity(0.15)", self.theme)
        self.assertIn("cornerRadius: Tokens.Radius.sheet", self.theme)
        self.assertIn("Tokens.Elevation.panel.color", self.theme)

    def test_modal_blocks_the_picker_and_focuses_the_first_value(self) -> None:
        self.assertIn(".disabled(model.filling != nil)", self.hud)
        self.assertIn(".accessibilityHidden(model.filling != nil)", self.hud)
        self.assertIn("@FocusState private var focusedName", self.fill)
        self.assertIn("focusedName = model.names.first", self.fill)
        self.assertIn(".frame(height: fieldsHeight)", self.fill)
        self.assertNotIn(".frame(maxHeight: 320)", self.fill)

    def test_chrome_background_expands_across_short_headers(self) -> None:
        chrome = self.theme.index("func chromeBar()")
        frame = self.theme.index(".frame(maxWidth: .infinity", chrome)
        background = self.theme.index(".background(Tokens.Surface.chrome)", chrome)
        self.assertLess(frame, background)


if __name__ == "__main__":
    unittest.main()
