import Foundation
import Sentry
import XCTest
@testable import Seedbed

/// Whether the reporter came up decides started against unavailable.
///
/// `SentrySDK.start` cannot throw, so the old test, which handed the gate a
/// closure that threw, proved a path production could never take. These drive
/// the production decision (`CrashReporting.startReporter`) and the production
/// gate with the SDK's real `Options` and DSN parser. Only the SDK's global
/// start and its `isEnabled` are stood in, so nothing installs a crash handler
/// in the test process and nothing can reach the network.
final class CrashReportingStartTests: XCTestCase {
    private let shipped = CrashReporting.Configuration(
        dsn: "https://0123456789abcdef@ingest.crashbox.dev/42",
        provider: "crashbox",
        release: "net.amnesia.seedbed@" + String(repeating: "a1", count: 20),
        environment: "production")

    /// Thread-safe flag for the "SDK" a test simulates on the main queue.
    private final class Flag: @unchecked Sendable {
        private let lock = NSLock()
        private var value = false
        func set() { lock.withLock { value = true } }
        func get() -> Bool { lock.withLock { value } }
    }

    /// Runs the real gate around the real decision, as `startSDKOnce` does.
    private func attempt(_ gate: ReportingAttemptGate, _ configuration: CrashReporting.Configuration,
                         starts: inout [Options], setupRan: Bool, enabled: Bool) -> ReportingAttemptGate.Outcome {
        var started: [Options] = []
        let outcome = gate.runOnce {
            try CrashReporting.startReporter(configuration, start: { started.append($0) },
                                             waitForSetup: { setupRan }, isEnabled: { enabled })
        }
        starts += started
        return outcome
    }

    func testAReporterThatComesUpIsStartedWithTheShippedOptions() throws {
        let gate = ReportingAttemptGate()
        var starts: [Options] = []
        XCTAssertEqual(attempt(gate, shipped, starts: &starts, setupRan: true, enabled: true), .started)
        XCTAssertEqual(gate.current(), .started)
        let options = try XCTUnwrap(starts.first)
        XCTAssertEqual(starts.count, 1)
        XCTAssertNotNil(options.parsedDsn, "the SDK's own parser accepts the Crashbox DSN shape")
        XCTAssertEqual(options.parsedDsn?.url.host, "ingest.crashbox.dev")
        XCTAssertEqual(options.releaseName, shipped.release)
        XCTAssertEqual(options.environment, shipped.environment)
        XCTAssertNotNil(options.urlSession, "the options started are the ones with the bounded transport")
    }

    func testAReporterThatDoesNotEnableIsUnavailableAndDoesNotRetry() {
        let gate = ReportingAttemptGate()
        var starts: [Options] = []
        XCTAssertEqual(attempt(gate, shipped, starts: &starts, setupRan: true, enabled: false), .failed)
        XCTAssertEqual(gate.current(), .failed)
        XCTAssertEqual(attempt(gate, shipped, starts: &starts, setupRan: true, enabled: true), .failed,
                       "a failed start must not retry on its own")
        XCTAssertEqual(starts.count, 1)
        gate.resetAfterExplicitDisable()
        XCTAssertEqual(attempt(gate, shipped, starts: &starts, setupRan: true, enabled: true), .started,
                       "turning it off and on again is the retry Settings offers")
        XCTAssertEqual(starts.count, 2)
    }

    func testASetupThatNeverRunsIsUnavailable() {
        XCTAssertThrowsError(try CrashReporting.startReporter(shipped, start: { _ in }, waitForSetup: { false },
                                                              isEnabled: { true })) {
            XCTAssertEqual($0 as? CrashReporting.StartFailure, .setupTimedOut)
        }
        let gate = ReportingAttemptGate()
        var starts: [Options] = []
        XCTAssertEqual(attempt(gate, shipped, starts: &starts, setupRan: false, enabled: true), .failed)
        XCTAssertEqual(gate.current(), .failed)
    }

    func testAConfigurationTheSDKRefusesIsUnavailableAndNeverStarted() {
        // No public key: the SDK's DSN parser refuses it. Built directly, since
        // `configuration(from:)` already refuses this shape before the SDK sees it.
        let refused = CrashReporting.Configuration(dsn: "https://ingest.crashbox.dev/42",
                                                   provider: shipped.provider,
                                                   release: shipped.release,
                                                   environment: shipped.environment)
        var startCalls = 0
        XCTAssertThrowsError(try CrashReporting.startReporter(refused, start: { _ in startCalls += 1 },
                                                              waitForSetup: { true }, isEnabled: { true })) {
            XCTAssertEqual($0 as? CrashReporting.StartFailure, .configurationRejected)
        }
        XCTAssertEqual(startCalls, 0)
        let gate = ReportingAttemptGate()
        var starts: [Options] = []
        XCTAssertEqual(attempt(gate, refused, starts: &starts, setupRan: true, enabled: true), .failed)
        XCTAssertTrue(starts.isEmpty)
        XCTAssertEqual(gate.current(), .failed)
    }

    func testAStartInProgressIsStartingAndNotStartedTwice() {
        let gate = ReportingAttemptGate()
        var seenDuringStart: ReportingAttemptGate.Outcome?
        var secondCaller: ReportingAttemptGate.Outcome?
        _ = gate.runOnce {
            seenDuringStart = gate.current()
            secondCaller = gate.runOnce { XCTFail("a concurrent caller must not start a second client") }
        }
        XCTAssertEqual(seenDuringStart, .starting)
        XCTAssertEqual(secondCaller, .starting)
        XCTAssertEqual(gate.current(), .started)
    }

    /// The production wait, run as production runs it (off the main thread),
    /// against a stand-in that sets up the way the SDK does: `dispatch_async`
    /// on the main queue from the calling thread.
    func testTheMainQueueWaitSeesSetupQueuedBeforeIt() {
        let enabled = Flag()
        let done = expectation(description: "start finished")
        var result: Result<Void, Error>?
        DispatchQueue.global().async {
            result = Result {
                try CrashReporting.startReporter(self.shipped,
                                                 start: { _ in DispatchQueue.main.async { enabled.set() } },
                                                 waitForSetup: { CrashReporting.mainQueueCaughtUp(within: 5) },
                                                 isEnabled: { enabled.get() })
            }
            done.fulfill()
        }
        wait(for: [done], timeout: 10)
        XCTAssertNoThrow(try XCTUnwrap(result).get())
    }

    func testTheMainQueueWaitGivesUpWhenTheMainThreadIsStuck() {
        let finished = DispatchSemaphore(value: 0)
        var caughtUp: Bool?
        DispatchQueue.global().async {
            caughtUp = CrashReporting.mainQueueCaughtUp(within: 0.2)
            finished.signal()
        }
        // Hold the main thread, as a hung launch would, until the wait gives up.
        XCTAssertEqual(finished.wait(timeout: .now() + 5), .success)
        XCTAssertEqual(caughtUp, false)
    }
}
