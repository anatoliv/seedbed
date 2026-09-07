#!/usr/bin/env bash
#
# Build Seedbed.app and sign it.
#
#   Scripts/make-app.sh && open build/Seedbed.app
#
# Signing identity matters here, and not only for distribution. macOS ties the
# Accessibility permission — the one that lets the app paste into the frontmost
# app — to the binary's code signature. An ad-hoc signature (`-`) changes on
# every build, so the permission is revoked and has to be granted again after
# every rebuild. Signing with a real identity keeps a stable designated
# requirement, so the permission survives.
#
# Override with IDENTITY="..."; falls back to ad-hoc if no identity is found,
# and says what that costs.
#
# Set NOTARY_PROFILE to also notarize and staple the bundle, which is what makes
# it launchable on a Mac that did not build it:
#
#   NOTARY_PROFILE=<your-profile> Scripts/make-app.sh
#
# (a notarytool keychain profile, created once with `xcrun notarytool
# store-credentials`; the credential is per Apple account, not per app, so the
# existing one covers this). Scripts/release.sh does this and then packages the
# stapled bundle into a DMG.

set -euo pipefail
cd "$(dirname "$0")/.."

# Keep the Mac awake through `notarytool submit`, which uploads to Apple and then
# blocks on a verdict. An idle Mac sleeping through it suspends the upload, and
# the step then looks exactly like a hang with no error to read.
if [[ -n "${NOTARY_PROFILE:-}" ]] && command -v caffeinate >/dev/null; then
    caffeinate -dimsu -w $$ &
fi

APP="build/Seedbed.app"

# Crashbox and hosted Sentry both accept Sentry envelopes, so the SDK does not
# choose the provider. Packaging does, exactly once. A configured reporting
# build must come from a clean, exact commit; version/build is not enough to
# identify the source or its dSYM later.
#
# A notarized build needs the same thing for a second, independent reason: it is
# the artifact that leaves this Mac and outlives the tree that made it, and the
# estate rule it must satisfy — link the exact live distribution to its source
# revision — applies whether or not the build could report anything. Requiring
# it only for reporting builds left the DMG built without a DSN as the one
# artifact nobody could interrogate later.
#
# A caller who supplies SEEDBED_BUILD_REF is asking for a revision to be
# recorded, so it is checked on the same terms whatever else is set. Without
# that third clause an ordinary dev build with the variable exported skipped
# every check here and still got a stamp — which is how a bundle came to name
# a commit while containing uncommitted work.
REPORTING_PROVIDER="$(Scripts/configure-crash-reporting.sh --provider-only)"
if [[ "$REPORTING_PROVIDER" != "none" || -n "${NOTARY_PROFILE:-}" \
      || -n "${SEEDBED_BUILD_REF:-}" ]]; then
    if [[ -n "$(git status --porcelain --untracked-files=normal)" ]]; then
        # A stamp from an uncommitted tree names a revision the build was not
        # made from: authoritative-looking and false, and the next person to
        # read it has no way to tell. Refused rather than warned about, because
        # the artifact it produces is indistinguishable from a good one.
        echo "error: refusing a distributable build from uncommitted source" >&2
        echo "       The recorded revision would name source this build does not contain." >&2
        exit 1
    fi
    SEEDBED_BUILD_REF="${SEEDBED_BUILD_REF:-$(git rev-parse HEAD)}"
    if [[ ! "$SEEDBED_BUILD_REF" =~ ^[0-9a-f]{40}$ ]]; then
        echo "error: a distributable build requires an exact 40-character source commit" >&2
        exit 1
    fi
    export SEEDBED_BUILD_REF
fi

# The signing identity is discovered, never written down. A Team ID in a tracked
# file is an identifier that follows the repo wherever it goes, and this one is
# meant to be publishable. Exactly one Developer ID Application identity is used silently,
# several ask, none falls through to the caller's own handling.
discover_identity() {
    security find-identity -v -p codesigning 2>/dev/null \
        | sed -nE 's/.*"(Developer ID Application: .*)"$/\1/p' | sort -u
}

IDENTITY="${IDENTITY:-}"
if [[ -z "$IDENTITY" ]]; then
    FOUND="$(discover_identity)"
    case "$(printf '%s' "$FOUND" | grep -c . || true)" in
        1) IDENTITY="$FOUND" ;;
        0) IDENTITY="-" ;;
        *) echo "error: several Developer ID identities in the keychain; say which:" >&2
           printf '         %s\n' "$FOUND" >&2
           echo "       IDENTITY=\"Developer ID Application: ...\" Scripts/make-app.sh" >&2
           exit 1 ;;
    esac
fi

# What the bundle will carry so a later check can ask whether it was built from
# these bytes, rather than from a tree whose files merely look older.
#
# The freshness gate in check-release.sh compared source MTIMES against the
# binary's, and content never entered into it. Restoring a file from a backup —
# which is this project's house pattern for proving a guard works — returns it
# byte for byte and moves its mtime, so a byte-correct bundle was reported stale
# in terms indistinguishable from a real staleness. On 2026-09-07 an auditor
# read one of those as proof that committed UI had never been built and sent a
# finished card back on the strength of it. It also fails in the other
# direction, silently: content edited without the mtime moving is invisible to
# an mtime comparison and free to catch with a hash.
#
# Paths are hashed alongside contents, so a rename or a deletion moves the
# digest even when every surviving byte is unchanged. Package.swift is in the
# set because it decides flags and dependencies: a change there produces a
# different binary from identical sources.
#
# Computed BEFORE the build, so it describes what was compiled. A tree edited
# while the build runs then disagrees with the bundle, which is exactly the
# staleness the reader downstream exists to catch.
#
# Kept character for character identical to the copy in check-release.sh — the
# two are compared against each other, so a divergence makes every comparison
# meaningless while looking entirely correct. tests/test_bundle_freshness.py
# pins them equal.
source_digest() {
    find Sources Package.swift -type f -name '*.swift' -print0 \
        | LC_ALL=C sort -z | xargs -0 shasum -a 256 | shasum -a 256 \
        | awk '{print $1}'
}
SOURCE_DIGEST="sha256:$(source_digest)"

echo "==> Building release binary (universal)"
# -Xswiftc -g emits DWARF so dsymutil can produce a real dSYM. Without it the
# binary carries only symtab and unwind info: Sentry can resolve function names
# but never file and line, which is most of what a crash report is worth.
#
# Both architectures, because a DMG is handed to a Mac whose CPU you do not
# choose. This shipped arm64-only until 2026-09-05, which means every Intel Mac
# would have downloaded a notarized, stapled, Gatekeeper-approved image and then
# failed to launch — the one failure mode all the signing work cannot catch,
# since the bundle is perfectly valid and simply has no code the machine can run.
ARCHS=(--arch arm64 --arch x86_64)
swift build -c release --build-system native -Xswiftc -g "${ARCHS[@]}"
BIN="$(swift build -c release --build-system native "${ARCHS[@]}" --show-bin-path)/Seedbed"

# The dSYM is built next to the binary inside .build, which is where release.sh
# points `sentry-cli debug-files upload`. It is deliberately NOT copied into the
# .app: it would enlarge the download for no user benefit.
if command -v dsymutil >/dev/null 2>&1; then
    echo "==> Generating dSYM for crash symbolication"
    dsymutil "$BIN" -o "$BIN.dSYM" 2>/dev/null \
        || echo "    dsymutil failed (non-fatal; crash reports lose file and line)"
fi

# Sparkle's nested code is signed deepest-first and explicitly, never with
# --deep, which mis-signs its XPC services. An outer signature over unsigned
# nested code passes ordinary verification and then fails notarization — or
# worse, fails at update time on someone else's Mac.
sign_sparkle() {
    local sign="$1" fw="$APP/Contents/Frameworks/Sparkle.framework"
    [[ -d "$fw" ]] || return 0
    local opts=(--force --options runtime --timestamp)
    [[ "$sign" == "-" ]] && opts=(--force)
    local v="$fw/Versions/B"
    for x in "$v/XPCServices/Downloader.xpc" "$v/XPCServices/Installer.xpc" \
             "$v/Autoupdate" "$v/Updater.app" "$fw"; do
        [[ -e "$x" ]] && codesign "${opts[@]}" --sign "$sign" "$x"
    done
}

echo "==> Assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Seedbed"
cp Packaging/Info.plist "$APP/Contents/Info.plist"
cp ../assets/brand/Seedbed.icns "$APP/Contents/Resources/Seedbed.icns"
cp ../assets/brand/seedbed-menu-template.png "$APP/Contents/Resources/SeedbedMenuBar.png"
cp ../assets/brand/seedbed-menu-template@2x.png "$APP/Contents/Resources/SeedbedMenuBar@2x.png"

# Inject one provider without ever printing its DSN. The helper refuses a build
# with both Crashbox and hosted-Sentry inputs, so rollback is a rebuild/swap and
# can never accidentally become dual-send.
Scripts/configure-crash-reporting.sh "$APP"

# Re-assert the identity by reading the BUILT bundle back.
#
# Everything above consults the working tree, and the working tree is the one
# witness that cannot testify about the artifact. The injection is a PlistBuddy
# write into a copied file; if it silently does not happen the app looks
# identical and carries an empty key, which is exactly the failure the DSN check
# downstream exists to catch. This asks the bundle what it actually says, and it
# is the only claim here that survives being handed to someone else.
if [[ -n "${SEEDBED_BUILD_REF:-}" ]]; then
    BAKED_RELEASE="$(/usr/libexec/PlistBuddy -c 'Print :CrashReportingRelease' \
        "$APP/Contents/Info.plist" 2>/dev/null || true)"
    if [[ "$BAKED_RELEASE" != "net.amnesia.seedbed@$SEEDBED_BUILD_REF" ]]; then
        echo "error: the built bundle records its release as '${BAKED_RELEASE:-<empty>}'," >&2
        echo "       not net.amnesia.seedbed@$SEEDBED_BUILD_REF. The injection did not" >&2
        echo "       take, so this artifact could not be mapped back to a revision once" >&2
        echo "       it is on someone else's Mac." >&2
        exit 1
    fi
    echo "==> Identity verified from the bundle: $BAKED_RELEASE"
fi

# The second field of the same record, and the one that answers freshness.
#
# Written for EVERY build, unlike the commit above. A commit stamp can be false
# — a tree with uncommitted work carries a perfectly truthful HEAD — which is
# why it is refused unless the tree is clean. A digest cannot be false in that
# way: it describes the bytes that were actually compiled, so a local build's
# digest is as true as a release build's, and withholding it would leave the
# ordinary case relying on the mtime comparison this exists to replace.
#
# Added rather than Set, so the tracked Packaging/Info.plist needs no new key.
# A digest committed into the tree would be a claim the tree makes about a build
# that has not happened, and stale the moment anyone edits a source file. The
# Delete first keeps the Add idempotent against a bundle that already has one.
PLIST="$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Delete :SeedbedSourceDigest' "$PLIST" >/dev/null 2>&1 || true
/usr/libexec/PlistBuddy -c "Add :SeedbedSourceDigest string $SOURCE_DIGEST" "$PLIST" >/dev/null

# Read back out of the bundle, for the same reason the release is: the working
# tree cannot testify about the artifact, and a PlistBuddy write that silently
# did not take leaves an app that looks identical and carries nothing. An absent
# digest is not a quiet pass downstream — it falls back to the mtime check — so
# a failed write here would restore the very defect this replaces.
BAKED_DIGEST="$(/usr/libexec/PlistBuddy -c 'Print :SeedbedSourceDigest' "$PLIST" 2>/dev/null || true)"
if [[ "$BAKED_DIGEST" != "$SOURCE_DIGEST" ]]; then
    echo "error: the built bundle records its source digest as '${BAKED_DIGEST:-<empty>}'," >&2
    echo "       not $SOURCE_DIGEST. The write did not take, so nothing downstream" >&2
    echo "       can tell this bundle from one built before its sources changed." >&2
    exit 1
fi
echo "==> Source digest recorded from the bundle: $BAKED_DIGEST"

# Bundle Sparkle.framework, which the app links and needs at runtime. The rpath
# in Package.swift points here; without the copy the bundle links fine and dies
# on launch, which only ever happens in the packaged app.
SPARKLE_FW="$(find .build -type d -name 'Sparkle.framework' -path '*macos*' 2>/dev/null | head -1)"
if [[ -n "$SPARKLE_FW" ]]; then
    echo "==> Bundling Sparkle.framework"
    mkdir -p "$APP/Contents/Frameworks"
    cp -R "$SPARKLE_FW" "$APP/Contents/Frameworks/"
else
    echo "error: Sparkle.framework not found in .build — the app links it and" >&2
    echo "       would not launch. Run 'swift package resolve' and rebuild." >&2
    exit 1
fi

if [[ "$IDENTITY" == "-" ]]; then
    echo "==> Ad-hoc signing (no identity found)"
    echo "    Accessibility permission will need re-granting after every rebuild."
    sign_sparkle -
    codesign --force --sign - "$APP"
else
    echo "==> Signing as: $IDENTITY"
    # --timestamp is required for notarization; --options runtime is the
    # hardened runtime, likewise required.
    sign_sparkle "$IDENTITY"
    codesign --force --options runtime --timestamp --sign "$IDENTITY" "$APP"
fi
# --strict, because the default verification is lenient enough to pass a bundle
# that then fails notarization.
codesign --verify --strict --deep --verbose=1 "$APP" 2>&1 | sed 's/^/    /'

if [[ -n "${NOTARY_PROFILE:-}" ]]; then
    if [[ "$IDENTITY" == "-" ]]; then
        echo "error: NOTARY_PROFILE is set but the bundle is ad-hoc signed." >&2
        echo "       Apple will not notarize that. Install the Developer ID identity" >&2
        echo "       or unset NOTARY_PROFILE." >&2
        exit 1
    fi
    # GNU timeout is not part of macOS. Where it is absent, run the command bare
    # rather than failing on a missing binary: the retry loop still works, it just
    # loses the outer wall clock that the comment below explains.
    command -v timeout >/dev/null 2>&1 || timeout() { shift; "$@"; }
    echo "==> Notarizing the bundle (profile: $NOTARY_PROFILE)"
    ZIP="build/notarize-upload.zip"
    ditto -c -k --keepParent "$APP" "$ZIP"
    # `--timeout` covers the wait for Apple's verdict and NOT the upload, and the
    # upload is the half that hangs: `notarytool submit` sits at "initiating
    # connection to the Apple notary service" while nothing ever reaches
    # `notarytool history`, so the flag never fires. An outer wall clock turns an
    # hour of silence into a hiccup and fails loudly instead of appearing to work.
    if ! timeout 900 xcrun notarytool submit "$ZIP" \
            --keychain-profile "$NOTARY_PROFILE" --wait --timeout 12m; then
        rm -f "$ZIP"
        echo "error: notarization of the bundle did not complete within 15 minutes." >&2
        echo "       Check whether the upload ever landed:" >&2
        echo "         xcrun notarytool history --keychain-profile $NOTARY_PROFILE | head" >&2
        echo "       Absent from that list means nothing uploaded, and waiting cannot help." >&2
        exit 1
    fi
    rm -f "$ZIP"
    echo "==> Stapling"
    # Staple the .app itself, not just the DMG it will be packaged into. A
    # stapled ticket is what lets the copy in /Applications launch on a Mac that
    # is offline or behind a filter, once it has been dragged out of the image.
    xcrun stapler staple "$APP"
    xcrun stapler validate "$APP" && echo "    staple validated"
    spctl --assess --type execute --verbose "$APP" 2>&1 | sed 's/^/    gatekeeper: /' || true
fi

echo "==> Done: $APP"
echo "    Launch it, then press ⌥⌘P. Quit from the menu-bar icon."
