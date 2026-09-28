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
        self.assertIn('.appendingPathComponent("Seedbed/LibraryData"', self.library)
        resolver = self.library.split("static func resolveDefaultRoot", 1)[1]
        self.assertIn("if isLibrary(commonRoot) { return commonRoot }", resolver)
        self.assertIn("return commonRoot", resolver)

    def test_older_checkouts_are_migration_sources(self) -> None:
        resolver = self.library.split("static func resolveDefaultRoot", 1)[1]
        self.assertNotIn("if isLibrary(legacyDefaultRoot)", resolver)
        self.assertIn('.appendingPathComponent("Projects/seedbed"', self.library)
        bootstrap = (ROOT / "macos" / "Sources" / "Seedbed" /
                     "LibraryBootstrap.swift").read_text()
        self.assertIn("[previousRoot, legacyRoot].first(where: LibraryClient.isLibrary)", bootstrap)
        self.assertIn("copyDataLibrary(from: source, to: staging)", bootstrap)

    def test_an_explicit_saved_selection_is_validated_before_it_wins(self) -> None:
        saved = self.app.index("UserDefaults.standard.string(forKey: Self.rootKey)")
        recovery = self.app.index("LibraryClient.resolveUsableRoot", saved)
        default = self.app.index("return LibraryClient.defaultRoot", saved)
        self.assertLess(saved, recovery)
        self.assertLess(recovery, default)

    def test_every_library_command_recovers_before_reading_or_writing(self) -> None:
        run = self.library.split("private func run", 1)[1]
        self.assertIn("let usableRoot = self.usableRoot", run)
        self.assertIn("process.currentDirectoryURL = usableRoot", run)

    def test_install_instructions_name_the_data_location(self) -> None:
        common = "~/Library/Application Support/Seedbed/LibraryData"
        self.assertIn(common, self.install_copy)
        self.assertIn("starter", self.install_copy.lower())


if __name__ == "__main__":
    unittest.main()
