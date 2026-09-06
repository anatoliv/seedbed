"""Deciding what needs rendering, and running those renders in the background.

Shared by the CLI and the server so "what is stale" has exactly one definition.
Rendering calls an LLM and takes tens of seconds per pair, so anything with a UI
has to run it off the request thread and report progress.
"""

from __future__ import annotations

import threading
from dataclasses import dataclass, field
from datetime import date, datetime, timezone
from pathlib import Path

from .enhance import DEFAULT_BACKEND, EnhancerError, enhance
from .enhancer import EnhancerConfig
from .guides import GuideCache, Model
from .store import CONTEXTS, Library, Render, Seed
from .variables import find as find_variables
from . import compare as compare_mod



@dataclass
class Pair:
    """One seed rendered for one target."""

    seed: Seed
    model: Model
    guidance: str
    guide_hash: str

    @property
    def key(self) -> str:
        return f"{self.seed.id}/{self.model.id}"


def targets_for(seed: Seed, models: dict[str, Model]) -> list[str]:
    """A seed with no explicit targets is rendered for every registered model."""
    wanted = seed.targets or list(models)
    return [m for m in wanted if m in models]


def pending(
    lib: Library,
    models: dict[str, Model],
    cache: GuideCache,
    *,
    seed_id: str | None = None,
    model_id: str | None = None,
    force: bool = False,
    refresh_guides: bool = False,
    problems: list[str] | None = None,
) -> list[Pair]:
    """Every pair whose render is missing or stale.

    `problems` collects the reason for every guidance source that could not be
    read, so a caller can tell the difference between "these renders are stale"
    and "these renders are stale because a vendor doc 404'd and the replacement
    would be built on less than the original was".
    """
    seeds = [lib.seed(seed_id)] if seed_id else lib.seeds()
    guidance: dict[str, tuple[str, str]] = {}
    out: list[Pair] = []
    for seed in seeds:
        for mid in targets_for(seed, models):
            if model_id and mid != model_id:
                continue
            if mid not in guidance:
                guidance[mid] = cache.guidance_for(
                    models[mid], force=refresh_guides, problems=problems)
            text, ghash = guidance[mid]
            existing = lib.render(seed.id, mid)
            if existing and existing.is_current(seed, ghash) and not force:
                continue
            out.append(Pair(seed=seed, model=models[mid], guidance=text, guide_hash=ghash))
    return out


def render_one(lib: Library, pair: Pair, enhancer: str | None = None,
               config: EnhancerConfig | None = None) -> Path:
    """Render a single pair and write it. Raises EnhancerError on failure."""
    config = config or EnhancerConfig.load(lib.root)
    body = enhance(pair.seed.body, pair.model.name, pair.guidance,
                   backend=enhancer, config=config, context=pair.seed.context)
    render = Render(
        seed_id=pair.seed.id,
        model=pair.model.id,
        body=body,
        seed_hash=pair.seed.hash,
        guide_hash=pair.guide_hash,
        enhancer=enhancer or config.auth,
        generated=date.today().isoformat(),
        context=pair.seed.context,
    )
    path = lib.render_path(pair.seed.id, pair.model.id)
    render.write(path)
    return path


@dataclass
class Job:
    """A background build. One at a time, so two builds cannot race on a file."""

    total: int = 0
    done: int = 0
    current: str = ""
    errors: list[str] = field(default_factory=list)
    finished: bool = True
    started: str = ""

    @property
    def running(self) -> bool:
        return not self.finished


class Builder:
    """Runs builds on a worker thread and exposes progress."""

    def __init__(self, lib: Library, enhancer: str | None = None):
        self.lib = lib
        self.enhancer = enhancer
        self._lock = threading.Lock()
        self._job = Job()
        self._thread: threading.Thread | None = None

    @property
    def job(self) -> Job:
        with self._lock:
            return Job(
                total=self._job.total,
                done=self._job.done,
                current=self._job.current,
                errors=list(self._job.errors),
                finished=self._job.finished,
                started=self._job.started,
            )

    def start(self, pairs: list[Pair]) -> bool:
        """Begin a build. Returns False when one is already running."""
        with self._lock:
            if not self._job.finished:
                return False
            self._job = Job(
                total=len(pairs),
                done=0,
                current="",
                errors=[],
                finished=not pairs,
                started=datetime.now(timezone.utc).strftime("%H:%M:%S"),
            )
        if not pairs:
            return True
        self._thread = threading.Thread(target=self._run, args=(pairs,), daemon=True)
        self._thread.start()
        return True

    def _run(self, pairs: list[Pair]) -> None:
        for pair in pairs:
            with self._lock:
                self._job.current = pair.key
            try:
                render_one(self.lib, pair, self.enhancer)
            except EnhancerError as exc:
                with self._lock:
                    self._job.errors.append(f"{pair.key}: {exc}")
            except OSError as exc:
                with self._lock:
                    self._job.errors.append(f"{pair.key}: could not write render. {exc}")
            finally:
                with self._lock:
                    self._job.done += 1
        with self._lock:
            self._job.current = ""
            self._job.finished = True


def library_view(lib: Library, models: dict[str, Model], cache, usage=None) -> dict:
    """The whole library as plain data: seeds, targets, state, and what the UI
    needs to sort — pin flag, copy count, last use, newest render date.

    One definition, consumed by the CLI's json command, the web server and the
    macOS app. Anything that lists prompts reads this.
    """
    guide_hashes: dict[str, str] = {}
    seeds = []
    for seed in lib.seeds():
        entries = []
        for mid in targets_for(seed, models):
            if mid not in guide_hashes:
                guide_hashes[mid] = cache.guidance_for(models[mid])[1]
            render = lib.render(seed.id, mid)
            if render is None:
                state = "missing"
            elif render.is_current(seed, guide_hashes[mid]):
                state = "current"
            else:
                state = "stale"
            entries.append(
                {
                    "model": mid,
                    "name": models[mid].name,
                    "state": state,
                    "generated": render.generated if render else "",
                    "words": len(render.body.split()) if render else 0,
                    # Per target, not per seed: the enhancer introduces its own
                    # placeholders, so two models can want different values.
                    "variables": find_variables(render.body) if render else [],
                }
            )
        seeds.append(
            {
                "id": seed.id,
                "title": seed.title or seed.id.replace("-", " "),
                "body": seed.body,
                "tags": seed.tags,
                "category": seed.category,
                "pinned": seed.pinned,
                "context": seed.context,
                "targets": entries,
                "uses": usage.count(seed.id) if usage else 0,
                "last_used": usage.last_used(seed.id) if usage else "",
                "favourite_model": usage.favourite_model(seed.id) if usage else "",
                # Newest render date across targets: "last refreshed" for sorting.
                "refreshed": max((e["generated"] for e in entries), default=""),
                "comparison": compare_mod.state(lib, seed.id, models),
            }
        )
    return {
        "seeds": seeds,
        "models": [
            {
                "id": m.id,
                "name": m.name,
                "family": m.family,
                "guides": m.guides,
                "notes": m.notes,
            }
            for m in models.values()
        ],
        # Every category in use, so a filter can be offered without inventing one.
        "categories": sorted({s["category"] for s in seeds if s["category"]}),
        # The context vocabulary and what each one means, so the app's picker is
        # generated from the library rather than being a second hardcoded copy
        # that can disagree with it.
        "contexts": [{"id": k, "description": v} for k, v in sorted(CONTEXTS.items())],
    }
