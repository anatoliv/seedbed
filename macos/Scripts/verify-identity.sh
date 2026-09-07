#!/usr/bin/env bash
#
# Which revision is this artifact?
#
#   Scripts/verify-identity.sh                          the built app
#   Scripts/verify-identity.sh path/to/Seedbed.app
#   Scripts/verify-identity.sh path/to/Seedbed_0.1.9_universal.dmg
#   Scripts/verify-identity.sh <artifact> <expected-sha>  assert, don't just print
#
# Distinct from Scripts/verify-reporting-artifact.sh, which asks a bigger
# question — provider, environment, signature, universality, and whether the
# dSYM matches the binary — and needs the unpacked app plus its dSYM to do it.
# That is the right check at release time, when both are still on the machine.
# This one is for the artifact you were HANDED, where the dSYM is long gone and
# a DMG is all that exists.
#
# It exists because "what source produced the copy people are running?" had no
# answer that did not require trusting something. A tag names a commit and not
# the bytes anyone downloaded. A cask sha256 and an appcast signature prove the
# bytes are the ones that were published, which is a different claim entirely:
# they establish integrity, not provenance. The only artifact-borne answer is
# the one the artifact carries itself, which make-app.sh writes into Info.plist
# as CrashReportingRelease.
#
# For anything built before that record existed -- 0.1.8 and earlier -- the
# answer has to come from the repository instead, and it can:
#
#   curl -sL https://seedbed.dev/Seedbed_0.1.8_universal.dmg | shasum -a 256
#   git log -S<that hash> -- Casks/seedbed.rb        # the commit pinning it
#   git rev-list -n1 v0.1.8                          # the tagged revision
#
# The cask commit sits directly on the tagged release. That chain resolves only
# against the PRIVATE repository: the public mirror carries rewritten snapshot
# commits with different SHAs and no tags at all. It is also attestation by
# bookkeeping rather than by the artifact -- it trusts those records were honest
# when written, and it breaks silently if a DMG is rebuilt and re-uploaded
# without touching the cask. That is precisely the weakness an embedded record
# removes.
#
# Deliberately does no build and no network. It reads a plist out of a bundle,
# mounting the image read-only first if it was handed one, so it is seconds
# against anything -- including a DMG downloaded from the live site, which is
# the case that matters:
#
#   curl -sLO https://seedbed.dev/Seedbed_0.1.9_universal.dmg
#   Scripts/verify-identity.sh Seedbed_0.1.9_universal.dmg
#
# Exit status is the check: 0 identity present (and equal to the expected SHA if
# one was given), 1 absent, malformed, or mismatched.

set -euo pipefail

TARGET="${1:-}"
EXPECTED="${2:-}"

if [[ -z "$TARGET" ]]; then
    cd "$(dirname "$0")/.."
    TARGET="build/Seedbed.app"
fi

if [[ ! -e "$TARGET" ]]; then
    echo "error: no such artifact: $TARGET" >&2
    exit 1
fi

# An expected value that is itself malformed would quietly never match, so it is
# checked before it is used rather than after it has failed.
if [[ -n "$EXPECTED" && ! "$EXPECTED" =~ ^[0-9a-f]{40}$ ]]; then
    echo "error: the expected SHA '$EXPECTED' is not 40 lowercase hex characters." >&2
    exit 1
fi

MOUNT=""
cleanup() { [[ -n "$MOUNT" ]] && hdiutil detach "$MOUNT" >/dev/null 2>&1 || true; }
trap cleanup EXIT

APP="$TARGET"
if [[ "$TARGET" == *.dmg ]]; then
    # -nobrowse keeps it out of the Finder sidebar; -readonly so inspecting an
    # artifact can never modify the thing being inspected.
    MOUNT="$(mktemp -d -t seedbed-verify)"
    if ! hdiutil attach -nobrowse -readonly -mountpoint "$MOUNT" "$TARGET" >/dev/null 2>&1; then
        echo "error: could not mount $TARGET" >&2
        exit 1
    fi
    APP="$(find "$MOUNT" -maxdepth 1 -name '*.app' -print -quit)"
    if [[ -z "$APP" ]]; then
        echo "error: no .app at the top level of $TARGET" >&2
        exit 1
    fi
fi

PLIST="$APP/Contents/Info.plist"
if [[ ! -f "$PLIST" ]]; then
    echo "error: $APP has no Contents/Info.plist — not an app bundle." >&2
    exit 1
fi

# Each field read on its own, so a bundle carrying fields this script predates
# is read for what it does have rather than refused for what it does not.
read_key() { /usr/libexec/PlistBuddy -c "Print :$1" "$PLIST" 2>/dev/null || true; }

VERSION="$(read_key CFBundleShortVersionString)"
BUILD="$(read_key CFBundleVersion)"
RELEASE="$(read_key CrashReportingRelease)"
PROVIDER="$(read_key CrashReportingProvider)"

echo "artifact: $TARGET"
echo "version:  ${VERSION:-<absent>} (${BUILD:-<absent>})"

# The commit is the part after the "@". Extracted rather than assumed, so a
# release string in some other shape fails the check below instead of being
# silently truncated into something that looks like an answer.
COMMIT=""
[[ "$RELEASE" == *@* ]] && COMMIT="${RELEASE##*@}"

if [[ ! "$COMMIT" =~ ^[0-9a-f]{40}$ ]]; then
    echo "release:  ${RELEASE:-<absent>}"
    echo
    echo "error: this artifact carries no usable source identity." >&2
    if [[ -z "$RELEASE" ]]; then
        # The honest reading for anything built before the record existed.
        # Saying "unknown" would imply a lookup was attempted and failed;
        # nothing was ever recorded to look up.
        echo "       CrashReportingRelease is absent or empty, so this predates the record" >&2
        echo "       or was not built by Scripts/make-app.sh. Nothing about the bytes can" >&2
        echo "       establish which revision produced them — a matching cask hash or" >&2
        echo "       appcast signature proves integrity, not provenance." >&2
        echo "       Attribute it from the repository instead; see the header of this" >&2
        echo "       script for the tag-and-cask chain, and its limits." >&2
    else
        echo "       CrashReportingRelease is present but does not end in a 40-character" >&2
        echo "       lowercase hex commit, which is worse than absent: it reads as an" >&2
        echo "       answer." >&2
    fi
    exit 1
fi

echo "release:  $RELEASE"
echo "commit:   $COMMIT"
echo "reporting: ${PROVIDER:-none}"

if [[ -n "$EXPECTED" ]]; then
    if [[ "$COMMIT" != "$EXPECTED" ]]; then
        echo
        echo "error: expected $EXPECTED, but the artifact says $COMMIT." >&2
        exit 1
    fi
    echo "matches the expected revision."
fi

# Only meaningful inside a checkout, and only when that checkout knows the
# commit — verifying a downloaded DMG somewhere else must not fail for it.
if git rev-parse --git-dir >/dev/null 2>&1; then
    if git cat-file -e "${COMMIT}^{commit}" 2>/dev/null; then
        echo "resolves here: $(git log -1 --format='%h %s' "$COMMIT" 2>/dev/null)"
    else
        echo "note: $COMMIT is not in this checkout — fetch, or it was built elsewhere."
    fi
fi
