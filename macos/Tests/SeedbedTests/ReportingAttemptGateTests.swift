import XCTest
@testable import Seedbed

final class ReportingAttemptGateTests: XCTestCase {
    private enum ExpectedFailure: Error { case unavailable }

    func testInitializationFailureIsContainedAndNotRetried() {
        let gate = ReportingAttemptGate()
        var attempts = 0

        let first = gate.runOnce {
            attempts += 1
            throw ExpectedFailure.unavailable
        }
        let second = gate.runOnce {
            attempts += 1
        }

        XCTAssertEqual(first, .failed)
        XCTAssertEqual(second, .failed)
        XCTAssertEqual(attempts, 1)
    }

    func testExplicitDisableIsTheOnlyRetryReset() {
        let gate = ReportingAttemptGate()
        XCTAssertEqual(gate.runOnce {}, .started)
        XCTAssertEqual(gate.runOnce { XCTFail("automatic retry") }, .started)

        gate.resetAfterExplicitDisable()
        XCTAssertEqual(gate.runOnce {}, .started)
    }

    func testDisabledAndMalformedConfigurationsFailClosed() {
        XCTAssertNil(CrashReporting.configuration(from: [:]))

        let base: [String: Any] = [
            "CrashReportingDSN": "https://public@example.invalid/project",
            "CrashReportingProvider": "crashbox",
            "CrashReportingRelease": "net.amnesia.seedbed@" + String(repeating: "a", count: 40),
            "CrashReportingEnvironment": "production",
        ]
        XCTAssertNotNil(CrashReporting.configuration(from: base))

        for malformed in [
            "http://public@example.invalid/project",
            "https://example.invalid/project",
            "https://public:secret@example.invalid/project",
            "https://public@example.invalid/",
            "https://public@example.invalid/project?secret=value",
        ] {
            var candidate = base
            candidate["CrashReportingDSN"] = malformed
            XCTAssertNil(CrashReporting.configuration(from: candidate), malformed)
        }

        var mutableRelease = base
        mutableRelease["CrashReportingRelease"] = "net.amnesia.seedbed@main"
        XCTAssertNil(CrashReporting.configuration(from: mutableRelease))

        var unknownProvider = base
        unknownProvider["CrashReportingProvider"] = "automatic"
        XCTAssertNil(CrashReporting.configuration(from: unknownProvider))
    }

    func testSlowInitializationCanRunWithoutBlockingTheCaller() {
        let gate = ReportingAttemptGate()
        let queue = DispatchQueue(label: "reporting-test", qos: .utility)
        let entered = expectation(description: "initializer entered")
        let finished = expectation(description: "initializer finished")
        let release = DispatchSemaphore(value: 0)

        queue.async {
            _ = gate.runOnce {
                entered.fulfill()
                _ = release.wait(timeout: .now() + 1)
            }
            finished.fulfill()
        }

        wait(for: [entered], timeout: 0.5)
        XCTAssertEqual(gate.current(), .failed) // reserved, not retried
        release.signal()
        wait(for: [finished], timeout: 0.5)
        XCTAssertEqual(gate.current(), .started)
    }
}
