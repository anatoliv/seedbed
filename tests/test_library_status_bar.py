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
    def test_status_can_wrap_to_the_two_lines_its_errors_are_written_for(self) -> None:
        source = LIBRARY_WINDOW.read_text(encoding="utf-8")
        status_bar = source.split("private var statusBar:", 1)[1].split("\n    }", 1)[0]

        self.assertIn(".lineLimit(2)", status_bar)
        self.assertIn(".fixedSize(horizontal: false, vertical: true)", status_bar)


if __name__ == "__main__":
    unittest.main()
