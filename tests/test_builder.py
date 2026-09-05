"""Tests for which pairs get rendered.

`pending()` is the gate in front of every LLM call, so a mistake here either
spends tokens rebuilding current prompts or, worse, leaves a stale prompt in the
dropdown looking fresh.
"""

import sys
import unittest
from pathlib import Path
from tempfile import TemporaryDirectory

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from promptlib import builder
from promptlib.guides import Model
from promptlib.store import Library, Render, Seed


class FakeCache:
    """Stands in for GuideCache so no test touches the network."""

    def __init__(self, hashes: dict[str, str], unreadable: set[str] | None = None):
        self.hashes = hashes
        self.forced = False
        #: Model ids whose guidance cannot be read, so the degraded path can be
        #: exercised without a network or a 404.
        self.unreadable = unreadable or set()

    def guidance_for(self, model, force=False, problems=None):
        if force:
            self.forced = True
        h = self.hashes.get(model.id, "g1")
        if model.id in self.unreadable:
            if problems is not None:
                problems.append(f"{model.id}: could not fetch https://example/doc")
            return (f"[guidance unavailable: could not fetch https://example/doc]", h)
        return (f"guidance for {model.id}", h)


def model(mid: str) -> Model:
    return Model(id=mid, name=mid.upper(), family="x", guides=[])


class Pending(unittest.TestCase):
    def setUp(self):
        self.tmp = TemporaryDirectory()
        self.root = Path(self.tmp.name)
        self.addCleanup(self.tmp.cleanup)
        self.lib = Library(self.root)
        self.lib.prompts.mkdir(parents=True)
        self.models = {"a": model("a"), "b": model("b")}
        self.cache = FakeCache({"a": "g1", "b": "g1"})
        Seed(id="s1", title="S1", targets=["a", "b"], body="do the thing").write(
            self.lib.prompts / "s1.md"
        )

    def build_render(self, seed_id="s1", mid="a", seed_hash=None, guide_hash="g1"):
        seed = self.lib.seed(seed_id)
        Render(
            seed_id=seed_id,
            model=mid,
            body="expanded",
            seed_hash=seed_hash or seed.hash,
            guide_hash=guide_hash,
        ).write(self.lib.render_path(seed_id, mid))

    def pending(self, **kw):
        return builder.pending(self.lib, self.models, self.cache, **kw)

    def test_everything_is_pending_when_nothing_is_built(self):
        self.assertEqual({p.key for p in self.pending()}, {"s1/a", "s1/b"})

    def test_a_current_render_is_not_rebuilt(self):
        self.build_render(mid="a")
        self.assertEqual({p.key for p in self.pending()}, {"s1/b"})

    def test_moved_guidance_restages_only_that_model(self):
        self.build_render(mid="a")
        self.build_render(mid="b")
        self.cache.hashes["b"] = "g2"
        self.assertEqual({p.key for p in self.pending()}, {"s1/b"})

    def test_force_rebuilds_current_renders(self):
        self.build_render(mid="a")
        self.build_render(mid="b")
        self.assertEqual({p.key for p in self.pending(force=True)}, {"s1/a", "s1/b"})

    def test_model_filter_narrows_the_work(self):
        self.assertEqual({p.key for p in self.pending(model_id="a")}, {"s1/a"})

    def test_refresh_guides_is_passed_through_to_the_cache(self):
        self.pending(refresh_guides=True)
        self.assertTrue(self.cache.forced)

    def test_a_target_missing_from_the_registry_is_skipped(self):
        Seed(id="s2", title="S2", targets=["a", "gone"], body="x").write(
            self.lib.prompts / "s2.md"
        )
        self.assertEqual({p.key for p in self.pending(seed_id="s2")}, {"s2/a"})

    def test_no_targets_means_every_registered_model(self):
        Seed(id="s3", title="S3", targets=[], body="x").write(self.lib.prompts / "s3.md")
        self.assertEqual({p.key for p in self.pending(seed_id="s3")}, {"s3/a", "s3/b"})

    def test_guidance_is_fetched_once_per_model_not_once_per_pair(self):
        Seed(id="s4", title="S4", targets=["a"], body="y").write(self.lib.prompts / "s4.md")
        calls = []
        original = self.cache.guidance_for

        def counting(m, force=False, problems=None):
            calls.append(m.id)
            return original(m, force=force, problems=problems)

        self.cache.guidance_for = counting
        self.pending()
        self.assertEqual(calls.count("a"), 1)


class BuilderJob(unittest.TestCase):
    def setUp(self):
        self.tmp = TemporaryDirectory()
        self.root = Path(self.tmp.name)
        self.addCleanup(self.tmp.cleanup)
        self.lib = Library(self.root)
        self.lib.prompts.mkdir(parents=True)

    def test_an_empty_build_finishes_immediately(self):
        b = builder.Builder(self.lib)
        self.assertTrue(b.start([]))
        self.assertFalse(b.job.running)

    def test_job_snapshot_does_not_alias_internal_state(self):
        b = builder.Builder(self.lib)
        b.start([])
        snapshot = b.job
        snapshot.errors.append("mutating the copy")
        self.assertEqual(b.job.errors, [])


if __name__ == "__main__":
    unittest.main()
