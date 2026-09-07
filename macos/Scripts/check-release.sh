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
# The two-moment structure is the point: a stale release note or a failing test is
# knowable in seconds, and finding out after a build plus two notarizations has
# cost ten minutes is how a gate stops being run.

set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Packaging/Info.plist)"
BUILD_NUM="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' Packaging/Info.plist)"
APP="build/Seedbed.app"
DMG="dist/Seedbed_${VERSION}_universal.dmg"

# The same digest make-app.sh stamps into the bundle, recomputed over the tree.
#
# Kept character for character identical to the copy in make-app.sh — the two
# values are compared against each other, so a divergence here makes every
# comparison meaningless while looking entirely correct, and it would fail in
# the loud direction on every release rather than the quiet one.
# tests/test_bundle_freshness.py pins them equal.
source_digest() {
    find Sources Package.swift -type f -name '*.swift' -print0 \
        | LC_ALL=C sort -z | xargs -0 shasum -a 256 | shasum -a 256 \
        | awk '{print $1}'
}

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
# Sparkle decides whether an update exists by comparing sparkle:version — the
# BUILD number — and ignores the short version entirely. Two releases sharing a
# build number are invisible to each other: no update offered, no error shown,
# and the feed looks perfectly correct. Live since v0.1.1, the first tag.
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

# The bundle must be built from the CURRENT sources, not merely carry the right
# version number. `swift build` updates .build; `make-app.sh` assembles the app.
# Running the first and shipping the second gives you a bundle whose Info.plist
# is right and whose code is old, which every other check here passes happily.
# This has now cost two debugging sessions in one day: a fix that looked like it
# had no effect, and a design comparison reported against a build that predated
# it. Neither was a wrong change; both were the previous binary.
#
# Asked of the CONTENT where the bundle records a digest, and of modification
# times only where it does not. Read from the built bundle, because the tree
# cannot testify about the artifact.
#
# The shape is checked rather than the mere presence of a value: a truncated or
# differently-computed digest would compare unequal forever, which reads as a
# permanently stale bundle and teaches everyone to ignore the gate.
BUNDLE_DIGEST="$(/usr/libexec/PlistBuddy -c 'Print :SeedbedSourceDigest' \
    "$APP/Contents/Info.plist" 2>/dev/null || true)"
if [[ "$BUNDLE_DIGEST" =~ ^sha256:[0-9a-f]{64}$ ]]; then
    TREE_DIGEST="sha256:$(source_digest)"
    if [[ "$BUNDLE_DIGEST" != "$TREE_DIGEST" ]]; then
        echo "error: the sources are not the ones $APP was built from." >&2
        echo "       bundle: $BUNDLE_DIGEST" >&2
        echo "       tree:   $TREE_DIGEST" >&2
        echo "       Some source file, or Package.swift, differs in content from the" >&2
        echo "       set this binary was compiled out of. Modification times do not" >&2
        echo "       come into it, so this is a real difference in bytes." >&2
        echo "       Run Scripts/make-app.sh — 'swift build' alone does not assemble it." >&2
        exit 1
    fi
else
    # No digest, so the bundle predates the record and gets the check it was
    # always subject to. Absence must never read as "nothing to compare,
    # therefore fine": an older bundle silently starting to pass a check it was
    # previously failing is worse than the false alarm below, because it fails
    # open and says nothing.
    #
    # The false alarm is real and is worth naming in the error itself, since the
    # last person to read one of these believed it. A file rewritten with
    # identical bytes — a restore from backup, a checkout, a formatter that
    # changed nothing — moves its mtime and trips this while the bundle is
    # byte-correct. Rebuilding records a digest and retires the ambiguity.
    NEWEST_SOURCE="$(find Sources -name '*.swift' -newer "$APP/Contents/MacOS/Seedbed" -print -quit 2>/dev/null || true)"
    if [[ -n "$NEWEST_SOURCE" ]]; then
        echo "error: $NEWEST_SOURCE is newer than the built binary." >&2
        echo "       The bundle in build/ predates the source it claims to be." >&2
        echo "       This bundle records no source digest, so the comparison is by" >&2
        echo "       modification time and cannot see content: a file restored with" >&2
        echo "       identical bytes trips it too. Compare the file against the" >&2
        echo "       revision the bundle names before believing it is stale." >&2
        echo "       Run Scripts/make-app.sh — 'swift build' alone does not assemble it." >&2
        exit 1
    fi
fi

# The bundle must say which revision built it, and it must be the revision this
# gate is looking at. Read from the BUILT bundle rather than from the tree: the
# tree cannot testify about the artifact, and the whole value of the record is
# that it survives being handed to a stranger.
#
# Checked for EVERY release, not only a reporting one. The block below verifies
# the reporting fields when a provider is configured; identity is a property of
# the artifact rather than of crash reporting, and the DMG built without a DSN
# is precisely the one nobody can interrogate later.
#
# Everything shipped before this record existed is attributable only from
# outside — the tag names a commit and the cask commit records the sha256 of the
# bytes that were served. That chain is real, resolves only against the private
# repository, and is attestation by bookkeeping: it trusts those records were
# honest when written and breaks silently if a DMG is rebuilt and re-uploaded
# without touching the cask. This makes the artifact answer for itself.
#
# Note what it CANNOT do, so nothing downstream leans on it: a commit is not a
# freshness check. An unrebuilt tree carries a perfectly truthful HEAD, so this
# says which revision was claimed and never whether the binary was rebuilt from
# it. The staleness check above covers that and is deliberately left
# unconditional — a bundle predating this record must not start passing a check
# it was previously subject to.
BUNDLE_RELEASE="$(/usr/libexec/PlistBuddy -c 'Print :CrashReportingRelease' \
    "$APP/Contents/Info.plist" 2>/dev/null || true)"
if [[ ! "$BUNDLE_RELEASE" =~ ^net\.amnesia\.seedbed@[0-9a-f]{40}$ ]]; then
    echo "error: the bundle's CrashReportingRelease is '${BUNDLE_RELEASE:-<empty>}', not" >&2
    echo "       net.amnesia.seedbed@<40-character lowercase hex>. This artifact could" >&2
    echo "       not be traced back to source once it is on someone else's Mac." >&2
    echo "       Scripts/make-app.sh records it; 'swift build' alone does not." >&2
    exit 1
fi
HEAD_COMMIT="$(git rev-parse HEAD 2>/dev/null || true)"
if [[ -n "$HEAD_COMMIT" && "$BUNDLE_RELEASE" != "net.amnesia.seedbed@$HEAD_COMMIT" ]]; then
    echo "error: the bundle records ${BUNDLE_RELEASE#*@} but HEAD is $HEAD_COMMIT." >&2
    echo "       Rebuild, or you will publish an artifact whose recorded origin is" >&2
    echo "       not the source you are about to tag." >&2
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
REPORTING_PROVIDER="$(Scripts/configure-crash-reporting.sh --provider-only)"
if [[ "$REPORTING_PROVIDER" != "none" ]]; then
    BUNDLED_DSN="$(/usr/libexec/PlistBuddy -c 'Print :CrashReportingDSN' "$APP/Contents/Info.plist" 2>/dev/null || true)"
    BUNDLED_PROVIDER="$(/usr/libexec/PlistBuddy -c 'Print :CrashReportingProvider' "$APP/Contents/Info.plist" 2>/dev/null || true)"
    BUNDLED_RELEASE="$(/usr/libexec/PlistBuddy -c 'Print :CrashReportingRelease' "$APP/Contents/Info.plist" 2>/dev/null || true)"
    BUNDLED_ENVIRONMENT="$(/usr/libexec/PlistBuddy -c 'Print :CrashReportingEnvironment' "$APP/Contents/Info.plist" 2>/dev/null || true)"
    EXPECTED_RELEASE="net.amnesia.seedbed@$(git rev-parse HEAD)"
    if [[ -z "$BUNDLED_DSN" ]]; then
        echo "error: a reporting DSN is configured but the bundle's CrashReportingDSN is empty." >&2
        echo "       This build cannot report crashes however anyone sets the toggle." >&2
        exit 1
    fi
    if [[ "$BUNDLED_PROVIDER" != "$REPORTING_PROVIDER" || "$BUNDLED_RELEASE" != "$EXPECTED_RELEASE" \
          || "$BUNDLED_ENVIRONMENT" != "${SEEDBED_ERROR_ENVIRONMENT:-production}" ]]; then
        echo "error: the bundle's reporting provider/release/environment does not match this build." >&2
        exit 1
    fi
fi

# --- The feed ------------------------------------------------------------------
# A release nobody is offered is a release that did not happen. The appcast is
# generated from every DMG in dist/, so the failure to catch here is a feed whose
# newest entry is not this build: installed copies keep being told they are
# current while a newer version sits on the server.
APPCAST="dist/appcast.xml"
if [[ ! -f "$APPCAST" ]]; then
    echo "error: missing $APPCAST — installed copies would never hear about this." >&2
    exit 1
fi
APPCAST_BUILD="$(perl -0ne 'if (/<sparkle:version>(\d+)<\/sparkle:version>/) { print $1; exit }' "$APPCAST")"
APPCAST_VERSION="$(perl -0ne 'if (/<sparkle:shortVersionString>([^<]+)<\/sparkle:shortVersionString>/) { print $1; exit }' "$APPCAST")"
if [[ -z "$APPCAST_BUILD" || "$APPCAST_BUILD" -lt "$BUILD_NUM" ]]; then
    echo "error: the appcast's newest build (${APPCAST_BUILD:-missing}) is older than $BUILD_NUM." >&2
    exit 1
fi
if [[ -n "$APPCAST_VERSION" && "$APPCAST_VERSION" != "$VERSION" ]]; then
    echo "error: the appcast's newest version ($APPCAST_VERSION) is not $VERSION." >&2
    exit 1
fi
# An unsigned enclosure is one every installed copy refuses, silently.
if ! grep -q 'sparkle:edSignature' "$APPCAST"; then
    echo "error: $APPCAST carries no EdDSA signature — every installed copy would" >&2
    echo "       reject the update without showing anyone why." >&2
    exit 1
fi

# --- The Homebrew cask ---------------------------------------------------------
# A version-pinned surface, and the one nobody here installs from — which is
# exactly why it goes stale unnoticed. Every failure below is silent at the
# moment it is introduced and only shows up on a stranger's Mac:
#   * a stale version/sha256  -> `brew install --cask seedbed` 404s or refuses
#   * pinned "X" not "X,BUILD" -> `brew audit --online` fails, autobump breaks
#   * caveats drifted from the DMG readme -> two install paths, two stories,
#     and the app that "installs fine and shows 0 prompts" is nobody's fault
# All three are mechanically checkable, so check them rather than remembering.
CASK="../Casks/seedbed.rb"
if [[ ! -f "$CASK" ]]; then
    echo "error: missing $CASK — the public repo is a Homebrew tap and the cask is" >&2
    echo "       what makes it one. A guard aimed at an absent file passes forever." >&2
    exit 1
fi
CASK_VERSION="$(sed -nE 's/^  version "([^"]+)".*/\1/p' "$CASK" | head -1)"
CASK_SHA="$(sed -nE 's/^  sha256 "([0-9a-f]{64})".*/\1/p' "$CASK" | head -1)"
WANT_VERSION="${VERSION},${BUILD_NUM}"
if [[ "$CASK_VERSION" != "$WANT_VERSION" ]]; then
    echo "error: cask version '${CASK_VERSION:-missing}' != '$WANT_VERSION'." >&2
    echo "       The appcast carries both shortVersionString and version, so Homebrew's" >&2
    echo "       Sparkle livecheck reports them joined; pin '<short>,<build>'." >&2
    echo "       Scripts/release.sh syncs this in step 5b — run Scripts/sync-cask.sh." >&2
    exit 1
fi
DMG_SHA="$(shasum -a 256 "$DMG" | awk '{print $1}')"
if [[ "$CASK_SHA" != "$DMG_SHA" ]]; then
    echo "error: the cask's sha256 is not this DMG's." >&2
    echo "       cask: ${CASK_SHA:-missing}" >&2
    echo "       dmg : $DMG_SHA" >&2
    echo "       Run Scripts/sync-cask.sh." >&2
    exit 1
fi
# The caveats are generated from Packaging/dmg-readme.txt. Ask whether the cask
# on disk IS what this release generates, rather than trusting that the sync
# ran: a hand-edited caveats block is the normal way this drifts, and it looks
# entirely correct in review. --check writes nothing and prints the diff.
if ! python3 Scripts/support/cask.py "$VERSION" "$BUILD_NUM" "$DMG_SHA" --check; then
    exit 1
fi
# Homebrew 6+ refuses a third-party tap that has not been trusted, so install
# instructions that omit the step do not work.
if ! grep -q 'brew trust' ../README.md 2>/dev/null; then
    echo "error: the README install steps omit 'brew trust' — Homebrew 6+ refuses" >&2
    echo "       third-party taps without it, so the instructions do not work." >&2
    exit 1
fi

# --- The public site ------------------------------------------------------------
# site/index.html links the DMG by file name, three times, and is the surface a
# stranger meets first. A page pinned to the previous release offers a download
# that still works and an "updates itself" that is a lie, and a page pinned to
# a release not yet uploaded 404s. sync-site.sh --check reads every marker and
# refuses anything but this version; Scripts/publish-site.sh separately refuses
# to deploy until the DMG it links is served.
if [[ -f ../site/index.html ]]; then
    Scripts/sync-site.sh --check || exit 1
else
    echo "error: missing ../site/index.html — the public site is part of the release." >&2
    exit 1
fi

echo "release ok: $VERSION ($BUILD_NUM)"
echo "  app and DMG stapled, Gatekeeper accepts the app, bundle matches the plist"
echo "  cask, appcast and site all pin this release"
echo "  appcast offers $APPCAST_VERSION ($APPCAST_BUILD), EdDSA signed"
echo "  cask pins $WANT_VERSION and this DMG's sha256, caveats match the DMG readme"
