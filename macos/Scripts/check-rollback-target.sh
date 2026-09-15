#!/usr/bin/env bash
# Verify that a retained Seedbed artifact is an allowed Crashbox rollback.

set -euo pipefail

TARGET="${1:?usage: check-rollback-target.sh <Seedbed.app|Seedbed.dmg> <version> <build> <commit> <signer>}"
EXPECTED_VERSION="${2:?usage: check-rollback-target.sh <Seedbed.app|Seedbed.dmg> <version> <build> <commit> <signer>}"
EXPECTED_BUILD="${3:?usage: check-rollback-target.sh <Seedbed.app|Seedbed.dmg> <version> <build> <commit> <signer>}"
EXPECTED_COMMIT="${4:?usage: check-rollback-target.sh <Seedbed.app|Seedbed.dmg> <version> <build> <commit> <signer>}"
EXPECTED_SIGNER="${5:?usage: check-rollback-target.sh <Seedbed.app|Seedbed.dmg> <version> <build> <commit> <signer>}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$SCRIPT_DIR/../.." && pwd)"

if [[ ! "$EXPECTED_SIGNER" =~ ^Developer\ ID\ Application:\ .+\ \(([A-Z0-9]{10})\)$ ]]; then
    echo "error: the expected Seedbed signer is not one exact Developer ID Application identity." >&2
    exit 1
fi
EXPECTED_TEAM="${BASH_REMATCH[1]}"

if [[ ! -e "$TARGET" ]]; then
    echo "error: no such rollback artifact: $TARGET" >&2
    exit 1
fi

MOUNT=""
cleanup() {
    if [[ -n "$MOUNT" ]]; then
        /usr/bin/hdiutil detach "$MOUNT" >/dev/null 2>&1 || true
        /bin/rmdir "$MOUNT" >/dev/null 2>&1 || true
    fi
}
trap cleanup EXIT

APP="$TARGET"
verify_signer() {
    local artifact="$1" description="$2" details authority team
    details="$(/usr/bin/codesign -d --verbose=4 "$artifact" 2>&1)" || {
        echo "error: the $description signing identity could not be read." >&2
        return 1
    }
    authority="$(printf '%s\n' "$details" | /usr/bin/sed -n 's/^Authority=//p' | /usr/bin/head -1)"
    team="$(printf '%s\n' "$details" | /usr/bin/sed -n 's/^TeamIdentifier=//p' | /usr/bin/head -1)"
    if [[ "$authority" != "$EXPECTED_SIGNER" || "$team" != "$EXPECTED_TEAM" ]]; then
        echo "error: the $description was not signed by the expected Seedbed Developer ID team." >&2
        return 1
    fi
}

if [[ "$TARGET" == *.dmg ]]; then
    if ! /usr/bin/codesign --verify --strict "$TARGET" >/dev/null 2>&1; then
        echo "error: the rollback DMG does not carry a valid code signature." >&2
        exit 1
    fi
    verify_signer "$TARGET" "rollback DMG" || exit 1
    if ! /usr/bin/xcrun stapler validate "$TARGET" >/dev/null 2>&1; then
        echo "error: the rollback DMG carries no valid stapled notarization ticket." >&2
        exit 1
    fi
    MOUNT="$(mktemp -d -t seedbed-rollback)"
    if ! /usr/bin/hdiutil attach -nobrowse -readonly -mountpoint "$MOUNT" "$TARGET" >/dev/null 2>&1; then
        echo "error: could not mount rollback artifact: $TARGET" >&2
        exit 1
    fi
    # The helper enumerates directory entries rather than using `*.app`, because
    # Bash's ordinary glob omits a hidden second application from the count.
    if ! APP="$(python3 "$SCRIPT_DIR/support/select_rollback_app.py" "$MOUNT")"; then
        exit 1
    fi
elif [[ "${APP##*/}" != "Seedbed.app" || ! -d "$APP" || -L "$APP" ]]; then
    echo "error: the rollback app must be a non-symlink Seedbed.app directory." >&2
    exit 1
fi

if ! python3 "$SCRIPT_DIR/support/rollback_metadata.py" \
    "$REPO" "$APP" "$EXPECTED_VERSION" "$EXPECTED_BUILD" "$EXPECTED_COMMIT"; then
    echo "error: the rollback artifact metadata is not an allowed Seedbed rollback identity." >&2
    exit 1
fi

if ! /usr/bin/codesign --verify --deep --strict "$APP" >/dev/null 2>&1; then
    echo "error: the rollback Seedbed.app does not carry a valid code signature." >&2
    exit 1
fi
verify_signer "$APP" "rollback Seedbed.app" || exit 1
if ! /usr/sbin/spctl --assess --type execute "$APP" >/dev/null 2>&1; then
    echo "error: Gatekeeper does not accept the rollback Seedbed.app." >&2
    exit 1
fi
if ! /usr/bin/xcrun stapler validate "$APP" >/dev/null 2>&1; then
    echo "error: the rollback Seedbed.app carries no valid stapled notarization ticket." >&2
    exit 1
fi

PLIST="$APP/Contents/Info.plist"
EXECUTABLE_NAME="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$PLIST")"
EXECUTABLE="$APP/Contents/MacOS/$EXECUTABLE_NAME"
if ! /usr/bin/lipo "$EXECUTABLE" -verify_arch arm64 x86_64 >/dev/null 2>&1; then
    echo "error: the rollback Seedbed executable is not universal arm64 and x86_64." >&2
    exit 1
fi
PROVIDER="$(/usr/libexec/PlistBuddy -c 'Print :CrashReportingProvider' "$PLIST" 2>/dev/null || true)"
REPORTING="${PROVIDER:-disabled}"

echo "rollback identity: net.amnesia.seedbed@${EXPECTED_COMMIT}"
echo "rollback version: $EXPECTED_VERSION ($EXPECTED_BUILD)"
echo "rollback reporting: $REPORTING"
