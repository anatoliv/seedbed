import XCTest
@testable import Seedbed

/// What Settings says about reporting comes from the gate's real outcome, not
/// from the toggle alone. Only a start that failed this session reads
/// unavailable and shows the line under the toggle.
final class CrashReportingStatusTests: XCTestCase {
    private let outcomes: [ReportingAttemptGate.Outcome] = [.idle, .starting, .started, .failed]

    func testUnconfiguredBuildIsNotConfiguredWhateverElseIsTrue() {
        for outcome in outcomes {
            for enabled in [true, false] {
                XCTAssertEqual(CrashReporting.status(enabled: enabled, configured: false, outcome: outcome),
                               .notConfigured, "enabled \(enabled), outcome \(outcome)")
            }
        }
    }

    func testToggleOffIsOffWhateverTheGateRecorded() {
        for outcome in outcomes {
            XCTAssertEqual(CrashReporting.status(enabled: false, configured: true, outcome: outcome),
                           .off, "outcome \(outcome)")
        }
    }

    func testOnlyAFailedStartIsUnavailable() {
        XCTAssertEqual(CrashReporting.status(enabled: true, configured: true, outcome: .failed), .unavailable)
        for outcome in [ReportingAttemptGate.Outcome.idle, .starting, .started] {
            XCTAssertEqual(CrashReporting.status(enabled: true, configured: true, outcome: outcome),
                           .on, "outcome \(outcome)")
        }
    }

    /// Drives the real gate with a start that throws, the way `startSDKOnce`
    /// records a reporter that did not come up, then the explicit off and on.
    func testStatusFollowsTheGateThroughAFailedStartAndAReset() {
        struct DidNotComeUp: Error {}
        let gate = ReportingAttemptGate()
        XCTAssertEqual(gate.runOnce { throw DidNotComeUp() }, .failed)
        XCTAssertEqual(CrashReporting.status(enabled: true, configured: true, outcome: gate.current()), .unavailable)

        gate.resetAfterExplicitDisable()
        XCTAssertEqual(CrashReporting.status(enabled: true, configured: true, outcome: gate.current()), .on)
        XCTAssertEqual(gate.runOnce {}, .started)
        XCTAssertEqual(CrashReporting.status(enabled: true, configured: true, outcome: gate.current()), .on)
    }

    func testSettingsShowsTheLineOnlyWhenUnavailable() {
        XCTAssertEqual(CrashReporting.settingsNotice(for: .unavailable),
                       "Crash reporting could not start. Turn it off and on to try again.")
        for status in [CrashReporting.Status.notConfigured, .off, .on] {
            XCTAssertNil(CrashReporting.settingsNotice(for: status), "status \(status)")
        }
    }

    func testSettingsLineHasNoDashes() throws {
        let line = try XCTUnwrap(CrashReporting.settingsNotice(for: .unavailable))
        XCTAssertFalse(line.contains("\u{2014}") || line.contains("\u{2013}"))
    }
}
