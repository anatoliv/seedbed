"""Tests for placeholders and their remembered values.

This is the last thing that touches a prompt before it reaches the clipboard, so
a mistake here is pasted straight into a worker agent.
"""

import sys
import unittest
from pathlib import Path
from tempfile import TemporaryDirectory

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from promptlib.variables import History, fill, find


class Finding(unittest.TestCase):
    def test_finds_placeholders_in_reading_order(self):
        self.assertEqual(find("Fix {{BUG}} in {{FILE}} now"), ["BUG", "FILE"])

    def test_repeats_are_listed_once(self):
        self.assertEqual(find("{{P}} and {{P}} again"), ["P"])

    def test_tolerates_inner_spaces(self):
        self.assertEqual(find("{{ PROJECT }}"), ["PROJECT"])

    def test_ignores_things_that_are_not_placeholders(self):
        self.assertEqual(find("{single} {{}} {{9NUM}} plain text"), [])

    def test_underscores_and_digits_are_allowed_after_a_letter(self):
        self.assertEqual(find("{{BUG_REPORT_2}}"), ["BUG_REPORT_2"])


class Filling(unittest.TestCase):
    def test_substitutes_every_occurrence(self):
        self.assertEqual(fill("{{P}}/{{P}}", {"P": "x"}), "x/x")

    def test_unanswered_placeholder_stays_visible(self):
        # A silent hole is worse than a visible one: you can see what is missing.
        self.assertEqual(fill("{{A}} {{B}}", {"A": "x"}), "x {{B}}")

    def test_empty_value_is_treated_as_unanswered(self):
        self.assertEqual(fill("{{A}}", {"A": ""}), "{{A}}")

    def test_a_value_containing_braces_is_not_re_expanded(self):
        self.assertEqual(fill("{{A}}", {"A": "{{B}}"}), "{{B}}")

    def test_unrelated_text_is_untouched(self):
        text = "Use JSON like {\"a\": 1} and keep it"
        self.assertEqual(fill(text, {"A": "x"}), text)


class Remembering(unittest.TestCase):
    def setUp(self):
        self.tmp = TemporaryDirectory()
        self.root = Path(self.tmp.name)
        self.addCleanup(self.tmp.cleanup)

    def test_most_recent_value_comes_first(self):
        h = History(self.root)
        h.record_all({"P": "one"})
        h.record_all({"P": "two"})
        self.assertEqual(History(self.root).values("P"), ["two", "one"])

    def test_reusing_a_value_moves_it_to_the_front_without_duplicating(self):
        h = History(self.root)
        for value in ["a", "b", "a"]:
            h.record_all({"P": value})
        self.assertEqual(History(self.root).values("P"), ["a", "b"])

    def test_blank_values_are_not_remembered(self):
        History(self.root).record_all({"P": "   "})
        self.assertEqual(History(self.root).values("P"), [])

    def test_history_is_capped(self):
        h = History(self.root)
        for i in range(40):
            h.record_all({"P": f"v{i}"})
        self.assertLessEqual(len(History(self.root).values("P")), 25)

    def test_a_corrupt_history_file_never_blocks_a_fill(self):
        (self.root / ".variables.json").write_text("not json", encoding="utf-8")
        h = History(self.root)
        self.assertEqual(h.values("P"), [])
        h.record_all({"P": "x"})
        self.assertEqual(History(self.root).values("P"), ["x"])
