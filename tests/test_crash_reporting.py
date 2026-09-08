import os
import re
import plistlib
import subprocess
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "macos" / "Scripts" / "configure-crash-reporting.sh"
VERIFY = ROOT / "macos" / "Scripts" / "verify-reporting-artifact.sh"
PLIST = ROOT / "macos" / "Packaging" / "Info.plist"
SOURCE = ROOT / "macos" / "Sources" / "Seedbed" / "CrashReporting.swift"
SOURCES = ROOT / "macos" / "Sources" / "Seedbed"
SETTINGS = SOURCES / "SettingsWindow.swift"
GUIDE = SOURCES / "Guide.swift"
DMG_README = ROOT / "macos" / "Packaging" / "dmg-readme.txt"
SITE = ROOT / "site"


def swift_code(text: str) -> str:
    """`text` with whole-line Swift comments dropped.

    Crude on purpose: it removes lines whose first non-space characters are
    `//`, and nothing else. That is enough to tell a mention of `SentrySDK` in
    a doc comment from a call to it, which is the only distinction the cases
    below need, and it cannot mangle a string literal the way a real comment
    stripper's edge cases can.
    """
    return "\n".join(line for line in text.splitlines()
                     if not line.lstrip().startswith("//"))


class CrashReportingTests(unittest.TestCase):
    def setUp(self) -> None:
        """Point the script at an empty packaging directory.

        Scrubbing the environment covers only half the input. The other half is
        `Packaging/*-dsn.local` on disk, which the script resolves relative to
        its own location — so no amount of environment hygiene on this side can
        stop a configured machine from being seen. That is exactly how these
        tests came to be green everywhere except the machine that builds
        releases, where `sentry-dsn.local` exists and five cases asserting "no
        provider" saw "hosted-sentry" instead.

        An empty directory is the neutral state these cases mean by "default",
        stated rather than assumed from the checkout.
        """
        packaging = tempfile.TemporaryDirectory()
        self.addCleanup(packaging.cleanup)
        self.packaging = Path(packaging.name)

    def run_config(self, *args: str, **extra: str) -> subprocess.CompletedProcess[str]:
        env = os.environ.copy()
        for key in (
            "SEEDBED_CRASHBOX_DSN",
            "SEEDBED_SENTRY_DSN",
            "SEEDBED_BUILD_REF",
            "SEEDBED_ERROR_ENVIRONMENT",
        ):
            env.pop(key, None)
        env.setdefault("SEEDBED_PACKAGING_DIR", str(self.packaging))
        env.update(extra)
        return subprocess.run(
            [str(SCRIPT), *args], env=env, text=True,
            stdout=subprocess.PIPE, stderr=subprocess.PIPE, check=False,
        )

    def test_the_isolation_can_actually_see_configuration(self) -> None:
        """The assertion that would have caught this.

        Every other case here asserts the script reports *no* provider, which a
        broken seam satisfies for free: a script that could not read the
        directory at all would pass all of them. This one asserts the opposite
        direction — that a DSN placed in the packaging directory IS seen — so
        the two together pin that the tests are reading the configuration they
        think they are, rather than reporting emptiness for the wrong reason.
        """
        self.assertEqual("none\n", self.run_config("--provider-only").stdout)

        (self.packaging / "sentry-dsn.local").write_text(
            "https://public@example.invalid/project\n")
        result = self.run_config("--provider-only")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(
            "hosted-sentry\n", result.stdout,
            "a DSN in the packaging directory was not seen, so these tests "
            "would report 'none' whatever the machine is configured with")

    def test_the_dsn_files_are_read_through_the_override(self) -> None:
        """Asserted at the source, because the honest runtime proof is unsafe.

        Demonstrating this at runtime means writing a DSN into the repository's
        own Packaging directory, and a run killed between the write and its
        cleanup would leave a bogus DSN on the machine that builds releases --
        where the next build would pick it up. A test that can misconfigure the
        release machine is not worth the coverage.

        Reinstating a bare literal is the one edit that reintroduces the bug, so
        that is what this pins: the read itself, not the prose around it. An
        earlier version forbade the string anywhere in the file and failed on
        the header comment that explains the bug -- prose about a mistake is not
        the mistake.
        """
        script = SCRIPT.read_text()
        self.assertIn(
            'PACKAGING_DIR="${SEEDBED_PACKAGING_DIR:-Packaging}"', script,
            "the packaging directory is no longer overridable, so these tests "
            "would read whatever the machine is configured with")
        for variable, name in (
            ("SEEDBED_CRASHBOX_DSN", "crashbox-dsn.local"),
            ("SEEDBED_SENTRY_DSN", "sentry-dsn.local"),
        ):
            self.assertIn(
                f'read_value {variable} "$PACKAGING_DIR/{name}"', script,
                f"{name} is not read through the override, so it resolves "
                "against the repository whatever the caller asks for")

    def temporary_app(self, root: str) -> Path:
        app = Path(root) / "Seedbed.app"
        contents = app / "Contents"
        contents.mkdir(parents=True)
        (contents / "Info.plist").write_bytes(PLIST.read_bytes())
        return app

    def test_no_provider_is_the_default(self) -> None:
        result = self.run_config("--provider-only")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout, "none\n")

    def test_disabled_bundle_keeps_all_reporting_fields_empty(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            app = self.temporary_app(tmp)
            result = self.run_config(str(app))
            self.assertEqual(result.returncode, 0, result.stderr)
            values = plistlib.loads((app / "Contents" / "Info.plist").read_bytes())
            for key in (
                "CrashReportingDSN",
                "CrashReportingProvider",
                "CrashReportingRelease",
                "CrashReportingEnvironment",
            ):
                self.assertEqual(values[key], "")

    def test_crashbox_injection_has_exact_identity(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            app = self.temporary_app(tmp)
            commit = "a" * 40
            result = self.run_config(
                str(app),
                SEEDBED_CRASHBOX_DSN="https://public@example.invalid/project",
                SEEDBED_BUILD_REF=commit,
                SEEDBED_ERROR_ENVIRONMENT="production",
            )
            self.assertEqual(result.returncode, 0, result.stderr)
            values = plistlib.loads((app / "Contents" / "Info.plist").read_bytes())
            self.assertEqual(values["CrashReportingProvider"], "crashbox")
            self.assertEqual(values["CrashReportingRelease"], f"net.amnesia.seedbed@{commit}")
            self.assertEqual(values["CrashReportingEnvironment"], "production")
            self.assertEqual(values["CrashReportingDSN"], "https://public@example.invalid/project")

    def test_dual_provider_configuration_fails_without_echoing_dsns(self) -> None:
        first = "https://first@example.invalid/project"
        second = "https://second@example.invalid/project"
        result = self.run_config(
            "--provider-only", SEEDBED_CRASHBOX_DSN=first, SEEDBED_SENTRY_DSN=second
        )
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("refusing dual-send", result.stderr)
        self.assertNotIn(first, result.stdout + result.stderr)
        self.assertNotIn(second, result.stdout + result.stderr)

    def test_nonimmutable_release_fails_closed(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            app = self.temporary_app(tmp)
            result = self.run_config(
                str(app),
                SEEDBED_CRASHBOX_DSN="https://public@example.invalid/project",
                SEEDBED_BUILD_REF="main",
            )
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("exact 40-character", result.stderr)

    def test_malformed_dsn_fails_closed_without_echoing_it(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            app = self.temporary_app(tmp)
            dsn = "http://public@example.invalid/project"
            result = self.run_config(
                str(app), SEEDBED_CRASHBOX_DSN=dsn, SEEDBED_BUILD_REF="a" * 40
            )
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("not a valid HTTPS", result.stderr)
            self.assertNotIn(dsn, result.stdout + result.stderr)

    def test_sdk_is_event_only_and_bounded(self) -> None:
        source = SOURCE.read_text()
        for setting in (
            "options.shutdownTimeInterval = 0",
            "options.tracesSampleRate = 0.0",
            "profiling.sessionSampleRate = 0",
            "profiling.profileAppStarts = false",
            "options.enableAutoSessionTracking = false",
            "options.enableWatchdogTerminationTracking = false",
            "options.enableAppHangTracking = false",
            "options.enableAutoPerformanceTracing = false",
            "options.enableNetworkTracking = false",
            "options.enableFileIOTracing = false",
            "options.enableCoreDataTracing = false",
            "options.enableAutoBreadcrumbTracking = false",
            "options.sendClientReports = false",
            "options.maxBreadcrumbs = 0",
            "options.maxCacheItems = UInt(perLaunchBudget)",
        ):
            self.assertIn(setting, source)
        self.assertIn("static let perLaunchBudget = 20", source)

    def test_startup_and_canary_work_are_off_the_ui_path_and_bounded(self) -> None:
        source = SOURCE.read_text()
        app = (ROOT / "macos" / "Sources" / "Seedbed" / "App.swift").read_text()
        self.assertIn("private static let queue = DispatchQueue", source)
        self.assertGreaterEqual(source.count("queue.async"), 3)
        self.assertIn("static let initializationWait: TimeInterval = 1", source)
        self.assertIn("static let canaryFlushTimeout: TimeInterval = 2", source)
        self.assertIn("SentrySDK.flush(timeout: canaryFlushTimeout)", source)
        self.assertEqual(source.count("SentrySDK.start {"), 1)
        self.assertIn("captureTestEvent { NSApp.terminate(nil) }", app)

    # ------------------------------------------------------------------
    # The privacy promise. Everything above this line is about bandwidth,
    # noise and packaging; everything below is about the sentence printed on
    # the download page and in the Homebrew caveats.
    # ------------------------------------------------------------------

    def test_the_pii_switch_is_off_at_the_sdk(self) -> None:
        """Kept apart from its fifteen neighbours because it is a different claim.

        `test_sdk_is_event_only_and_bounded` pins options that keep the app
        quiet and cheap. Losing one of those costs bandwidth. Losing this one
        attaches the reporting library's own idea of who you are -- IP address,
        user id, request bodies -- to a report that four other files promise
        carries none of it. Same file, same mechanism, different failure, so it
        fails under a name that says which.
        """
        self.assertIn(
            "options.sendDefaultPii = false", SOURCE.read_text(),
            "the SDK is back to attaching an IP address and a user id, which "
            "Settings, the DMG readme, the cask caveats and seedbed.dev all "
            "say it does not")

    def test_the_scrubber_is_wired_into_both_paths_out(self) -> None:
        """What the Swift test cannot see: whether anything calls it.

        `CrashReportingScrubbingTests` runs `scrub` and `redact` and proves they
        strip what they claim to. A scrubber that nothing is wired to passes
        every one of those cases forever, so the wiring is pinned here, at the
        source, where both callbacks are set. There are exactly two ways out of
        this app -- an event and a breadcrumb -- and each must go through one.
        """
        source = SOURCE.read_text()
        self.assertIn("options.beforeSend = { event in", source)
        self.assertIn(
            "return scrub(event)", source,
            "beforeSend no longer routes the event through the scrubber, so "
            "the Swift cases that prove the scrubber works prove nothing about "
            "what is sent")
        self.assertIn(
            "options.beforeBreadcrumb = { redact($0) }", source,
            "breadcrumbs now leave unscrubbed on their own path")
        self.assertIn(
            "static func scrub(_ event: Event) -> Event", source,
            "the scrubber is no longer a named function, so the only way to "
            "run it in a test is to start the SDK and send something")

    def test_the_scrubber_is_reachable_without_starting_the_sdk(self) -> None:
        """The seam exists so the promise can be run rather than read.

        Both scrubbing entry points are internal `static func`s for one reason:
        a closure handed to `SentrySDK.start` can only be exercised by starting
        the SDK, and a test that starts the SDK is a test that can send. Marking
        either of these `private` again would silently reduce the privacy
        contract back to string matching, and the Swift file would stop
        compiling somewhere else entirely.
        """
        source = SOURCE.read_text()
        for signature in (
            "static func scrub(_ event: Event) -> Event",
            "static func redact(_ crumb: Breadcrumb) -> Breadcrumb",
            "static func redact(_ s: String) -> String",
        ):
            self.assertIn(signature, source)
            self.assertNotIn(
                f"private {signature}", source,
                f"{signature} is private again, so nothing outside this file "
                "can run it and the promise goes back to being asserted")

    def test_nothing_in_the_app_hands_library_content_to_the_reporter(self) -> None:
        """"Prompt text is never captured" is a construction, not a filter.

        seedbed.dev/privacy states it in those words, and the header comment of
        `CrashReporting.swift` explains why: the scrubbing is the second line,
        and the first is that nothing calls `capture` with library content.
        `LibraryError.commandFailed` carries `promptlib` stderr, which can quote
        a prompt, and it is deliberately shown in the window instead.

        That is a claim about the absence of call sites, so it is pinned as one.
        A test cannot prove a future `capture` would be given something safe,
        but it can make adding one impossible to do quietly: today the app
        reaches the SDK from a single file, and captures a single fixed string.
        Anything else fails here and gets read by a person.
        """
        offenders = []
        captures = []
        for path in sorted(SOURCES.rglob("*.swift")):
            code = swift_code(path.read_text())
            if "SentrySDK" in code and path != SOURCE:
                offenders.append(str(path.relative_to(ROOT)))
            captures += [line.strip() for line in code.splitlines()
                         if "SentrySDK.capture" in line]

        self.assertEqual(
            offenders, [],
            "these files now reach the reporting SDK directly; the whole "
            "argument for 'prompt text is never captured' is that only "
            "CrashReporting.swift can send anything")
        self.assertEqual(
            captures,
            ['let eventId = SentrySDK.capture(message: "Seedbed crash-reporting wiring test")'],
            "the app captures something other than the one fixed wiring-test "
            "string; whatever it is, check it cannot be a prompt, a render or "
            "a filled-in value before changing this")

    def test_reporting_is_off_until_asked_and_dead_without_a_dsn(self) -> None:
        """Two gates, and each is a line that a refactor can drop.

        Off by default is not a setting anywhere; it is `bool(forKey:)`
        answering false for a key nobody has written, plus the absence of a
        `register(defaults:)` that would supply a true. And a build with no DSN
        must be unable to report whatever the toggle says -- which is every
        copy built out of the checkout, so it is also the state a reader of the
        public source is in.
        """
        source = SOURCE.read_text()
        self.assertIn(
            "static var isEnabled: Bool { UserDefaults.standard.bool(forKey: enabledKey) }",
            source,
            "the opt-in no longer fails off for a key that was never written")
        self.assertNotIn(
            "register(defaults", source,
            "a registered default could make reporting on out of the box")
        self.assertIn(
            "guard isEnabled, let configuration else { return }", source,
            "start() no longer requires both gates")
        self.assertIn(
            "guard let configuration else { return false }", source,
            "the deliberate-crash path no longer requires a DSN")
        self.assertIn("SentrySDK.close()", source,
                      "turning the toggle off no longer stops the SDK")

        settings = SETTINGS.read_text()
        self.assertIn(
            'Toggle("Send crash reports", isOn: $crashReporting)\n'
            "                        .disabled(!CrashReporting.isConfigured)",
            settings,
            "the toggle is offered on a build that cannot report, so it "
            "promises something it cannot do")

    def test_the_published_promise_and_the_code_move_together(self) -> None:
        """The four places a user is told what a report does not carry.

        The point of this case is the direction of the failure. Editing the
        copy is fine; editing it without checking the code still does what the
        new wording says is what this stops. If one of these fails, read
        `CrashReporting.scrub` and `CrashReporting.redact` first, then update
        the phrase here.

        `Casks/seedbed.rb` is deliberately absent: its caveats are generated
        from the DMG readme by `macos/Scripts/sync-cask.sh` and
        `tests/test_cask_parity.py` already pins that they match, so pinning
        the readme pins the cask too.

        Every file read here ships in the public snapshot -- checked against
        the exclude list in `Scripts/publish-repo.sh`, which excludes `*.local`,
        the design plan, the experiment transcripts and the private ops
        scripts, and none of these. So they are read unconditionally on
        purpose; a missing one is a real failure rather than a publish
        artefact.
        """
        promises = [
            (SETTINGS, ["a prompt, a render, a value you typed into a placeholder",
                        "rewritten to a tilde"]),
            (GUIDE, ["none of it is captured", "replaced with a tilde"]),
            (DMG_README, ["never a prompt, a render, a value you filled in, "
                          "or an access token"]),
            (SITE / "index.html", ["never a prompt, a render, a value you filled in, "
                                   "or a token"]),
            (SITE / "privacy.html", ["Prompt text is never captured.",
                                     "any long run of hexadecimal"]),
        ]
        for path, phrases in promises:
            # Hard-wrapped in the readme, one long line in the HTML, and split
            # across `+ "` joins in the Swift. Collapsing runs of whitespace
            # makes one phrase list work for all three; no phrase here crosses
            # a Swift string-concatenation join, which collapsing cannot mend.
            text = re.sub(r"\s+", " ", path.read_text())
            for phrase in phrases:
                self.assertIn(
                    phrase, text,
                    f"{path.relative_to(ROOT)} no longer makes this promise. "
                    "If the wording changed, check CrashReporting.scrub and "
                    "CrashReporting.redact still do what the new wording says, "
                    "then update this list")

    def test_artifact_verifier_never_prints_the_dsn(self) -> None:
        verifier = VERIFY.read_text()
        self.assertIn('[[ -n "$dsn" ]]', verifier)
        for line in verifier.splitlines():
            if line.lstrip().startswith("echo "):
                self.assertNotIn("$dsn", line)


if __name__ == "__main__":
    unittest.main()
