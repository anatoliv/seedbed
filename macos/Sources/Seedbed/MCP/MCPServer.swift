import Foundation
import Network
import OSLog

private let log = Logger(subsystem: "net.amnesia.seedbed", category: "MCP")

/// Sizes and protocol constants.
enum MCPConstants {
    /// Hard cap on a single request. A localhost JSON-RPC call is tiny; anything
    /// larger is a bug or abuse, so refuse rather than buffer it.
    static let maxRequestBytes = 1_000_000
    /// Echoed when the client does not send one.
    static let defaultProtocolVersion = "2025-06-18"
    static let serverVersion = "1.0"
    /// How long a connection may take to deliver a complete request. `receive`
    /// blocks forever on a connection that opens and then sends nothing, and
    /// without a bound a handful of silent connections tie up tasks for the life
    /// of the app.
    static let readTimeout: TimeInterval = 30
    /// Concurrent connections served at once. Real clients use one or two.
    static let maxConcurrentConnections = 16
    /// A fixed default of its own, clear of 8787 and 8788. Those two are
    /// commonly taken by other local agent servers, and sharing a port makes
    /// launch order decide which program works — a failure that looks like the
    /// app being broken rather than like a collision.
    static let defaultPort: UInt16 = 8789
    static let legacyDefaultPort: UInt16 = 8787
}

/// Resumes a continuation at most once, from whichever of several callbacks
/// arrives first. A state handler and a deadline can both fire, and resuming a
/// checked continuation twice is a crash rather than a warning.
private final class ResumeOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Bool, Never>?

    init(_ continuation: CheckedContinuation<Bool, Never>) {
        self.continuation = continuation
    }

    func resume(_ value: Bool) {
        lock.lock()
        let pending = continuation
        continuation = nil
        lock.unlock()
        pending?.resume(returning: value)
    }
}

/// Caps how many connections are in flight at once, so nothing that can reach
/// the socket can open them until the process runs out of room.
private actor MCPConnectionLimiter {
    static let shared = MCPConnectionLimiter()
    private var inFlight = 0

    func acquire() -> Bool {
        guard inFlight < MCPConstants.maxConcurrentConnections else { return false }
        inFlight += 1
        return true
    }

    func release() { inFlight = max(0, inFlight - 1) }
}

/// A parsed HTTP request. All value types, so it crosses isolation boundaries.
struct HTTPRequestData: Sendable {
    let method: String
    let path: String
    /// Header names are lowercased for case-insensitive lookup.
    let headers: [String: String]
    let body: Data
}

struct HTTPResponseData: Sendable {
    let status: Int
    let body: Data
    let extraHeaders: [String: String]

    init(status: Int, body: Data, extraHeaders: [String: String] = [:]) {
        self.status = status
        self.body = body
        self.extraHeaders = extraHeaders
    }
}

enum MCPServerError: Error {
    case connectionClosed
    case requestTooLarge
    case malformedRequest
    case timedOut
}

/// What the server can say about a client it just refused, beyond "401".
///
/// The refusal is the only signal a person gets, and it reaches them through
/// the client rather than through this app, as a bare authentication error. The
/// server knows more than that. It knows whether a credential arrived at all,
/// and it knows the same client has been refused eleven times in a row, which
/// is what a retry loop holding a token from before a regeneration looks like.
/// None of that was surfaced anywhere until this type existed, so the person
/// reading "401" had no way to tell a wrong token from a wrong address.
///
/// Carries no part of the presented token. A token that is wrong for this
/// server may well be right for another one, and a diagnostic pane is exactly
/// the kind of place a secret gets read out of.
struct MCPAuthAlert: Equatable, Sendable {
    enum Cause: Equatable, Sendable {
        /// A bearer token arrived and is not either of this server's two.
        case wrongToken
        /// No `Authorization` header at all, which is a differently shaped
        /// mistake: the entry is missing its `headers` block, or its `type` is
        /// not `http`, so the client never sends one.
        case noCredential
    }

    var cause: Cause
    /// Consecutive refusals of this same shape. Reset by any request that
    /// authenticates, so it counts one failing client rather than a lifetime.
    var attempts: Int
    var lastAttempt: Date

    var title: String {
        let time = lastAttempt.formatted(date: .omitted, time: .shortened)
        // "refused once, most recently at" is wrong: one refusal has no most
        // recent. The singular gets its own sentence rather than a count.
        return attempts == 1
            ? "A client was refused at \(time)."
            : "A client was refused \(attempts) times, most recently at \(time)."
    }

    var detail: String {
        switch cause {
        case .wrongToken:
            return "It sent an access token this server is not using. Either that client "
                + "kept a token from before you regenerated one, or it is dialling a port "
                + "some other program answers on. Copy the configuration below and replace "
                + "that client's entry with it."
        case .noCredential:
            return "It sent no authorization header at all, so its entry is probably "
                + "missing the headers block, or its type is not set to http. Copy the "
                + "configuration below, which carries both."
        }
    }
}

/// Runs `work`, or throws if it has not finished in `seconds`.
func withTimeout<T: Sendable>(
    seconds: TimeInterval,
    _ work: @escaping @Sendable () async throws -> T
) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask { try await work() }
        group.addTask {
            try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            throw MCPServerError.timedOut
        }
        guard let first = try await group.next() else { throw MCPServerError.timedOut }
        group.cancelAll()
        return first
    }
}

/// An HTTP server speaking the Model Context Protocol (JSON-RPC 2.0), so an
/// agent — Claude Code, Cursor, Claude Desktop — can ask this library for a
/// prompt instead of a person copying one out of the panel.
///
/// Security model, ported from a sibling app rather than approximated: the listener
/// binds to **loopback only**, so it is unreachable from the network, AND every
/// request must carry a bearer token. Both layers, neither sufficient alone.
/// There is deliberately no remote-access switch and no tunnel here — an agent
/// that needs this library runs on this Mac, and each of those is a way to get
/// the exposure wrong.
@MainActor
final class MCPServer: ObservableObject {
    private var listener: NWListener?
    private let handler: MCPRequestHandler
    /// All socket I/O runs here, off the main actor.
    private let ioQueue = DispatchQueue(label: "net.amnesia.seedbed.mcp", qos: .utility)
    /// Serialises rapid start/stop. Each call chains onto the in-flight task so
    /// socket teardown finishes before the next bind — the kernel needs the old
    /// socket fully released before a new bind on the same port can succeed, and
    /// without this a quick toggle hits EADDRINUSE.
    private var restartTask: Task<Void, Never>?

    @Published private(set) var isRunning = false
    @Published private(set) var lastError: String?
    @Published private(set) var boundPort: UInt16 = MCPConstants.defaultPort
    /// The most recent authentication failure, or nil once something has
    /// authenticated. Published so Settings can say what the client's 401
    /// cannot.
    @Published private(set) var authAlert: MCPAuthAlert?
    /// Something other than this app is listening on the port Seedbed used to
    /// default to. A client left pointed there is not talking to Seedbed at
    /// all, and the error it reports is an authentication error, so the address
    /// is the last thing anyone suspects.
    @Published private(set) var legacyPortHeldByAnother = false

    init(client: LibraryClient) {
        handler = MCPRequestHandler(client: client)
        observeAuthFailures()
    }

    /// Bridges the handler actor's view of a refusal onto the main actor, where
    /// a view can observe it.
    private func observeAuthFailures() {
        let handler = self.handler
        Task { [weak self] in
            await handler.setAuthAlertObserver { alert in
                Task { @MainActor in self?.authAlert = alert }
            }
        }
    }

    /// A fresh access token — two CSPRNG-backed UUIDs as lowercase hex, about
    /// 244 bits. Long enough that the endpoint cannot be reached by guessing.
    /// Deliberately outside the main actor: `MCPTokenStore.ensure()` runs at
    /// launch, before there is any UI to be isolated to.
    nonisolated static func generateToken() -> String {
        (UUID().uuidString + UUID().uuidString)
            .replacingOccurrences(of: "-", with: "")
            .lowercased()
    }

    /// Starts, or restarts. A non-empty token is required: without one the
    /// server refuses to start, so an unauthenticated endpoint cannot exist.
    func start(port: UInt16, token: String, readOnlyToken: String) {
        chain { [weak self] in
            await self?.tearDownCurrentListener()
            await self?.beginListening(port: port, token: token, readOnlyToken: readOnlyToken)
        }
    }

    func stop() {
        chain { [weak self] in await self?.tearDownCurrentListener() }
    }

    private func chain(_ work: @escaping @MainActor () async -> Void) {
        let previous = restartTask
        restartTask = Task { @MainActor in
            _ = await previous?.value
            await work()
        }
    }

    private func tearDownCurrentListener() async {
        guard let old = listener else { return }
        listener = nil
        isRunning = false
        await Self.awaitTerminal(old)
    }

    /// Waits for a listener to reach a terminal state, which is what guarantees
    /// its socket has been released. `.cancelled` and `.failed` are both
    /// terminal, so the continuation resumes at most once.
    nonisolated private static func awaitTerminal(_ listener: NWListener) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            listener.stateUpdateHandler = { state in
                switch state {
                case .cancelled, .failed: continuation.resume()
                default: break
                }
            }
            listener.cancel()
        }
    }

    private func beginListening(port: UInt16, token: String, readOnlyToken: String) async {
        guard !token.isEmpty else {
            lastError = "Cannot start without an access token."
            log.error("MCP server start refused: empty token")
            return
        }
        guard let nwPort = NWEndpoint.Port(rawValue: port) else {
            lastError = "Invalid port \(port)."
            return
        }
        // A read-only token equal to the full one would silently grant full
        // access to everyone handed the "safe" one.
        guard readOnlyToken != token else {
            lastError = "The read-only token must differ from the full token."
            log.error("MCP server start refused: read-only token equals the full token")
            return
        }
        await handler.setTokens(full: token, readOnly: readOnlyToken)
        boundPort = port

        let params = NWParameters.tcp
        params.requiredInterfaceType = .loopback
        params.allowLocalEndpointReuse = true

        do {
            let listener = try NWListener(using: params, on: nwPort)
            listener.newConnectionHandler = { [weak self] connection in
                guard let self else { connection.cancel(); return }
                connection.start(queue: self.ioQueue)
                Task { await self.serve(connection) }
            }
            listener.stateUpdateHandler = { [weak self] state in
                Task { @MainActor in
                    guard let self else { return }
                    switch state {
                    case .ready:
                        self.isRunning = true
                        self.lastError = nil
                    case let .failed(error):
                        self.isRunning = false
                        self.lastError = error.localizedDescription
                        log.error("MCP listener failed: \(error.localizedDescription, privacy: .public)")
                    case .cancelled:
                        self.isRunning = false
                    default:
                        break
                    }
                }
            }
            listener.start(queue: ioQueue)
            self.listener = listener
            await refreshLegacyPortCheck(currentPort: port)
        } catch {
            lastError = error.localizedDescription
            log.error("MCP server failed to start: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Asks whether the port Seedbed no longer uses is answered by something
    /// else, so Settings can warn that a client still aimed there is talking to
    /// a different program. Skipped when this app is itself on that port, where
    /// a listener is the app doing its job rather than a collision.
    func refreshLegacyPortCheck(currentPort: UInt16) async {
        guard currentPort != MCPConstants.legacyDefaultPort else {
            legacyPortHeldByAnother = false
            return
        }
        let held = await Self.isSomethingListening(on: MCPConstants.legacyDefaultPort)
        legacyPortHeldByAnother = held
        if held {
            log.info("MCP: another program holds port \(MCPConstants.legacyDefaultPort, privacy: .public)")
        }
    }

    /// One loopback connect, opened and closed at once, which is the only way
    /// to learn this without asking for a privilege the app does not have:
    /// enumerating other processes' sockets needs `lsof` or root, and binding
    /// the port to see it fail would steal it from whoever holds it.
    ///
    /// A refused connect surfaces as `.waiting`, not `.failed`: Network
    /// framework treats "nothing there yet" as something to retry. So `.ready`
    /// is the only state that means occupied, and the deadline covers the case
    /// where none of them arrives.
    nonisolated static func isSomethingListening(
        on port: UInt16, timeout: TimeInterval = 0.4
    ) async -> Bool {
        guard let nwPort = NWEndpoint.Port(rawValue: port) else { return false }
        let connection = NWConnection(host: "127.0.0.1", port: nwPort, using: .tcp)
        let queue = DispatchQueue(label: "net.amnesia.seedbed.mcp.probe")
        let answer = await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            let once = ResumeOnce(continuation)
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready: once.resume(true)
                case .waiting, .failed, .cancelled: once.resume(false)
                default: break
                }
            }
            queue.asyncAfter(deadline: .now() + timeout) { once.resume(false) }
            connection.start(queue: queue)
        }
        connection.cancel()
        return answer
    }

    /// One connection: read the request, dispatch it, write the response, close.
    /// One request per connection — responses carry `Connection: close`.
    nonisolated private func serve(_ connection: NWConnection) async {
        // Take the slot FIRST, and arm the release only once it is held.
        // Releasing a slot that was never acquired would let each refusal widen
        // the cap by one, so the limiter would erode itself under exactly the
        // load it exists to bound.
        guard await MCPConnectionLimiter.shared.acquire() else {
            log.error("MCP refused a connection: already serving the maximum")
            connection.cancel()
            return
        }
        defer {
            connection.cancel()
            Task { await MCPConnectionLimiter.shared.release() }
        }
        do {
            let request = try await withTimeout(seconds: MCPConstants.readTimeout) {
                try await Self.readRequest(connection)
            }
            let response = await handler.handle(request)
            try await Self.send(response, on: connection)
        } catch {
            log.debug("MCP connection closed early: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: - HTTP framing

    nonisolated private static func readRequest(
        _ connection: NWConnection
    ) async throws -> HTTPRequestData {
        var buffer = Data()
        let separator = Data("\r\n\r\n".utf8)

        while true {
            if let headerEnd = buffer.range(of: separator) {
                let headerBlock = buffer.subdata(in: buffer.startIndex ..< headerEnd.lowerBound)
                let (method, path, headers) = try parseHead(headerBlock)
                let contentLength = headers["content-length"].flatMap { Int($0) } ?? 0
                guard contentLength <= MCPConstants.maxRequestBytes else {
                    throw MCPServerError.requestTooLarge
                }
                var body = buffer.subdata(in: headerEnd.upperBound ..< buffer.endIndex)
                while body.count < contentLength {
                    let chunk = try await receive(connection)
                    if chunk.isEmpty { break }
                    body.append(chunk)
                }
                return HTTPRequestData(method: method, path: path, headers: headers,
                                       body: body.prefix(contentLength))
            }
            let chunk = try await receive(connection)
            if chunk.isEmpty { throw MCPServerError.connectionClosed }
            buffer.append(chunk)
            guard buffer.count <= MCPConstants.maxRequestBytes else {
                throw MCPServerError.requestTooLarge
            }
        }
    }

    nonisolated static func parseHead(
        _ data: Data
    ) throws -> (method: String, path: String, headers: [String: String]) {
        guard let text = String(data: data, encoding: .utf8) else {
            throw MCPServerError.malformedRequest
        }
        let lines = text.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else { throw MCPServerError.malformedRequest }
        let parts = requestLine.split(separator: " ")
        guard parts.count >= 2 else { throw MCPServerError.malformedRequest }
        var headers: [String: String] = [:]
        for line in lines.dropFirst() where !line.isEmpty {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            headers[name] = value
        }
        return (String(parts[0]), String(parts[1]), headers)
    }

    nonisolated private static func receive(_ connection: NWConnection) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) {
                data, _, _, error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: data ?? Data())
                }
            }
        }
    }

    nonisolated private static func send(
        _ response: HTTPResponseData, on connection: NWConnection
    ) async throws {
        let extras = response.extraHeaders
            .sorted { $0.key < $1.key }
            .map { "\($0.key): \($0.value)\r\n" }
            .joined()
        let head = "HTTP/1.1 \(response.status) \(reasonPhrase(response.status))\r\n"
            + "Content-Type: application/json\r\n"
            + "Content-Length: \(response.body.count)\r\n"
            + extras
            + "Connection: close\r\n\r\n"
        var packet = Data(head.utf8)
        packet.append(response.body)
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(content: packet, completion: .contentProcessed { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            })
        }
    }

    nonisolated private static func reasonPhrase(_ status: Int) -> String {
        switch status {
        case 200: "OK"
        case 202: "Accepted"
        case 400: "Bad Request"
        case 401: "Unauthorized"
        case 403: "Forbidden"
        case 404: "Not Found"
        case 405: "Method Not Allowed"
        case 429: "Too Many Requests"
        default: "Error"
        }
    }
}

/// Transport-level checks that belong to an HTTP server a browser might reach,
/// not just a CLI holding a token.
///
/// The attack the MCP spec singles out is **DNS rebinding**. A page served from
/// `evil.com` re-points `evil.com` at `127.0.0.1`; the browser now treats
/// `http://evil.com:8789` as same-origin with the page, so there is no CORS
/// preflight and the response is readable — the whole prompt library, read out
/// by a page the user merely visited. The bearer token is why that does not
/// already work, but "an unrelated control happens to stop it" is not a defence.
///
/// Both halves of the rebind are visible in the request: `Host` becomes
/// `evil.com:8789` and `Origin` becomes `http://evil.com`. So the rule is one
/// predicate over a hostname — a public DNS name this server has no reason to
/// answer to is refused, and everything a real local client uses is not.
enum MCPRequestGuard {
    /// The endpoint is the server root. Ignoring the path entirely would make
    /// every URL on the port a live endpoint, so a client misconfigured with a
    /// stray path appears to work and a scanner gets a hit on anything it tries.
    static let allowedPaths: Set<String> = ["/", "/mcp"]

    static func isAllowedPath(_ raw: String) -> Bool {
        let path = raw.prefix { $0 != "?" && $0 != "#" }
        let trimmed = path.count > 1 && path.hasSuffix("/") ? String(path.dropLast()) : String(path)
        return allowedPaths.contains(trimmed)
    }

    /// `Host: example.com:8789` / `[::1]:8789` / `example.com` → the bare,
    /// lowercased hostname.
    static func hostname(fromHostHeader header: String) -> String {
        var value = header.trimmingCharacters(in: .whitespaces)
        if value.hasPrefix("[") {
            if let close = value.firstIndex(of: "]") {
                value = String(value[value.index(after: value.startIndex) ..< close])
            }
        } else if let colon = value.lastIndex(of: ":") {
            value = String(value[..<colon])
        }
        return normalizedHostname(value)
    }

    /// `Origin: https://evil.com:443` → `evil.com`. Nil for the opaque `null`
    /// origin, which is never trusted.
    static func hostname(fromOriginHeader header: String) -> String? {
        let value = header.trimmingCharacters(in: .whitespaces)
        guard value != "null", let host = URL(string: value)?.host else { return nil }
        return normalizedHostname(host)
    }

    /// Trailing dots removed, so a legal fully-qualified form cannot be a way to
    /// slip a name past the comparison.
    static func normalizedHostname(_ raw: String) -> String {
        var value = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        while value.hasSuffix(".") { value.removeLast() }
        return value
    }

    static func isTrustedHostname(_ name: String, localName: String) -> Bool {
        if name == "localhost" || name.hasSuffix(".localhost") { return true }
        if name.hasSuffix(".local") { return true }
        if IPv4Address(name) != nil || IPv6Address(name) != nil { return true }
        let local = localName.lowercased()
        if !local.isEmpty, name == local { return true }
        // `ProcessInfo.hostName` is usually the Bonjour form; accept the bare
        // label too, since a client may be configured either way.
        if let bare = local.split(separator: ".").first, !bare.isEmpty, name == String(bare) {
            return true
        }
        return false
    }

    /// `Host` absent is allowed (HTTP/1.0 and hand-rolled clients omit it).
    /// `Origin` absent is the normal case: only browsers send one, and a
    /// non-browser client cannot be rebound.
    static func isTrusted(_ request: HTTPRequestData, localName: String) -> Bool {
        if let host = request.headers["host"],
           !isTrustedHostname(hostname(fromHostHeader: host), localName: localName) {
            return false
        }
        if let origin = request.headers["origin"] {
            guard let name = hostname(fromOriginHeader: origin),
                  isTrustedHostname(name, localName: localName)
            else { return false }
        }
        return true
    }
}

/// Bounds how fast a wrong bearer token can be guessed.
///
/// Two properties are deliberate. **Only failures are refused** — the token is
/// checked first and a correct one is always served, even mid-lockout, so a
/// passer-by cannot lock the owner out of their own library; the overwhelmingly
/// common source of repeated 401s is not an attacker but a client still holding
/// a regenerated token, retrying in a loop. And **it refuses rather than
/// sleeps**: delaying the response would pin one of the sixteen connection slots
/// per guess, turning a rate limit into a denial-of-service lever.
struct MCPAuthThrottle {
    static let failureBudget = 10
    static let firstLockout: TimeInterval = 60
    static let maxLockout: TimeInterval = 15 * 60

    enum Outcome: Equatable {
        case rejected
        case lockedOut(retryAfter: Int)
    }

    private var consecutiveFailures = 0
    private var lockedUntil: Date?
    private var lockoutStreak = 0

    mutating func recordFailure(at now: Date) -> Outcome {
        if let until = lockedUntil, until > now {
            return .lockedOut(retryAfter: Self.seconds(from: now, to: until))
        }
        consecutiveFailures += 1
        guard consecutiveFailures > Self.failureBudget else { return .rejected }

        consecutiveFailures = 0
        lockoutStreak += 1
        let window = min(Self.firstLockout * pow(2, Double(lockoutStreak - 1)), Self.maxLockout)
        let until = now.addingTimeInterval(window)
        lockedUntil = until
        return .lockedOut(retryAfter: Self.seconds(from: now, to: until))
    }

    /// Clears the budget AND the escalation streak: whoever holds the real token
    /// is by definition not the guesser, so the next honest mistake starts fresh.
    mutating func recordSuccess() {
        consecutiveFailures = 0
        lockedUntil = nil
        lockoutStreak = 0
    }

    /// Never below 1 — `Retry-After: 0` reads as "try immediately", which is the
    /// opposite of what a lockout means.
    private static func seconds(from now: Date, to until: Date) -> Int {
        max(1, Int(until.timeIntervalSince(now).rounded(.up)))
    }
}

/// Authenticates and dispatches MCP JSON-RPC requests.
///
/// An actor rather than a main-actor class, unlike the app it was ported from: every tool here
/// runs `python3 -m promptlib`, and a build takes minutes. On the main actor
/// that would freeze the panel; inside the actor the blocking work is pushed to
/// a detached task, so one slow build does not block a `find_prompt` behind it.
actor MCPRequestHandler {
    private let client: LibraryClient
    private var token = ""
    private var readOnlyToken = ""
    private var throttle = MCPAuthThrottle()
    /// This Mac's own name, so a request addressed to it is not a rebind. Read
    /// once: `ProcessInfo.hostName` is a syscall and this is per request.
    private let localHostName = ProcessInfo.processInfo.hostName
    private var authAlert: MCPAuthAlert?
    private var reportAuthAlert: (@Sendable (MCPAuthAlert?) -> Void)?

    init(client: LibraryClient) { self.client = client }

    func setTokens(full: String, readOnly: String) {
        token = full
        readOnlyToken = readOnly
        // A restart is the point at which the person has just been told what
        // the tokens and the port now are, so an alert from before it describes
        // a state they have already been given the answer to.
        clearAuthAlert()
    }

    func setAuthAlertObserver(_ observer: @escaping @Sendable (MCPAuthAlert?) -> Void) {
        reportAuthAlert = observer
    }

    /// What a presented token may do.
    enum Access {
        /// Every tool, including the one that spends an LLM call.
        case full
        /// Reads only. `tools/list` is filtered to match, so a client is never
        /// offered a tool it cannot call: advertising the rest would have the
        /// agent on the other end pick one, call it, and fail — spending a turn
        /// to learn what the list could have told it.
        case readOnly
    }

    func handle(_ request: HTTPRequestData) async -> HTTPResponseData {
        guard let access = access(for: request) else {
            return rejectUnauthenticated(
                credentialPresented: request.headers["authorization"] != nil
            )
        }
        throttle.recordSuccess()
        clearAuthAlert()
        guard MCPRequestGuard.isTrusted(request, localName: localHostName) else {
            log.error("MCP request rejected: untrusted Host/Origin")
            return HTTPResponseData(status: 403, body: jsonObject([
                "error": "forbidden",
                "detail": "This request's Host or Origin isn't one Seedbed answers to. "
                    + "Connect to the address shown in Seedbed → MCP Server.",
            ]))
        }
        guard MCPRequestGuard.isAllowedPath(request.path) else {
            return HTTPResponseData(status: 404, body: jsonObject([
                "error": "not found",
                "detail": "The MCP endpoint is the server root. Drop the path from this "
                    + "client's URL, or copy the configuration from Seedbed → MCP Server.",
            ]))
        }
        guard request.method == "POST" else {
            return HTTPResponseData(status: 405, body: jsonObject(["error": "method not allowed"]))
        }
        guard let root = try? JSONSerialization.jsonObject(with: request.body) as? [String: Any] else {
            return rpcError(id: nil, code: -32700, message: "Parse error")
        }
        guard let method = root["method"] as? String else {
            return rpcError(id: root["id"], code: -32600, message: "Invalid Request")
        }
        let id = root["id"]
        let params = root["params"] as? [String: Any] ?? [:]

        // Notifications carry no id — acknowledge with 202 and no body.
        // `notifications/initialized` is the common one.
        if id == nil || id is NSNull {
            return HTTPResponseData(status: 202, body: Data())
        }

        switch method {
        case "initialize":
            let version = (params["protocolVersion"] as? String)
                ?? MCPConstants.defaultProtocolVersion
            return rpcResult(id: id, result: [
                "protocolVersion": version,
                "capabilities": ["tools": [String: Any](), "prompts": [String: Any]()],
                "serverInfo": ["name": "Seedbed", "version": MCPConstants.serverVersion],
            ])
        case "ping":
            return rpcResult(id: id, result: [String: Any]())
        case "tools/list":
            return rpcResult(id: id, result: ["tools": tools(for: access)])
        case "tools/call":
            return await handleToolCall(id: id, params: params, access: access)
        case "prompts/list":
            return await handlePromptsList(id: id)
        case "prompts/get":
            return await handlePromptGet(id: id, params: params)
        default:
            return rpcError(id: id, code: -32601, message: "Method not found: \(method)")
        }
    }

    // MARK: - Prompts
    //
    // This app IS a prompt library, so `prompts/list` and `prompts/get` are the
    // native way for a client to pull one — a tool call is the fallback for
    // clients that only implement tools.

    private func handlePromptsList(id: Any?) async -> HTTPResponseData {
        do {
            let data = try await load()
            return rpcResult(id: id, result: ["prompts": MCPToolCatalog.promptDefinitions(data)])
        } catch {
            return rpcError(id: id, code: -32603, message: error.localizedDescription)
        }
    }

    private func handlePromptGet(id: Any?, params: [String: Any]) async -> HTTPResponseData {
        guard let name = params["name"] as? String else {
            return rpcError(id: id, code: -32602, message: "Missing prompt name")
        }
        let arguments = params["arguments"] as? [String: Any] ?? [:]
        let model = arguments["model"] as? String ?? ""
        do {
            let rendered = try await MCPToolCatalog.renderPrompt(
                name: name, model: model, client: client
            )
            return rpcResult(id: id, result: [
                "description": rendered.description,
                "messages": [[
                    "role": "user",
                    "content": ["type": "text", "text": rendered.text],
                ]],
            ])
        } catch {
            return rpcError(id: id, code: -32602, message: error.localizedDescription)
        }
    }

    // MARK: - Tools

    private func tools(for access: Access) -> [[String: Any]] {
        switch access {
        case .full:
            return MCPToolCatalog.definitions
        case .readOnly:
            return MCPToolCatalog.definitions.filter { def in
                guard let name = def["name"] as? String else { return false }
                return MCPToolCatalog.readOnlyTools.contains(name)
            }
        }
    }

    private func handleToolCall(
        id: Any?, params: [String: Any], access: Access
    ) async -> HTTPResponseData {
        guard let name = params["name"] as? String else {
            return rpcError(id: id, code: -32602, message: "Missing tool name")
        }
        if case .readOnly = access, !MCPToolCatalog.readOnlyTools.contains(name) {
            log.error("MCP read-only token refused \(name, privacy: .public)")
            return rpcError(
                id: id, code: -32600,
                message: "\(name) rebuilds prompts, which spends an LLM call, and this "
                    + "client is using the read-only access token. Use the full token "
                    + "from Seedbed → MCP Server if this client is meant to do that."
            )
        }
        let arguments = params["arguments"] as? [String: Any] ?? [:]
        let outcome = await MCPToolCatalog.run(name: name, arguments: arguments, client: client)
        return rpcResult(id: id, result: [
            "content": [["type": "text", "text": outcome.text]],
            "isError": outcome.isError,
        ])
    }

    /// The library, loaded off the actor so a slow read does not block it.
    private func load() async throws -> LibraryData {
        let client = self.client
        return try await Task.detached { try client.load() }.value
    }

    // MARK: - Auth

    private func rejectUnauthenticated(credentialPresented: Bool) -> HTTPResponseData {
        recordAuthAlert(credentialPresented: credentialPresented)
        switch throttle.recordFailure(at: Date()) {
        case let .lockedOut(retryAfter):
            log.error("MCP auth locked out for \(retryAfter, privacy: .public)s after repeated bad tokens")
            return HTTPResponseData(
                status: 429,
                body: jsonObject([
                    "error": "too many failed attempts",
                    "detail": "Too many requests with a wrong access token. Wait "
                        + "\(retryAfter)s, then retry with the token from Seedbed → MCP Server.",
                ]),
                extraHeaders: ["Retry-After": String(retryAfter)]
            )
        case .rejected:
            log.error("MCP request rejected: bad or missing token")
            // A bare "unauthorized" is indistinguishable from the server being
            // broken, and the common cause is a token this client cached before
            // the user regenerated it. Say which, and where the new one is.
            return HTTPResponseData(status: 401, body: jsonObject([
                "error": "unauthorized",
                "detail": "The bearer token this client sent isn't the one Seedbed is using. "
                    + "If the token was regenerated, copy the current configuration from "
                    + "Seedbed → MCP Server and update this client.",
            ]))
        }
    }

    /// Counts consecutive refusals of one shape and hands the running total to
    /// whoever is watching. A run of these is the signal: one is a person
    /// pasting a URL into a browser, a dozen is a configured client looping on
    /// a credential or an address that stopped being right.
    private func recordAuthAlert(credentialPresented: Bool) {
        let cause: MCPAuthAlert.Cause = credentialPresented ? .wrongToken : .noCredential
        let previous = authAlert?.cause == cause ? (authAlert?.attempts ?? 0) : 0
        let alert = MCPAuthAlert(cause: cause, attempts: previous + 1, lastAttempt: Date())
        authAlert = alert
        reportAuthAlert?(alert)
    }

    /// Anything that authenticates clears the diagnosis, so the pane never
    /// reports a client that has since been fixed.
    private func clearAuthAlert() {
        guard authAlert != nil else { return }
        authAlert = nil
        reportAuthAlert?(nil)
    }

    /// Both comparisons are constant-time and both always run, so the answer
    /// does not leak which token was closer.
    private func access(for request: HTTPRequestData) -> Access? {
        guard let header = request.headers["authorization"] else { return nil }
        let matchesFull = !token.isEmpty
            && Self.constantTimeEquals(header, "Bearer \(token)")
        let matchesReadOnly = !readOnlyToken.isEmpty
            && Self.constantTimeEquals(header, "Bearer \(readOnlyToken)")
        if matchesFull { return .full }
        if matchesReadOnly { return .readOnly }
        return nil
    }

    /// The token's length is not secret, so an early length mismatch is
    /// acceptable; the per-byte loop avoids leaking where a same-length guess
    /// diverges.
    static func constantTimeEquals(_ lhs: String, _ rhs: String) -> Bool {
        let a = Array(lhs.utf8)
        let b = Array(rhs.utf8)
        guard a.count == b.count else { return false }
        var diff: UInt8 = 0
        for i in a.indices { diff |= a[i] ^ b[i] }
        return diff == 0
    }

    // MARK: - JSON-RPC envelopes

    private func rpcResult(id: Any?, result: [String: Any]) -> HTTPResponseData {
        HTTPResponseData(status: 200, body: jsonObject([
            "jsonrpc": "2.0", "id": id ?? NSNull(), "result": result,
        ]))
    }

    private func rpcError(id: Any?, code: Int, message: String) -> HTTPResponseData {
        HTTPResponseData(status: 200, body: jsonObject([
            "jsonrpc": "2.0", "id": id ?? NSNull(),
            "error": ["code": code, "message": message],
        ]))
    }

    private func jsonObject(_ object: [String: Any]) -> Data {
        (try? JSONSerialization.data(withJSONObject: object)) ?? Data("{}".utf8)
    }
}
