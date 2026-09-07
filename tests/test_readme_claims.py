"""Numbers the README states about the library, checked against the library.

README.md's "Same seed, two targets" section is the one place the project
quantifies its own premise, and it is the sentence a reader is most likely to
take away. It said 233 and 433 words until 2026-09-07, when the real renders
were 182 and 698: the renders had been rebuilt in the meantime (prompts gained a
usage context, which restages every render) and nothing compared the prose to
the files. The public site quoted the measured numbers, so the two disagreed.

A claim nobody checks is a claim that goes stale silently. This checks it.
"""

import re
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
README = ROOT / "README.md"
SEED = "fix-bug-and-test"
CLAIMED = {"claude-opus-5": 182, "llama-3.3-70b": 698}
HEADER_WORDS = 23


def body_words(render: Path) -> int:
    """Word count of the prompt body, excluding the TOML provenance header."""
    text = render.read_text(encoding="utf-8")
    parts = text.split("+++")
    # ["", frontmatter, body...] — rejoin in case the body itself contains +++.
    body = "+++".join(parts[2:]) if len(parts) >= 3 else text
    return len(body.split())


class ReadmeWordCounts(unittest.TestCase):
    def setUp(self) -> None:
        self.readme = README.read_text(encoding="utf-8")

    def test_the_two_quoted_counts_are_the_renders_actual_lengths(self) -> None:
        for model, claimed in CLAIMED.items():
            render = ROOT / "rendered" / model / f"{SEED}.md"
            if not render.is_file():
                self.skipTest(f"{render.relative_to(ROOT)} is not in this checkout")
            with self.subTest(model=model):
                self.assertEqual(body_words(render), claimed,
                                 f"README says {claimed} words for {model}; rebuild the "
                                 f"number in README.md or explain the difference")
                self.assertIn(f"{claimed} words", self.readme)

    def test_the_provenance_header_offset_is_right(self) -> None:
        render = ROOT / "rendered" / "claude-opus-5" / f"{SEED}.md"
        if not render.is_file():
            self.skipTest("the opus render is not in this checkout")
        whole = len(render.read_text(encoding="utf-8").split())
        self.assertEqual(whole - body_words(render), HEADER_WORDS)
        self.assertIn(f"reports {HEADER_WORDS}", self.readme)

    def test_the_claim_is_dated_so_a_reader_knows_when_it_was_measured(self) -> None:
        section = self.readme.split("## Same seed, two targets", 1)
        self.assertEqual(len(section), 2, "the section this test guards has been renamed")
        self.assertRegex(section[1], r"Counted on the prompt body, \d{4}-\d{2}-\d{2}")


if __name__ == "__main__":
    unittest.main()
