"""The Library footer leaves enough room for an actionable error message."""

import unittest
from pathlib import Path


LIBRARY_WINDOW = (
    Path(__file__).resolve().parent.parent
    / "macos"
    / "Sources"
    / "Seedbed"
    / "LibraryWindow.swift"
)


class LibraryStatusBarTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.source = LIBRARY_WINDOW.read_text(encoding="utf-8")

    def test_status_can_wrap_to_the_two_lines_its_errors_are_written_for(self) -> None:
        status_bar = self.source.split("private var statusBar:", 1)[1].split("\n    }", 1)[0]

        self.assertIn(".lineLimit(2)", status_bar)
        self.assertIn(".fixedSize(horizontal: false, vertical: true)", status_bar)

    def test_a_successful_reload_clears_an_old_error(self) -> None:
        reload_method = self.source.split("func reload(keepingDraft:", 1)[1].split(
            "\n    func select", 1
        )[0]
        success_path = reload_method.split("} catch {", 1)[0]

        self.assertIn('if self.statusIsError { self.report("") }', success_path)


if __name__ == "__main__":
    unittest.main()
