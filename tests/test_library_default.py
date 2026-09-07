"""Keep first-run library resolution conventional and migration-safe."""

from __future__ import annotations

import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parent.parent
LIBRARY = ROOT / "macos" / "Sources" / "Seedbed" / "Library.swift"
APP = ROOT / "macos" / "Sources" / "Seedbed" / "App.swift"
DMG_README = ROOT / "macos" / "Packaging" / "dmg-readme.txt"


class LibraryDefaultTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.library = LIBRARY.read_text()
        cls.app = APP.read_text()
        cls.install_copy = DMG_README.read_text()

    def test_first_run_points_to_the_common_application_support_library(self) -> None:
        self.assertIn("for: .applicationSupportDirectory, in: .userDomainMask", self.library)
        self.assertIn('.appendingPathComponent("Seedbed/Library"', self.library)
        resolver = self.library.split("static func resolveDefaultRoot", 1)[1]
        self.assertIn("if isLibrary(commonRoot) { return commonRoot }", resolver)
        self.assertTrue(resolver.rstrip().endswith("}"))
        self.assertIn("return commonRoot", resolver)

    def test_valid_legacy_checkout_remains_the_second_choice(self) -> None:
        resolver = self.library.split("static func resolveDefaultRoot", 1)[1]
        common = resolver.index("if isLibrary(commonRoot)")
        legacy = resolver.index("if isLibrary(legacyDefaultRoot)")
        fallback = resolver.index("return commonRoot", resolver.index("return legacyDefaultRoot"))
        self.assertLess(common, legacy)
        self.assertLess(legacy, fallback)
        self.assertIn('.appendingPathComponent("Projects/seedbed"', self.library)

    def test_an_explicit_saved_selection_still_wins(self) -> None:
        saved = self.app.index("UserDefaults.standard.string(forKey: Self.rootKey)")
        default = self.app.index("return LibraryClient.defaultRoot", saved)
        self.assertLess(saved, default)

    def test_install_instructions_clone_to_the_first_run_location(self) -> None:
        common = "$HOME/Library/Application Support/Seedbed/Library"
        self.assertIn(common, self.install_copy)
        self.assertIn("git clone", self.install_copy)
        self.assertIn("automatic fallback", self.install_copy)


if __name__ == "__main__":
    unittest.main()
