#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

# Takes the path explicitly. Guessing a checkout from a directory layout works
# on exactly one machine, and this repository stands on its own.
SRC="${1:-}"
[[ -n "$SRC" && -f "$SRC" ]] || {
    echo "usage: $0 <path-to-Tokens.swift>" >&2
    echo "       Regenerates the vendored design contract from that file." >&2
    exit 1
}

OUT="Design/reference-tokens.json"
python3 Scripts/support/tokens.py "$SRC" > "$OUT"
echo "wrote $OUT from $SRC"
echo "Review the diff: this is the visual contract Seedbed follows."
