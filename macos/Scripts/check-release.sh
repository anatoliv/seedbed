#!/usr/bin/env bash
#
# The release gate. Run by Scripts/release.sh at two moments, and worth running
# by hand before you think you are ready:
#
#   PREFLIGHT_ONLY=1 Scripts/check-release.sh    the half that needs no artifacts
#   Scripts/check-release.sh                     everything, after the DMG exists
#
# Overrides, each of which prints loudly rather than passing quietly:
#   SKIP_TESTS=1        do not run the Python suite
#
# Ported from Reference's Scripts/check-release.sh, which is where the
# two-moment structure comes from: a stale release note or a failing test is
# knowable in seconds, and finding out after a build plus two notarizations has
# cost ten minutes is how a gate stops being run.

set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Packaging/Info.plist)"
BUILD_NUM="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' Packaging/Info.plist)"
APP="build/Seedbed.app"
DMG="dist/Seedbed_${VERSION}_aarch64.dmg"

# --- The test suite -----------------------------------------------------------
# The Python core owns the library: staleness, guidance, the enhancer, the
# registry. The app is a front end to it, so shipping a bundle built from a tree
# whose suite is red ships a broken library with a working window on it.
#
# Note what this can and cannot see, because the learning log is explicit about
# it: 194 tests over the core, and every user-visible defect so far has been in
# the SwiftUI layer where no test reaches. A green run here is a floor, not a
# guarantee, and it is still the cheapest thing in this file.
if [[ "${SKIP_TESTS:-}" == "1" ]]; then
    echo "WARNING: SKIP_TESTS=1 — packaging without running the suite" >&2
else
    echo "==> Test suite"
    # Captured rather than piped. `cmd | tail` returns TAIL's status, so
    # `if ! cmd | tail` is always false and the gate would pass a red suite
    # while printing its failures — a check that looks present and never fires.
    TEST_OUT="$( (cd .. && python3 -m unittest discover -s tests -q) 2>&1 )" || {
        printf '%s\n' "$TEST_OUT" | tail -25 >&2
        echo "error: the test suite failed — nothing built." >&2
        echo "       Run it yourself: python3 -m unittest discover -s tests" >&2
        echo "       To package anyway, deliberately: SKIP_TESTS=1 Scripts/release.sh" >&2
        exit 1
    }
    printf '%s\n' "$TEST_OUT" | tail -3 | sed 's/^/    /'
fi

# --- Design drift -------------------------------------------------------------
# Views draw from Tokens; Theme.swift is the source of truth and
# docs/design/DESIGN_SYSTEM.md says so in its first section. tests/ already
# checks that the document and the tokens agree in both directions. What no test
# sees is a view that skips the tokens entirely and hard-codes a number, which is
# how the tables become a description of a product nobody shipped.
#
# SF-Rounded faces are allowed: those are a deliberate typographic choice, not a
# size literal waiting to be tokenized.
RADIUS_DRIFT="$(grep -rnE 'cornerRadius: [0-9]' Sources/Seedbed --include='*.swift' \
    | grep -v 'Theme.swift' || true)"
FONT_DRIFT="$(grep -rnE '\.system\(size: [0-9]' Sources/Seedbed --include='*.swift' \
    | grep -vE 'Theme\.swift|design: \.rounded' || true)"
if [[ -n "$RADIUS_DRIFT" || -n "$FONT_DRIFT" ]]; then
    echo "error: design drift — raw style values in view code." >&2
    echo "       Use Tokens; see docs/design/DESIGN_SYSTEM.md, \"Which artifact wins\"." >&2
    [[ -n "$RADIUS_DRIFT" ]] && printf '       %s\n' "$RADIUS_DRIFT" >&2
    [[ -n "$FONT_DRIFT" ]] && printf '       %s\n' "$FONT_DRIFT" >&2
    exit 1
fi

# --- Release notes ------------------------------------------------------------
# WhatsNew.swift is this app's changelog: it is what the user is shown, once, on
# the first launch of a new version. A release with no entry there is a release
# nobody can find out about — the DMG installs, the version number moves, and the
# only human-readable record of what changed skips a version.
if ! grep -qE "version: \"${VERSION//./\\.}\"" Sources/Seedbed/WhatsNew.swift; then
    echo "error: WhatsNew.swift has no entry for $VERSION." >&2
    echo "       Add a WhatsNewRelease for it before releasing. It is the only thing" >&2
    echo "       that tells anyone what is different about the build they just got." >&2
    exit 1
fi

# --- The build number must actually increase ----------------------------------
# Compares this release against the last one that shipped, which is the only
# check here that looks outside the working tree. Everything else compares the
# release against itself and cannot see a repeated version.
#
# Today this no-ops: nothing tags releases yet, because there is no feed and no
# download page, so `release.sh` does not tag. It starts working the moment a
# `v*` tag exists, which is why it is written now rather than remembered later.
PREV_TAG="$(git tag --list 'v*' --sort=-v:refname 2>/dev/null | grep -v "^v${VERSION}\$" | head -1 || true)"
if [[ -n "$PREV_TAG" ]]; then
    PREV_PLIST="$(mktemp -t seedbed-prevplist)"
    if git show "$PREV_TAG:macos/Packaging/Info.plist" > "$PREV_PLIST" 2>/dev/null; then
        PREV_BUILD="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$PREV_PLIST" 2>/dev/null || true)"
    fi
    rm -f "$PREV_PLIST"
    case "${PREV_BUILD:-x}" in
        (*[!0-9]*|'') : ;;      # unreadable, or predates the field
        (*)
            if [[ "$BUILD_NUM" -le "$PREV_BUILD" ]]; then
                echo "error: build $BUILD_NUM is not greater than $PREV_BUILD (shipped in $PREV_TAG)." >&2
                echo "       Bump CFBundleVersion in Packaging/Info.plist." >&2
                exit 1
            fi
            ;;
    esac
fi

if [[ "${PREFLIGHT_ONLY:-}" == "1" ]]; then
    echo "preflight ok: $VERSION ($BUILD_NUM) — tests, design tokens, release notes, build number"
    exit 0
fi

# --- Everything below needs the built artifacts -------------------------------

if [[ ! -f "$DMG" ]]; then
    echo "error: missing release DMG: $DMG" >&2
    exit 1
fi
if [[ ! -d "$APP" ]]; then
    echo "error: missing built app: $APP" >&2
    exit 1
fi

# The bundle must be the version this gate has been checking. A stale build/
# directory is the easy mistake here: bump the plist, forget to rebuild, and
# every check above passes against a DMG containing the previous release.
APP_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")"
APP_BUILD="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$APP/Contents/Info.plist")"
if [[ "$APP_VERSION" != "$VERSION" || "$APP_BUILD" != "$BUILD_NUM" ]]; then
    echo "error: the built app is $APP_VERSION ($APP_BUILD), but Packaging/Info.plist" >&2
    echo "       says $VERSION ($BUILD_NUM). The bundle in build/ is stale — rebuild." >&2
    exit 1
fi

# Notarization is the whole point of the exercise: without a stapled ticket on
# the .app itself, the copy dragged out of the image has to reach Apple to be
# verified, and fails on a Mac that is offline or behind a filter.
if ! xcrun stapler validate "$APP" >/dev/null 2>&1; then
    echo "error: $APP has no valid stapled notarization ticket." >&2
    exit 1
fi
if ! xcrun stapler validate "$DMG" >/dev/null 2>&1; then
    echo "error: $DMG has no valid stapled notarization ticket." >&2
    exit 1
fi
if ! spctl --assess --type execute "$APP" >/dev/null 2>&1; then
    echo "error: Gatekeeper rejects $APP — it would not launch on another Mac." >&2
    spctl --assess --type execute --verbose "$APP" 2>&1 | sed 's/^/       /' >&2
    exit 1
fi

# If a DSN source exists, injection must actually have happened. It is a
# PlistBuddy write into a copied file, and if it silently does not happen the
# build looks identical, ships, reports nothing, and the first anyone knows is a
# crash nobody hears about.
if [[ -n "${SEEDBED_SENTRY_DSN:-}" || -f Packaging/sentry-dsn.local ]]; then
    BUNDLED_DSN="$(/usr/libexec/PlistBuddy -c 'Print :SentryDSN' "$APP/Contents/Info.plist" 2>/dev/null || true)"
    if [[ -z "$BUNDLED_DSN" ]]; then
        echo "error: a Sentry DSN is configured but the bundle's SentryDSN is empty." >&2
        echo "       This build cannot report crashes however anyone sets the toggle." >&2
        exit 1
    fi
fi

echo "release ok: $VERSION ($BUILD_NUM)"
echo "  app and DMG both stapled, Gatekeeper accepts the app, bundle matches the plist"
