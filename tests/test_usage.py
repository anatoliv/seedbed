"""Tests for the copy counter.

It decides the "most used" and "recent" orderings and the default model that ⏎
copies, so a miscount changes what lands on the clipboard.
"""

import sys
import unittest
from pathlib import Path
from tempfile import TemporaryDirectory

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from promptlib.usage import Usage


class Counting(unittest.TestCase):
    def setUp(self):
        self.tmp = TemporaryDirectory()
        self.root = Path(self.tmp.name)
        self.addCleanup(self.tmp.cleanup)

    def test_unknown_prompt_counts_zero(self):
        self.assertEqual(Usage(self.root).count("nope"), 0)
        self.assertEqual(Usage(self.root).last_used("nope"), "")
        self.assertEqual(Usage(self.root).favourite_model("nope"), "")

    def test_records_accumulate_across_instances(self):
        Usage(self.root).record("s", "m")
        Usage(self.root).record("s", "m")
        self.assertEqual(Usage(self.root).count("s"), 2)

    def test_favourite_model_is_the_most_copied_one(self):
        u = Usage(self.root)
        u.record("s", "opus")
        u.record("s", "llama")
        u.record("s", "llama")
        self.assertEqual(Usage(self.root).favourite_model("s"), "llama")

    def test_last_used_is_stamped(self):
        Usage(self.root).record("s", "m")
        self.assertTrue(Usage(self.root).last_used("s").endswith("Z"))

    def test_a_corrupt_counter_file_never_blocks_a_copy(self):
        (self.root / ".usage.json").write_text("{ not json", encoding="utf-8")
        usage = Usage(self.root)
        self.assertEqual(usage.count("s"), 0)
        usage.record("s", "m")            # must not raise
        self.assertEqual(Usage(self.root).count("s"), 1)
