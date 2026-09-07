#!/usr/bin/env bash
#
# Point the public site at the release in Packaging/Info.plist.
#
#   Scripts/sync-site.sh            rewrite site/index.html to this version
#   Scripts/sync-site.sh --check    write nothing; fail if the site pins another
#
# Called by Scripts/release.sh beside sync-cask.sh, for the same reason the cask
# is synced: site/index.html pins a DMG file name in its download links, and a
# page nobody here installs from is a page that goes stale unnoticed, offering a
# download that still works and an "updates itself" that is a lie.
#
# Three places carry the version and all three move together: every
# Seedbed_<v>_universal.dmg link, every data-version attribute, and the visible
# label. --check is what check-release.sh runs, so a hand-edited page cannot
# pass the gate with a link to a DMG that is about to stop being served.
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Packaging/Info.plist)"
SITE="../site/index.html"
[[ -f "$SITE" ]] || { echo "error: missing $SITE" >&2; exit 1; }

pinned() {
    grep -oE 'Seedbed_[0-9]+\.[0-9]+\.[0-9]+_universal\.dmg|data-version="[^"]+"|data-version-label>[^<]+<' "$SITE" \
        | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | sort -u
}

if [[ "${1:-}" == "--check" ]]; then
    HAVE="$(pinned | tr '\n' ' ' | sed 's/ $//')"
    if [[ "$HAVE" != "$VERSION" ]]; then
        echo "error: site/index.html pins '${HAVE:-nothing}', not $VERSION." >&2
        echo "       Every download link, data-version and version label must agree." >&2
        echo "       Run Scripts/sync-site.sh, and commit it with the version bump." >&2
        exit 1
    fi
    exit 0
fi

# One pass per pattern. The label pattern is anchored to the attribute so a
# version number in prose ("Homebrew 6") is never touched.
perl -pi -e "s/Seedbed_[0-9]+\\.[0-9]+\\.[0-9]+_universal\\.dmg/Seedbed_${VERSION}_universal.dmg/g;
             s/data-version=\"[^\"]+\"/data-version=\"${VERSION}\"/g;
             s/(data-version-label>)[^<]+</\${1}${VERSION}</g" "$SITE"
echo "    site/index.html now pins $VERSION ($(grep -c "Seedbed_${VERSION}_universal.dmg" "$SITE") download links)"
