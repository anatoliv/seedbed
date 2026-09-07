"""The local web UI follows Reference's browser design adapter."""

import hashlib
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
PAGE = ROOT / "promptlib" / "web" / "index.html"
SERVER = ROOT / "promptlib" / "server.py"
FONTS = ROOT / "promptlib" / "web" / "fonts"
FONT_SHA256 = {
    "InterVariable.ttf": "746431e950fd28d29b0189d708d4a5852a8458edb3184387eadcee9e5e34676c",
    "JetBrainsMono.ttf": "662a196d58f1183bf2d77428b6d5283fe3f45161ab021bea4036bc98e5cac016",
    "Inter-LICENSE.txt": "262481e844521b326f5ecd053e59b98c8b2da78c8ee1bdbb6e8174305e54935a",
    "JetBrainsMono-LICENSE.txt": "60d55f23c6ce05a81099a762cb67ca2c9b6ea251c7912720998b4c89ebfd4faa",
}


class WebDesignParity(unittest.TestCase):
    def test_reference_fonts_are_bundled_and_served(self) -> None:
        page = PAGE.read_text()
        server = SERVER.read_text()
        for name in ("InterVariable.ttf", "JetBrainsMono.ttf"):
            self.assertTrue((FONTS / name).is_file())
            self.assertIn(f"/fonts/{name}", page)
            self.assertIn(f'"/fonts/{name}"', server)
        for name in ("Inter-LICENSE.txt", "JetBrainsMono-LICENSE.txt"):
            self.assertTrue((FONTS / name).is_file())
        for name, expected in FONT_SHA256.items():
            actual = hashlib.sha256((FONTS / name).read_bytes()).hexdigest()
            self.assertEqual(actual, expected, name)

    def test_paper_and_midnight_palettes_match_reference_web_tokens(self) -> None:
        page = "".join(PAGE.read_text().split()).lower()
        for declaration in (
            "--bg:#f8f6f2", "--sunken:#f2f0ea", "--card:#fffdf9",
            "--ink:#3a3a35", "--accent:#e07a4b", "--bg:#0d0e11",
            "--sunken:#08080a", "--card:#1c1c20", "--ink:#e8eaec",
        ):
            self.assertIn(declaration, page)

    def test_geometry_and_accessibility_contracts_are_present(self) -> None:
        page = "".join(PAGE.read_text().split()).lower()
        for declaration in (
            "--r-chip:4px", "--r-button:6px", "--r-card:8px", "--r-sheet:12px",
            "font-feature-settings:'tnum','cv11'", "prefers-reduced-motion:reduce",
        ):
            self.assertIn(declaration, page)

    def test_visual_qa_can_force_either_palette_without_changing_the_default(self) -> None:
        page = "".join(PAGE.read_text().split()).lower()
        self.assertIn('newurlsearchparams(location.search).get("appearance")', page)
        self.assertIn('requestedappearance==="dark"||requestedappearance==="light"', page)
        self.assertIn(':root:not([data-appearance="light"])', page)
        self.assertIn(':root[data-appearance="dark"]', page)


if __name__ == "__main__":
    unittest.main()
