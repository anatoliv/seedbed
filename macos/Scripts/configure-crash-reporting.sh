#!/usr/bin/env bash
# Select exactly one Sentry-compatible crash-reporting provider and, when given
# an app bundle, inject only that provider into its copied Info.plist.

set -euo pipefail
cd "$(dirname "$0")/.."

# Where the gitignored *-dsn.local files live. The `cd` above re-anchors to the
# repository regardless of the caller's directory, which is what a build wants
# and what a test cannot escape: a machine that has a real DSN configured makes
# this script resolve a provider no caller asked for.
#
# That is not hypothetical. The crash-reporting suite was green on a clean
# checkout, on the public snapshot and in CI, and red on the one machine where
# releases are actually built — because it had `Packaging/sentry-dsn.local`, so
# five cases asserting "no provider" saw "hosted-sentry". The tests passed
# precisely where the feature they cover is inert.
#
# Overriding the directory is the only seam that fixes that honestly. Copying
# this script into a fixture tree from the test side would also go green, and
# would be worse: it would stop exercising the real path resolution, which is
# the thing that broke.
#
# Unset, this is exactly the old literal `Packaging` — a build cannot tell the
# difference.
PACKAGING_DIR="${SEEDBED_PACKAGING_DIR:-Packaging}"

read_value() {
    local from_environment="$1" from_file="$2" value
    value="${!from_environment:-}"
    if [[ -z "$value" && -f "$from_file" ]]; then
        value="$(tr -d ' \t\r\n' < "$from_file")"
    fi
    printf '%s' "$value"
}

crashbox_dsn="$(read_value SEEDBED_CRASHBOX_DSN "$PACKAGING_DIR/crashbox-dsn.local")"
sentry_dsn="$(read_value SEEDBED_SENTRY_DSN "$PACKAGING_DIR/sentry-dsn.local")"

if [[ -n "$crashbox_dsn" && -n "$sentry_dsn" ]]; then
    echo "error: both Crashbox and hosted-Sentry DSNs are configured; refusing dual-send" >&2
    exit 1
fi

provider=none
dsn=""
if [[ -n "$crashbox_dsn" ]]; then
    provider=crashbox
    dsn="$crashbox_dsn"
elif [[ -n "$sentry_dsn" ]]; then
    provider=hosted-sentry
    dsn="$sentry_dsn"
fi

if [[ "${1:-}" == "--provider-only" ]]; then
    printf '%s\n' "$provider"
    exit 0
fi

app="${1:?usage: configure-crash-reporting.sh APP | --provider-only}"
plist="$app/Contents/Info.plist"
[[ -f "$plist" ]] || { echo "error: missing bundle Info.plist" >&2; exit 1; }

set_plist() {
    /usr/libexec/PlistBuddy -c "Set :$1 $2" "$plist"
}

if [[ "$provider" == "none" ]]; then
    set_plist CrashReportingDSN ""
    set_plist CrashReportingProvider ""
    set_plist CrashReportingEnvironment ""
    # The release is source identity, and identity is not a property of crash
    # reporting. A notarized DMG built with no DSN is still an artifact handed
    # to someone else, and the estate rule it has to satisfy — link the exact
    # live distribution to its source revision — does not ask whether the build
    # could report. Leaving this empty for a non-reporting build made the one
    # artifact nobody can interrogate later the one carrying no identity.
    #
    # Still empty when the caller supplied no revision, because a local dev
    # build has none worth asserting and inventing one would be worse.
    if [[ "${SEEDBED_BUILD_REF:-}" =~ ^[0-9a-f]{40}$ ]]; then
        set_plist CrashReportingRelease "net.amnesia.seedbed@$SEEDBED_BUILD_REF"
        echo "==> No reporting DSN: this build cannot report crashes"
        echo "==> Source identity recorded for immutable source $SEEDBED_BUILD_REF"
    else
        set_plist CrashReportingRelease ""
        echo "==> No reporting DSN: this build cannot report crashes"
    fi
    exit 0
fi

case "$dsn" in
    https://?*@?*/?*) ;;
    *) echo "error: the selected reporting DSN is not a valid HTTPS Sentry-compatible DSN" >&2; exit 1 ;;
esac

build_ref="${SEEDBED_BUILD_REF:-}"
if [[ ! "$build_ref" =~ ^[0-9a-f]{40}$ ]]; then
    echo "error: SEEDBED_BUILD_REF must be the exact 40-character lowercase source commit" >&2
    exit 1
fi
environment="${SEEDBED_ERROR_ENVIRONMENT:-production}"
if [[ ! "$environment" =~ ^[a-z0-9][a-z0-9._-]{0,63}$ ]]; then
    echo "error: SEEDBED_ERROR_ENVIRONMENT is not a bounded environment identifier" >&2
    exit 1
fi

set_plist CrashReportingDSN "$dsn"
set_plist CrashReportingProvider "$provider"
set_plist CrashReportingRelease "net.amnesia.seedbed@$build_ref"
set_plist CrashReportingEnvironment "$environment"
echo "==> Configured $provider crash reporting for immutable source $build_ref"
