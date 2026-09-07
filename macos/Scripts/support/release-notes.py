#!/usr/bin/env python3
"""Write Sparkle release-notes files from the app's own What's New list.

Sparkle shows the contents of a file named after the archive, with an `.html`
extension and sitting beside it, as the release notes in the update dialog.
Seedbed shipped none, so every user was asked to accept a binary update against
an empty pane — while the app already carried the notes for all nine releases in
`Sources/Seedbed/WhatsNew.swift` and the release gate already refused to ship a
version without an entry there.

So this does not write release notes. It reads the ones that exist and puts them
where Sparkle looks, which keeps one source: edit WhatsNew.swift, and the
in-app "What's New" screen and the updater say the same thing.

    Scripts/support/release-notes.py <dist-dir> [--check]

`--check` writes nothing and exits non-zero if the current version has no entry.
"""

from __future__ import annotations

import html
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent.parent          # macos/
SOURCE = ROOT / "Sources" / "Seedbed" / "WhatsNew.swift"

# `text: "a " + "b"` across lines. Grab every double-quoted segment and join.
_SEGMENT = re.compile(r'"((?:[^"\\]|\\.)*)"')
_RELEASE = re.compile(
    r'WhatsNewRelease\(\s*version:\s*"([^"]+)"\s*,\s*date:\s*"([^"]+)"\s*,'
    r'\s*highlight:\s*(.*?)\s*,\s*changes:\s*\[(.*?)\]\s*\)',
    re.DOTALL,
)
_KIND = re.compile(r'kind:\s*\.(\w+)')


def _joined(literal: str) -> str:
    """Swift's `"a " + "b"` is one string; give it back as one."""
    parts = [m.group(1) for m in _SEGMENT.finditer(literal)]
    return "".join(parts).replace('\\"', '"').replace("\\\\", "\\")


def releases(source: Path = SOURCE) -> list[dict]:
    text = source.read_text(encoding="utf-8")
    out = []
    for version, date, highlight, changes in _RELEASE.findall(text):
        entries = []
        for chunk in changes.split("WhatsNewChange(")[1:]:
            kind = _KIND.search(chunk)
            body = _joined(chunk)
            if kind and body:
                entries.append((kind.group(1), body))
        out.append({
            "version": version,
            "date": date,
            "highlight": _joined(highlight),
            "changes": entries,
        })
    return out


def render(release: dict) -> str:
    """A fragment, deliberately: generate_appcast embeds a notes file as CDATA
    in the item's <description> only when it carries no DOCTYPE and no body
    tags, and otherwise treats it as a linked file needing a URL prefix and its
    own hosting. Embedded is simpler and leaves nothing to publish separately.
    No styling either — Sparkle's update window supplies that, and matching the
    user's appearance matters more than matching ours."""
    lines = [
        f"<h3>Seedbed {html.escape(release['version'])}</h3>",
        f"<p><em>{html.escape(release['date'])}</em></p>",
        f"<p>{html.escape(release['highlight'])}</p>",
        "<ul>",
    ]
    for kind, body in release["changes"]:
        lines.append(f"<li><b>{html.escape(kind.capitalize())}.</b> {html.escape(body)}</li>")
    lines.append("</ul>")
    return "\n".join(lines)


def main(argv: list[str]) -> int:
    check = "--check" in argv
    positional = [a for a in argv if not a.startswith("--")]
    dist = Path(positional[0]) if positional else ROOT / "dist"

    found = releases()
    if not found:
        print("error: no WhatsNewRelease entries parsed from WhatsNew.swift", file=sys.stderr)
        return 1

    if check:
        print(f"release notes parsed for {len(found)} versions: "
              + ", ".join(r["version"] for r in found))
        return 0

    dist.mkdir(parents=True, exist_ok=True)
    written = 0
    for release in found:
        # Named for the archive Sparkle is describing, which is how it finds
        # them — so the name has to follow the DMG that is actually there.
        # 0.1.0 shipped as `_aarch64` before the build went universal, and a
        # file named for a convention rather than for the artifact is a file
        # generate_appcast silently ignores.
        matches = sorted(dist.glob(f"Seedbed_{release['version']}_*.dmg"))
        stem = matches[0].stem if matches else f"Seedbed_{release['version']}_universal"
        (dist / f"{stem}.html").write_text(render(release), encoding="utf-8")
        written += 1
    print(f"    {written} release-note files in {dist}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
