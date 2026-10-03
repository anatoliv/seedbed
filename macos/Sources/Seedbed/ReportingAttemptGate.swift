import Foundation

/// A one-attempt fuse around optional diagnostics initialization.
///
/// An endpoint outage must not turn application launch into a retry loop. The
/// first caller owns initialization. A start that did not come up
/// (`CrashReporting.startReporter` throws) leaves the gate failed, which is the
/// unavailable state, until an explicit user disable/enable cycle resets it.
final class ReportingAttemptGate: @unchecked Sendable {
    enum Outcome: Equatable {
        case idle
        case starting
        case started
        case failed
    }

    private let lock = NSLock()
    private var outcome: Outcome = .idle

    func runOnce(_ initialize: () throws -> Void) -> Outcome {
        lock.lock()
        guard outcome == .idle else {
            let existing = outcome
            lock.unlock()
            return existing
        }
        // Reserve the only attempt before running it. A concurrent call sees
        // starting and returns instead of initializing a second SDK client.
        outcome = .starting
        lock.unlock()

        do {
            try initialize()
            lock.withLock { outcome = .started }
            return .started
        } catch {
            lock.withLock { outcome = .failed }
            return .failed
        }
    }

    func current() -> Outcome {
        lock.withLock { outcome }
    }

    /// Only a direct user action may permit another attempt. There is no timer,
    /// network callback, or automatic fallback path that invokes this method.
    func resetAfterExplicitDisable() {
        lock.withLock { outcome = .idle }
    }
}
