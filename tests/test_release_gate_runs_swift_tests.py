"""The release gate must run the Swift suite, and must fail closed on it.

Until 2026-09-08 `macos/Scripts/check-release.sh` had exactly one test step and
it ran the Python suite only. Every Swift test in the package could be red and
a release would still build, notarize, publish and reach a stranger's Mac, with
the gate printing `preflight ok`. Nothing else in the repository ran
`swift test` either, so the suite was decorative on the release path.

What lives only in Swift is the code that decides whether a shipped build can
report a crash at all: the DSN configuration parser, the reporting attempt
fuse, the MCP client-config path override, and the gates in front of the
deliberate test crash. A regression in any of those leaves the Python suite
green and the crash-reporting loop silently unprovable.

This test pins the step in place, and pins its *shape*. Shape matters more than
presence here: `swift test | tail` returns tail's status, so a step written
that way runs the suite, prints its failures and passes the gate — a check that
looks present in review and never fires. That exact trap is why the Python step
next to it captures its output into a variable, and the comment above it says
so.
"""

from __future__ import annotations

import unittest
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
GATE = REPO / "macos" / "Scripts" / "check-release.sh"


class TheReleaseGateRunsTheSwiftSuite(unittest.TestCase):
    def setUp(self) -> None:
        self.source = GATE.read_text()

    def test_the_gate_invokes_swift_test(self) -> None:
        self.assertIn(
            "swift test", self.source,
            "check-release.sh never runs the Swift suite, so every XCTest case "
            "in macos/Tests can be red and the release still ships")

    def test_the_run_is_captured_not_piped(self) -> None:
        """`cmd | tail` reports tail's status and would pass a red suite."""
        self.assertIn(
            'SWIFT_TEST_OUT="$(swift test 2>&1)"', self.source,
            "the swift test run must be captured into a variable; piping it "
            "straight to tail or sed discards its exit status")
        self.assertNotIn(
            "swift test 2>&1 |", self.source,
            "a piped swift test run cannot fail the gate")

    def test_a_failure_exits_nonzero(self) -> None:
        """The failure branch has to stop the release, not just complain."""
        start = self.source.index('SWIFT_TEST_OUT="$(swift test 2>&1)"')
        branch = self.source[start:start + 600]
        self.assertIn("|| {", branch,
                      "nothing reacts to a failed swift test run")
        self.assertIn("exit 1", branch,
                      "a red Swift suite must exit the gate non-zero; printing "
                      "the failures and continuing is the fail-open shape")

    def test_it_runs_in_the_preflight_half(self) -> None:
        """Learning about a red suite after two notarizations is how a gate
        stops being run. The step belongs before the artifacts, like the
        Python one, not only in the post-build invocation."""
        swift = self.source.index("swift test")
        preflight_exit = self.source.index('if [[ "${PREFLIGHT_ONLY:-}" == "1" ]]')
        self.assertLess(
            swift, preflight_exit,
            "the Swift suite runs only after the PREFLIGHT_ONLY early exit, so "
            "a red suite is discovered after the build and notarization")

    def test_the_skip_override_covers_it(self) -> None:
        """One deliberate override, not two. A release that skips one suite is
        already off the paved road, and a second variable is one more thing to
        forget."""
        skip = self.source.index('if [[ "${SKIP_TESTS:-}" == "1" ]]')
        swift = self.source.index("swift test")
        self.assertLess(
            skip, swift,
            "the swift test step sits outside the SKIP_TESTS guard")
        self.assertNotIn(
            "SKIP_SWIFT_TESTS", self.source,
            "a separate skip variable for the Swift suite means the documented "
            "override no longer describes what the gate does")


if __name__ == "__main__":
    unittest.main()
