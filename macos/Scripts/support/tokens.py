"""Read a `Theme.swift` token surface into plain data, so two apps' design
systems can be compared by a machine instead of by eye.

Both files are parsed by THIS function, so the comparison is like for like.
Values are normalised rather than string-matched, because the same token can be
written two correct ways: Reference spells a font `.system(size: 21, weight:
.semibold, design: .rounded)` and Seedbed spells the identical thing
`.system(size: ReadingSize.display, weight: .semibold, design: .rounded)`.
Comparing the raw text would report a difference that is not one, and a check
that cries wolf is a check that gets muted.
"""

from __future__ import annotations

import json
import re
import sys
from pathlib import Path

_ENUM = re.compile(r"^\s*enum (\w+) \{")
_LET = re.compile(
    r"^\s*static let (\w+)\s*(?::\s*[\w<>.]+)?\s*=\s*(.+?)\s*(?://.*)?$"
)
_CLOSE = re.compile(r"^\s*\}\s*$")


def parse(path: Path) -> dict[str, dict[str, str]]:
    """`{enum name: {token: normalised value}}` for every nested token enum."""
    groups: dict[str, dict[str, str]] = {}
    current: str | None = None
    depth = 0
    for line in path.read_text().splitlines():
        match = _ENUM.match(line)
        if match:
            current = match.group(1)
            groups.setdefault(current, {})
            depth = 0
            continue
        if current is None:
            continue
        match = _LET.match(line)
        if match:
            groups[current][match.group(1)] = match.group(2).strip()
            continue
        if _CLOSE.match(line):
            if depth == 0:
                current = None
            else:
                depth -= 1
    return {name: values for name, values in groups.items() if values}


def resolve(groups: dict[str, dict[str, str]]) -> dict[str, dict[str, str]]:
    """Replace `Group.token` references with the literal they stand for.

    One pass is enough: the token files are one level of indirection deep, and a
    deeper chain would be worth failing on rather than silently resolving.
    """
    flat = {
        f"{group}.{token}": value
        for group, values in groups.items()
        for token, value in values.items()
    }
    out: dict[str, dict[str, str]] = {}
    for group, values in groups.items():
        out[group] = {}
        for token, value in values.items():
            for ref, literal in flat.items():
                value = re.sub(rf"\b{re.escape(ref)}\b", literal, value)
            out[group][token] = re.sub(r"\s+", " ", value).strip()
    return out


def spec(path: Path) -> dict[str, dict[str, str]]:
    return resolve(parse(path))


if __name__ == "__main__":
    if len(sys.argv) != 2:
        print("usage: tokens.py <path to Theme.swift>", file=sys.stderr)
        raise SystemExit(2)
    print(json.dumps(spec(Path(sys.argv[1])), indent=2, sort_keys=True))
