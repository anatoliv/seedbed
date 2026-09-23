import Foundation
import UserNotifications

/// Which port to bind when the configured one is already taken.
///
/// The server used to bind whatever port Settings named and, with address
/// reuse on, a loopback bind could even succeed beside another program's
/// wildcard listener on the same port, so a collision surfaced as a client
/// that reached the wrong server, or as nothing at all. Now the port is probed
/// first, and if something answers there the server walks upward to the first
/// free port instead of failing, then tells the person where it went.
///
/// Pure: the probe is handed in, so the walk can be checked without a socket.
enum MCPPortScan {
    /// How far above the requested port the walk goes before giving up. Far
    /// enough to clear a cluster of local servers, small enough that "every
    /// port is taken" still gets reported instead of the app wandering off
    /// into a range nobody would think to look in.
    static let scanLimit: UInt16 = 32

    /// Ports the walk steps over even when they are free, because other local
    /// agent servers default to them or scan through them. Binding one would
    /// take it from the program that owns it, and that program would then do
    /// exactly what this one does and move, which puts the two of them a
    /// launch order apart from swapping places. The requested port itself is
    /// never skipped: a person who typed one of these into Settings meant it.
    static let reservedPorts: Set<UInt16> = Set([8765, 8784] + Array(8787...8802))

    /// The ports tried, in order: the requested one first, then upward,
    /// skipping the reserved ones and stopping at `limit` above the request or
    /// at the top of the port range.
    static func candidates(for requested: UInt16, limit: UInt16 = scanLimit) -> [UInt16] {
        let top = min(Int(requested) + Int(limit), Int(UInt16.max))
        var out = [requested]
        if Int(requested) < top {
            for port in (Int(requested) + 1)...top where !reservedPorts.contains(UInt16(port)) {
                out.append(UInt16(port))
            }
        }
        return out
    }

    /// The first candidate `isFree` says yes to, or nil when it says no to all
    /// of them.
    static func firstFree(
        requested: UInt16, limit: UInt16 = scanLimit,
        isFree: (UInt16) async -> Bool
    ) async -> UInt16? {
        for candidate in candidates(for: requested, limit: limit) where await isFree(candidate) {
            return candidate
        }
        return nil
    }
}

/// The server started somewhere other than where Settings said, and the person
/// has to be told: the port field has changed under them, and every client
/// configured with the old number is now pointing at whatever took it.
struct MCPPortMove: Equatable, Sendable {
    let requested: UInt16
    let bound: UInt16

    var title: String {
        "Port \(requested) was taken, so Seedbed is listening on \(bound)."
    }

    var detail: String {
        "Another program was already listening on port \(requested) when the server "
        + "started. The port field above now shows \(bound), and that is the port Seedbed "
        + "will use from now on. Every client you configured with port \(requested) is "
        + "reaching that other program instead and will report an authentication "
        + "failure. Press Update my client config, or copy the configuration again."
    }

    /// The user notification, which is how the news reaches somebody whose
    /// Settings window is closed, which at launch is everybody.
    var notificationTitle: String { "Seedbed moved its MCP server to port \(bound)" }
    var notificationBody: String {
        "Port \(requested) was already taken. Update your MCP client's configuration "
        + "from Settings, then MCP."
    }
}

/// Posts a port move as a macOS user notification.
///
/// Delivery needs a bundled app: `UNUserNotificationCenter` refuses a bare
/// executable, which is what a test process and a `swift run` are, so the
/// server takes this as a closure and the tests hand in a recorder instead.
enum MCPPortMoveNotifier {
    static func post(_ move: MCPPortMove) {
        guard Bundle.main.bundleIdentifier != nil else { return }
        Task {
            let center = UNUserNotificationCenter.current()
            let settings = await center.notificationSettings()
            if settings.authorizationStatus == .notDetermined {
                _ = try? await center.requestAuthorization(options: [.alert, .sound])
            }
            let status = await center.notificationSettings().authorizationStatus
            guard status == .authorized || status == .provisional else { return }
            let content = UNMutableNotificationContent()
            content.title = move.notificationTitle
            content.body = move.notificationBody
            let request = UNNotificationRequest(
                identifier: "mcp.port-move.\(move.bound)", content: content, trigger: nil
            )
            try? await center.add(request)
        }
    }
}
