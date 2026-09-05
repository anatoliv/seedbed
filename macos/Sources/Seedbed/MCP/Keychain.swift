import Foundation
import Security

/// The login Keychain, for secrets that must not sit in the preferences plist.
///
/// `promptlib` already keeps the enhancer's API key here, through the `security`
/// command line. This is the same store reached the proper way from Swift, so
/// the app does not spawn a process to read one string.
enum Keychain {
    static func string(for account: String, service: String) -> String? {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        let status = withUnsafeMutablePointer(to: &item) {
            SecItemCopyMatching(query as CFDictionary, $0)
        }
        query.removeAll()
        guard status == errSecSuccess, let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Writes, replacing whatever was there. An empty value deletes the item
    /// rather than storing an empty secret, so "no token" has one representation.
    @discardableResult
    static func set(_ value: String, for account: String, service: String) -> Bool {
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(base as CFDictionary)
        guard !value.isEmpty else { return true }
        var insert = base
        insert[kSecValueData as String] = Data(value.utf8)
        // The token is needed by a server that starts at launch, before anyone
        // has necessarily unlocked anything, so it must survive a locked screen.
        insert[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        return SecItemAdd(insert as CFDictionary, nil) == errSecSuccess
    }
}

/// Where the MCP server's bearer tokens live.
///
/// Keychain, never `@AppStorage`. A sibling app's token store carries the reason:
/// its tokens were once in `~/Library/Preferences` in cleartext, readable by any
/// process running as this user and copied into every backup and every synced
/// prefs snapshot. These grant read access to the whole prompt library and, in
/// the full token's case, the ability to spend an LLM call.
enum MCPTokenStore {
    static let service = "net.amnesia.seedbed.mcp"
    static let fullAccount = "access-token"
    static let readOnlyAccount = "access-token-readonly"

    static func load() -> String {
        Keychain.string(for: fullAccount, service: service) ?? ""
    }

    static func save(_ token: String) {
        Keychain.set(token, for: fullAccount, service: service)
    }

    /// The read-only companion. A separate secret, never derived from the full
    /// one — deriving it would mean holding either is holding both.
    static func loadReadOnly() -> String {
        Keychain.string(for: readOnlyAccount, service: service) ?? ""
    }

    static func saveReadOnly(_ token: String) {
        Keychain.set(token, for: readOnlyAccount, service: service)
    }

    /// Both tokens, generating and storing either if it is missing. Called at
    /// launch and by the settings pane, so the server never has to start
    /// without one and the pane never shows an empty field.
    @discardableResult
    static func ensure() -> (full: String, readOnly: String) {
        var full = load()
        if full.isEmpty {
            full = MCPServer.generateToken()
            save(full)
        }
        var readOnly = loadReadOnly()
        // Equal to the full token would quietly make the "safe" token an unsafe
        // one, so treat that like an empty slot.
        if readOnly.isEmpty || readOnly == full {
            readOnly = MCPServer.generateToken()
            saveReadOnly(readOnly)
        }
        return (full, readOnly)
    }
}
