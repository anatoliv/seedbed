"""Placeholders in a prompt, and the values you have used for them before.

A tailored prompt usually carries `{{PLACEHOLDER}}` tokens — the enhancer is told
to keep them, and it also introduces its own (`{{BUG_REPORT}}`, `{{CODE}}`).
Filling those by hand in a text editor is exactly the friction this tool exists
to remove, so the values are remembered and offered back.

Values are machine-local (gitignored), the same call as the copy counter: a
tracked file rewritten on every fill would mean a diff per copy and a merge
conflict whenever two machines use the same prompt. Project names and paths are
also the kind of thing worth keeping out of a synced file by default.
"""

from __future__ import annotations

import json
import re
from pathlib import Path

FILENAME = ".variables.json"
PLACEHOLDER = re.compile(r"\{\{\s*([A-Za-z][A-Za-z0-9_]*)\s*\}\}")
MAX_HISTORY = 25


def find(text: str) -> list[str]:
    """Placeholder names in first-appearance order, deduplicated.

    Order matters: the fill form is easier to work through when it matches the
    order the prompt reads in.
    """
    seen: list[str] = []
    for match in PLACEHOLDER.finditer(text):
        name = match.group(1)
        if name not in seen:
            seen.append(name)
    return seen


def fill(text: str, values: dict[str, str]) -> str:
    """Substitute what was provided, and leave the rest standing.

    An unanswered placeholder stays visible as `{{NAME}}` rather than becoming
    an empty string — a prompt with a silent hole in it is worse than one that
    says what is missing.
    """
    def replace(match: re.Match) -> str:
        name = match.group(1)
        value = values.get(name)
        return value if value not in (None, "") else match.group(0)

    return PLACEHOLDER.sub(replace, text)


class History:
    """Values previously entered, most recent first, per placeholder name."""

    def __init__(self, root: Path):
        self.path = root / FILENAME
        self.data: dict[str, list[str]] = {}
        self.load()

    def load(self) -> None:
        try:
            raw = json.loads(self.path.read_text(encoding="utf-8"))
            self.data = {k: list(v) for k, v in raw.items() if isinstance(v, list)}
        except (FileNotFoundError, json.JSONDecodeError, OSError, AttributeError):
            self.data = {}   # a corrupt history must never block a fill

    def save(self) -> None:
        try:
            self.path.write_text(
                json.dumps(self.data, indent=1, sort_keys=True), encoding="utf-8"
            )
        except OSError:
            pass

    def values(self, name: str) -> list[str]:
        return list(self.data.get(name, []))

    def record(self, name: str, value: str) -> None:
        """Most recent first, no duplicates, capped — so the dropdown stays a
        shortlist rather than a log."""
        value = value.strip()
        if not value:
            return
        existing = [v for v in self.data.get(name, []) if v != value]
        self.data[name] = [value] + existing[: MAX_HISTORY - 1]

    def record_all(self, values: dict[str, str]) -> None:
        for name, value in values.items():
            self.record(name, value)
        self.save()

    def as_dict(self) -> dict[str, list[str]]:
        return {k: list(v) for k, v in self.data.items()}
