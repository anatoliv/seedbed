"""How often each prompt is copied, and when.

Deliberately NOT in the seed files. A counter bumped on every copy would rewrite
a tracked file constantly: noisy diffs, and a merge conflict every time two
machines copy the same prompt. This lives in a gitignored file instead, so
"most used" is per-machine — which is also the honest answer, since it reflects
how you work on that machine.
"""

from __future__ import annotations

import json
from datetime import datetime, timezone
from pathlib import Path

FILENAME = ".usage.json"


class Usage:
    def __init__(self, root: Path):
        self.path = root / FILENAME
        self.data: dict[str, dict] = {}
        self.load()

    def load(self) -> None:
        try:
            self.data = json.loads(self.path.read_text(encoding="utf-8"))
        except (FileNotFoundError, json.JSONDecodeError, OSError):
            self.data = {}   # a corrupt counter file must never block a copy

    def save(self) -> None:
        try:
            self.path.write_text(json.dumps(self.data, indent=1, sort_keys=True), encoding="utf-8")
        except OSError:
            pass

    def record(self, seed_id: str, model: str) -> None:
        entry = self.data.setdefault(seed_id, {"count": 0, "last_used": "", "models": {}})
        entry["count"] = entry.get("count", 0) + 1
        entry["last_used"] = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
        entry["models"][model] = entry["models"].get(model, 0) + 1
        self.save()

    def count(self, seed_id: str) -> int:
        return int(self.data.get(seed_id, {}).get("count", 0))

    def last_used(self, seed_id: str) -> str:
        return str(self.data.get(seed_id, {}).get("last_used", ""))

    def favourite_model(self, seed_id: str) -> str:
        """The model this prompt is copied for most — a better default than the
        first in the list once there are seven of them."""
        models = self.data.get(seed_id, {}).get("models", {})
        return max(models, key=models.get) if models else ""
