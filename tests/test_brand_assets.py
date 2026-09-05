"""Keep the two optical icon variants mapped to the contexts they fit."""

from __future__ import annotations

import plistlib
import struct
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parent.parent
BRAND = ROOT / "assets" / "brand"


def png_size(path: Path) -> tuple[int, int]:
    data = path.read_bytes()
    if data[:8] != b"\x89PNG\r\n\x1a\n" or data[12:16] != b"IHDR":
        raise AssertionError(f"{path} is not a PNG with an IHDR header")
    return struct.unpack(">II", data[16:24])


class BrandAssets(unittest.TestCase):
    def test_every_documented_production_asset_exists(self):
        names = {
            "seedbed-app-icon.svg",
            "seedbed-app-icon-1024.png",
            "seedbed-mark.svg",
            "seedbed-mark-512.png",
            "seedbed-favicon.svg",
            "seedbed-menu-template.svg",
            "seedbed-menu-template.png",
            "seedbed-menu-template@2x.png",
            "Seedbed.icns",
            "favicon.svg",
            "favicon-32.png",
            "apple-touch-icon.png",
        }
        self.assertEqual([], sorted(name for name in names if not (BRAND / name).is_file()))

    def test_menu_exports_are_the_native_18_point_sizes(self):
        self.assertEqual((18, 18), png_size(BRAND / "seedbed-menu-template.png"))
        self.assertEqual((36, 36), png_size(BRAND / "seedbed-menu-template@2x.png"))

    def test_app_exports_have_the_expected_container_sizes(self):
        self.assertEqual((1024, 1024), png_size(BRAND / "seedbed-app-icon-1024.png"))
        self.assertEqual((32, 32), png_size(BRAND / "favicon-32.png"))
        self.assertEqual((180, 180), png_size(BRAND / "apple-touch-icon.png"))
        self.assertEqual(b"icns", (BRAND / "Seedbed.icns").read_bytes()[:4])

    def test_browser_favicon_uses_the_single_leaf_micro_mark(self):
        self.assertEqual(
            (BRAND / "seedbed-favicon.svg").read_bytes(),
            (BRAND / "favicon.svg").read_bytes(),
        )
        self.assertNotEqual(
            (BRAND / "seedbed-app-icon.svg").read_bytes(),
            (BRAND / "favicon.svg").read_bytes(),
        )

    def test_macos_uses_the_micro_mark_as_a_template(self):
        app = (ROOT / "macos" / "Sources" / "Seedbed" / "App.swift").read_text()
        package = (ROOT / "macos" / "Scripts" / "make-app.sh").read_text()
        plist = plistlib.loads((ROOT / "macos" / "Packaging" / "Info.plist").read_bytes())

        self.assertIn('NSImage(named: "SeedbedMenuBar")', app)
        self.assertIn("isTemplate = true", app)
        self.assertIn("seedbed-menu-template.png", package)
        self.assertIn("seedbed-menu-template@2x.png", package)
        self.assertIn("Seedbed.icns", package)
        self.assertEqual("Seedbed", plist["CFBundleIconFile"])

    def test_web_uses_the_mark_and_purpose_built_favicons(self):
        page = (ROOT / "promptlib" / "web" / "index.html").read_text()
        server = (ROOT / "promptlib" / "server.py").read_text()

        for asset in ("favicon.svg", "favicon-32.png", "apple-touch-icon.png"):
            self.assertIn(f'/{asset}', page)
            self.assertIn(f'/{asset}', server)
        self.assertIn('/seedbed-mark.svg', page)
        self.assertIn('/seedbed-mark.svg', server)

    def test_concept_art_is_not_packaged_or_served(self):
        package = (ROOT / "macos" / "Scripts" / "make-app.sh").read_text()
        page = (ROOT / "promptlib" / "web" / "index.html").read_text()
        server = (ROOT / "promptlib" / "server.py").read_text()

        for shipped_surface in (package, page, server):
            self.assertNotIn("seedbed-icon-concept", shipped_surface)


if __name__ == "__main__":
    unittest.main()
