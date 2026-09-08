# shellcheck shell=bash
#
# Notarization: an outer wall clock, and bounded retries around it.
#
# Sourced, never executed:
#
#     . Scripts/support/notarize.sh
#
# from macos/, which is where make-app.sh and release.sh both cd to. Those two
# are separately runnable and release.sh invokes make-app.sh as a child process
# rather than as a function, so each sources this for itself; neither depends on
# the other having done it first.
#
# WHY ANY OF THIS EXISTS. `xcrun notarytool submit` hangs during the UPLOAD. It
# prints "initiating connection to the Apple notary service" and then nothing,
# while nothing ever reaches `notarytool history`. Its own `--timeout` flag
# governs the wait for Apple's verdict, not the upload, so on that hang the flag
# never fires. Observed twice in one afternoon on another project, at 69 and 18
# minutes, both killed by hand. The mitigation is an outer wall clock with
# bounded retries: an hour of silence becomes a hiccup, and it fails loudly
# instead of appearing to work.
#
# Both submissions here — the .app in make-app.sh, the DMG in release.sh — talk
# to the same service and hang the same way. Until 2026-09-08 only the DMG
# retried, because the two loops were written separately and one of them was
# never finished. They share this file now so the next change reaches both.

# Seconds per attempt, and how many attempts. Overridable because the tests
# drive this loop against a command that hangs on purpose and cannot wait 45
# minutes to watch it give up. A release that sets them is switching off its own
# guard, which is a decision someone can make and is not the default.
NOTARIZE_WALL_CLOCK="${NOTARIZE_WALL_CLOCK:-900}"
NOTARIZE_ATTEMPTS="${NOTARIZE_ATTEMPTS:-3}"

# Resolved by require_wall_clock, which must run before the loop.
NOTARIZE_TIMEOUT_BIN=""

# GNU timeout is not part of macOS. Until 2026-09-08 both scripts shimmed it to
# a pass-through when it was missing:
#
#     command -v timeout >/dev/null 2>&1 || timeout() { shift; "$@"; }
#
# which is the worst available outcome. The wall clock is gone and the source
# still shows a guard, so the original unbounded hang returns on any Mac without
# coreutils — and that fresh Mac is exactly where the release is being run by
# someone who has never met this failure. Refuse instead. Nothing is lost by
# stopping: the hang being guarded against is unbounded, so proceeding without
# the clock is the failure rather than a lesser version of it.
#
# Presence is not the check. A `timeout` on PATH that does not actually kill
# what it wraps is the same hole wearing the right name, so this makes it prove
# itself on a one second clock over a three second sleep before a release is
# allowed to depend on it.
require_wall_clock() {
    local candidate status
    NOTARIZE_TIMEOUT_BIN=""

    if [[ ! "$NOTARIZE_WALL_CLOCK" =~ ^[1-9][0-9]*$ ]]; then
        echo "error: NOTARIZE_WALL_CLOCK must be a positive whole number of seconds," >&2
        echo "       not \"$NOTARIZE_WALL_CLOCK\"." >&2
        return 1
    fi
    if [[ ! "$NOTARIZE_ATTEMPTS" =~ ^[1-9][0-9]*$ ]]; then
        echo "error: NOTARIZE_ATTEMPTS must be a positive whole number," >&2
        echo "       not \"$NOTARIZE_ATTEMPTS\"." >&2
        return 1
    fi

    for candidate in timeout gtimeout; do
        if command -v "$candidate" >/dev/null 2>&1; then
            NOTARIZE_TIMEOUT_BIN="$candidate"
            break
        fi
    done
    if [[ -z "$NOTARIZE_TIMEOUT_BIN" ]]; then
        cat >&2 <<'MSG'
error: no GNU timeout on PATH, so notarization cannot be given a wall clock.
       `xcrun notarytool submit` hangs during the upload with nothing to
       interrupt it, and this refuses to start a submission it has no way to
       stop. That is the whole guard; without it a release can sit silent for
       an hour and then still fail.

  Install it:
      brew install coreutils

  coreutils provides `gtimeout`, and `timeout` where its gnubin directory is on
  PATH. Either one satisfies this.

  Only notarization needs it. An ordinary local build (no NOTARY_PROFILE) never
  reaches here and does not require coreutils.
MSG
        return 1
    fi

    # 124 is what GNU timeout returns when it kills what it wrapped. The old
    # pass-through shim returns sleep's own 0, three seconds later, so a check
    # that only asked for a non-zero status would have accepted it.
    if "$NOTARIZE_TIMEOUT_BIN" 1 sleep 3 >/dev/null 2>&1; then
        status=0
    else
        status=$?
    fi
    if [[ "$status" -ne 124 ]]; then
        echo "error: \`$NOTARIZE_TIMEOUT_BIN\` did not interrupt a command that outlived it" >&2
        echo "       (a 1s clock over a 3s sleep should exit 124; this exited $status)." >&2
        echo "       Notarization would run unbounded, so it stops here. Check what" >&2
        echo "       \`$NOTARIZE_TIMEOUT_BIN\` resolves to: a shell function or a stub on PATH" >&2
        echo "       ahead of coreutils will do this." >&2
        return 1
    fi
    return 0
}

# Called after an attempt has been abandoned. `timeout` kills its own child, but
# notarytool's upload can outlive it, and a second submission racing the first
# is how one hang becomes two.
#
# It is a hook rather than a line in the loop so the tests can replace it. They
# drive the loop with a fake hanging command, and a test run has no business
# pkilling a real notarization that happens to be in flight on this Mac.
notarize_abandon_hook() {
    pkill -f "notarytool submit" 2>/dev/null || true
}

# Run "$@" under the wall clock, up to NOTARIZE_ATTEMPTS times; return 0 as soon
# as one attempt succeeds, non-zero when every attempt has been abandoned.
#
# The command is passed in rather than written here so this loop can be run
# against something that hangs on purpose. Control flow that is only ever read,
# never executed, is control flow nobody has tested.
notarize_retry_loop() {
    local attempt
    if [[ -z "$NOTARIZE_TIMEOUT_BIN" ]]; then
        require_wall_clock || return 1
    fi
    for (( attempt = 1; attempt <= NOTARIZE_ATTEMPTS; attempt++ )); do
        if "$NOTARIZE_TIMEOUT_BIN" "$NOTARIZE_WALL_CLOCK" "$@"; then
            return 0
        fi
        if (( attempt < NOTARIZE_ATTEMPTS )); then
            echo "    WARNING: attempt $attempt did not finish within ${NOTARIZE_WALL_CLOCK}s — retrying" >&2
        fi
        notarize_abandon_hook
    done
    return 1
}

# Submit one artifact — the .app's zip or the DMG — and wait for the verdict.
# `--timeout 12m` is notarytool's own wait for Apple, deliberately shorter than
# the wall clock outside it so a slow verdict fails on its own terms.
notarize_with_retry() {
    local artifact="$1" profile="$2"
    notarize_retry_loop xcrun notarytool submit "$artifact" \
        --keychain-profile "$profile" --wait --timeout 12m
}

# What to print when every attempt has been abandoned. Same advice from both
# scripts, because it is the same failure: the decisive question is whether the
# upload ever landed, and elapsed time cannot answer it.
notarize_failure_advice() {
    local profile="$1"
    echo "       Each attempt was given ${NOTARIZE_WALL_CLOCK}s; ${NOTARIZE_ATTEMPTS} were made." >&2
    echo "       Check whether the upload ever landed:" >&2
    echo "         xcrun notarytool history --keychain-profile $profile | head -20" >&2
    echo "       Absent from that list means nothing uploaded, and waiting cannot help." >&2
}
