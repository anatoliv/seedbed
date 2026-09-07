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
        """Give every case an empty packaging directory of its own.

        Scrubbing the environment is only half the isolation, and scrubbing
        alone is what made these tests machine-dependent: the DSN files are
        gitignored, so their presence is a property of the developer's machine,
        and the script anchors to its own directory whatever the caller's cwd.
        The suite therefore passed on a checkout with no DSN and failed on one
        with a real `sentry-dsn.local` present, which is the machine that cuts
        releases. A test that is green only where the feature is inert is worse
        than no test, because it reads as coverage.
        """
        self._packaging = tempfile.TemporaryDirectory()
        self.addCleanup(self._packaging.cleanup)
        self.packaging = Path(self._packaging.name)

    def run_config(self, *args: str, **extra: str) -> subprocess.CompletedProcess[str]:
        env = os.environ.copy()
        for key in (
            "SEEDBED_CRASHBOX_DSN",
            "SEEDBED_SENTRY_DSN",
            "SEEDBED_BUILD_REF",
            "SEEDBED_ERROR_ENVIRONMENT",
        ):
            env.pop(key, None)
        # The file half of the isolation. Without it the real, gitignored
        # Packaging directory leaks in and the answer depends on the machine.
        env["SEEDBED_PACKAGING_DIR"] = str(self.packaging)
        env.update(extra)
        return subprocess.run(
            [str(SCRIPT), *args], env=env, text=True,
            stdout=subprocess.PIPE, stderr=subprocess.PIPE, check=False,
        )

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

    # ------------------------------------------------------------------ the
    # isolation itself, tested rather than assumed. These two exist because the
    # rest of this class was green on a machine with no DSN and red on one with,
    # and nothing in the suite could say which machine it was running on.

    def test_the_override_really_displaces_the_repository_directory(self) -> None:
        """A DSN in the temp directory is read; the real one is not.

        This is the assertion the whole class rests on. If the override ever
        stops working, every other case here silently starts reporting on
        whatever the developer happens to have configured, which is exactly the
        failure that was shipped.
        """
        (self.packaging / "crashbox-dsn.local").write_text(
            "https://public@crashbox.invalid/42\n")
        result = self.run_config("--provider-only")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout, "crashbox\n",
                         "the script read something other than the injected directory")

    def test_the_default_is_still_the_repository_packaging_directory(self) -> None:
        """Real callers pass nothing and must keep the original behaviour.

        Checked in the source rather than by running it, because running it
        without the override is precisely the machine-dependent thing this
        change exists to remove: the answer would depend on whether whoever
        runs the suite happens to have a DSN.
        """
        script = SCRIPT.read_text()
        self.assertIn('PACKAGING_DIR="${SEEDBED_PACKAGING_DIR:-$PWD/Packaging}"', script,
                      "the default packaging directory changed; real callers rely on it")
        self.assertIn('cd "$(dirname "$0")/.."', script,
                      "$PWD in the default is only correct while the script anchors itself")


if __name__ == "__main__":
    unittest.main()
