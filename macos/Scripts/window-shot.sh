#!/usr/bin/env bash
#
# Photograph one of this app's windows, and nothing else on the screen.
#
#   Scripts/window-shot.sh                  every Seedbed window -> /tmp
#   Scripts/window-shot.sh ~/Desktop        somewhere else
#
# WHY THIS EXISTS, AND WHY IT IS NOT `screencapture` ON ITS OWN.
#
# A UI change here has been verified by asking the owner to look at it and send
# a picture back. That works and it is slow: on 2026-09-05 a design port took
# four rounds over about an hour, each one fixing whatever happened to be in the
# last screenshot.
#
# The obvious fix, a screenshot, had already been tried and abandoned. A plain
# `screencapture` photographs the whole display, and the first one taken here
# came back holding unrelated windows including a signed-in page, so it was
# deleted unexamined. `-R x,y,w,h` is no better: it grabs a REGION of screen, so
# whatever is stacked in front of the target is what you get. Aimed at Seedbed,
# it returned a picture of the terminal.
#
# `-l<windowID>` captures the window's own content, occluded or not, and nothing
# around it. The id comes from CGWindowListCopyWindowInfo, which needs no Screen
# Recording permission for bounds and ids (window TITLES are what require it).
#
# So: a UI claim can be checked by looking, without photographing someone's Mac.
set -euo pipefail
cd "$(dirname "$0")/.."

OUT="${1:-/tmp}"
APP="${SEEDBED_APP_NAME:-Seedbed}"
HELPER="$(mktemp -d)/window-id"
trap 'rm -rf "$(dirname "$HELPER")"' EXIT

swiftc -O Scripts/support/window-id.swift -o "$HELPER" 2>/dev/null \
    || { echo "error: could not build the window-id helper (needs the Swift toolchain)." >&2; exit 1; }

# `mapfile` is bash 4; macOS ships bash 3.2 as /bin/bash, and this script has to
# run on a stock Mac rather than only where Homebrew's bash is first on PATH.
WINDOWS=()
while IFS= read -r line; do [[ -n "$line" ]] && WINDOWS+=("$line"); done < <("$HELPER" "$APP" || true)
if [[ ${#WINDOWS[@]} -eq 0 ]]; then
    echo "No on-screen $APP window. Open one first:" >&2
    echo "  SEEDBED_OPEN_LIBRARY=help build/Seedbed.app/Contents/MacOS/Seedbed &" >&2
    exit 1
fi

mkdir -p "$OUT"
n=0
for entry in "${WINDOWS[@]}"; do
    id="${entry%% *}"; size="${entry##* }"
    lower="$(printf '%s' "$APP" | tr '[:upper:]' '[:lower:]')"
    n=$((n + 1))
    file="$OUT/${lower}-${n}-${size}.png"
    screencapture -x -o -l"$id" "$file"
    echo "  $file"
done
