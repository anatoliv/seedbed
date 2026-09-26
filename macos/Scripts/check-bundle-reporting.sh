#!/usr/bin/env bash
#
# Ask a built Seedbed whether it can report a crash, from the artifact itself.
#
#   Scripts/check-bundle-reporting.sh <Seedbed.app|Seedbed.dmg> crashbox <release> <environment>
#   ALLOW_NO_REPORTING=1 Scripts/check-bundle-reporting.sh <Seedbed.app|Seedbed.dmg> none
#
# Given a DMG it mounts the image read-only and reads the one Seedbed.app inside,
# because the DMG is what strangers download. A check of build/Seedbed.app says
# nothing about an image rebuilt by hand afterwards.
#
# Six releases in a row (0.1.11 to 0.1.16) shipped with every reporting field
# empty. Each was built in a worktree with no DSN file, so the build resolved
# the provider to "none", printed one line saying so, and every gate downstream
# took "none" as the answer to "which checks apply" rather than as a defect. The
# configuration was never lying; it was never asked the right question. So this
# refuses a non-reporting artifact outright, and the only way past is a named,
# deliberate override.
#
# It never prints the DSN, only whether it has the canonical shape.

set -euo pipefail

usage="usage: check-bundle-reporting.sh <Seedbed.app|Seedbed.dmg> crashbox <release> <environment>
       ALLOW_NO_REPORTING=1 check-bundle-reporting.sh <Seedbed.app|Seedbed.dmg> none"
TARGET="${1:?$usage}"
PROVIDER="${2:?$usage}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

case "$PROVIDER" in
    crashbox)
        EXPECTED_RELEASE="${3:?$usage}"
        EXPECTED_ENVIRONMENT="${4:?$usage}"
        ;;
    none)
        if [[ "${ALLOW_NO_REPORTING:-}" != "1" ]]; then
            echo "error: $TARGET is being checked as a build that cannot report crashes," >&2
            echo "       and nothing said that was intended. Set ALLOW_NO_REPORTING=1 to" >&2
            echo "       ship one deliberately." >&2
            exit 1
        fi
        ;;
    *)
        echo "error: unknown crash-reporting provider '$PROVIDER'." >&2
        echo "$usage" >&2
        exit 64
        ;;
esac

if [[ ! -e "$TARGET" ]]; then
    echo "error: no such artifact: $TARGET" >&2
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
LABEL="$TARGET"
if [[ "$TARGET" == *.dmg ]]; then
    MOUNT="$(mktemp -d -t seedbed-reporting)"
    if ! /usr/bin/hdiutil attach -nobrowse -readonly -noverify -mountpoint "$MOUNT" "$TARGET" >/dev/null 2>&1; then
        echo "error: could not mount $TARGET to read the app it ships." >&2
        exit 1
    fi
    # Exactly one top-level, non-symlink Seedbed.app, the same rule the rollback
    # check applies. A glob would skip a hidden second app.
    if ! APP="$(python3 "$SCRIPT_DIR/support/select_rollback_app.py" "$MOUNT")"; then
        echo "error: $TARGET does not hold exactly one Seedbed.app." >&2
        exit 1
    fi
    LABEL="$TARGET (the app inside)"
elif [[ ! -d "$APP" || -L "$APP" ]]; then
    echo "error: $APP is not a Seedbed.app directory." >&2
    exit 1
fi

PLIST="$APP/Contents/Info.plist"
if [[ ! -f "$PLIST" ]]; then
    echo "error: $LABEL has no Contents/Info.plist." >&2
    exit 1
fi
read_plist() { /usr/libexec/PlistBuddy -c "Print :$1" "$PLIST" 2>/dev/null || true; }
BUNDLED_DSN="$(read_plist CrashReportingDSN)"
BUNDLED_PROVIDER="$(read_plist CrashReportingProvider)"
BUNDLED_RELEASE="$(read_plist CrashReportingRelease)"
BUNDLED_ENVIRONMENT="$(read_plist CrashReportingEnvironment)"

if [[ "$PROVIDER" == "none" ]]; then
    # A deliberate non-reporting build must be one, not half of one. A DSN left
    # behind with an empty provider is a build nobody can reason about.
    if [[ -n "$BUNDLED_DSN" || -n "$BUNDLED_PROVIDER" || -n "$BUNDLED_ENVIRONMENT" ]]; then
        echo "error: $LABEL was meant to be a non-reporting build but carries reporting" >&2
        echo "       fields. Rebuild it with Scripts/make-app.sh." >&2
        exit 1
    fi
    echo "WARNING: $LABEL cannot report crashes (ALLOW_NO_REPORTING=1)." >&2
    exit 0
fi

if [[ -z "$BUNDLED_DSN" ]]; then
    echo "error: $LABEL has an empty CrashReportingDSN. It cannot report a crash" >&2
    echo "       however anyone sets the toggle. Rebuild in a checkout that has" >&2
    echo "       macos/Packaging/crashbox-dsn.local (mode 0600), then re-run." >&2
    exit 1
fi
if [[ ! "$BUNDLED_DSN" =~ ^https://[A-Za-z0-9._~-]+@ingest\.crashbox\.dev/[0-9]+$ ]]; then
    echo "error: $LABEL carries a CrashReportingDSN that does not name the canonical" >&2
    echo "       Crashbox collector. (The value is not printed.)" >&2
    exit 1
fi
if [[ "$BUNDLED_PROVIDER" != "crashbox" ]]; then
    echo "error: $LABEL reports provider '${BUNDLED_PROVIDER:-<empty>}', not crashbox." >&2
    exit 1
fi
if [[ "$BUNDLED_RELEASE" != "$EXPECTED_RELEASE" ]]; then
    echo "error: $LABEL reports as '${BUNDLED_RELEASE:-<empty>}', not $EXPECTED_RELEASE." >&2
    echo "       Its crashes would be filed under a release nobody is looking at." >&2
    exit 1
fi
if [[ "$BUNDLED_ENVIRONMENT" != "$EXPECTED_ENVIRONMENT" ]]; then
    echo "error: $LABEL reports environment '${BUNDLED_ENVIRONMENT:-<empty>}', not $EXPECTED_ENVIRONMENT." >&2
    exit 1
fi
echo "    $LABEL: reports to crashbox as $BUNDLED_RELEASE ($BUNDLED_ENVIRONMENT)"
