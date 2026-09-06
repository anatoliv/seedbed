"""A written comparison of what each model made of the same seed.

Reading four long prompts side by side tells you they are different; it does not
tell you *how*, and that is the question the library exists to answer. So the
enhancer is asked to say it in a few lines.

Cached against a hash of the renders themselves, so it is generated once and
regenerated exactly when one of them changes.
"""

from __future__ import annotations

from datetime import date
from pathlib import Path

from .enhance import run_prompt
from .store import Library, digest

SUMMARY_DIR = "comparisons"

#: Excerpt cap per render. Four full renders is a few thousand tokens, which is
#: affordable, but a prompt library grows and the cost should not grow with it.
EXCERPT_CHARS = 4000

SYSTEM = """You compare several versions of the same instruction, each written \
for a different AI model.

You are given one prompt per model, all generated from the same short seed. Say \
how they DIFFER, in a way that helps a developer choose between them.

Rules:
- Lead with the single biggest difference in one sentence.
- Then 3 to 6 bullets. Each names the models it is about.
- Compare things that change the output: structure (prose vs numbered steps), \
whether an output format is imposed, length and density, what each forbids, \
what each emphasises, whether examples are included, and tone.
- Quote at most a few words at a time, only when the wording is the point.
- Do not summarise what the prompts are for; the reader knows. Do not praise \
any of them or say which is best unless one is clearly missing something the \
others have.
- No preamble, no heading, no closing summary. Plain text with "- " bullets."""


def _sources(lib: Library, seed_id: str, models: dict) -> list[tuple[str, str, str]]:
    """(model id, display name, body) for every render that exists."""
    out = []
    for model_id, model in models.items():
        render = lib.render(seed_id, model_id)
        if render and render.body.strip():
            out.append((model_id, model.name, render.body))
    return out


def fingerprint(sources: list[tuple[str, str, str]]) -> str:
    """Changes when any render changes, or when a model joins or leaves."""
    return digest(*[f"{mid}\n{body}" for mid, _, body in sources])


def summary_path(lib: Library, seed_id: str) -> Path:
    return lib.root / SUMMARY_DIR / f"{seed_id}.md"


def load(lib: Library, seed_id: str) -> tuple[str, str, str]:
    """Return (text, fingerprint, generated) for the stored comparison."""
    path = summary_path(lib, seed_id)
    if not path.is_file():
        return "", "", ""
    text = path.read_text(encoding="utf-8")
    stamp, mark, generated = "", "", ""
    lines = text.splitlines()
    body_start = 0
    for index, line in enumerate(lines[:4]):
        if line.startswith("<!-- renders:"):
            mark = line.removeprefix("<!-- renders:").split()[0].strip()
            generated = line.rstrip(" -->").split("generated:")[-1].strip()
            body_start = index + 1
    stamp = "\n".join(lines[body_start:]).strip()
    return stamp, mark, generated


def build(lib: Library, seed_id: str, models: dict, config=None, force: bool = False
          ) -> tuple[str, bool]:
    """Return (summary, regenerated). Cached unless the renders moved."""
    sources = _sources(lib, seed_id, models)
    if len(sources) < 2:
        return ("Only one model has been built for this prompt. "
                "build another to compare them.", False)

    mark = fingerprint(sources)
    cached, cached_mark, _ = load(lib, seed_id)
    if cached and cached_mark == mark and not force:
        return cached, False

    parts = []
    for _, name, body in sources:
        excerpt = body[:EXCERPT_CHARS]
        if len(body) > EXCERPT_CHARS:
            excerpt += "\n…(truncated)"
        parts.append(f"<prompt model=\"{name}\" words=\"{len(body.split())}\">\n"
                     f"{excerpt}\n</prompt>")
    text = run_prompt(SYSTEM, "\n\n".join(parts), config=config).strip()

    path = summary_path(lib, seed_id)
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(
        f"<!-- renders:{mark} generated:{date.today().isoformat()} -->\n{text}\n",
        encoding="utf-8")
    return text, True


def state(lib: Library, seed_id: str, models: dict) -> str:
    """"missing" | "stale" | "current" — what the UI needs to show a badge."""
    sources = _sources(lib, seed_id, models)
    if len(sources) < 2:
        return "not-applicable"
    cached, cached_mark, _ = load(lib, seed_id)
    if not cached:
        return "missing"
    return "current" if cached_mark == fingerprint(sources) else "stale"
