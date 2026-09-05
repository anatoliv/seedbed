"""The target registry and the guidance cache.

Guidance is *how to prompt* a given model. It comes from vendor documentation
(https) or from a file on this machine, and is cached under .cache/ so a build
works offline and so a render's inputs can be hashed.
"""

from __future__ import annotations

import re
import tomllib
import urllib.error
import urllib.request
from dataclasses import dataclass
from datetime import datetime, timezone
from html.parser import HTMLParser
from pathlib import Path

from .store import digest

CACHE_DIRNAME = ".cache"
USER_AGENT = "prompt-library/0.1 (personal tool)"
FETCH_TIMEOUT = 20


@dataclass
class Model:
    id: str
    name: str
    family: str
    guides: list[str]
    notes: str = ""


class _Text(HTMLParser):
    """Crude HTML-to-text. Vendor guides are prose; markup is noise here."""

    SKIP = {"script", "style", "nav", "footer", "header", "svg"}

    def __init__(self):
        super().__init__()
        self.parts: list[str] = []
        self._skip = 0

    def handle_starttag(self, tag, attrs):
        if tag in self.SKIP:
            self._skip += 1

    def handle_endtag(self, tag):
        if tag in self.SKIP and self._skip:
            self._skip -= 1
        elif tag in {"p", "li", "h1", "h2", "h3", "h4", "div", "tr"}:
            self.parts.append("\n")

    def handle_data(self, data):
        if not self._skip and data.strip():
            self.parts.append(data.strip())
            self.parts.append(" ")

    def text(self) -> str:
        joined = "".join(self.parts)
        return re.sub(r"\n{3,}", "\n\n", joined).strip()


def load_registry(path: Path) -> dict[str, Model]:
    data = tomllib.loads(path.read_text(encoding="utf-8"))
    models = {}
    for model_id, spec in data.get("models", {}).items():
        models[model_id] = Model(
            id=model_id,
            name=spec.get("name", model_id),
            family=spec.get("family", ""),
            guides=list(spec.get("guides", [])),
            notes=spec.get("notes", ""),
        )
    return models


def save_registry(path: Path, models: dict[str, Model]) -> None:
    """Rewrite models.toml from the registry.

    Everything above the first `[models.` table is kept verbatim: that block
    explains what a target is and why guides may be local files, and losing it
    the first time a model is added from the UI would be a poor trade.
    """
    header = ""
    if path.is_file():
        existing = path.read_text(encoding="utf-8")
        marker = existing.find("[models.")
        header = existing[:marker] if marker > 0 else existing if not existing.strip() else ""

    blocks = []
    for model in models.values():
        lines = [f'[models."{model.id}"]', f"name    = {_toml_str(model.name)}"]
        if model.family:
            lines.append(f"family  = {_toml_str(model.family)}")
        if model.guides:
            items = ",\n  ".join(_toml_str(g) for g in model.guides)
            lines.append(f"guides  = [\n  {items},\n]")
        else:
            lines.append("guides  = []")
        if model.notes:
            lines.append(f"notes   = {_toml_str(model.notes)}")
        blocks.append("\n".join(lines))

    path.write_text(header.rstrip("\n") + "\n\n" + "\n\n".join(blocks) + "\n",
                    encoding="utf-8")


def _toml_str(value: str) -> str:
    escaped = value.replace("\\", "\\\\").replace('"', '\\"').replace("\n", "\\n")
    return f'"{escaped}"'


class GuideCache:
    def __init__(self, root: Path):
        self.dir = root / CACHE_DIRNAME / "guides"

    def _slot(self, source: str) -> Path:
        return self.dir / f"{digest(source)}.txt"

    def fetch(self, source: str, force: bool = False) -> tuple[str, bool]:
        """Return (text, fetched_now). Local paths are read directly, never cached."""
        local = Path(source).expanduser()
        if not source.startswith(("http://", "https://")):
            if not local.is_file():
                raise FileNotFoundError(f"guide source not found on disk: {source}")
            return local.read_text(encoding="utf-8"), False

        slot = self._slot(source)
        if slot.is_file() and not force:
            return slot.read_text(encoding="utf-8"), False

        req = urllib.request.Request(source, headers={"User-Agent": USER_AGENT})
        try:
            with urllib.request.urlopen(req, timeout=FETCH_TIMEOUT) as resp:
                raw = resp.read().decode("utf-8", errors="replace")
        except (urllib.error.URLError, TimeoutError) as exc:
            if slot.is_file():
                return slot.read_text(encoding="utf-8"), False  # stale beats nothing
            raise RuntimeError(f"could not fetch {source}: {exc}") from None

        parser = _Text()
        parser.feed(raw)
        text = parser.text()
        slot.parent.mkdir(parents=True, exist_ok=True)
        stamp = datetime.now(timezone.utc).strftime("%Y-%m-%d")
        slot.write_text(f"# source: {source}\n# fetched: {stamp}\n\n{text}\n", encoding="utf-8")
        return slot.read_text(encoding="utf-8"), True

    #: What goes into the blob when a source cannot be read. Named because the
    #: builder tests for it: a blob carrying this is degraded, and a render
    #: built from it is worse than the one already on disk.
    UNAVAILABLE = "[guidance unavailable:"

    def guidance_for(self, model: Model, force: bool = False,
                     problems: list[str] | None = None) -> tuple[str, str]:
        """Concatenated guidance for a model, plus its hash.

        A model with no sources is legitimate — a local model whose guidance is
        the registry note. The note is always included, so changing it restages
        every render for that model.

        **Pass `problems` to find out when the guidance is degraded.** A source
        that cannot be read still produces a blob, because a build with partial
        guidance beats no build at all when you are offline. But that blob has a
        different hash, which restages every render for the model, and the
        rebuild then runs on WORSE input than the one it replaces. Nothing used
        to say so. Appending the reasons here is what lets `guides` exit
        non-zero and the builder refuse.
        """
        chunks = []
        if model.notes:
            chunks.append(f"Notes for {model.name}:\n{model.notes}")
        for source in model.guides:
            try:
                text, _ = self.fetch(source, force=force)
            except (RuntimeError, FileNotFoundError) as exc:
                chunks.append(f"{self.UNAVAILABLE} {exc}]")
                if problems is not None:
                    problems.append(f"{model.id}: {exc}")
                continue
            chunks.append(text)
        blob = "\n\n---\n\n".join(chunks)
        return blob, digest(blob)

    @classmethod
    def is_degraded(cls, blob: str) -> bool:
        """True when at least one source could not be read into this blob."""
        return cls.UNAVAILABLE in blob
