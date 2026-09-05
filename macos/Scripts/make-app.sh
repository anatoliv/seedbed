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

# The signing identity is discovered, never written down. A Team ID in a tracked
# file is an identifier that follows the repo wherever it goes, and this one is
# meant to be publishable; Reference's public tree carries no Team ID for the
# same reason. Exactly one Developer ID Application identity is used silently,
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

# Inject the Sentry DSN into the BUNDLE's Info.plist from a gitignored source.
# The tracked Packaging/Info.plist keeps SentryDSN empty, so the DSN is never
# committed and a build without a source cannot report at all — which is the
# right state for every copy built on the machine it runs on.
SENTRY_DSN_VALUE="${SEEDBED_SENTRY_DSN:-}"
if [[ -z "$SENTRY_DSN_VALUE" && -f Packaging/sentry-dsn.local ]]; then
    SENTRY_DSN_VALUE="$(tr -d ' \t\r\n' < Packaging/sentry-dsn.local)"
fi
if [[ -n "$SENTRY_DSN_VALUE" ]]; then
    /usr/libexec/PlistBuddy -c "Set :SentryDSN $SENTRY_DSN_VALUE" "$APP/Contents/Info.plist"
    echo "==> Injected Sentry DSN into the bundle (reporting still needs the user's opt-in)"
else
    echo "==> No Sentry DSN: this build cannot report crashes, whatever the toggle says"
fi

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
