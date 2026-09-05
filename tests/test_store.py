"""Tests for the on-disk format and the staleness rule.

Staleness is what decides whether a prompt gets regenerated, so an error here
either wastes tokens rebuilding what is current or, worse, serves a prompt built
against guidance that has since changed.
"""

import sys
import unittest
from pathlib import Path
from tempfile import TemporaryDirectory

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from promptlib.store import FormatError, Library, Render, Seed, digest


SEED_TEXT = """+++
id = "fix-bug"
title = "Fix a bug"
targets = ["claude-opus-5"]
tags = ["coding"]
+++
fix this bug and test
"""


class SeedFormat(unittest.TestCase):
    def setUp(self):
        self.tmp = TemporaryDirectory()
        self.dir = Path(self.tmp.name)
        self.addCleanup(self.tmp.cleanup)

    def write(self, text: str) -> Path:
        path = self.dir / "fix-bug.md"
        path.write_text(text, encoding="utf-8")
        return path

    def test_reads_frontmatter_and_body(self):
        seed = Seed.load(self.write(SEED_TEXT))
        self.assertEqual(seed.id, "fix-bug")
        self.assertEqual(seed.title, "Fix a bug")
        self.assertEqual(seed.targets, ["claude-opus-5"])
        self.assertEqual(seed.body, "fix this bug and test")

    def test_body_keeps_internal_blank_lines(self):
        seed = Seed.load(self.write(SEED_TEXT.rstrip() + "\n\nsecond paragraph\n"))
        self.assertEqual(seed.body, "fix this bug and test\n\nsecond paragraph")

    def test_missing_opening_fence_is_an_error(self):
        with self.assertRaises(FormatError):
            Seed.load(self.write("id = 'x'\nfix this bug\n"))

    def test_unclosed_fence_is_an_error(self):
        with self.assertRaises(FormatError):
            Seed.load(self.write('+++\nid = "x"\nfix this bug\n'))

    def test_invalid_toml_is_an_error(self):
        with self.assertRaises(FormatError):
            Seed.load(self.write("+++\nid = not quoted\n+++\nbody\n"))

    def test_empty_body_is_an_error(self):
        with self.assertRaises(FormatError):
            Seed.load(self.write('+++\nid = "x"\n+++\n\n'))

    def test_round_trips_through_write(self):
        original = Seed.load(self.write(SEED_TEXT))
        out = self.dir / "again.md"
        original.write(out)
        again = Seed.load(out)
        self.assertEqual(again.id, original.id)
        self.assertEqual(again.targets, original.targets)
        self.assertEqual(again.body, original.body)

    def test_quotes_in_a_title_survive(self):
        seed = Seed(id="x", title='the "hard" one', body="do it")
        out = self.dir / "x.md"
        seed.write(out)
        self.assertEqual(Seed.load(out).title, 'the "hard" one')


class Staleness(unittest.TestCase):
    def setUp(self):
        self.seed = Seed(id="fix-bug", body="fix this bug and test")
        self.render = Render(
            seed_id="fix-bug",
            model="claude-opus-5",
            body="a long tailored prompt",
            seed_hash=self.seed.hash,
            guide_hash="guide-v1",
        )

    def test_current_when_nothing_moved(self):
        self.assertTrue(self.render.is_current(self.seed, "guide-v1"))

    def test_stale_when_the_seed_changes(self):
        edited = Seed(id="fix-bug", body="fix this bug and add a regression test")
        self.assertFalse(self.render.is_current(edited, "guide-v1"))

    def test_stale_when_the_guidance_changes(self):
        self.assertFalse(self.render.is_current(self.seed, "guide-v2"))

    def test_whitespace_only_edit_still_counts_as_a_change(self):
        # Body is stripped on load, so a trailing-newline edit must NOT restage;
        # a real internal edit must. This pins which of the two we mean.
        same = Seed(id="fix-bug", body="fix this bug and test")
        self.assertEqual(same.hash, self.seed.hash)
        spaced = Seed(id="fix-bug", body="fix this  bug and test")
        self.assertNotEqual(spaced.hash, self.seed.hash)


class Digest(unittest.TestCase):
    def test_parts_cannot_be_confused_by_concatenation(self):
        # Without a separator, ("ab","c") and ("a","bc") would hash the same.
        self.assertNotEqual(digest("ab", "c"), digest("a", "bc"))


class LibraryPaths(unittest.TestCase):
    def setUp(self):
        self.tmp = TemporaryDirectory()
        self.root = Path(self.tmp.name)
        self.addCleanup(self.tmp.cleanup)
        (self.root / "prompts").mkdir()

    def test_missing_seed_names_itself(self):
        lib = Library(self.root)
        with self.assertRaises(FileNotFoundError) as caught:
            lib.seed("nope")
        self.assertIn("nope", str(caught.exception))

    def test_render_round_trips_with_provenance(self):
        lib = Library(self.root)
        render = Render(
            seed_id="fix-bug",
            model="claude-opus-5",
            body="tailored",
            seed_hash="abc123",
            guide_hash="def456",
            enhancer="claude-cli",
            generated="2026-09-04",
        )
        render.write(lib.render_path("fix-bug", "claude-opus-5"))
        loaded = lib.render("fix-bug", "claude-opus-5")
        self.assertEqual(loaded.seed_hash, "abc123")
        self.assertEqual(loaded.guide_hash, "def456")
        self.assertEqual(loaded.enhancer, "claude-cli")
        self.assertEqual(loaded.body, "tailored")

    def test_no_render_yet_reads_as_none(self):
        self.assertIsNone(Library(self.root).render("fix-bug", "claude-opus-5"))



class Pinning(unittest.TestCase):
    """Pinning is in the seed file so it travels with the library — but it must
    not touch the render hash, or pinning would rebuild everything it touches."""

    def setUp(self):
        self.tmp = TemporaryDirectory()
        self.dir = Path(self.tmp.name)
        self.addCleanup(self.tmp.cleanup)

    def test_pin_survives_a_round_trip(self):
        path = self.dir / "s.md"
        Seed(id="s", title="S", body="do it", pinned=True).write(path)
        self.assertTrue(Seed.load(path).pinned)

    def test_unpinned_is_the_default(self):
        path = self.dir / "s.md"
        Seed(id="s", title="S", body="do it").write(path)
        self.assertFalse(Seed.load(path).pinned)

    def test_pinning_does_not_change_the_seed_hash(self):
        plain = Seed(id="s", title="S", body="do it")
        pinned = Seed(id="s", title="S", body="do it", pinned=True)
        self.assertEqual(plain.hash, pinned.hash)

    def test_retitling_does_not_change_the_seed_hash(self):
        self.assertEqual(
            Seed(id="s", title="One", body="do it").hash,
            Seed(id="s", title="Another", body="do it").hash,
        )


class Categories(unittest.TestCase):
    """Category is a grouping, not content — it must not restage renders."""

    def setUp(self):
        self.tmp = TemporaryDirectory()
        self.dir = Path(self.tmp.name)
        self.addCleanup(self.tmp.cleanup)

    def test_category_round_trips(self):
        path = self.dir / "s.md"
        Seed(id="s", title="S", body="do it", category="Coding").write(path)
        self.assertEqual(Seed.load(path).category, "Coding")

    def test_missing_category_reads_as_empty(self):
        path = self.dir / "s.md"
        path.write_text('+++\nid = "s"\n+++\ndo it\n', encoding="utf-8")
        self.assertEqual(Seed.load(path).category, "")

    def test_category_does_not_change_the_seed_hash(self):
        self.assertEqual(
            Seed(id="s", body="do it").hash,
            Seed(id="s", body="do it", category="Coding").hash,
        )

if __name__ == "__main__":
    unittest.main()
