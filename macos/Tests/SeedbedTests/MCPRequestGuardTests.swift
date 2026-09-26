import XCTest
@testable import Seedbed

/// Which Host and Origin the MCP server answers to, and that the answer is
/// given before the bearer token is looked at.
///
/// The listener binds to loopback only, so every name a real client uses is a
/// loopback name or this Mac's own. A browser page that rebinds its own domain
/// to 127.0.0.1 still sends `Host: evil.com`, and that request must be refused
/// as a 403 without spending the owner's wrong-token budget or raising the
/// "a client was refused" alert.
final class MCPRequestGuardTests: XCTestCase {
    private let localName = "Studio-Mac.local"

    private func trusted(_ name: String) -> Bool {
        MCPRequestGuard.isTrustedHostname(name, localName: localName)
    }

    // MARK: The host rule

    func testLoopbackNamesAndLiteralsAreTrusted() {
        for name in ["localhost", "app.localhost", "127.0.0.1", "127.8.9.10", "::1",
                     "::ffff:127.0.0.1"] {
            XCTAssertTrue(trusted(name), "\(name) is loopback and should be answered")
        }
    }

    func testThisMacsOwnNameIsTrustedInBothForms() {
        XCTAssertTrue(trusted("studio-mac.local"))
        XCTAssertTrue(trusted("studio-mac"))
    }

    /// The two over-broad rules the card named: any IP literal, any .local.
    func testOtherMachinesAreNotTrusted() {
        for name in ["203.0.113.5", "198.51.100.20", "0.0.0.0", "8.8.8.8", "fe80::1",
                     "2001:db8::1", "::ffff:203.0.113.5", "another-mac.local", "local"] {
            XCTAssertFalse(trusted(name), "\(name) is not this Mac and should be refused")
        }
    }

    func testPublicNamesAreNotTrusted() {
        for name in ["evil.com", "seedbed.example.com", "localhost.evil.com",
                     "studio-mac.local.evil.com", "127.0.0.1.nip.io"] {
            XCTAssertFalse(trusted(name), "\(name) should be refused")
        }
    }

    func testAnEmptyLocalNameTrustsNothingExtra() {
        XCTAssertFalse(MCPRequestGuard.isTrustedHostname("", localName: ""))
        XCTAssertTrue(MCPRequestGuard.isTrustedHostname("127.0.0.1", localName: ""))
    }

    // MARK: Header parsing

    func testHostHeadersAreReducedToTheBareName() {
        XCTAssertEqual(MCPRequestGuard.hostname(fromHostHeader: "127.0.0.1:8789"), "127.0.0.1")
        XCTAssertEqual(MCPRequestGuard.hostname(fromHostHeader: "[::1]:8789"), "::1")
        XCTAssertEqual(MCPRequestGuard.hostname(fromHostHeader: "Evil.COM.:8789"), "evil.com")
    }

    func testTheNullOriginIsNeverTrusted() {
        XCTAssertNil(MCPRequestGuard.hostname(fromOriginHeader: "null"))
        XCTAssertFalse(isTrusted(["origin": "null"]))
    }

    private func isTrusted(_ headers: [String: String]) -> Bool {
        MCPRequestGuard.isTrusted(
            HTTPRequestData(method: "POST", path: "/", headers: headers, body: Data()),
            localName: localName)
    }

    func testARebindIsVisibleInEitherHeader() {
        XCTAssertTrue(isTrusted([:]), "a client that sends neither header is not a browser")
        XCTAssertTrue(isTrusted(["host": "127.0.0.1:8789"]))
        XCTAssertFalse(isTrusted(["host": "evil.com:8789"]))
        XCTAssertFalse(isTrusted(["host": "127.0.0.1:8789", "origin": "http://evil.com"]))
        XCTAssertFalse(isTrusted(["host": "203.0.113.5:8789"]))
    }

    // MARK: Before the token

    private func request(host: String, token: String?) -> HTTPRequestData {
        var headers = ["host": host, "content-type": "application/json"]
        if let token { headers["authorization"] = "Bearer \(token)" }
        let body = Data(#"{"jsonrpc":"2.0","id":1,"method":"ping"}"#.utf8)
        return HTTPRequestData(method: "POST", path: "/", headers: headers, body: body)
    }

    private final class AlertLog: @unchecked Sendable {
        private let lock = NSLock()
        private var raised = 0
        func record(_ alert: MCPAuthAlert?) {
            lock.lock(); defer { lock.unlock() }
            if alert != nil { raised += 1 }
        }
        var count: Int { lock.lock(); defer { lock.unlock() }; return raised }
    }

    /// Well past the throttle's budget of wrong tokens, all from a rebound
    /// origin. Every one is a 403, no alert is raised, and afterwards a wrong
    /// token from a real local client is a plain 401 rather than a lockout,
    /// which proves none of them were counted.
    func testAnUntrustedHostIsRefusedBeforeTheTokenIsCounted() async {
        let handler = MCPRequestHandler(client: LibraryClient(
            root: FileManager.default.temporaryDirectory))
        await handler.setTokens(full: "right-token", readOnly: "read-token")
        let alerts = AlertLog()
        await handler.setAuthAlertObserver { alerts.record($0) }

        for _ in 0 ..< (MCPAuthThrottle.failureBudget * 3) {
            let response = await handler.handle(request(host: "evil.com:8789", token: "wrong"))
            XCTAssertEqual(response.status, 403)
        }
        let unauthenticated = await handler.handle(request(host: "attacker.example", token: nil))
        XCTAssertEqual(unauthenticated.status, 403, "no token and a bad Host is still a Host refusal")
        XCTAssertEqual(alerts.count, 0, "a rebound request raised the wrong-token alert")

        let local = await handler.handle(request(host: "127.0.0.1:8789", token: "wrong"))
        XCTAssertEqual(local.status, 401,
                       "the throttle was charged for requests it should never have seen")
    }

    func testTheRightTokenFromAnUntrustedHostIsStillRefused() async {
        let handler = MCPRequestHandler(client: LibraryClient(
            root: FileManager.default.temporaryDirectory))
        await handler.setTokens(full: "right-token", readOnly: "read-token")
        let response = await handler.handle(request(host: "evil.com:8789", token: "right-token"))
        XCTAssertEqual(response.status, 403)
    }
}
