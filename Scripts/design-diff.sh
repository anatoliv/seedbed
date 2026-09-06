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
set -uo pipefail
cd "$(dirname "$0")/.."

OTHER="${Reference:-$HOME/Projects/Reference}/Sources/Reference/Theme.swift"
MINE="macos/Sources/Seedbed/Theme.swift"

if [[ ! -f "$OTHER" ]]; then
    echo "Reference not checked out at ${Reference:-$HOME/Projects/Reference} — nothing to compare."
    echo "Set Reference=/path/to/Reference to point at it."
    exit 0
fi

# `Group.name = value`, one per line, so the two files can be compared as data
# rather than as prose.
tokens() {
    awk '
        /^    enum [A-Z][A-Za-z]* \{/ { group = $2; next }
        /^    \}/                     { group = "" }
        group != "" && /static (let|var) [a-zA-Z]+/ {
            name = ""; val = ""
            for (i = 1; i <= NF; i++) if ($i == "let" || $i == "var") { name = $(i+1); break }
            sub(/:$/, "", name)
            p = index($0, "="); if (p == 0) next
            val = substr($0, p + 1)
            sub(/\/\/.*/, "", val); gsub(/^[ \t]+|[ \t]+$/, "", val)
            if (name != "" && val != "") print group "." name " = " val
        }
    ' "$1" | sort
}

A=$(mktemp); B=$(mktemp); trap 'rm -f "$A" "$B"' EXIT
tokens "$OTHER" > "$A"
tokens "$MINE"  > "$B"

echo "=== in Reference, absent or different here ==="
comm -23 "$A" "$B" | sed 's/^/  /' || true
echo
echo "=== here, absent or different in Reference ==="
comm -13 "$A" "$B" | sed 's/^/  /' || true
echo
SHARED=$(comm -12 "$A" "$B" | wc -l | tr -d ' ')
echo "$SHARED tokens identical."
echo
echo "A difference is not automatically a defect: this app has its own canvas, so"
echo "'warning' is deliberately darker and 'ReadingSize' carries names Reference"
echo "spells 'FontScale'. What matters is that every difference is one somebody"
echo "chose. docs/design/DESIGN_SYSTEM.md is where a chosen one gets written down."
