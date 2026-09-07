import os
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

    def test_artifact_verifier_never_prints_the_dsn(self) -> None:
        verifier = VERIFY.read_text()
        self.assertIn('[[ -n "$dsn" ]]', verifier)
        for line in verifier.splitlines():
            if line.lstrip().startswith("echo "):
                self.assertNotIn("$dsn", line)


if __name__ == "__main__":
    unittest.main()
