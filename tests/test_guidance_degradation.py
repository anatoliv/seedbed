"""A guidance source that cannot be read must not silently make renders worse.

The failure this pins is subtle and it is the only one in the project that
degrades the product's *output* rather than merely inconveniencing someone:

1. A vendor documentation URL starts returning 404.
2. `guidance_for` catches it and puts `[guidance unavailable: ...]` in the blob,
   because a partial build beats no build when you are offline.
3. That changes the blob's hash, so every render for that model is now "stale".
4. A rebuild runs, and writes renders built on LESS guidance than the ones they
   replace, stamped current.

Nothing warned, and afterwards there is no way to tell it happened: the renders
look fresh.

The behaviour these tests pin is that step 2 still happens (offline builds keep
working) but steps 3 and 4 now require someone to say so out loud.
"""

from __future__ import annotations

import sys
import unittest
from pathlib import Path
from tempfile import TemporaryDirectory

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from promptlib import builder
from promptlib.guides import GuideCache, Model
from promptlib.store import Library, Seed


class UnreachableCache(GuideCache):
    """A real `GuideCache` whose fetches all fail, with no network involved."""

    def fetch(self, source: str, force: bool = False):
        raise RuntimeError(f"could not fetch {source}: HTTP Error 404: Not Found")


class DegradedGuidance(unittest.TestCase):
    def setUp(self):
        self.tmp = TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.cache = UnreachableCache(self.root)
        self.model = Model(id="m", name="M", family="f",
                           guides=["https://example.invalid/prompting"],
                           notes="Prefer short prompts.")

    def test_a_dead_source_still_produces_a_blob(self):
        """Offline builds keep working. This is the behaviour worth keeping."""
        blob, _ = self.cache.guidance_for(self.model)
        self.assertIn("Prefer short prompts.", blob)
        self.assertIn("[guidance unavailable:", blob)

    def test_the_reason_is_reported_when_asked_for(self):
        problems: list[str] = []
        self.cache.guidance_for(self.model, problems=problems)
        self.assertEqual(len(problems), 1)
        self.assertIn("https://example.invalid/prompting", problems[0])
        self.assertIn("404", problems[0])
        self.assertTrue(problems[0].startswith("m:"),
                        "a problem has to name the model, or a multi-model run "
                        f"cannot say which one is broken: {problems[0]!r}")

    def test_nothing_is_reported_when_every_source_reads(self):
        """The guard must stay quiet on the happy path or it will be ignored."""
        healthy = Model(id="m", name="M", family="f", guides=[], notes="A note.")
        problems: list[str] = []
        blob, _ = GuideCache(self.root).guidance_for(healthy, problems=problems)
        self.assertEqual(problems, [])
        self.assertFalse(GuideCache.is_degraded(blob))

    def test_a_degraded_blob_is_recognisable(self):
        blob, _ = self.cache.guidance_for(self.model)
        self.assertTrue(GuideCache.is_degraded(blob))

    def test_the_degraded_blob_hashes_differently(self):
        """The mechanism behind the whole problem, pinned so it stays understood.

        If this ever stopped being true the staleness cascade would not happen,
        and the guard below would be dead weight rather than protection.
        """
        _, broken_hash = self.cache.guidance_for(self.model)
        _, healthy_hash = GuideCache(self.root).guidance_for(
            Model(id="m", name="M", family="f", guides=[], notes="Prefer short prompts."))
        self.assertNotEqual(broken_hash, healthy_hash)


class PendingReportsProblems(unittest.TestCase):
    """`builder.pending` has to pass the reasons up, or the CLI cannot refuse."""

    def setUp(self):
        self.tmp = TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.lib = Library(self.root)
        self.lib.prompts.mkdir(parents=True)
        Seed(id="s1", title="S1", targets=["m"], body="do the thing").write(
            self.lib.prompts / "s1.md")
        self.models = {"m": Model(id="m", name="M", family="f",
                                  guides=["https://example.invalid/prompting"])}

    def test_problems_reach_the_caller(self):
        problems: list[str] = []
        pairs = builder.pending(self.lib, self.models, UnreachableCache(self.root),
                                problems=problems)
        self.assertEqual({p.key for p in pairs}, {"s1/m"},
                         "the pair is still staged; refusing is the CLI's decision, "
                         "not this function's")
        self.assertEqual(len(problems), 1)
        self.assertIn("404", problems[0])

    def test_problems_stay_empty_when_guidance_reads(self):
        models = {"m": Model(id="m", name="M", family="f", guides=[], notes="A note.")}
        problems: list[str] = []
        builder.pending(self.lib, models, GuideCache(self.root), problems=problems)
        self.assertEqual(problems, [])

    def test_a_model_is_reported_once_not_once_per_seed(self):
        """Guidance is fetched per model; the problem list must follow that."""
        Seed(id="s2", title="S2", targets=["m"], body="another").write(
            self.lib.prompts / "s2.md")
        problems: list[str] = []
        pairs = builder.pending(self.lib, self.models, UnreachableCache(self.root),
                                problems=problems)
        self.assertEqual(len(pairs), 2)
        self.assertEqual(len(problems), 1,
                         f"one broken source reported {len(problems)} times: {problems}")


if __name__ == "__main__":
    unittest.main()
