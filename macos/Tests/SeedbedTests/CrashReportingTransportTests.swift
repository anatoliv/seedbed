import Darwin
import Foundation
import Sentry
import XCTest
@testable import Seedbed

/// A send to a collector that accepts and never answers gives up
/// within the resource bound, rather than the SDK's default 7 days.
///
/// The send is made by the SDK's own client and HTTP transport, built from the
/// shipped `configure` output, so the request is the one sentry-cocoa builds
/// (with its own 15 s `timeoutInterval`) and the session is the one Seedbed
/// wires in. Only the DSN points elsewhere: at a listener on 127.0.0.1 that
/// accepts and reads but never writes a byte. `SentrySDK` is never started, so
/// no crash handler is installed in the test process.
final class CrashReportingTransportTests: XCTestCase {
    private let release = "net.amnesia.seedbed@" + String(repeating: "b2", count: 20)

    func testTheShippedOptionsCarryTheBoundedEphemeralSession() throws {
        let options = Options()
        CrashReporting.configure(options, configuration: .init(
            dsn: "https://0123456789abcdef@ingest.crashbox.dev/42", provider: "crashbox",
            release: release, environment: "production"))

        let settings = try XCTUnwrap(options.urlSession?.configuration,
                                     "no session is wired in, so the SDK's 7-day default applies")
        XCTAssertEqual(settings.timeoutIntervalForResource, CrashReporting.resourceTimeout)
        XCTAssertEqual(CrashReporting.resourceTimeout, 5)
        XCTAssertFalse(settings.waitsForConnectivity)
        XCTAssertNil(settings.urlCache)
        XCTAssertNil(settings.httpCookieStorage)
        XCTAssertFalse(settings.httpShouldSetCookies)
        XCTAssertNil(settings.urlCredentialStorage)
        XCTAssertEqual(options.shutdownTimeInterval, 0)
        XCTAssertEqual(options.maxCacheItems, UInt(CrashReporting.perLaunchBudget))
    }

    func testASendToASilentCollectorGivesUpWithinTheResourceBound() throws {
        let collector = try SilentCollector()
        defer { collector.stop() }
        let cache = FileManager.default.temporaryDirectory
            .appendingPathComponent("seedbed-transport-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: cache) }

        let options = Options()
        CrashReporting.configure(options, configuration: .init(
            dsn: "http://0123456789abcdef@127.0.0.1:\(collector.port)/42", provider: "crashbox",
            release: release, environment: "test"))
        options.cacheDirectoryPath = cache.path
        let client = try XCTUnwrap(SentryClient(options: options))

        let began = Date()
        client.capture(message: "Seedbed transport bound test")
        XCTAssertLessThan(Date().timeIntervalSince(began), 1, "capture blocked its caller on the network")

        let bound = CrashReporting.resourceTimeout
        let outcome = try XCTUnwrap(collector.waitForHangUp(timeout: bound + 6),
                                    "the SDK never connected, or never gave up on the silent collector")
        let held = outcome.closed.timeIntervalSince(outcome.accepted)
        let total = outcome.closed.timeIntervalSince(began)
        // Longer than a refusal or an immediate error: it was the timeout that ended it.
        XCTAssertGreaterThan(held, bound - 1, "the send ended before the resource bound; something else stopped it")
        // And no later than about a second past the bound (MenuBurrow measured about 6 s).
        XCTAssertLessThanOrEqual(total, bound + 1.5, "the send held the collector past the resource bound")
    }
}

/// A TCP listener on 127.0.0.1 that accepts one connection, reads whatever
/// arrives and never writes, and records when the peer hangs up. Every wait in
/// it is bounded by `poll`, so a broken test cannot hang the suite.
private final class SilentCollector: @unchecked Sendable {
    struct HangUp { let accepted: Date; let closed: Date }

    let port: UInt16
    private let listener: Int32
    private let lock = NSLock()
    private var stopped = false
    private var result: HangUp?
    private let finished = DispatchSemaphore(value: 0)

    init() throws {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw POSIXError(.EIO) }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        address.sin_port = 0
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let bound = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { pointer -> Bool in
                Darwin.bind(fd, pointer, length) == 0
                    && listen(fd, 8) == 0
                    && getsockname(fd, pointer, &length) == 0
            }
        }
        guard bound else { close(fd); throw POSIXError(.EADDRNOTAVAIL) }
        listener = fd
        port = UInt16(bigEndian: address.sin_port)
        Thread.detachNewThread { [self] in serve() }
    }

    private var isStopped: Bool { lock.withLock { stopped } }

    /// Polls in short slices so `stop` is noticed, up to `limit` seconds.
    private func readable(_ fd: Int32, limit: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(limit)
        var entry = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
        while !isStopped && Date() < deadline {
            if poll(&entry, 1, 100) > 0 { return true }
        }
        return false
    }

    private func serve() {
        defer { finished.signal() }
        guard readable(listener, limit: 20) else { return }
        let connection = accept(listener, nil, nil)
        guard connection >= 0 else { return }
        defer { close(connection) }
        let accepted = Date()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while readable(connection, limit: 30) {
            if read(connection, &buffer, buffer.count) <= 0 {
                lock.withLock { result = HangUp(accepted: accepted, closed: Date()) }
                return
            }
        }
    }

    func waitForHangUp(timeout: TimeInterval) -> HangUp? {
        // Re-signal, so `stop` does not wait again for a thread already gone.
        if finished.wait(timeout: .now() + timeout) == .success { finished.signal() }
        return lock.withLock { result }
    }

    func stop() {
        lock.withLock { stopped = true }
        _ = finished.wait(timeout: .now() + 1)
        close(listener)
    }
}
