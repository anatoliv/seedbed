#!/usr/bin/env python3
"""Keep the public pages' asset query stamps tied to their actual bytes."""

from __future__ import annotations

import hashlib
import re
import sys
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
SITE = ROOT / "site"
PAGES = (
    SITE / "index.html", SITE / "privacy.html", SITE / "evidence/index.html", SITE / "404.html",
)
ASSETS = (
    "og.png", "favicon.svg", "favicon-32.png", "apple-touch-icon.png",
    "site.css", "seedbed-mark.svg", "seedbed-app-icon.svg",
)
NAMES = "|".join(re.escape(name) for name in ASSETS)
REFERENCE = re.compile(
    rf'(?P<start>(?:href|src|content)=")(?P<host>https://seedbed\.dev)?/'
    rf'(?P<name>{NAMES})(?:\?v=[^" ]*)?"'
)


def stamp(name: str) -> str:
    return hashlib.sha256((SITE / name).read_bytes()).hexdigest()[:12]


def update(page: Path) -> bool:
    # Preserve undecodable bytes so the publish guard can report its
    # path and line instead of stopping here with a traceback.
    before = page.read_text(encoding="utf-8", errors="surrogateescape")
    after = REFERENCE.sub(
        lambda match: f'{match["start"]}{match["host"] or ""}/{match["name"]}'
        f'?v={stamp(match["name"])}"',
        before,
    )
    if after != before and "--write" in sys.argv:
        page.write_text(after, encoding="utf-8", errors="surrogateescape")
    return before == after


def main() -> int:
    if len(sys.argv) != 2 or sys.argv[1] not in {"--check", "--write"}:
        print("usage: stamp-site-assets.py --check|--write", file=sys.stderr)
        return 2
    stale = [page for page in PAGES if not update(page)]
    if stale and sys.argv[1] == "--check":
        for page in stale:
            print(f"stale asset stamp: {page.relative_to(ROOT)}", file=sys.stderr)
        return 1
    print(f"asset stamps current across {len(PAGES)} pages")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
