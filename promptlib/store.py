"""Reading and writing the library's files.

Frontmatter is TOML between `+++` fences, so parsing needs nothing outside the
standard library. A seed is what you maintain; a render is generated from one.
"""

from __future__ import annotations

import hashlib
import tomllib
from dataclasses import dataclass, field
from pathlib import Path

FENCE = "+++"


class FormatError(ValueError):
    """A file on disk is not a well-formed prompt file."""


def _split(text: str, source: str) -> tuple[dict, str]:
    """Return (frontmatter, body). Raises FormatError rather than guessing."""
    lines = text.splitlines()
    if not lines or lines[0].strip() != FENCE:
        raise FormatError(f"{source}: must start with a {FENCE} frontmatter fence")
    try:
        close = next(i for i, line in enumerate(lines[1:], 1) if line.strip() == FENCE)
    except StopIteration:
        raise FormatError(f"{source}: frontmatter fence is never closed") from None
    try:
        meta = tomllib.loads("\n".join(lines[1:close]))
    except tomllib.TOMLDecodeError as exc:
        raise FormatError(f"{source}: frontmatter is not valid TOML. {exc}") from None
    return meta, "\n".join(lines[close + 1 :]).strip()


def _render_frontmatter(meta: dict) -> str:
    """Minimal TOML writer: strings, booleans, and lists of strings."""
    out = []
    for key, value in meta.items():
        if isinstance(value, bool):
            out.append(f"{key} = {'true' if value else 'false'}")
        elif isinstance(value, list):
            items = ", ".join(_quote(v) for v in value)
            out.append(f"{key} = [{items}]")
        else:
            out.append(f"{key} = {_quote(value)}")
    return "\n".join(out)


def _quote(value) -> str:
    s = str(value)
    if '"' in s or "\\" in s:
        s = s.replace("\\", "\\\\").replace('"', '\\"')
    return f'"{s}"'


def normalise_context(value) -> str:
    """Accept what is on disk, reject what cannot be honoured.

    An unknown context is a FormatError rather than a silent fallback: a seed
    saying `context = "repl"` was written with an intent this tool cannot serve,
    and quietly building it as an agent prompt would be the accidental-assumption
    problem all over again.
    """
    if value is None or value == "":
        return DEFAULT_CONTEXT
    text = str(value).strip().lower()
    if text not in CONTEXTS:
        known = ", ".join(sorted(CONTEXTS))
        raise FormatError(f"unknown context {value!r}. Expected one of: {known}")
    return text


def digest(*parts: str) -> str:
    """Short content hash. Used to decide whether a render is stale."""
    h = hashlib.sha256()
    for part in parts:
        h.update(part.encode("utf-8"))
        h.update(b"\0")
    return h.hexdigest()[:12]


#: Where a prompt is going to be used, which decides how its render is written.
#:
#: Measured 2026-09-05: the renders instruct a model to reproduce a
#: bug and read the surrounding code before changing anything. That is right for
#: an agent sitting in a checkout and wrong for a chat window holding one
#: snippet — given a bare snippet the render searched for code that was not
#: there and declined to fix anything, losing both fix tasks to the raw seed.
#: Given the same bug inside the repo it recovered completely.
#:
#: The tool was building for one context and handing the result to another. This
#: makes the assumption explicit instead of accidental.
CONTEXTS: dict[str, str] = {
    "agent": "an agent with the repository open, able to read files, run "
             "commands and reproduce a failure before changing anything",
    "chat": "a chat window, where the person pastes the prompt followed by one "
            "snippet and nothing else is available",
}

#: What a seed with no `context` means. Every prompt written before the field
#: existed was written for an agent, so this keeps them correct rather than
#: silently reinterpreting them.
DEFAULT_CONTEXT = "agent"


@dataclass
class Seed:
    """A short prompt you maintain by hand."""

    id: str
    body: str
    title: str = ""
    targets: list[str] = field(default_factory=list)
    tags: list[str] = field(default_factory=list)
    category: str = ""
    pinned: bool = False
    context: str = DEFAULT_CONTEXT
    path: Path | None = None

    @property
    def hash(self) -> str:
        """What decides staleness: the body, and the context it is written for.

        Pinning, retitling or re-filing must not invalidate a render that is
        still correct, so those are excluded. Context is not like them — it
        changes what the enhancer is asked to produce, so a render built for one
        context is genuinely wrong for the other and has to be rebuilt.
        """
        return digest(self.body, self.context)

    @classmethod
    def load(cls, path: Path) -> "Seed":
        meta, body = _split(path.read_text(encoding="utf-8"), path.name)
        if not body:
            raise FormatError(f"{path.name}: seed body is empty")
        return cls(
            id=meta.get("id") or path.stem,
            body=body,
            title=meta.get("title", ""),
            targets=list(meta.get("targets", [])),
            tags=list(meta.get("tags", [])),
            category=meta.get("category", ""),
            pinned=bool(meta.get("pinned", False)),
            context=normalise_context(meta.get("context")),
            path=path,
        )

    def write(self, path: Path) -> None:
        meta = {
            "id": self.id,
            "title": self.title,
            "targets": self.targets,
            "tags": self.tags,
            "category": self.category,
            "pinned": self.pinned,
            "context": self.context,
        }
        path.write_text(
            f"{FENCE}\n{_render_frontmatter(meta)}\n{FENCE}\n{self.body}\n",
            encoding="utf-8",
        )
        self.path = path


@dataclass
class Render:
    """A seed expanded for one target model."""

    seed_id: str
    model: str
    body: str
    seed_hash: str = ""
    guide_hash: str = ""
    enhancer: str = ""
    generated: str = ""
    #: The context this render was written for. Recorded as well as hashed, so
    #: `list` can say "built for chat, prompt now says agent" instead of the
    #: bare "stale" a hash comparison alone would give.
    context: str = DEFAULT_CONTEXT
    path: Path | None = None

    @classmethod
    def load(cls, path: Path) -> "Render":
        meta, body = _split(path.read_text(encoding="utf-8"), path.name)
        return cls(
            seed_id=meta.get("seed", path.stem),
            model=meta.get("model", ""),
            body=body,
            seed_hash=meta.get("seed_hash", ""),
            guide_hash=meta.get("guide_hash", ""),
            enhancer=meta.get("enhancer", ""),
            generated=meta.get("generated", ""),
            context=normalise_context(meta.get("context")),
            path=path,
        )

    def write(self, path: Path) -> None:
        path.parent.mkdir(parents=True, exist_ok=True)
        meta = {
            "seed": self.seed_id,
            "model": self.model,
            "seed_hash": self.seed_hash,
            "guide_hash": self.guide_hash,
            "enhancer": self.enhancer,
            "generated": self.generated,
            "context": self.context,
        }
        path.write_text(
            f"{FENCE}\n{_render_frontmatter(meta)}\n{FENCE}\n{self.body}\n",
            encoding="utf-8",
        )
        self.path = path

    def is_current(self, seed: Seed, guide_hash: str) -> bool:
        """True when neither the seed nor the guidance has moved since this render."""
        return self.seed_hash == seed.hash and self.guide_hash == guide_hash


class Library:
    """The repository on disk."""

    def __init__(self, root: Path):
        self.root = root
        self.prompts = root / "prompts"
        self.rendered = root / "rendered"

    def seeds(self) -> list[Seed]:
        if not self.prompts.is_dir():
            return []
        return sorted(
            (Seed.load(p) for p in self.prompts.glob("*.md")), key=lambda s: s.id
        )

    def seed(self, seed_id: str) -> Seed:
        path = self.prompts / f"{seed_id}.md"
        if not path.is_file():
            raise FileNotFoundError(f"no seed named {seed_id!r} in {self.prompts}")
        return Seed.load(path)

    def render_path(self, seed_id: str, model: str) -> Path:
        return self.rendered / model / f"{seed_id}.md"

    def render(self, seed_id: str, model: str) -> Render | None:
        path = self.render_path(seed_id, model)
        return Render.load(path) if path.is_file() else None
