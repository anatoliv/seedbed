"""Tests for reading and writing models.toml.

The registry is hand-edited *and* written by the app, so a save must not destroy
what a person put there.
"""

import sys
import unittest
from pathlib import Path
from tempfile import TemporaryDirectory

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from promptlib.guides import Model, load_registry, save_registry

SAMPLE = '''# Target models: what prompts are written FOR.
#
# This comment explains the file and must survive a save.

[models."claude-opus-5"]
name    = "Claude Opus 5"
family  = "claude"
guides  = [
  "https://docs.claude.com/overview",
]
notes   = "Adaptive thinking is on by default."
'''


class RoundTrip(unittest.TestCase):
    def setUp(self):
        self.tmp = TemporaryDirectory()
        self.path = Path(self.tmp.name) / "models.toml"
        self.path.write_text(SAMPLE, encoding="utf-8")
        self.addCleanup(self.tmp.cleanup)

    def test_the_explanatory_header_survives_a_save(self):
        save_registry(self.path, load_registry(self.path))
        self.assertTrue(self.path.read_text().startswith("# Target models"))
        self.assertIn("must survive a save", self.path.read_text())

    def test_fields_survive_a_round_trip(self):
        save_registry(self.path, load_registry(self.path))
        model = load_registry(self.path)["claude-opus-5"]
        self.assertEqual(model.name, "Claude Opus 5")
        self.assertEqual(model.family, "claude")
        self.assertEqual(model.guides, ["https://docs.claude.com/overview"])
        self.assertEqual(model.notes, "Adaptive thinking is on by default.")

    def test_adding_a_model_leaves_the_others_alone(self):
        models = load_registry(self.path)
        models["new-one"] = Model(id="new-one", name="New One", family="x", guides=[], notes="")
        save_registry(self.path, models)
        back = load_registry(self.path)
        self.assertEqual(set(back), {"claude-opus-5", "new-one"})
        self.assertEqual(back["claude-opus-5"].guides, ["https://docs.claude.com/overview"])

    def test_quotes_and_newlines_in_notes_are_escaped(self):
        models = load_registry(self.path)
        models["claude-opus-5"].notes = 'say "hello"\nthen stop'
        save_registry(self.path, models)
        self.assertEqual(load_registry(self.path)["claude-opus-5"].notes,
                         'say "hello"\nthen stop')

    def test_a_model_with_no_guides_writes_a_valid_empty_list(self):
        models = load_registry(self.path)
        models["local"] = Model(id="local", name="Local", family="", guides=[], notes="")
        save_registry(self.path, models)
        self.assertEqual(load_registry(self.path)["local"].guides, [])
