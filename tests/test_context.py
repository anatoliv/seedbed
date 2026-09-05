"""A prompt says where it will be pasted, and that changes what gets built.

Measured on 2026-09-05: the renders instruct a model
to reproduce a failure and read the surrounding code before changing anything.
That is right for an agent sitting in a checkout. Given a bare snippet the same
render searched for code that was not there and declined to fix anything, losing
both fix tasks to the raw seed; given the same bug inside the repo it recovered
completely.

So the tool was building for one context and handing the result to another. The
fix makes the assumption explicit. These tests pin the three things that have to
hold for that to be worth anything:

1. A seed written before the field existed still means what it meant.
2. Changing the context restages the renders, because a render built for one
   context is genuinely wrong for the other.
3. The context actually reaches the enhancer, rather than being recorded and
   ignored — which would be the same accidental-assumption bug wearing a field.
"""

from __future__ import annotations

import sys
import unittest
from pathlib import Path
from tempfile import TemporaryDirectory

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from promptlib import builder, enhance
from promptlib.guides import Model
from promptlib.store import (CONTEXTS, DEFAULT_CONTEXT, FormatError, Library,
                             Render, Seed, normalise_context)


class ContextVocabulary(unittest.TestCase):
    def test_the_two_contexts_are_the_two_that_were_measured(self):
        self.assertEqual(set(CONTEXTS), {"agent", "chat"})

    def test_each_context_describes_itself_in_a_sentence(self):
        """The description is sent to the enhancer, so it has to be usable prose."""
        for name, description in CONTEXTS.items():
            with self.subTest(context=name):
                self.assertGreater(len(description.split()), 8,
                                   f"{name}'s description is too thin to steer a model")

    def test_an_unknown_context_is_refused_not_defaulted(self):
        """A silent fallback would be the original bug in a new place.

        A seed saying `context = "repl"` was written with an intent this tool
        cannot serve. Quietly building it as an agent prompt is exactly the
        accidental assumption the field exists to remove.
        """
        with self.assertRaises(FormatError) as caught:
            normalise_context("repl")
        self.assertIn("repl", str(caught.exception))
        self.assertIn("agent", str(caught.exception), "the error should list what IS valid")

    def test_absent_and_empty_mean_the_documented_default(self):
        self.assertEqual(normalise_context(None), DEFAULT_CONTEXT)
        self.assertEqual(normalise_context(""), DEFAULT_CONTEXT)

    def test_the_default_is_agent(self):
        """Every prompt written before the field existed was written for an agent.

        If this ever changes, every legacy seed silently changes meaning.
        """
        self.assertEqual(DEFAULT_CONTEXT, "agent")


class SeedRoundTrip(unittest.TestCase):
    def setUp(self):
        self.tmp = TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.dir = Path(self.tmp.name)

    def test_a_seed_written_before_the_field_existed_still_loads(self):
        legacy = self.dir / "legacy.md"
        legacy.write_text('+++\nid = "legacy"\ntitle = "Legacy"\n+++\ndo the thing\n')
        seed = Seed.load(legacy)
        self.assertEqual(seed.context, "agent")

    def test_context_survives_a_write_and_reload(self):
        path = self.dir / "s.md"
        Seed(id="s", body="do it", context="chat").write(path)
        self.assertEqual(Seed.load(path).context, "chat")
        self.assertIn('context = "chat"', path.read_text())

    def test_a_seed_file_with_a_bad_context_fails_loudly(self):
        bad = self.dir / "bad.md"
        bad.write_text('+++\nid = "bad"\ncontext = "telepathy"\n+++\ndo it\n')
        with self.assertRaises(FormatError):
            Seed.load(bad)


class Staleness(unittest.TestCase):
    """Context is part of the staleness rule; the cosmetic fields are not."""

    def test_changing_the_context_changes_the_hash(self):
        agent = Seed(id="s", body="fix this bug", context="agent")
        chat = Seed(id="s", body="fix this bug", context="chat")
        self.assertNotEqual(agent.hash, chat.hash)

    def test_renaming_and_pinning_still_do_not_restage(self):
        """The existing guarantee must survive the new field."""
        plain = Seed(id="s", body="fix this bug")
        dressed = Seed(id="s", body="fix this bug", title="Fix it",
                       tags=["a"], category="Coding", pinned=True)
        self.assertEqual(plain.hash, dressed.hash)

    def test_a_render_built_for_the_other_context_reads_as_stale(self):
        seed = Seed(id="s", body="fix this bug", context="chat")
        render = Render(seed_id="s", model="m", body="...",
                        seed_hash=Seed(id="s", body="fix this bug",
                                       context="agent").hash,
                        guide_hash="g1", context="agent")
        self.assertFalse(render.is_current(seed, "g1"))

    def test_a_render_records_the_context_it_was_built_for(self):
        """Recorded as well as hashed, so the CLI can name the specific cause."""
        tmp = TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        path = Path(tmp.name) / "r.md"
        Render(seed_id="s", model="m", body="x", context="chat").write(path)
        self.assertEqual(Render.load(path).context, "chat")
        self.assertIn('context = "chat"', path.read_text())

    def test_a_legacy_render_with_no_context_reads_as_agent(self):
        tmp = TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        path = Path(tmp.name) / "r.md"
        path.write_text('+++\nseed = "s"\nmodel = "m"\n+++\nbody\n')
        self.assertEqual(Render.load(path).context, "agent")


class ReachesTheEnhancer(unittest.TestCase):
    """Recorded and ignored would be the same bug wearing a field."""

    def test_the_context_description_is_in_the_message(self):
        for name, description in CONTEXTS.items():
            with self.subTest(context=name):
                message = enhance._user_message("fix it", "M", "guidance", name)
                self.assertIn(description, message)

    def test_the_default_is_used_when_none_is_given(self):
        message = enhance._user_message("fix it", "M", "guidance")
        self.assertIn(CONTEXTS[DEFAULT_CONTEXT], message)

    def test_the_system_prompt_tells_the_enhancer_what_to_do_with_it(self):
        """Passing the context is useless if nothing instructs on it."""
        self.assertIn("usage context", enhance.SYSTEM)
        self.assertIn("chat window", enhance.SYSTEM)

    def test_render_one_passes_the_seed_s_context(self):
        """The end-to-end link, with the enhancer stubbed so nothing is spent."""
        tmp = TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        root = Path(tmp.name)
        lib = Library(root)
        lib.prompts.mkdir(parents=True)
        seed = Seed(id="s", body="fix this bug", context="chat")
        seed.write(lib.prompts / "s.md")

        seen = {}

        def fake_enhance(body, model_name, guidance, backend=None, config=None,
                         context=DEFAULT_CONTEXT):
            seen["context"] = context
            return "the built prompt"

        original = builder.enhance
        builder.enhance = fake_enhance
        self.addCleanup(lambda: setattr(builder, "enhance", original))

        pair = builder.Pair(seed=seed, model=Model(id="m", name="M", family="f",
                                                   guides=[]),
                            guidance="g", guide_hash="g1")

        class Config:
            auth = "stub"
        builder.render_one(lib, pair, config=Config())

        self.assertEqual(seen["context"], "chat")
        written = lib.render("s", "m")
        self.assertEqual(written.context, "chat",
                         "the render must record the context it was built for")
        self.assertTrue(written.is_current(seed, "g1"))


if __name__ == "__main__":
    unittest.main()
