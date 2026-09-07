#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

SRC="${1:-}"
[[ -f "$SRC" ]] || { echo "error: pass the path to the reference Tokens.swift" >&2; exit 1; }

OUT="Design/reference-tokens.json"
python3 Scripts/support/tokens.py "$SRC" > "$OUT"
echo "wrote $OUT from $SRC"
echo "Review the diff: this is the visual contract Seedbed follows."
