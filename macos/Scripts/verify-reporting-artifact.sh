#!/usr/bin/env bash
# Verify a configured app/dSYM pair without printing the DSN or sending data.

set -euo pipefail
app="${1:?usage: verify-reporting-artifact.sh APP DSYM}"
dsym="${2:?usage: verify-reporting-artifact.sh APP DSYM}"
plist="$app/Contents/Info.plist"
binary="$app/Contents/MacOS/Seedbed"

[[ -f "$plist" && -f "$binary" && -d "$dsym" ]] \
    || { echo "error: missing app, binary, or dSYM" >&2; exit 1; }

read_plist() { /usr/libexec/PlistBuddy -c "Print :$1" "$plist" 2>/dev/null || true; }
provider="$(read_plist CrashReportingProvider)"
release="$(read_plist CrashReportingRelease)"
environment="$(read_plist CrashReportingEnvironment)"
dsn="$(read_plist CrashReportingDSN)"

[[ "$provider" == "crashbox" || "$provider" == "hosted-sentry" ]] \
    || { echo "error: bundle has no valid reporting provider" >&2; exit 1; }
[[ "$release" =~ ^net\.amnesia\.seedbed@[0-9a-f]{40}$ ]] \
    || { echo "error: bundle release is not an exact source identity" >&2; exit 1; }
[[ "$environment" =~ ^[a-z0-9][a-z0-9._-]{0,63}$ ]] \
    || { echo "error: bundle environment is invalid" >&2; exit 1; }
[[ -n "$dsn" ]] || { echo "error: bundle has no reporting DSN" >&2; exit 1; }

codesign --verify --strict --deep "$app"
architectures="$(lipo -archs "$binary")"
[[ "$architectures" == *arm64* && "$architectures" == *x86_64* ]] \
    || { echo "error: bundle is not universal" >&2; exit 1; }

binary_uuids="$(dwarfdump --uuid "$binary" | sed -E 's/^UUID: ([0-9A-F-]+).*/\1/' | sort)"
dsym_uuids="$(dwarfdump --uuid "$dsym" | sed -E 's/^UUID: ([0-9A-F-]+).*/\1/' | sort)"
[[ -n "$binary_uuids" && "$binary_uuids" == "$dsym_uuids" ]] \
    || { echo "error: bundle and dSYM UUIDs differ" >&2; exit 1; }

echo "reporting artifact verified: provider=$provider release=$release environment=$environment architectures=$architectures"
