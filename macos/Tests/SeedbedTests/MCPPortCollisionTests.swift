import Network
import XCTest
@testable import Seedbed

/// The walk from a taken port to a free one, checked as a value with the probe
/// handed in, so no socket is opened and no port on this Mac is touched.
final class MCPPortScanTests: XCTestCase {
    func testTheRequestedPortComesFirstEvenWhenItIsOneTheWalkWouldSkip() {
        XCTAssertEqual(MCPPortScan.candidates(for: 8789).first, 8789)
        // A person who typed one of the reserved ports into Settings meant it.
        XCTAssertEqual(MCPPortScan.candidates(for: 8787).first, 8787)
        XCTAssertEqual(MCPPortScan.candidates(for: 8765).first, 8765)
    }

    func testTheWalkStepsOverThePortsOtherLocalServersUse() {
        let above = MCPPortScan.candidates(for: 8760).dropFirst()
        XCTAssertFalse(above.contains(8765))
        XCTAssertFalse(above.contains(8784))
        for reserved in 8787...8802 {
            XCTAssertFalse(above.contains(UInt16(reserved)), "\(reserved) is reserved")
        }
        XCTAssertTrue(above.contains(8766))
        XCTAssertTrue(above.contains(8786))
        XCTAssertEqual(above.first, 8761)
        XCTAssertEqual(Array(above.prefix(6)), [8761, 8762, 8763, 8764, 8766, 8767])
    }

    func testTheWalkIsBoundedAndStopsAtTheTopOfThePortRange() {
        let candidates = MCPPortScan.candidates(for: 8789)
        XCTAssertEqual(candidates.last, 8789 + MCPPortScan.scanLimit)
        XCTAssertTrue(candidates.allSatisfy { $0 >= 8789 && $0 <= 8789 + MCPPortScan.scanLimit })
        XCTAssertEqual(MCPPortScan.candidates(for: 65530).last, 65535)
        XCTAssertEqual(MCPPortScan.candidates(for: 65535), [65535])
    }

    func testAFreeRequestedPortIsTheOneBound() async {
        let port = await MCPPortScan.firstFree(requested: 8789) { _ in true }
        XCTAssertEqual(port, 8789)
    }

    func testATakenRequestedPortMovesToTheNextFreePortThatIsNotReserved() async {
        // 8785 and 8786 are taken; 8787 through 8802 are stepped over.
        let taken: Set<UInt16> = [8785, 8786]
        let port = await MCPPortScan.firstFree(requested: 8785) { !taken.contains($0) }
        XCTAssertEqual(port, 8803)
    }

    func testTheProbeIsAskedInOrderAndNotPastTheFirstFreePort() async {
        var asked: [UInt16] = []
        let port = await MCPPortScan.firstFree(requested: 8810) { probe in
            asked.append(probe)
            return probe == 8812
        }
        XCTAssertEqual(port, 8812)
        XCTAssertEqual(asked, [8810, 8811, 8812])
    }

    /// The default port taken is the case that will actually happen, and the
    /// answer is not the next number: the walk clears the reserved cluster
    /// above it first.
    func testTheDefaultPortTakenLandsAboveTheReservedCluster() async {
        let port = await MCPPortScan.firstFree(requested: MCPConstants.defaultPort) {
            $0 != MCPConstants.defaultPort
        }
        XCTAssertEqual(port, 8803)
    }

    func testWhenEveryCandidateIsTakenThereIsNoPort() async {
        let port = await MCPPortScan.firstFree(requested: 8789) { _ in false }
        XCTAssertNil(port)
    }

    /// The copy a person reads. No dashes, and it names the button that
    /// repairs the client configuration the move made stale.
    func testTheNoticeNamesBothPortsAndTheRepair() {
        let move = MCPPortMove(requested: 8789, bound: 8803)
        for text in [move.title, move.detail, move.notificationTitle, move.notificationBody] {
            XCTAssertFalse(text.contains("\u{2014}"), "em dash in: \(text)")
            XCTAssertFalse(text.contains("\u{2013}"), "en dash in: \(text)")
        }
        XCTAssertTrue(move.title.contains("8789"))
        XCTAssertTrue(move.title.contains("8803"))
        XCTAssertTrue(move.detail.contains("Update my client config"))
        XCTAssertTrue(move.notificationTitle.contains("8803"))
        XCTAssertTrue(move.notificationBody.contains("8789"))
    }
}

/// The live path, on real sockets. Every port here is an ephemeral one the
/// kernel hands out, never a fixed number: the servers this walk exists to
/// step around are running on this Mac while the suite does.
@MainActor
final class MCPPortCollisionTests: XCTestCase {
    private var scratch: UserDefaults!
    private var moves: [MCPPortMove] = []
    private var servers: [MCPServer] = []
    private var listeners: [NWListener] = []
    private var sockets: [Int32] = []

    override func setUp() async throws {
        scratch = ThrowawayDefaults.make("port-collision")
        moves = []
    }

    override func tearDown() async throws {
        for server in servers {
            server.stop()
            await server.awaitPendingRestart()
        }
        servers = []
        listeners.forEach { $0.cancel() }
        listeners = []
        sockets.forEach { close($0) }
        sockets = []
    }

    private func makeServer() -> MCPServer {
        let server = MCPServer(
            client: LibraryClient(root: URL(fileURLWithPath: NSTemporaryDirectory())),
            defaults: scratch,
            notifyPortMove: { [weak self] move in self?.moves.append(move) }
        )
        servers.append(server)
        return server
    }

    private func start(_ server: MCPServer, on port: UInt16) async {
        server.start(port: port, token: "full-token", readOnlyToken: "read-only-token")
        await server.awaitPendingRestart()
    }

    /// Starts `listener` and reports the first state it settles in: "ready",
    /// "cancelled", or "failed: <error>".
    private func firstState(of listener: NWListener, label: String) async -> String {
        let queue = DispatchQueue(label: "net.amnesia.seedbed.tests.\(label)")
        return await withCheckedContinuation { continuation in
            let once = TestResumeOnce(continuation)
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready: once.resume("ready")
                case let .failed(error): once.resume("failed: \(error)")
                case .cancelled: once.resume("cancelled")
                default: break
                }
            }
            listener.start(queue: queue)
        }
    }

    /// A throwaway loopback listener on a port the kernel picks.
    private func occupyEphemeralLoopbackPort() async throws -> UInt16 {
        let params = NWParameters.tcp
        params.requiredInterfaceType = .loopback
        let listener = try NWListener(using: params, on: .any)
        listener.newConnectionHandler = { $0.cancel() }
        listeners.append(listener)
        let ready = await firstState(of: listener, label: "occupant") == "ready"
        XCTAssertTrue(ready, "the occupant listener did not come up")
        return try XCTUnwrap(listener.port?.rawValue)
    }

    /// A throwaway listener on every address, which is the shape of the
    /// collision that address reuse used to hide: a loopback bind beside a
    /// wildcard one can silently succeed and take part of its traffic.
    private func occupyEphemeralWildcardPort() throws -> UInt16 {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        XCTAssertGreaterThanOrEqual(fd, 0)
        sockets.append(fd)
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = 0
        address.sin_addr.s_addr = INADDR_ANY
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        XCTAssertEqual(bound, 0, "bind failed: \(String(cString: strerror(errno)))")
        XCTAssertEqual(listen(fd, 4), 0)
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let named = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) }
        }
        XCTAssertEqual(named, 0)
        return UInt16(bigEndian: address.sin_port)
    }

    func testATakenPortMovesTheServerUpPersistsTheMoveAndSaysSo() async throws {
        let taken = try await occupyEphemeralLoopbackPort()
        let server = makeServer()

        await start(server, on: taken)

        XCTAssertTrue(server.isRunning, server.lastError ?? "")
        XCTAssertNil(server.lastError)
        XCTAssertNotEqual(server.boundPort, taken)
        XCTAssertGreaterThan(server.boundPort, taken)
        XCTAssertLessThanOrEqual(server.boundPort, taken + MCPPortScan.scanLimit)
        let answered = await MCPServer.isSomethingListening(on: server.boundPort)
        XCTAssertTrue(answered, "nothing answers on the port the server says it bound")

        XCTAssertEqual(scratch.integer(forKey: AppController.mcpPortKey), Int(server.boundPort),
                       "the moved port did not reach the preference Settings reads")
        XCTAssertEqual(server.portMove, MCPPortMove(requested: taken, bound: server.boundPort))
        XCTAssertEqual(moves, [MCPPortMove(requested: taken, bound: server.boundPort)])
    }

    func testAFreePortIsBoundAsRequestedWithNoMoveAndNoNotice() async throws {
        // Borrow a port the kernel hands out, then give it back so it is free.
        let borrowed = try await occupyEphemeralLoopbackPort()
        let occupant = try XCTUnwrap(listeners.popLast())
        occupant.cancel()
        try await Task.sleep(nanoseconds: 100_000_000)
        let server = makeServer()

        await start(server, on: borrowed)

        XCTAssertTrue(server.isRunning, server.lastError ?? "")
        XCTAssertEqual(server.boundPort, borrowed)
        XCTAssertNil(server.portMove)
        XCTAssertEqual(moves, [])
        XCTAssertNil(scratch.object(forKey: AppController.mcpPortKey),
                     "a bind on the requested port must not rewrite the preference")
    }

    func testAWildcardListenerOnThePortIsDetectedAndNotBoundBeside() async throws {
        let taken = try occupyEphemeralWildcardPort()

        let seen = await MCPServer.isSomethingListening(on: taken)
        XCTAssertTrue(seen, "the probe did not see a listener bound on every address")

        // The bind itself refuses to share, so a collision the probe somehow
        // missed still surfaces as a failure rather than as a shared port.
        let nwPort = try XCTUnwrap(NWEndpoint.Port(rawValue: taken))
        let beside = try NWListener(using: MCPServer.listenerParameters(), on: nwPort)
        listeners.append(beside)
        let outcome = await firstState(of: beside, label: "beside")
        XCTAssertTrue(outcome.hasPrefix("failed"),
                      "a loopback bind beside a wildcard listener should fail, got \(outcome)")

        let server = makeServer()
        await start(server, on: taken)
        XCTAssertTrue(server.isRunning, server.lastError ?? "")
        XCTAssertNotEqual(server.boundPort, taken)
        XCTAssertEqual(server.portMove?.requested, taken)
    }

    func testARestartOnTheSamePortKeepsWorkingWithReuseOff() async throws {
        let borrowed = try await occupyEphemeralLoopbackPort()
        let occupant = try XCTUnwrap(listeners.popLast())
        occupant.cancel()
        try await Task.sleep(nanoseconds: 100_000_000)
        let server = makeServer()

        await start(server, on: borrowed)
        XCTAssertTrue(server.isRunning, server.lastError ?? "")
        XCTAssertEqual(server.boundPort, borrowed)

        // The same port again, which is what every token regeneration does.
        await start(server, on: borrowed)
        XCTAssertTrue(server.isRunning, server.lastError ?? "")
        XCTAssertEqual(server.boundPort, borrowed, "the restart did not land on its own port")
        XCTAssertNil(server.portMove, "a restart must not read its own old listener as a collision")
        XCTAssertEqual(moves, [])

        // And a stop followed by a start, which is the toggle.
        server.stop()
        await server.awaitPendingRestart()
        XCTAssertFalse(server.isRunning)
        await start(server, on: borrowed)
        XCTAssertTrue(server.isRunning, server.lastError ?? "")
        XCTAssertEqual(server.boundPort, borrowed)
        XCTAssertNil(server.portMove)
    }
}

/// Resumes a continuation at most once from whichever listener callback
/// arrives first, the same guard the server keeps for its own probe.
private final class TestResumeOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<String, Never>?

    init(_ continuation: CheckedContinuation<String, Never>) {
        self.continuation = continuation
    }

    func resume(_ value: String) {
        lock.lock()
        let pending = continuation
        continuation = nil
        lock.unlock()
        pending?.resume(returning: value)
    }
}
