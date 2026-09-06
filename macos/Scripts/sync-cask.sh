#!/usr/bin/env bash
#
# Point the Homebrew cask at the release sitting in dist/.
#
#   Scripts/sync-cask.sh
#
# Called by Scripts/release.sh once the DMG is final, and runnable by hand when
# a cask edit needs its caveats regenerating. It rewrites three things in
# ../Casks/seedbed.rb: the pinned version, the sha256 of the DMG, and the
# caveats block, which is generated from Packaging/dmg-readme.txt so the two
# cannot tell people different stories.
#
# It does not commit. The cask is a version-pinned surface like the appcast, so
# it belongs in the same commit as the version bump — and the public tap only
# learns about it when Scripts/publish-repo.sh next runs.
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Packaging/Info.plist)"
BUILD_NUM="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' Packaging/Info.plist)"
DMG="dist/Seedbed_${VERSION}_universal.dmg"

if [[ ! -f "$DMG" ]]; then
    echo "error: missing $DMG — the cask pins the sha256 of a real file." >&2
    echo "       Run Scripts/release.sh first." >&2
    exit 1
fi

SHA="$(shasum -a 256 "$DMG" | awk '{print $1}')"
exec python3 Scripts/support/cask.py "$VERSION" "$BUILD_NUM" "$SHA"
