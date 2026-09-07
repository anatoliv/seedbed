#!/usr/bin/env bash
#
# Package Seedbed for a Mac that did not build it: a Developer ID signed,
# notarized, stapled .app inside a notarized, stapled DMG.
#
#   Scripts/release.sh
#
# Everything is discovered by default — the Developer ID identity from the
# keychain, the notarytool profile if there is exactly one saved. Override:
#
#   IDENTITY="Developer ID Application: Name (TEAMID)"
#   NOTARY_PROFILE=<a notarytool keychain profile>
#   FORCE_REBUILD=1     rebuild a DMG for a version already packaged
#   ALLOW_DIRTY=1       skip the "which commit is this?" warning
#   SKIP_TESTS=1        package without running the suite (prints loudly)
#
# This builds, generates the Sparkle appcast, syncs the Homebrew cask and tags.
# What it deliberately does NOT do is put anything where a stranger can reach it:
# Scripts/publish.sh uploads the DMG and the feed, and ../Scripts/publish-repo.sh
# pushes the cask to the public tap. See macos/README.md.
#
# (This comment said Seedbed had no download site and no Sparkle feed until
# 2026-09-06. Both have existed since 0.1.1, and the script had grown an appcast
# step and a tag step while still claiming to do neither.)

set -euo pipefail

# Keep the Mac awake for the whole run. The long unattended stretch is
# `notarytool submit`, and an idle Mac sleeping through it suspends the upload,
# which then looks exactly like a hang. `-w $$` rather than wrapping the script,
# so a TERM reaches this script rather than a wrapper.
if command -v caffeinate >/dev/null; then
    caffeinate -dimsu -w $$ &
fi

cd "$(dirname "$0")/.."

APP_NAME="Seedbed"
APP="build/${APP_NAME}.app"
DIST="dist"

# The signing identity is discovered, never written down. A Team ID in a tracked
# file is an identifier that follows the repo wherever it goes, and this one is
# meant to be publishable; Reference's public tree carries no Team ID for the
# same reason. Exactly one Developer ID Application identity is used silently,
# several ask, none falls through to the caller's own handling.
discover_identity() {
    security find-identity -v -p codesigning 2>/dev/null \
        | sed -nE 's/.*"(Developer ID Application: .*)"$/\1/p' | sort -u
}

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Packaging/Info.plist)"
BUILD_NUM="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' Packaging/Info.plist)"
DMG="${DIST}/${APP_NAME}_${VERSION}_universal.dmg"
# Where the feed says the downloads live. The enclosure URLs in appcast.xml are
# built from this, so it must be the host that actually serves them.
APPCAST_BASE="${APPCAST_BASE:-https://seedbed.dev}"

# 0a. A Developer ID identity is not optional here. An ad-hoc signature is fine
#     for a copy that never leaves this Mac and cannot be notarized at all, so
#     failing now is better than failing after a full build.
IDENTITY="${IDENTITY:-}"
if [[ -z "$IDENTITY" ]]; then
    FOUND="$(discover_identity)"
    case "$(printf '%s' "$FOUND" | grep -c . || true)" in
        1) IDENTITY="$FOUND" ;;
        0) echo "error: no Developer ID Application identity found in the keychain." >&2
           echo "       A release has to be Developer ID signed and notarized, or it will" >&2
           echo "       not launch on any Mac but this one. Set IDENTITY=... to override." >&2
           exit 1 ;;
        *) echo "error: several Developer ID identities in the keychain; say which:" >&2
           printf '         %s\n' "$FOUND" >&2
           echo "       IDENTITY=\"Developer ID Application: ...\" Scripts/release.sh" >&2
           exit 1 ;;
    esac
fi

# 0b. The notarytool credential is per Apple account, not per app, so an existing
#     profile from another project of yours is the right one to use. Discover it
#     rather than making the name something to remember; ambiguity asks.
NOTARY_PROFILE="${NOTARY_PROFILE:-}"
if [[ -z "$NOTARY_PROFILE" ]]; then
    PROFILES=$(security dump-keychain 2>/dev/null \
        | grep -o 'com.apple.gke.notary.tool.saved-creds.[A-Za-z0-9_.-]*' \
        | sed 's/.*saved-creds\.//' | sort -u)
    COUNT=$(printf '%s' "$PROFILES" | grep -c . || true)
    if [[ "$COUNT" == "1" ]]; then
        NOTARY_PROFILE="$PROFILES"
        echo "==> Using the only saved notarytool profile: $NOTARY_PROFILE"
    elif [[ "$COUNT" == "0" ]]; then
        echo "error: no notarytool credential profile saved in the keychain." >&2
        echo "       Create one once (it covers every app on this Apple account):" >&2
        echo "         xcrun notarytool store-credentials <name> --apple-id <id> --team-id <team>" >&2
        exit 1
    else
        echo "error: several notarytool profiles are saved; say which one:" >&2
        printf '         %s\n' $PROFILES >&2
        echo "       NOTARY_PROFILE=<name> Scripts/release.sh" >&2
        exit 1
    fi
fi

# 0c. Refuse to package while a Seedbed built from this repo is running. A
#     running copy holds files open under build/, which produces a CORRUPT DMG
#     — and a corrupt DMG makes `notarytool submit` hang exactly like a dead
#     connection: nothing reaches Apple, no error is printed, and every network
#     check comes back clean. Two debugging sessions were lost to this on
#     another project. A copy running from /Applications is the normal state of
#     a menu-bar app and cannot hold anything under build/, so it is allowed.
REPO_RUNNERS=""
for pid in $(pgrep -x Seedbed 2>/dev/null || true); do
    exe="$(ps -p "$pid" -o comm= 2>/dev/null || true)"
    [[ -z "$exe" ]] && continue
    case "$exe" in
        /Applications/Seedbed.app/*) : ;;
        *) REPO_RUNNERS+="$pid  $exe"$'\n' ;;
    esac
done
if [[ -n "$REPO_RUNNERS" ]]; then
    echo "error: a Seedbed built outside /Applications is running — quit it first." >&2
    printf '       %s' "$REPO_RUNNERS" >&2
    echo "       It can hold files open under build/, which corrupts the DMG that" >&2
    echo "       hdiutil creates, which then hangs notarization with no error." >&2
    exit 1
fi

# 0c2. The Sparkle signing key must match the SUPublicEDKey baked into shipped
#      builds. If it does not, generate_appcast still produces a perfectly
#      well-formed, EdDSA-signed feed — and every installed copy REJECTS the
#      signature and silently stops updating. No error is shown to anyone: the
#      feed looks correct, the DMG downloads, the release appears to succeed.
#      Nothing downstream can see it either, which is why it is checked here
#      rather than discovered by users going quiet.
GK_BIN="${GK_BIN:-$(find "$HOME/Library/Developer" "$HOME/Library/Caches/org.swift.swiftpm" \
    ./.build "$HOME/Projects" -type f -name generate_keys -path '*Sparkle*' 2>/dev/null | head -1)}"
PLIST_ED_KEY="$(/usr/libexec/PlistBuddy -c 'Print :SUPublicEDKey' Packaging/Info.plist 2>/dev/null || true)"
if [[ -n "${GK_BIN:-}" && -x "$GK_BIN" && -n "$PLIST_ED_KEY" ]]; then
    KEYCHAIN_ED_KEY="$("$GK_BIN" -p 2>/dev/null | tr -d '[:space:]' || true)"
    if [[ -z "$KEYCHAIN_ED_KEY" ]]; then
        echo "error: no Sparkle signing key in the keychain — the appcast could not be signed." >&2
        echo "       This key is shared with the other Mac apps here; restore it rather" >&2
        echo "       than generating a new one, which would break their updates too." >&2
        exit 1
    fi
    if [[ "$KEYCHAIN_ED_KEY" != "$PLIST_ED_KEY" ]]; then
        if [[ "${ALLOW_KEY_MISMATCH:-}" != "1" ]]; then
            cat >&2 <<MSG
error: the Sparkle signing key does not match SUPublicEDKey in Packaging/Info.plist.

  keychain  : $KEYCHAIN_ED_KEY
  Info.plist: $PLIST_ED_KEY

  Shipping this produces a valid-looking feed that EVERY installed copy rejects.
  Auto-update stops silently, with nothing shown to the user.

  Restore the original key, or — if rotating deliberately — set SUPublicEDKey to
  the new public key and re-run with ALLOW_KEY_MISMATCH=1. Note a rotation only
  reaches people through a build signed with the OLD key, so ship the key change
  before relying on it.
MSG
            exit 1
        fi
        echo "WARNING: ALLOW_KEY_MISMATCH=1 — signing key differs from SUPublicEDKey" >&2
    fi
    echo "==> Sparkle key matches SUPublicEDKey"
else
    echo "WARNING: generate_keys not found — cannot verify the Sparkle key matches" >&2
    echo "         SUPublicEDKey. A mismatch would break updates silently." >&2
fi

# 0d. Never clobber an already-packaged DMG for this version. That artifact may
#     already be installed on another Mac, and silently replacing its bytes
#     under the same name is how "which build is that machine actually running"
#     becomes unanswerable. Also catches simply forgetting to bump the version.
if [[ -f "$DMG" && "${FORCE_REBUILD:-}" != "1" ]]; then
    cat >&2 <<MSG
error: ${DMG} already exists — refusing to overwrite it.

  Version ${VERSION} (build ${BUILD_NUM}) is already packaged. If this is a new
  release, bump CFBundleShortVersionString and CFBundleVersion in
  Packaging/Info.plist first.

  To rebuild this exact version on purpose:
      FORCE_REBUILD=1 Scripts/release.sh
MSG
    exit 1
fi

# 0e. Which commit is this? A DMG handed to another Mac outlives the working
#     tree it came from, so a dirty tree means the answer is "we cannot say".
#     A warning rather than a refusal, because there is no publish step here
#     that a wrong answer would corrupt.
COMMIT="$(git rev-parse --short HEAD 2>/dev/null || echo unknown)"
DIRTY=0
[[ -n "$(git status --porcelain 2>/dev/null)" ]] && DIRTY=1
if [[ "$DIRTY" == "1" && "${ALLOW_DIRTY:-}" != "1" ]]; then
    echo "WARNING: the working tree is dirty, so this DMG is not reproducible from" >&2
    echo "         commit ${COMMIT}. Commit first if this build is going anywhere" >&2
    echo "         you will later have to reason about." >&2
fi

# 0e2. A tag that already exists means this version has already been released,
#      and the artifact under that name is somewhere it cannot be recalled from.
#      The DMG-overwrite guard only sees this machine's dist/; this sees history.
if git rev-parse -q --verify "refs/tags/v${VERSION}" >/dev/null 2>&1 \
   && [[ "${FORCE_REBUILD:-}" != "1" ]]; then
    echo "error: tag v${VERSION} already exists — that version has shipped." >&2
    echo "       Bump CFBundleShortVersionString and CFBundleVersion, or if you" >&2
    echo "       really mean to rebuild it: FORCE_REBUILD=1 Scripts/release.sh" >&2
    exit 1
fi

# 0f. If this build can report crashes, it must also be able to symbolicate
#     them. Shipping reporting without dSYMs gets you stack traces with no
#     function names or line numbers, which is most of the way to no reports at
#     all — and the discovery happens months later, on the crash you needed.
HAS_DSN=0
[[ -n "${SEEDBED_SENTRY_DSN:-}" || -f Packaging/sentry-dsn.local ]] && HAS_DSN=1
if [[ -z "${SENTRY_AUTH_TOKEN:-}" ]]; then
    SENTRY_AUTH_TOKEN="$(security find-generic-password -s sentry-release-token -w 2>/dev/null || true)"
    export SENTRY_AUTH_TOKEN
fi
# The org slug is an identifier, so it is not written into this tracked file —
# it comes from the environment or, failing that, a gitignored local file, which
# is exactly how the DSN beside it works. Absent, the gate below fails loudly
# rather than shipping a reporting build with no symbolication.
SENTRY_ORG="${SENTRY_ORG:-}"
if [[ -z "$SENTRY_ORG" && -f Packaging/sentry-org.local ]]; then
    SENTRY_ORG="$(tr -d ' \t\r\n' < Packaging/sentry-org.local)"
fi
if [[ "$HAS_DSN" == "1" && ( -z "${SENTRY_AUTH_TOKEN:-}" || -z "$(command -v sentry-cli)" || -z "$SENTRY_ORG" ) ]]; then
    if [[ "${ALLOW_NO_SYMBOLS:-}" != "1" ]]; then
        cat >&2 <<'MSG'
error: this build carries a Sentry DSN but cannot upload debug symbols, so its
       crash reports would arrive with no function names or line numbers.

  Needs all three:
    - sentry-cli            brew install getsentry/tools/sentry-cli
    - an auth token         security add-generic-password -U -s sentry-release-token -a sentry -w
                            (bare -w prompts hidden, keeping the token out of shell history)
    - SENTRY_ORG            your Sentry organization slug. Deliberately not
                            defaulted in this file: an org name is an identifier,
                            and this script is meant to be publishable.

  Or ship without symbols deliberately:
      ALLOW_NO_SYMBOLS=1 Scripts/release.sh
MSG
        exit 1
    fi
    echo "WARNING: ALLOW_NO_SYMBOLS=1 — shipping without symbolicated crash reports" >&2
fi

# 0g. Run the artifact-independent half of the gate NOW, before the build. A red
#     test suite or a missing release note is knowable in seconds; discovering it
#     after a build and two notarizations costs ten minutes, and a gate that
#     expensive stops being run. Same script, same rules, two moments.
echo "==> Preflight gate (Scripts/check-release.sh, artifact-independent checks)"
PREFLIGHT_ONLY=1 Scripts/check-release.sh || {
    echo "error: preflight gate failed — nothing built. Fix the above and re-run." >&2
    exit 1
}

# 1. Build, sign, notarize and staple the .app. Stapling the bundle (not only
#    the DMG) is what lets the installed copy launch on a Mac that is offline.
echo "==> Building and notarizing ${APP}"
IDENTITY="$IDENTITY" NOTARY_PROFILE="$NOTARY_PROFILE" ./Scripts/make-app.sh

# 2. Upload debug symbols for the build that is actually shipping.
#    Deliberately the .app plus the release dSYM, and NOT all of .build, which
#    also holds sentry-cocoa's iOS, watchOS, tvOS and simulator slices. Those
#    cannot be crashed in by a macOS app; they only burn upload time and quota.
if [[ "$HAS_DSN" == "1" && -n "${SENTRY_AUTH_TOKEN:-}" ]] && command -v sentry-cli >/dev/null 2>&1; then
    echo "==> Uploading debug symbols to Sentry"
    UPLOAD_PATHS=("$APP")
    # Same flags make-app.sh used, or this resolves a different build directory
    # and silently uploads nothing.
    RELEASE_DSYM="$(swift build -c release --build-system native --arch arm64 --arch x86_64 --show-bin-path 2>/dev/null)/Seedbed.dSYM"
    [[ -d "$RELEASE_DSYM" ]] && UPLOAD_PATHS+=("$RELEASE_DSYM")
    sentry-cli debug-files upload \
        --org "$SENTRY_ORG" \
        --project "${SENTRY_PROJECT:-seedbed}" "${UPLOAD_PATHS[@]}" 2>&1 | tail -3 \
        || echo "    symbol upload failed (non-fatal)"
fi

# 3. Stage and build the DMG: the app, a drop target, and the two things the
#    app needs on the other Mac that the bundle cannot carry.
echo "==> Building ${DMG}"
mkdir -p "$DIST"
rm -f "$DMG"
STAGE="build/dmg-stage"
rm -rf "$STAGE"; mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
cp Packaging/dmg-readme.txt "$STAGE/Before you start.txt"
hdiutil create -volname "$APP_NAME" -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null
rm -rf "$STAGE"

# 3b. Verify the image before spending five minutes of Apple's time on it. A
#     corrupt DMG makes notarytool hang rather than fail, and that gets chased
#     as a network problem for an hour. One second here says it outright.
if ! hdiutil verify "$DMG" >/dev/null 2>&1; then
    echo "error: $DMG failed hdiutil verify — refusing to notarize a corrupt image." >&2
    echo "       Rebuild it (delete dist/ and re-run); do not retry notarization." >&2
    exit 1
fi

# 4. Sign, then notarize, then staple. That order.
echo "==> Signing the DMG"
codesign --force --timestamp --sign "$IDENTITY" "$DMG"

# GNU timeout is not part of macOS. Where it is absent, run the command bare
# rather than failing on a missing binary: the retry loop still works, it just
# loses the outer wall clock that the comment below explains.
command -v timeout >/dev/null 2>&1 || timeout() { shift; "$@"; }
echo "==> Notarizing the DMG"
# `--timeout` covers the wait for Apple's verdict and NOT the upload, and the
# upload is the half that hangs: notarytool sits at "initiating connection to
# the Apple notary service" with nothing ever reaching `notarytool history`, so
# the flag never fires and the release appears to be working. Observed twice in
# one afternoon on another project, at 69 and 18 minutes, both killed by hand.
# An outer wall clock plus retries turns an hour of silence into a hiccup.
notarize_with_retry() {
    for attempt in 1 2 3; do
        if timeout 900 xcrun notarytool submit "$DMG" \
                --keychain-profile "$NOTARY_PROFILE" --wait --timeout 12m; then
            return 0
        fi
        echo "    WARNING: attempt $attempt did not finish within 15 minutes — retrying" >&2
        pkill -f "notarytool submit" 2>/dev/null || true
    done
    return 1
}
if ! notarize_with_retry; then
    echo "error: notarization failed after 3 attempts (15 minutes wall clock each)." >&2
    echo "       Check whether the upload ever landed:" >&2
    echo "         xcrun notarytool history --keychain-profile $NOTARY_PROFILE | head -20" >&2
    echo "       Absent from that list means nothing uploaded, and waiting cannot help." >&2
    echo "       Nothing was published: the DMG is local and no tag was written." >&2
    exit 1
fi

echo "==> Stapling"
xcrun stapler staple "$DMG"
xcrun stapler validate "$DMG" && echo "    staple validated"

# 5. The appcast. generate_appcast EdDSA-signs every DMG in dist/ from the
#     keychain key and writes dist/appcast.xml — the whole feed, not one item,
#     so a copy on an older version can still find a path forward.
GA_BIN="${GA_BIN:-$(find "$HOME/Library/Developer" "$HOME/Library/Caches/org.swift.swiftpm" \
    ./.build "$HOME/Projects" -type f -name generate_appcast -path '*Sparkle*' 2>/dev/null | head -1)}"
if [[ -n "${GA_BIN:-}" && -x "$GA_BIN" ]]; then
    echo "==> Generating the appcast"
    "$GA_BIN" "$DIST" --download-url-prefix "${APPCAST_BASE}/" -o "$DIST/appcast.xml" >/dev/null
    APPCAST_BUILD="$(perl -0ne 'if (/<sparkle:version>(\d+)<\/sparkle:version>/) { print $1; exit }' "$DIST/appcast.xml")"
    if [[ -z "$APPCAST_BUILD" || "$APPCAST_BUILD" -lt "$BUILD_NUM" ]]; then
        echo "error: the appcast's newest build (${APPCAST_BUILD:-missing}) is older than" >&2
        echo "       this bundle's $BUILD_NUM — nobody would be offered this release." >&2
        exit 1
    fi
    echo "    appcast.xml written, newest build $APPCAST_BUILD"
else
    echo "error: generate_appcast not found — refusing to ship a release with no feed." >&2
    echo "       Installed copies would never hear about it. Set GA_BIN to override." >&2
    exit 1
fi

# 5b. Sync the Homebrew cask to this release, BEFORE the gate, so the gate
#     validates what will actually be published rather than a file the next step
#     is about to rewrite. The cask pins a version and a sha256, so without this
#     it rots to a DMG that is no longer served and `brew install` 404s — the
#     same way a landing page goes stale, and just as invisibly, because nothing
#     the owner runs day to day ever reads it.
#
#     The caveats come from Packaging/dmg-readme.txt rather than being written
#     twice. Seedbed is a front end to a checkout and an interpreter, so both
#     install paths have to say so, and the one nobody uses is the one that
#     would go stale.
echo "==> Syncing the Homebrew cask"
Scripts/sync-cask.sh

# 5c. The public site is the third version-pinned surface, beside the cask and
#     the appcast: its download links name the DMG file. Synced here for the
#     same reason and checked by the same gate, so a page that still advertises
#     the previous release cannot pass. Publishing it is Scripts/publish-site.sh,
#     which refuses to deploy until this release's DMG is actually served.
echo "==> Syncing the public site"
Scripts/sync-site.sh

# 6. The other half of the gate, now that there are artifacts to check: the
#    bundle matches the plist, both tickets staple, Gatekeeper accepts the app,
#    and a configured DSN actually made it into the bundle.
echo "==> Release gate (Scripts/check-release.sh)"
Scripts/check-release.sh || {
    echo "error: release gate failed. The DMG exists but should not be handed to" >&2
    echo "       anyone until the above is fixed." >&2
    exit 1
}

# 7. Tag, last, and only when there is something a tag can honestly point at.
#    Nothing tagged releases before this, which is why check-release.sh's
#    "build number must increase" check had been a no-op since it was written:
#    it compares against the last v* tag and there were none. A tag is also the
#    only thing that makes "which build is that Mac running?" answerable, and
#    five DMGs were built in one afternoon all calling themselves 0.1.0 (1).
#
#    A dirty tree gets no tag. A tag on uncommitted work points at a commit that
#    does not contain what shipped, which is worse than no tag at all: it looks
#    like an answer.
if [[ "$DIRTY" == "1" ]]; then
    echo "==> Not tagging: the tree is dirty, so v${VERSION} would point at $COMMIT,"
    echo "    which is not what this DMG was built from. Commit, then tag by hand:"
    echo "      git tag -a v${VERSION} -m 'Seedbed ${VERSION} (${BUILD_NUM})' && git push origin v${VERSION}"
elif git rev-parse -q --verify "refs/tags/v${VERSION}" >/dev/null 2>&1; then
    echo "==> Tag v${VERSION} already exists (rebuild) — left alone."
else
    echo "==> Tagging v${VERSION}"
    git tag -a "v${VERSION}" -m "Seedbed ${VERSION} (${BUILD_NUM})"
    git push -q origin "v${VERSION}" 2>/dev/null \
        && echo "    pushed v${VERSION} to origin" \
        || echo "    tagged locally; push it when the remote is reachable"
fi

SHA="$(shasum -a 256 "$DMG" | awk '{print $1}')"
SIZE="$(du -h "$DMG" | awk '{print $1}')"

cat <<SUMMARY

Built: $DMG  ($SIZE)
  version   $VERSION (build $BUILD_NUM), commit $COMMIT
  sha256    $SHA
  signed    $IDENTITY
  notarized app and DMG, both stapled

To install on another Mac: copy the DMG over, open it, drag Seedbed to
Applications, and follow "Before you start.txt" inside the image — the app
needs a checkout of this repository and Python 3.11+ to do anything.

Verify it arrived intact, on that Mac, before installing:
  shasum -a 256 ~/Downloads/$(basename "$DMG")

Casks/seedbed.rb now pins $VERSION,$BUILD_NUM — commit it with the version bump.
Homebrew keeps offering the PREVIOUS release until the public tap is updated,
which is a separate step on its own schedule:
  Scripts/publish.sh          put the DMG and the feed on the download host
  ../Scripts/publish-repo.sh  push the sanitized snapshot, cask included
  ../Scripts/publish-site.sh  deploy site/ once the DMG above is served
SUMMARY
