"""A release that cannot report a crash is refused unless someone says so.

0.1.11 to 0.1.16 shipped with every crash-reporting field empty. Each was built
in a checkout with no DSN file, the provider resolved to "none", and every
reporting check on the release path was scoped "if a provider is configured".
So a missing DSN switched the checks off together with the reporting, and the
gate stayed green six releases running.

Three layers now refuse it, and this module exercises each by running it:

  * check-release.sh's preflight refuses provider "none" before the suites run,
    unless ALLOW_NO_REPORTING=1;
  * check-bundle-reporting.sh reads the fields out of a built app, or out of the
    app inside a DMG, and refuses an empty or non-canonical DSN, a wrong
    provider, release or environment, and an un-overridden "none";
  * check-release.sh's artifact half runs that helper on both build/Seedbed.app
    and the DMG, and publish.sh runs the full gate, so the last step before
    strangers download it reads the image they will get.
"""

from __future__ import annotations

import os
import plistlib
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
MACOS = REPO / "macos"
HELPER = MACOS / "Scripts" / "check-bundle-reporting.sh"
GATE = MACOS / "Scripts" / "check-release.sh"
PUBLISH = MACOS / "Scripts" / "publish.sh"

DSN = "https://public-key@ingest.crashbox.dev/12345"
RELEASE = "net.amnesia.seedbed@" + "a" * 40
ENVIRONMENT = "production"

SCRUBBED = (
    "SEEDBED_CRASHBOX_DSN",
    "SEEDBED_SENTRY_DSN",
    "SEEDBED_BUILD_REF",
    "SEEDBED_ERROR_ENVIRONMENT",
    "ALLOW_NO_REPORTING",
    "SEEDBED_PACKAGING_DIR",
)


def clean_env(**extra: str) -> dict[str, str]:
    env = os.environ.copy()
    for key in SCRUBBED:
        env.pop(key, None)
    env.update(extra)
    return env


def reporting_fields(**overrides: str) -> dict[str, str]:
    fields = {
        "CrashReportingDSN": DSN,
        "CrashReportingProvider": "crashbox",
        "CrashReportingRelease": RELEASE,
        "CrashReportingEnvironment": ENVIRONMENT,
    }
    fields.update(overrides)
    return fields


def disabled_fields() -> dict[str, str]:
    return reporting_fields(
        CrashReportingDSN="", CrashReportingProvider="",
        CrashReportingEnvironment="")


@unittest.skipUnless(HELPER.exists(), "check-bundle-reporting.sh is not in this checkout")
class TheArtifactIsAskedWhetherItReports(unittest.TestCase):
    def setUp(self) -> None:
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        self.tmp = Path(tmp.name)

    def make_app(self, fields: dict[str, str], where: Path | None = None) -> Path:
        app = (where or self.tmp) / "Seedbed.app"
        (app / "Contents" / "MacOS").mkdir(parents=True)
        plist = {"CFBundleExecutable": "Seedbed", **fields}
        with (app / "Contents" / "Info.plist").open("wb") as handle:
            plistlib.dump(plist, handle)
        return app

    def check(self, target: Path, *args: str, **env: str) -> subprocess.CompletedProcess[str]:
        return subprocess.run(
            [str(HELPER), str(target), *args], env=clean_env(**env), text=True,
            stdout=subprocess.PIPE, stderr=subprocess.PIPE, check=False,
        )

    def crashbox(self, target: Path, **env: str) -> subprocess.CompletedProcess[str]:
        return self.check(target, "crashbox", RELEASE, ENVIRONMENT, **env)

    def assertRefused(self, result: subprocess.CompletedProcess[str], why: str) -> None:
        self.assertNotEqual(result.returncode, 0, why)
        self.assertNotIn(DSN, result.stdout + result.stderr, "the DSN was printed")

    def test_a_reporting_app_passes_without_printing_the_dsn(self) -> None:
        result = self.crashbox(self.make_app(reporting_fields()))
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("reports to crashbox as " + RELEASE, result.stdout)
        self.assertNotIn(DSN, result.stdout + result.stderr)

    def test_the_shipped_defect_is_refused(self) -> None:
        """The exact shape of 0.1.11 to 0.1.16: every reporting field empty."""
        result = self.crashbox(self.make_app(disabled_fields()))
        self.assertRefused(result, "an app with no DSN passed as a reporting build")
        self.assertIn("empty CrashReportingDSN", result.stderr)

    def test_a_non_canonical_dsn_is_refused_and_not_echoed(self) -> None:
        stray = "https://key@collector.example.com/9"
        result = self.crashbox(self.make_app(reporting_fields(CrashReportingDSN=stray)))
        self.assertRefused(result, "a DSN naming another collector passed")
        self.assertNotIn(stray, result.stdout + result.stderr)

    def test_a_wrong_provider_release_or_environment_is_refused(self) -> None:
        for key, value in (
            ("CrashReportingProvider", ""),
            ("CrashReportingRelease", "net.amnesia.seedbed@" + "b" * 40),
            ("CrashReportingEnvironment", "staging"),
        ):
            with self.subTest(key=key):
                where = self.tmp / key
                where.mkdir()
                result = self.crashbox(self.make_app(reporting_fields(**{key: value}), where))
                self.assertRefused(result, f"a mismatched {key} passed")

    def test_none_is_refused_without_the_override(self) -> None:
        """Even called directly, so a caller cannot skip the preflight's rule."""
        result = self.check(self.make_app(disabled_fields()), "none")
        self.assertRefused(result, "a non-reporting app passed with no override")
        self.assertIn("ALLOW_NO_REPORTING=1", result.stderr)

    def test_none_passes_loudly_with_the_override(self) -> None:
        result = self.check(self.make_app(disabled_fields()), "none", ALLOW_NO_REPORTING="1")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("cannot report crashes", result.stderr)

    def test_a_half_disabled_app_is_refused_even_with_the_override(self) -> None:
        fields = disabled_fields()
        fields["CrashReportingDSN"] = DSN
        result = self.check(self.make_app(fields), "none", ALLOW_NO_REPORTING="1")
        self.assertRefused(result, "a DSN left in a non-reporting build passed")

    def test_an_unknown_provider_is_a_usage_error(self) -> None:
        result = self.check(self.make_app(reporting_fields()), "sentry")
        self.assertEqual(result.returncode, 64)

    def test_a_missing_artifact_is_refused(self) -> None:
        result = self.crashbox(self.tmp / "absent.dmg")
        self.assertRefused(result, "a missing artifact passed")

    @unittest.skipUnless(shutil.which("hdiutil"), "needs hdiutil (macOS)")
    def test_the_app_inside_a_dmg_is_what_gets_read(self) -> None:
        """A DMG re-staged after the gate read build/ is caught by reading the image."""
        for name, fields, ok in (
            ("good", reporting_fields(), True),
            ("silent", disabled_fields(), False),
        ):
            with self.subTest(name=name):
                stage = self.tmp / f"stage-{name}"
                stage.mkdir()
                self.make_app(fields, stage)
                dmg = self.tmp / f"{name}.dmg"
                subprocess.run(
                    ["hdiutil", "create", "-quiet", "-volname", "Seedbed",
                     "-srcfolder", str(stage), "-format", "UDZO", "-ov", str(dmg)],
                    check=True)
                result = self.crashbox(dmg)
                if ok:
                    self.assertEqual(result.returncode, 0, result.stderr)
                    self.assertIn("(the app inside)", result.stdout)
                else:
                    self.assertRefused(result, "a DMG whose app cannot report passed")
                    self.assertIn("(the app inside)", result.stderr)

    @unittest.skipUnless(shutil.which("hdiutil"), "needs hdiutil (macOS)")
    def test_a_dmg_with_a_second_app_is_refused(self) -> None:
        stage = self.tmp / "stage"
        stage.mkdir()
        self.make_app(reporting_fields(), stage)
        (stage / ".Other.app").mkdir()
        dmg = self.tmp / "two.dmg"
        subprocess.run(
            ["hdiutil", "create", "-quiet", "-volname", "Seedbed",
             "-srcfolder", str(stage), "-format", "UDZO", "-ov", str(dmg)],
            check=True)
        self.assertRefused(self.crashbox(dmg), "a DMG with two apps passed")


@unittest.skipUnless(GATE.exists(), "check-release.sh is not in this checkout")
class ThePreflightRefusesANonReportingCheckout(unittest.TestCase):
    """Run for real, with the suites skipped so it cannot recurse into this one."""

    def setUp(self) -> None:
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        self.packaging = Path(tmp.name)

    def preflight(self, **env: str) -> subprocess.CompletedProcess[str]:
        return subprocess.run(
            [str(GATE)],
            env=clean_env(PREFLIGHT_ONLY="1", SKIP_TESTS="1",
                          SEEDBED_PACKAGING_DIR=str(self.packaging), **env),
            text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE, check=False,
        )

    def test_a_checkout_with_no_dsn_is_refused_before_anything_runs(self) -> None:
        result = self.preflight()
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertIn("cannot report crashes", result.stderr)
        self.assertNotIn(
            "SKIP_TESTS=1", result.stderr,
            "the refusal came after the test step, so a real run would spend "
            "minutes on the suites before saying the build is unusable")

    def test_the_override_lets_it_through_and_says_so(self) -> None:
        result = self.preflight(ALLOW_NO_REPORTING="1")
        self.assertNotIn("error: this checkout would build", result.stderr)
        self.assertIn("ALLOW_NO_REPORTING=1", result.stderr)

    def test_a_configured_dsn_is_not_refused(self) -> None:
        (self.packaging / "crashbox-dsn.local").write_text(DSN + "\n")
        result = self.preflight()
        self.assertNotIn("cannot report crashes", result.stderr)
        self.assertNotIn(DSN, result.stdout + result.stderr)


@unittest.skipUnless(GATE.exists(), "check-release.sh is not in this checkout")
class TheFullGateReadsBothArtifacts(unittest.TestCase):
    def setUp(self) -> None:
        self.source = GATE.read_text()

    def test_the_preflight_rule_precedes_the_suites(self) -> None:
        self.assertLess(
            self.source.index('if [[ "${ALLOW_NO_REPORTING:-}" == "1" ]]'),
            self.source.index('echo "==> Test suite"'))

    def test_the_artifact_half_checks_the_app_and_the_dmg(self) -> None:
        artifact_half = self.source[self.source.index('if [[ "${PREFLIGHT_ONLY:-}" == "1" ]]'):]
        self.assertIn("Scripts/check-bundle-reporting.sh", artifact_half)
        self.assertEqual(
            artifact_half.count('for artifact in "$APP" "$DMG"; do'), 2,
            "one branch of the reporting check no longer covers both the app "
            "and the DMG")

    @unittest.skipUnless(PUBLISH.exists(), "publish.sh is not in this checkout")
    def test_publish_runs_the_full_gate(self) -> None:
        publish = PUBLISH.read_text()
        gate_line = next(line for line in publish.splitlines()
                         if "Scripts/check-release.sh" in line and not line.lstrip().startswith("#"))
        self.assertNotIn("PREFLIGHT_ONLY", gate_line,
                         "publish.sh runs only the preflight, which never reads the DMG")


PUBLISH_REPO = REPO / "Scripts" / "publish-repo.sh"


@unittest.skipUnless(PUBLISH_REPO.exists(), "publish-repo.sh is not in this checkout")
class ThePublicSnapshotSaysItCannotReport(unittest.TestCase):
    """The mirror excludes *.local, so it never carries a DSN, and its build gate
    runs the real preflight. Without the override that preflight refuses, and
    the public tap cannot be published at all: seen on the 0.1.18 release."""

    def test_the_snapshot_preflight_passes_the_override(self) -> None:
        source = PUBLISH_REPO.read_text()
        gate = next(line for line in source.splitlines()
                    if "PREFLIGHT_ONLY=1 Scripts/check-release.sh" in line
                    and not line.lstrip().startswith("#"))
        self.assertIn("ALLOW_NO_REPORTING=1", gate)
        self.assertIn("--exclude='*.local'", source,
                      "the override is only honest while the DSN is excluded")


if __name__ == "__main__":
    unittest.main()
