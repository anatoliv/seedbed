"""Neither notarization may run without a bounded wall clock around it.

`xcrun notarytool submit` hangs during the *upload*. It prints "initiating
connection to the Apple notary service" and then nothing, while nothing ever
reaches `notarytool history`. Its own `--timeout` flag governs the wait for
Apple's verdict, so on that hang it never fires. Two runs in one afternoon on
another project sat for 69 and 18 minutes before being killed by hand.

A release notarizes twice — the .app in `make-app.sh`, the DMG in `release.sh`
— and until 2026-09-08 the guard was applied unevenly and could vanish
entirely:

* the DMG retried three times under a 900s clock; the .app had the clock and a
  single attempt, so a hang there failed a release the next attempt would have
  finished;
* both scripts shimmed `timeout` to a pass-through when GNU timeout was
  missing, so on a Mac without coreutils the wall clock was gone while the
  source still showed a guard. That is the original unbounded hang, on the
  fresh machine whose operator has never met it.

The real path costs five minutes of Apple's time per attempt and cannot be
exercised here, so these tests work at two strengths. The structural ones read
the scripts, in the idiom of `test_release_gate_runs_swift_tests.py`. The
executable ones source `Scripts/support/notarize.sh` and drive the retry loop
against a command that hangs on purpose, with the clock turned down to a
second, because control flow that is only ever read is control flow nobody has
tested.
"""

from __future__ import annotations

import os
import shutil
import subprocess
import tempfile
import textwrap
import unittest
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
MACOS = REPO / "macos"
MAKE_APP = MACOS / "Scripts" / "make-app.sh"
RELEASE = MACOS / "Scripts" / "release.sh"
HELPER = MACOS / "Scripts" / "support" / "notarize.sh"

# The pass-through shim these tests exist to keep out. Written as a pattern
# rather than the exact old line so a reformatted version of the same idea is
# still caught.
PASS_THROUGH = 'timeout() { shift; "$@"; }'


def code(source: str) -> str:
    """The script with its comment lines removed.

    `notarize.sh` quotes the old pass-through shim in a comment to explain what
    it replaced, and that history is worth keeping. What must not come back is
    the shim as something the shell runs.
    """
    return "\n".join(line for line in source.splitlines()
                     if not line.lstrip().startswith("#"))


def run_bash(script: str, *, path: str | None = None, cwd: Path = MACOS):
    """Run a bash snippet, with the helper available to source."""
    env = dict(os.environ)
    if path is not None:
        env["PATH"] = path
    return subprocess.run(
        ["bash", "-c", textwrap.dedent(script)],
        cwd=cwd, env=env, capture_output=True, text=True, timeout=120)


def path_without_timeout() -> str | None:
    """A PATH holding the system tools but no GNU timeout, or None if one
    cannot be built on this machine."""
    candidate = "/usr/bin:/bin:/usr/sbin:/sbin"
    probe = subprocess.run(
        ["bash", "-c", "command -v timeout || command -v gtimeout"],
        env={"PATH": candidate}, capture_output=True, text=True)
    return None if probe.returncode == 0 else candidate


class TheScriptsShareOneGuard(unittest.TestCase):
    """Two submissions, one implementation, so the next fix reaches both."""

    def setUp(self) -> None:
        self.make_app = MAKE_APP.read_text()
        self.release = RELEASE.read_text()

    def test_the_helper_exists_and_is_sourced_by_both(self) -> None:
        self.assertTrue(HELPER.is_file(),
                        f"{HELPER} is missing; both scripts source it")
        for name, source in (("make-app.sh", self.make_app),
                             ("release.sh", self.release)):
            self.assertIn(
                ". Scripts/support/notarize.sh", source,
                f"{name} does not source the shared notarization helper, so "
                "its wall clock and retry loop are its own again")

    def test_the_helper_is_not_run_as_a_program(self) -> None:
        """release.sh runs make-app.sh as a child process, so the helper has to
        work when sourced by either alone. A helper with a shebang invites
        someone to execute it and get nothing."""
        self.assertFalse(
            HELPER.read_text().startswith("#!"),
            "notarize.sh is sourced, not executed; a shebang misdescribes it")


class TheAppSubmissionRetries(unittest.TestCase):
    """The .app hangs the same way the DMG does and recovers the same way."""

    def setUp(self) -> None:
        self.source = MAKE_APP.read_text()

    def test_the_submission_goes_through_the_retry_loop(self) -> None:
        self.assertIn(
            'notarize_with_retry "$ZIP" "$NOTARY_PROFILE"', self.source,
            "the bundle is submitted outside the retry loop, so one hung "
            "upload fails the whole release")

    def test_it_does_not_submit_directly(self) -> None:
        """A bare `xcrun notarytool submit` here is the single-attempt shape
        this replaced, whatever else surrounds it."""
        self.assertNotIn(
            "xcrun notarytool submit", code(self.source),
            "make-app.sh calls notarytool itself instead of going through the "
            "shared bounded retry")

    def test_the_loop_makes_more_than_one_attempt(self) -> None:
        helper = HELPER.read_text()
        self.assertIn('NOTARIZE_ATTEMPTS="${NOTARIZE_ATTEMPTS:-3}"', helper,
                      "the retry loop no longer defaults to three attempts")
        self.assertIn("attempt <= NOTARIZE_ATTEMPTS", helper,
                      "the loop does not iterate over the attempt budget")


class TheMissingWallClockRefuses(unittest.TestCase):
    """A release that cannot enforce its own wall clock stops and says so."""

    def setUp(self) -> None:
        self.make_app = MAKE_APP.read_text()
        self.release = RELEASE.read_text()
        self.helper = HELPER.read_text()

    def test_nothing_shims_timeout_to_a_pass_through(self) -> None:
        for name, source in (("make-app.sh", self.make_app),
                             ("release.sh", self.release),
                             ("notarize.sh", self.helper)):
            self.assertNotIn(
                PASS_THROUGH, code(source),
                f"{name} still runs the submission bare when GNU timeout is "
                "missing, which is the unbounded hang wearing a guard")

    def test_the_refusal_exits_nonzero(self) -> None:
        self.assertIn("return 1", self.helper,
                      "require_wall_clock has no failing branch")
        for name, source in (("make-app.sh", self.make_app),
                             ("release.sh", self.release)):
            self.assertIn(
                "require_wall_clock || exit 1", source,
                f"{name} calls require_wall_clock without acting on its "
                "verdict, so a missing wall clock only prints")

    def test_both_submissions_check_at_the_point_of_use(self) -> None:
        """A preflight check alone would be bypassed by running make-app.sh
        directly, and by any later reordering of release.sh."""
        self.assertIn("require_wall_clock", self.make_app)
        self.assertIn("notarize_with_retry", self.make_app)
        self.assertLess(self.make_app.index("require_wall_clock"),
                        self.make_app.index("notarize_with_retry"))

        dmg_submit = self.release.index('notarize_with_retry "$DMG"')
        dmg_check = self.release.rindex("require_wall_clock", 0, dmg_submit)
        self.assertLess(
            dmg_check, dmg_submit,
            "the DMG submission is not preceded by a wall-clock check")

    def test_the_release_refuses_before_it_builds(self) -> None:
        """Learning that coreutils is missing after a ten minute build and a
        preflight gate is how a check stops being worth having."""
        first_check = self.release.index("require_wall_clock || exit 1")
        build = self.release.index("./Scripts/make-app.sh")
        self.assertLess(
            first_check, build,
            "the wall-clock refusal happens after the build, so a machine "
            "without coreutils pays for the build before being told")

    def test_an_ordinary_dev_build_needs_no_coreutils(self) -> None:
        """The common path must not get harder. `make-app.sh` with no
        NOTARY_PROFILE never notarizes, so it must never demand the clock."""
        notarize_block = self.make_app.index('if [[ -n "${NOTARY_PROFILE:-}" ]]; then')
        self.assertLess(
            notarize_block, self.make_app.index("require_wall_clock"),
            "make-app.sh demands GNU timeout outside the notarization branch, "
            "so a local build now fails without coreutils")

    def test_presence_alone_is_not_accepted(self) -> None:
        """A `timeout` on PATH that does not kill what it wraps is the same
        hole with the right name, so the check makes it prove itself."""
        self.assertIn("sleep 3", self.helper,
                      "require_wall_clock never exercises the timeout it found")
        self.assertIn("-ne 124", self.helper,
                      "the probe does not check for GNU timeout's kill status, "
                      "so a pass-through returning 0 would satisfy it")


class TheRetryLoopRuns(unittest.TestCase):
    """The loop, executed. Everything above this reads the scripts.

    The clock is turned down to a second and the hanging command sleeps for
    thirty, so a three-attempt give-up takes about three seconds rather than
    forty-five minutes.
    """

    @classmethod
    def setUpClass(cls) -> None:
        if not HELPER.is_file():
            raise unittest.SkipTest(f"{HELPER} is absent")
        cls.timeout_bin = shutil.which("timeout") or shutil.which("gtimeout")
        if cls.timeout_bin is None:
            raise unittest.SkipTest(
                "no GNU timeout on PATH; the loop cannot be exercised here "
                "(brew install coreutils)")

    def setUp(self) -> None:
        self.tmp = tempfile.TemporaryDirectory()
        self.dir = Path(self.tmp.name)
        self.counter = self.dir / "attempts"
        self.counter.write_text("")
        self.addCleanup(self.tmp.cleanup)

    def attempts(self) -> int:
        return len(self.counter.read_text().split())

    def fake(self, name: str, body: str) -> Path:
        """A stand-in for `xcrun`, as a real executable.

        Not a shell function: `timeout` execs what it is given, so it cannot
        wrap one. That is a property of the production call too — the thing
        under the clock there is the `xcrun` binary — and writing the fakes as
        functions produced a loop that "failed" three times without ever
        running them, which is a green test that proves nothing.
        """
        script = self.dir / name
        script.write_text(f'#!/bin/sh\necho x >> "{self.counter}"\n{body}\n')
        script.chmod(0o755)
        return script

    def drive(self, command: Path, attempts: int = 3, wall_clock: int = 1):
        # notarize_abandon_hook is replaced because the real one pkills
        # `notarytool submit`, and a test run has no business killing a real
        # notarization that happens to be in flight on this Mac.
        # NOTARIZE_TIMEOUT_BIN is set so the loop does not re-run the one second
        # probe on every case here; the probe has tests of its own below.
        return run_bash(f"""
            set -uo pipefail
            NOTARIZE_WALL_CLOCK={wall_clock}
            NOTARIZE_ATTEMPTS={attempts}
            . Scripts/support/notarize.sh
            NOTARIZE_TIMEOUT_BIN="{self.timeout_bin}"
            notarize_abandon_hook() {{ :; }}
            notarize_retry_loop "{command}"
            echo "rc=$?"
        """)

    def test_a_hanging_command_is_cut_off_and_retried(self) -> None:
        result = self.drive(self.fake("hangs", "exec sleep 30"))
        self.assertIn("rc=1", result.stdout,
                      f"the loop did not give up: {result.stdout}{result.stderr}")
        self.assertEqual(3, self.attempts(),
                         "the hanging command was not attempted three times")
        self.assertIn("attempt 1 did not finish", result.stderr,
                      "an abandoned attempt is not reported")

    def test_it_stops_at_the_first_success(self) -> None:
        """Retries are for hangs, not a reason to notarize three times."""
        result = self.drive(self.fake("works", "exit 0"))
        self.assertIn("rc=0", result.stdout, result.stderr)
        self.assertEqual(1, self.attempts(),
                         "a successful submission was repeated")

    def test_a_later_attempt_can_still_succeed(self) -> None:
        """The whole point: the second attempt completes what the first hung
        on, instead of the release failing outright."""
        flaky = self.fake(
            "flaky",
            f'[ "$(wc -w < "{self.counter}")" -lt 2 ] && exec sleep 30\nexit 0')
        result = self.drive(flaky)
        self.assertIn("rc=0", result.stdout,
                      f"a hang on the first attempt was not recovered: "
                      f"{result.stdout}{result.stderr}")
        self.assertEqual(2, self.attempts())

    def test_the_failing_command_is_not_rerun_forever(self) -> None:
        """A command that fails fast still respects the attempt budget."""
        result = self.drive(self.fake("fails", "exit 3"), attempts=2)
        self.assertIn("rc=1", result.stdout, result.stderr)
        self.assertEqual(2, self.attempts())

    def test_the_clock_is_what_ends_the_attempt(self) -> None:
        """Not the command giving up on its own: a hung attempt is abandoned
        at the clock, in about a second here and 900 in a release."""
        result = self.drive(self.fake("hangs", "exec sleep 30"), attempts=1)
        self.assertIn("rc=1", result.stdout, result.stderr)
        self.assertEqual(1, self.attempts())


class TheLoopRefusesWithoutAClock(unittest.TestCase):
    """Executed too: with no GNU timeout, nothing is submitted at all."""

    @classmethod
    def setUpClass(cls) -> None:
        if not HELPER.is_file():
            raise unittest.SkipTest(f"{HELPER} is absent")
        cls.bare_path = path_without_timeout()
        if cls.bare_path is None:
            raise unittest.SkipTest(
                "GNU timeout is present even on a system-only PATH, so the "
                "absent case cannot be reproduced on this machine")

    def test_sourcing_alone_does_not_fail(self) -> None:
        """The refusal belongs at the point of use. A check at source time
        would break every local build on a Mac without coreutils."""
        result = run_bash(". Scripts/support/notarize.sh; echo sourced",
                          path=self.bare_path)
        self.assertEqual(0, result.returncode, result.stderr)
        self.assertIn("sourced", result.stdout)

    def test_the_check_fails_and_says_what_to_install(self) -> None:
        result = run_bash(
            ". Scripts/support/notarize.sh; require_wall_clock; echo \"rc=$?\"",
            path=self.bare_path)
        self.assertIn("rc=1", result.stdout,
                      "require_wall_clock passed with no GNU timeout on PATH")
        self.assertIn("brew install coreutils", result.stderr,
                      "the refusal does not say how to fix it")

    def test_a_timeout_that_does_not_enforce_is_rejected(self) -> None:
        """The pass-through shim, as someone else's `timeout` on PATH.

        This is the same hole from the other direction: the binary is there,
        `command -v` is satisfied, and nothing is ever killed. The probe is what
        separates the two, so it is worth running rather than reading.
        """
        with tempfile.TemporaryDirectory() as tmp:
            stub = Path(tmp) / "timeout"
            stub.write_text('#!/bin/sh\nshift\nexec "$@"\n')
            stub.chmod(0o755)
            result = run_bash(
                ". Scripts/support/notarize.sh; require_wall_clock; echo \"rc=$?\"",
                path=f"{tmp}:{self.bare_path}")
            self.assertIn(
                "rc=1", result.stdout,
                "a `timeout` that runs its command unbounded was accepted as a "
                "wall clock")
            self.assertIn("did not interrupt", result.stderr,
                          "the refusal does not say what was wrong with it")

    def test_the_loop_runs_nothing_unguarded(self) -> None:
        """The loop is the last line of defence: called with no clock, it must
        refuse rather than run the command bare, which is what the old
        pass-through shim did."""
        with tempfile.TemporaryDirectory() as tmp:
            ran = Path(tmp) / "ran"
            anything = Path(tmp) / "anything"
            anything.write_text(f'#!/bin/sh\ntouch "{ran}"\n')
            anything.chmod(0o755)
            result = run_bash(f"""
                . Scripts/support/notarize.sh
                notarize_abandon_hook() {{ :; }}
                notarize_retry_loop "{anything}"
                echo "rc=$?"
            """, path=self.bare_path)
            self.assertIn("rc=1", result.stdout,
                          "the retry loop ran without a wall clock")
            self.assertFalse(
                ran.exists(),
                "the command was executed unguarded when GNU timeout was "
                "missing, which is the failure this whole file is about")


if __name__ == "__main__":
    unittest.main()
