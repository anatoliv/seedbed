import Foundation

/// A one-attempt fuse around optional diagnostics initialization.
///
/// An endpoint outage must not turn application launch into a retry loop. The
/// first caller owns initialization; a thrown error is contained and leaves the
/// gate failed until an explicit user disable/enable cycle resets it.
final class ReportingAttemptGate: @unchecked Sendable {
    enum Outcome: Equatable {
        case idle
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
        // Reserve the only attempt before running user code. A concurrent call
        // sees failed and returns instead of initializing a second SDK client.
        outcome = .failed
        lock.unlock()

        do {
            try initialize()
            lock.lock()
            outcome = .started
            lock.unlock()
            return .started
        } catch {
            return .failed
        }
    }

    func current() -> Outcome {
        lock.lock()
        defer { lock.unlock() }
        return outcome
    }

    /// Only a direct user action may permit another attempt. There is no timer,
    /// network callback, or automatic fallback path that invokes this method.
    func resetAfterExplicitDisable() {
        lock.lock()
        outcome = .idle
        lock.unlock()
    }
}
