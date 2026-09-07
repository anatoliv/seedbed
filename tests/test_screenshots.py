"""The README's screenshots exist, are the library in this repository, and are small.

Added 2026-09-07: the public repository had no images at all, and a prompt tool
whose whole argument is "the same seed renders differently per model" is hard to
believe from prose.

Two things this guards. A README that links an image which is not published
shows a broken-image icon to every visitor and looks fine to the author, which
is the same defect class the mirror's dangling-reference guard exists for. And
weight: this repository is a Homebrew tap, so every `brew tap` is a clone that
pays for whatever is in here — a 937 KB rejected concept art was removed from
the snapshot the same day these were added.
"""

import re
import struct
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
README = ROOT / "README.md"
SHOTS = ROOT / "screenshots"

#: Generous, and still a bound. Past this, resize before committing.
MAX_TOTAL_KB = 900


def png_size(path: Path) -> tuple[int, int]:
    head = path.read_bytes()[:24]
    assert head[:8] == b"\x89PNG\r\n\x1a\n", f"{path.name} is not a PNG"
    return struct.unpack(">II", head[16:24])


class Screenshots(unittest.TestCase):
    def setUp(self) -> None:
        self.readme = README.read_text(encoding="utf-8")
        self.referenced = re.findall(r"!\[[^\]]*\]\((screenshots/[^)]+)\)", self.readme)

    def test_the_readme_shows_at_least_one(self) -> None:
        self.assertTrue(self.referenced, "the README references no screenshot")

    def test_every_referenced_image_exists(self) -> None:
        for rel in self.referenced:
            with self.subTest(image=rel):
                self.assertTrue((ROOT / rel).is_file(),
                                f"{rel} is linked from the README but not in the repository")

    def test_every_committed_image_is_used(self) -> None:
        if not SHOTS.is_dir():
            self.skipTest("no screenshots directory in this checkout")
        for path in sorted(SHOTS.iterdir()):
            if path.name.startswith("."):
                continue
            with self.subTest(image=path.name):
                self.assertIn(f"screenshots/{path.name}", self.readme,
                              "committed but referenced nowhere, so it is weight for nothing")

    def test_every_image_has_alt_text(self) -> None:
        # A screenshot with no alt text is invisible to a screen reader and to
        # anyone whose images did not load.
        for alt, rel in re.findall(r"!\[([^\]]*)\]\((screenshots/[^)]+)\)", self.readme):
            with self.subTest(image=rel):
                self.assertGreater(len(alt.strip()), 15,
                                   f"{rel} needs alt text that describes what is in it")

    def test_they_are_pngs_of_a_sane_size(self) -> None:
        if not SHOTS.is_dir():
            self.skipTest("no screenshots directory in this checkout")
        total = 0
        for path in sorted(SHOTS.iterdir()):
            if path.name.startswith("."):
                continue
            width, height = png_size(path)
            total += path.stat().st_size
            with self.subTest(image=path.name):
                self.assertLessEqual(width, 2000, "wider than any README renders it")
                self.assertGreater(height, 200)
        self.assertLessEqual(total // 1024, MAX_TOTAL_KB,
                             f"screenshots total {total // 1024} KB; every `brew tap` clones them")


if __name__ == "__main__":
    unittest.main()
