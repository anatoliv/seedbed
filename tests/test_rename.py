"""Renaming a prompt has to take everything named after it along.

An id is not just a filename. It is the filename, the `id` inside the seed's own
frontmatter, the filename of every render, the `seed` in each render's
provenance, the comparison summary's filename, and the key in `.usage.json`.
Six places. Renaming by hand means renaming five of them and finding the sixth
weeks later, when a render the library reports as missing turns out to be sitting
on disk under a name nothing points at.

Until `rename` existed there was no way to do it at all, which is why three seeds
scaffolded as `new-prompt`, `new-prompt-3` and `new-prompt-4` were still called
that after seven uses between them: the id a seed is born with was permanent.

The test that matters is the negative one — `test_a_render_is_not_left_behind`.
A rename that moves the seed and forgets the renders looks like it worked, prints
a success line, and quietly costs an LLM call per model to rebuild what was
already there.
"""

from __future__ import annotations

import json
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent


class Rename(unittest.TestCase):
    def setUp(self) -> None:
        self.dir = Path(tempfile.mkdtemp(prefix="seedbed-rename-"))
        self.addCleanup(shutil.rmtree, self.dir, ignore_errors=True)
        # A library is a checkout: promptlib resolves its root from its own
        # location, so the package has to be beside the content it owns.
        for item in ("promptlib", "models.toml", "enhancer.toml"):
            src = REPO / item
            (shutil.copytree if src.is_dir() else shutil.copy)(src, self.dir / item)
        shutil.rmtree(self.dir / "promptlib" / "__pycache__", ignore_errors=True)

        (self.dir / "prompts").mkdir()
        (self.dir / "prompts" / "old-name.md").write_text(
            '+++\nid = "old-name"\ntitle = "Old"\ntargets = ["claude-opus-5"]\n'
            'tags = []\ncategory = ""\npinned = false\ncontext = "agent"\n+++\n'
            "do the thing\n", encoding="utf-8")
        rendered = self.dir / "rendered" / "claude-opus-5"
        rendered.mkdir(parents=True)
        (rendered / "old-name.md").write_text(
            '+++\nseed = "old-name"\nmodel = "claude-opus-5"\n'
            'seed_hash = "abc123"\nguide_hash = "def456"\nenhancer = "claude-cli"\n'
            'generated = "2026-09-05"\ncontext = "agent"\n+++\n'
            "a long expansion\n", encoding="utf-8")
        (self.dir / ".usage.json").write_text(
            json.dumps({"old-name": {"count": 3, "last_used": "2026-09-05",
                                     "models": {"claude-opus-5": 3}}}), encoding="utf-8")

    def rename(self, old: str, new: str) -> subprocess.CompletedProcess:
        return subprocess.run([sys.executable, "-m", "promptlib", "rename", old, new],
                              cwd=self.dir, capture_output=True, text=True)

    def test_it_moves_the_seed_and_rewrites_the_id_inside_it(self) -> None:
        self.assertEqual(self.rename("old-name", "new-name").returncode, 0)
        self.assertFalse((self.dir / "prompts" / "old-name.md").exists())
        text = (self.dir / "prompts" / "new-name.md").read_text()
        self.assertIn('id = "new-name"', text)
        self.assertNotIn("old-name", text)
        self.assertIn("do the thing", text, "the body must survive untouched")

    def test_a_render_is_not_left_behind(self) -> None:
        """The expensive half: a render costs an LLM call to recreate."""
        self.assertEqual(self.rename("old-name", "new-name").returncode, 0)
        old = self.dir / "rendered" / "claude-opus-5" / "old-name.md"
        new = self.dir / "rendered" / "claude-opus-5" / "new-name.md"
        self.assertFalse(old.exists(), "the render was stranded under the old id")
        self.assertTrue(new.exists(), "the render did not arrive under the new id")
        self.assertIn('seed = "new-name"', new.read_text(),
                      "the render's provenance still points at the old id, so the "
                      "library cannot tell it belongs to this seed")
        self.assertIn("a long expansion", new.read_text())

    def test_the_usage_count_follows(self) -> None:
        self.assertEqual(self.rename("old-name", "new-name").returncode, 0)
        data = json.loads((self.dir / ".usage.json").read_text())
        self.assertNotIn("old-name", data)
        self.assertEqual(data["new-name"]["count"], 3)

    def test_it_refuses_an_id_that_is_taken(self) -> None:
        shutil.copy(self.dir / "prompts" / "old-name.md",
                    self.dir / "prompts" / "taken.md")
        result = self.rename("old-name", "taken")
        self.assertNotEqual(result.returncode, 0)
        self.assertTrue((self.dir / "prompts" / "old-name.md").exists(),
                        "a refused rename must change nothing")

    def test_it_refuses_an_unusable_id(self) -> None:
        for bad in ("Has Capitals", "has spaces", "-leading-hyphen", ""):
            with self.subTest(bad=bad):
                self.assertNotEqual(self.rename("old-name", bad).returncode, 0)
                self.assertTrue((self.dir / "prompts" / "old-name.md").exists())

    def test_it_refuses_a_prompt_that_does_not_exist(self) -> None:
        self.assertNotEqual(self.rename("no-such-prompt", "whatever").returncode, 0)


if __name__ == "__main__":
    unittest.main()
