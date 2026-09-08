"""The wiring around the deliberate crash, which no unit test can reach.

`macos/Tests/SeedbedTests/TestCrashTriggerTests.swift` runs the two gates as
values: whether an argument arms the trigger, and whether the menu item is
visible. What it cannot see is whether the app asks those questions at all, and
that is the whole failure mode here. A gate nobody consults is a gate that
passes its own tests forever while the trigger fires on every launch, or never
fires at all.

So this reads the call sites off the source: that launch consults
`TestCrash.decision`, that the menu consults `TestCrash.menuItemIsVisible` with
the modifiers held right now, that the crash function is called from exactly one
place, and that a person is asked before the app destroys itself.
"""

from __future__ import annotations

import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
APP = ROOT / "macos" / "Sources" / "Seedbed" / "App.swift"
TRIGGER = ROOT / "macos" / "Sources" / "Seedbed" / "TestCrash.swift"
REPORTING = ROOT / "macos" / "Sources" / "Seedbed" / "CrashReporting.swift"
SOURCES = ROOT / "macos" / "Sources" / "Seedbed"

#: The argument, written once here so a rename fails in this file rather than
#: leaving the documentation and the app disagreeing in silence.
ARGUMENT = "--crash-test"

#: The function whose name an operator looks for in a symbolicated stack.
CRASH_FUNCTION = "seedbedTestCrash"


def flattened(text: str) -> str:
    """The source with every run of whitespace collapsed to one space.

    The calls pinned below wrap across several lines and the wrapping is the
    formatter's business, not this test's.
    """
    return " ".join(text.split())


class TheLaunchArgumentIsAsked(unittest.TestCase):
    def setUp(self) -> None:
        self.app = APP.read_text(encoding="utf-8")
        self.flat = flattened(self.app)

    def test_launch_consults_the_gate_with_every_input(self) -> None:
        """Not one input short.

        Dropping `isConfigured` here is the edit that makes a stranger's
        checkout crashable from the command line, and it would leave every
        Swift test green: the gate would still refuse when asked, and nothing
        would ask it.
        """
        self.assertIn(
            "TestCrash.decision(arguments: ProcessInfo.processInfo.arguments, "
            "isConfigured: CrashReporting.isConfigured, "
            "isReportingEnabled: CrashReporting.isEnabled, "
            "isBeingDebugged: TestCrash.isBeingDebugged())",
            self.flat,
            "the launch path no longer asks the trigger gate for its decision",
        )

    def test_every_decision_is_handled(self) -> None:
        for case in (
            "case .notRequested:",
            "case .refusedNoProvider:",
            "case .refusedNotEnabled:",
            "case .refusedDebugger:",
            "case .crash:",
        ):
            self.assertIn(case, self.app, case)

    def test_the_gate_is_asked_after_reporting_has_been_started(self) -> None:
        """Order, because the handler is what catches the crash.

        `CrashReporting.start()` is the call that installs the crash handler on
        an opted-in build. Asking before it would arm a trigger whose crash
        nothing records.
        """
        start = self.app.index("CrashReporting.start()")
        gate = self.app.index("TestCrash.decision(")
        self.assertLess(start, gate)

    def test_the_argument_is_spelled_the_same_here_and_in_the_docs(self) -> None:
        self.assertIn(f'static let launchArgument = "{ARGUMENT}"',
                      TRIGGER.read_text(encoding="utf-8"))
        readme = (ROOT / "macos" / "README.md").read_text(encoding="utf-8")
        self.assertIn(ARGUMENT, readme,
                      "macos/README.md does not name the launch argument, so the "
                      "only record of how to fire the trigger is the source")


class TheMenuItemIsHidden(unittest.TestCase):
    def setUp(self) -> None:
        self.flat = flattened(APP.read_text(encoding="utf-8"))

    def test_the_item_is_added_only_behind_the_visibility_gate(self) -> None:
        self.assertIn(
            "if TestCrash.menuItemIsVisible(modifiers: NSEvent.modifierFlags, "
            "isConfigured: CrashReporting.isConfigured) {",
            self.flat,
            "the test-crash menu item is no longer gated on Option plus a "
            "configured provider",
        )

    def test_the_item_carries_the_shared_title_rather_than_its_own(self) -> None:
        """One spelling, so the Swift test's ellipsis rule reaches the real item."""
        self.assertIn(
            "menu.addItem(withTitle: TestCrash.menuItemTitle, "
            "action: #selector(sendTestCrash), keyEquivalent: \"\")",
            self.flat,
        )

    def test_the_action_asks_before_it_acts(self) -> None:
        action = self.flat[self.flat.index("@objc private func sendTestCrash()"):]
        action = action[: action.index("private func report(testCrashProblem:")]
        self.assertIn('alert.addButton(withTitle: "Cancel")', action)
        self.assertIn('alert.addButton(withTitle: "Crash Now")', action)
        self.assertIn("guard alert.runModal() == .alertSecondButtonReturn else { return }",
                      action)
        self.assertLess(action.index('alert.addButton(withTitle: "Cancel")'),
                        action.index('alert.addButton(withTitle: "Crash Now")'),
                        "Crash Now is the first button, so Return presses it")

    def test_the_action_repeats_both_gates_it_was_drawn_behind(self) -> None:
        """A menu can be left open while the world changes underneath it."""
        action = self.flat[self.flat.index("@objc private func sendTestCrash()"):]
        action = action[: action.index("private func report(testCrashProblem:")]
        self.assertIn("guard CrashReporting.isConfigured else { return }", action)
        self.assertIn("guard CrashReporting.isEnabled else {", action)
        self.assertIn("if TestCrash.isBeingDebugged() {", action)
        self.assertLess(action.index("TestCrash.isBeingDebugged()"),
                        action.index("alert.runModal()"),
                        "the debugger is checked after the confirmation, so a "
                        "person is asked to destroy the app for nothing")


class TheCrashHasOneWayIn(unittest.TestCase):
    def test_the_crash_function_is_called_from_exactly_one_place(self) -> None:
        """Every gate above is worth nothing if a second call site exists."""
        call_sites = []
        for path in sorted(SOURCES.rglob("*.swift")):
            text = path.read_text(encoding="utf-8")
            for number, line in enumerate(text.splitlines(), start=1):
                stripped = line.strip()
                if stripped.startswith("//") or stripped.startswith("///"):
                    continue
                if f"{CRASH_FUNCTION}()" in stripped and "func " not in stripped:
                    call_sites.append(f"{path.name}:{number}")
        self.assertEqual(
            ["App.swift"], sorted({site.split(":")[0] for site in call_sites}),
            f"the crash is called from more than one file: {call_sites}")
        self.assertEqual(1, len(call_sites), call_sites)

    def test_the_only_call_site_is_behind_the_readiness_wait(self) -> None:
        flat = flattened(APP.read_text(encoding="utf-8"))
        body = flat[flat.index("private func fireTestCrash("):]
        self.assertIn("let ready = CrashReporting.prepareForTestCrash()", body)
        self.assertLess(body.index("prepareForTestCrash()"),
                        body.index(f"{CRASH_FUNCTION}()"),
                        "the app crashes before waiting for the crash handler")
        self.assertIn("guard ready else {", body)

    def test_the_function_keeps_the_name_a_symbolicated_stack_will_show(self) -> None:
        """`@_cdecl` fixes the symbol, and the test suite looks it up by that name.

        Removing it does not break the build. It breaks the lookup in
        `TestCrashTriggerTests` and, more quietly, changes what an operator has
        to search for in the symbolicated issue.
        """
        trigger = TRIGGER.read_text(encoding="utf-8")
        self.assertIn(f'@_cdecl("{CRASH_FUNCTION}")', trigger)
        self.assertIn(f"public func {CRASH_FUNCTION}()", trigger)
        self.assertIn("@inline(never)", trigger)

    def test_the_crash_is_a_native_fault_not_a_captured_event(self) -> None:
        """The point of the exercise.

        `SentrySDK.capture` proves the transport and nothing about the crash
        handler, which is the half that has never been exercised in production.
        """
        trigger = TRIGGER.read_text(encoding="utf-8")
        code = [line for line in trigger.splitlines()
                if not line.strip().startswith(("//", "///"))]
        self.assertNotIn("SentrySDK", "\n".join(code),
                         "the trigger reaches for the SDK, so it is capturing an "
                         "event rather than faulting")
        self.assertIn("address.pointee = 0", trigger)
        self.assertIn("abort()", trigger)


class ThePreparationIsBounded(unittest.TestCase):
    def setUp(self) -> None:
        self.reporting = REPORTING.read_text(encoding="utf-8")
        self.flat = flattened(self.reporting)

    def test_preparation_fails_closed_without_a_configuration(self) -> None:
        body = self.flat[self.flat.index("static func prepareForTestCrash()"):]
        body = body[: body.index("static func onReportingQueue(")]
        self.assertIn("guard let configuration else { return false }", body)
        self.assertIn("return attemptGate.current() == .started && SentrySDK.isEnabled", body)

    def test_preparation_waits_on_the_same_bounded_deadline_as_the_canary(self) -> None:
        body = self.flat[self.flat.index("static func prepareForTestCrash()"):]
        body = body[: body.index("static func onReportingQueue(")]
        self.assertIn("Date().addingTimeInterval(initializationWait)", body)
        self.assertIn("while !SentrySDK.isEnabled && Date() < deadline", body)

    def test_the_trigger_did_not_add_a_second_sdk_start(self) -> None:
        """One client, one start call, still."""
        self.assertEqual(1, self.reporting.count("SentrySDK.start {"))


if __name__ == "__main__":
    unittest.main()
