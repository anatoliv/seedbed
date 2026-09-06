#!/usr/bin/env bash
#
# Print every design-token difference between this app and Reference.
#
#   Scripts/design-diff.sh
#
# WHY THIS EXISTS. On 2026-09-05 "use Reference's design and style" took four
# rounds and about an hour, because each round was driven by what happened to be
# visible in a screenshot rather than by reading Reference's Theme.swift. The
# whole delta was: two token groups missing entirely (IconSize, ChipPadding), a
# reading type ramp that had never been ported, an 8pt difference in the outer
# pane inset, a 66pt sidebar, and window minimums equal to their opening size.
# Every one of those is a number in a file, and comparing numbers is not work a
# person should do by looking at two windows side by side.
#
# Not a test: Reference is a separate repository and may not be checked out.
# This says so and exits 0 rather than failing a suite over someone's disk.
set -euo pipefail
cd "$(dirname "$0")/.."

OTHER="${Reference:-$HOME/Projects/Reference}/Sources/Reference/Theme.swift"
MINE="macos/Sources/Seedbed/Theme.swift"

if [[ ! -f "$OTHER" ]]; then
    echo "Reference not checked out at ${Reference:-$HOME/Projects/Reference} — nothing to compare."
    echo "Set Reference=/path/to/Reference to point at it."
    exit 0
fi

python3 - "$OTHER" "$MINE" <<'PY'
from pathlib import Path
import sys

sys.path.insert(0, "macos/Scripts/support")
from tokens import spec

theirs = spec(Path(sys.argv[1]))
ours = spec(Path(sys.argv[2]))

def flattened(groups):
    return {
        f"{group}.{name}": value
        for group, members in groups.items()
        for name, value in members.items()
    }

a, b = flattened(theirs), flattened(ours)
print("=== in Reference, absent or different here ===")
for key in sorted(a):
    if b.get(key) != a[key]:
        print(f"  {key} = {a[key]}")
print("\n=== here, absent or different in Reference ===")
for key in sorted(b):
    if a.get(key) != b[key]:
        print(f"  {key} = {b[key]}")
shared = sum(a[key] == b.get(key) for key in a)
print(f"\n{shared} tokens identical after resolving token references.")
PY
echo
echo "A difference is not automatically a defect: this app has its own canvas, so"
echo "'warning' is deliberately darker and 'ReadingSize' carries names Reference"
echo "uses to define 'FontScale'. What matters is that every difference is one somebody"
echo "chose. docs/design/DESIGN_SYSTEM.md is where a chosen one gets written down."
