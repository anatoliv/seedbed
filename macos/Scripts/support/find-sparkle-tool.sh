#!/usr/bin/env bash
#
# Print the path of one of Sparkle's command-line tools, or exit 1 with nothing.
#
#   Scripts/support/find-sparkle-tool.sh generate_keys|generate_appcast
#
# Run from macos/. Looks in this package's own .build first (the Sparkle this
# app links, once it has been built), then the SwiftPM and Xcode caches, and
# only then ~/Projects.
#
# release.sh used to find these with one `find … "$HOME/Projects" … | head -1`
# under `set -euo pipefail`. find exits non-zero when any directory it walks is
# unreadable or disappears mid-walk (another session removing a worktree), even
# after it has found the file, and pipefail turned that into a silent exit of
# the whole release straight after "Using the only saved notarytool profile".
# Here each find stops at its first match (-print -quit, no pipe), and its exit
# status is ignored: only whether a path came back counts.

set -uo pipefail

name="${1:-}"
case "$name" in
    generate_keys|generate_appcast) ;;
    *) echo "usage: find-sparkle-tool.sh generate_keys|generate_appcast" >&2; exit 64 ;;
esac

for root in ./.build "$HOME/Library/Caches/org.swift.swiftpm" "$HOME/Library/Developer" \
    "$HOME/Projects"; do
    [[ -d "$root" ]] || continue
    hit="$(find "$root" -type f -name "$name" -path '*Sparkle*' -perm -u+x -print -quit \
        2>/dev/null || true)"
    if [[ -n "$hit" ]]; then
        printf '%s\n' "$hit"
        exit 0
    fi
done
exit 1
