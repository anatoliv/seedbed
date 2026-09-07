"""HELP.md and FAQ.md are generated, and staying that way is the whole point.

Seedbed's help is a Swift value the app renders, so until 2026-09-07 the only
way to read it was to build the app. That is a gap for the audience the public
repository actually has: the Homebrew tap is a clone, and the snapshot ships no
binary.

The fix could have been two hand-written markdown files. It is not, because a
second copy of the same prose drifts and the copy nobody renders drifts first.
`Scripts/generate-help-docs.py` writes both from `Manual.swift`, and this is
what stops the generated files being edited by hand or left behind when the
manual moves.

The test that matters is the round trip: regenerate, and nothing changes.
"""

from __future__ import annotations

import importlib.util
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
GENERATOR = ROOT / "Scripts" / "generate-help-docs.py"
HELP = ROOT / "HELP.md"
FAQ = ROOT / "FAQ.md"


def load_generator():
    spec = importlib.util.spec_from_file_location("help_docs", GENERATOR)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


class HelpDocsAreGenerated(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        if not GENERATOR.exists():                      # pragma: no cover
            raise unittest.SkipTest(f"{GENERATOR.name} is absent from this tree")
        cls.gen = load_generator()
        cls.built = cls.gen.build()

    def test_both_documents_exist(self) -> None:
        for path in (HELP, FAQ):
            self.assertTrue(path.is_file(), f"{path.name} is missing; run "
                                            "Scripts/generate-help-docs.py")

    def test_regenerating_changes_nothing(self) -> None:
        """The one that catches a hand edit and a stale file alike."""
        for path, expected in self.built.items():
            with self.subTest(document=path.name):
                self.assertEqual(
                    path.read_text(encoding="utf-8"), expected,
                    f"{path.name} is stale or was edited by hand. Edit "
                    "macos/Sources/Seedbed/Manual.swift, then run "
                    "Scripts/generate-help-docs.py")

    def test_every_topic_in_the_manual_reaches_a_document(self) -> None:
        """A parser that silently skips a topic still produces a plausible file.

        Counting is what separates "it parsed" from "it parsed everything": the
        manual builds topics two ways, a `key(...)` helper for the keyboard
        table and `ManualTopic(...)` literals for prose, and an early version of
        the parser understood only the second.
        """
        source = self.gen.MANUAL.read_text(encoding="utf-8")
        # The literal inside `key(...)`'s own definition is the constructor, not
        # a topic, so the expected count is one fewer than the raw occurrences.
        literals = source.count("ManualTopic(") - 1
        helpers = sum(1 for line in source.splitlines()
                      if line.strip().startswith("key("))
        pages = self.gen.read_pages(source)
        parsed = sum(len(topics) for sections in pages.values()
                     for _, topics in sections)
        self.assertEqual(parsed, literals + helpers,
                         "the generator dropped topics the manual defines")

    def test_the_documents_carry_the_do_not_edit_banner(self) -> None:
        for path in (HELP, FAQ):
            with self.subTest(document=path.name):
                self.assertIn("Generated from", path.read_text(encoding="utf-8")[:400],
                              f"{path.name} lost the banner that tells a reader "
                              "not to edit it")

    def test_no_prose_dashes_in_either_document(self) -> None:
        """Published copy carries no em or en dash, the same bar as the site.

        The exception is notation rather than prose: the keyboard table's key
        ranges (`⌘1–9`) are the app's own captions, and they have to match what
        the app displays, character for character.
        """
        for path in (HELP, FAQ):
            for number, line in enumerate(path.read_text(encoding="utf-8").splitlines(), 1):
                if "–" in line and line.lstrip().startswith("| `"):
                    continue                            # a key capsule, not prose
                with self.subTest(document=path.name, line=number):
                    self.assertNotRegex(line, r"[—–]",
                                        "use a period, colon, comma or parentheses")


if __name__ == "__main__":
    unittest.main()
