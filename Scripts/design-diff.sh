#!/usr/bin/env bash
# Print every shared design-token difference between Seedbed's Theme.swift and
# the design contract it is held to.
#
# With no argument this checks against the vendored contract in
# macos/Design/reference-tokens.json, which is the definition Seedbed ships and
# the only one the tests use. Pass a path to a Tokens.swift, or set
# REFERENCE_THEME, to compare against an external source before refreshing the
# vendored copy — that is the one moment the two can legitimately differ.
set -euo pipefail
cd "$(dirname "$0")/.."

OTHER="${1:-${REFERENCE_THEME:-}}"
MINE="macos/Sources/Seedbed/Theme.swift"

if [[ -z "$OTHER" || ! -f "$OTHER" ]]; then
    echo "No external Tokens.swift given — checking against the vendored contract."
    python3 -m unittest tests.test_reference_parity -q
    exit 0
fi

python3 - "$OTHER" "$MINE" <<'PY'
from pathlib import Path
import sys

sys.path.insert(0, "macos/Scripts/support")
from tokens import spec

shared = ("Tokens", "Surface", "Fill", "FontScale", "Rounded", "Space",
          "Radius", "ChipPadding", "IconSize", "Elevation", "Motion")
theirs = spec(Path(sys.argv[1]))
ours = spec(Path(sys.argv[2]))

def normalized(group, value):
    if group == "Fill":
        return value.replace("promptAccent", "referenceAccent")
    return value

differences = []
for group in shared:
    left = theirs.get(group, {})
    right = ours.get(group, {})
    for token in sorted(set(left) | set(right)):
        a = normalized(group, left.get(token, "<missing>"))
        b = normalized(group, right.get(token, "<missing>"))
        if a != b:
            differences.append((f"{group}.{token}", a, b))

if differences:
    print("=== Reference / Seedbed shared-token differences ===")
    for name, reference, seedbed in differences:
        print(f"  {name}\n    Reference: {reference}\n    Seedbed: {seedbed}")
else:
    count = sum(len(theirs[group]) for group in shared)
    print(f"Reference parity: {count} shared tokens match exactly.")
PY
