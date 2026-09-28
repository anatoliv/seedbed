import CommonCrypto
import CryptoKit
import Foundation
import Security

/// A portable copy of user data. The Python package and Git metadata are not
/// data: a restored library gets the already installed package instead.
struct SeedbedBackupPayload: Codable {
    let version: Int
    let files: [String: Data]
    let preferences: Data
    let secrets: [String: String]
    let launchAtLogin: Bool
    let automaticUpdates: Bool?

    var promptCount: Int {
        files.keys.filter { $0.hasPrefix("prompts/") && $0.hasSuffix(".md") }.count
    }
}

enum SeedbedBackup {
    enum Failure: LocalizedError {
        case invalidPassword
        case invalidArchive
        case unsupportedVersion
        case unsafePath
        case tooLarge
        case missingModels
        case keychain
        case invalidLibrary

        var errorDescription: String? {
            switch self {
            case .invalidPassword: return "Use a password of at least 12 characters."
            case .invalidArchive: return "The password is wrong or the backup is damaged."
            case .unsupportedVersion: return "This backup was made by a newer version of Seedbed."
            case .unsafePath: return "The backup contains an unsafe file path or symbolic link."
            case .tooLarge: return "The backup is larger than Seedbed can safely import."
            case .missingModels: return "The backup has no model registry."
            case .keychain: return "Seedbed could not read or save a secret in the login Keychain."
            case .invalidLibrary: return "The restored folder is not a usable Seedbed library."
            }
        }
    }

    private static let magic = Data("SEEDBED-BACKUP-1\n".utf8)
    private static let saltLength = 16
    private static let maxArchiveBytes = 256 * 1024 * 1024
    private static let dataDirectories: Set<String> = [
        "prompts", "rendered", "comparisons", ".cache", "MigratedOriginals"
    ]
    private static let dataFiles: Set<String> = [
        "models.toml", "enhancer.toml", ".usage.json", ".variables.json"
    ]

    private struct SecretSlot {
        let id: String
        let service: String
        let account: String
    }

    private static let secretSlots = [
        SecretSlot(id: "mcp-full", service: MCPTokenStore.service,
                   account: MCPTokenStore.fullAccount),
        SecretSlot(id: "mcp-readonly", service: MCPTokenStore.service,
                   account: MCPTokenStore.readOnlyAccount),
        SecretSlot(id: "enhancer-primary", service: "promptlib-enhancer",
                   account: "promptlib"),
        SecretSlot(id: "enhancer-fallback", service: "promptlib-enhancer-fallback",
                   account: "promptlib"),
        SecretSlot(id: "chatgpt-oauth", service: "promptlib-codex-oauth",
                   account: "promptlib"),
    ]

    static func collect(from root: URL, defaults: UserDefaults = .standard,
                        launchAtLogin: Bool, automaticUpdates: Bool?) throws
        -> SeedbedBackupPayload {
        let files = try collectFiles(from: root)
        let domain = Bundle.main.bundleIdentifier ?? "net.amnesia.seedbed"
        let preferences = defaults.persistentDomain(forName: domain) ?? [:]
        let plist = try PropertyListSerialization.data(fromPropertyList: preferences,
                                                       format: .binary, options: 0)
        var secrets: [String: String] = [:]
        for slot in secretSlots {
            if let value = try readSecret(slot) { secrets[slot.id] = value }
        }
        return SeedbedBackupPayload(version: 1, files: files, preferences: plist,
                                    secrets: secrets, launchAtLogin: launchAtLogin,
                                    automaticUpdates: automaticUpdates)
    }

    static func collectFiles(from root: URL) throws -> [String: Data] {
        var files: [String: Data] = [:]
        let manager = FileManager.default
        let resolvedRoot = root.resolvingSymlinksInPath().standardizedFileURL.path
        for name in dataFiles.sorted() {
            let url = root.appendingPathComponent(name)
            guard manager.fileExists(atPath: url.path) else { continue }
            guard try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
                .isRegularFile == true,
                try url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink != true
            else { throw Failure.unsafePath }
            files[name] = try Data(contentsOf: url)
        }
        for name in dataDirectories.sorted() {
            let directory = root.appendingPathComponent(name)
            guard manager.fileExists(atPath: directory.path) else { continue }
            guard try directory.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
                .isDirectory == true,
                try directory.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink != true,
                let entries = manager.enumerator(at: directory,
                                                 includingPropertiesForKeys: [.isRegularFileKey,
                                                                               .isSymbolicLinkKey])
            else { throw Failure.unsafePath }
            for case let url as URL in entries {
                let values = try url.resourceValues(forKeys: [.isRegularFileKey,
                                                               .isSymbolicLinkKey])
                if values.isSymbolicLink == true { throw Failure.unsafePath }
                guard values.isRegularFile == true else { continue }
                let resolved = url.resolvingSymlinksInPath().standardizedFileURL.path
                guard resolved.hasPrefix(resolvedRoot + "/") else { throw Failure.unsafePath }
                let relative = String(resolved.dropFirst(resolvedRoot.count + 1))
                guard allowed(relative) else { throw Failure.unsafePath }
                files[relative] = try Data(contentsOf: url)
            }
        }
        guard files["models.toml"] != nil else { throw Failure.missingModels }
        return files
    }

    static func seal(_ payload: SeedbedBackupPayload, password: String) throws -> Data {
        guard password.count >= 12 else { throw Failure.invalidPassword }
        try validate(payload)
        let plain = try JSONEncoder().encode(payload)
        guard plain.count <= maxArchiveBytes else { throw Failure.tooLarge }
        var salt = Data(count: saltLength)
        let status = salt.withUnsafeMutableBytes { bytes in
            SecRandomCopyBytes(kSecRandomDefault, saltLength, bytes.baseAddress!)
        }
        guard status == errSecSuccess else { throw Failure.invalidArchive }
        let key = try deriveKey(password: password, salt: salt)
        let box = try AES.GCM.seal(plain, using: key)
        guard let combined = box.combined else { throw Failure.invalidArchive }
        return magic + salt + combined
    }

    static func open(_ archive: Data, password: String) throws -> SeedbedBackupPayload {
        guard archive.count <= maxArchiveBytes else { throw Failure.tooLarge }
        guard archive.starts(with: magic),
              archive.count > magic.count + saltLength + 28
        else { throw Failure.invalidArchive }
        let salt = archive.subdata(in: magic.count..<(magic.count + saltLength))
        let combined = archive.subdata(in: (magic.count + saltLength)..<archive.count)
        do {
            let key = try deriveKey(password: password, salt: salt)
            let box = try AES.GCM.SealedBox(combined: combined)
            let plain = try AES.GCM.open(box, using: key)
            let payload = try JSONDecoder().decode(SeedbedBackupPayload.self, from: plain)
            try validate(payload)
            return payload
        } catch let error as Failure {
            throw error
        } catch {
            throw Failure.invalidArchive
        }
    }

    /// A new sibling is used rather than writing over the active library or a
    /// Git checkout. A failed import removes only its own staging directory.
    static func restoreFiles(_ payload: SeedbedBackupPayload, runtimeRoot: URL,
                             parent: URL) throws -> URL {
        try validate(payload)
        let manager = FileManager.default
        try manager.createDirectory(at: parent, withIntermediateDirectories: true)
        let target = parent.appendingPathComponent("LibraryData-Imported-\(UUID().uuidString)",
                                                 isDirectory: true)
        try manager.createDirectory(at: target, withIntermediateDirectories: false)
        do {
            try manager.copyItem(at: runtimeRoot.appendingPathComponent("promptlib"),
                                 to: target.appendingPathComponent("promptlib"))
            let assets = runtimeRoot.appendingPathComponent("assets")
            if manager.fileExists(atPath: assets.path) {
                try manager.copyItem(at: assets, to: target.appendingPathComponent("assets"))
            }
            for (relative, data) in payload.files.sorted(by: { $0.key < $1.key }) {
                let url = target.appendingPathComponent(relative)
                try manager.createDirectory(at: url.deletingLastPathComponent(),
                                            withIntermediateDirectories: true)
                try data.write(to: url, options: .atomic)
            }
            guard LibraryClient.isLibrary(target) else { throw Failure.invalidLibrary }
            return target
        } catch {
            try? manager.removeItem(at: target)
            throw error
        }
    }

    /// Import only the secrets present in the archive. Existing secrets absent
    /// from it remain intact, and earlier writes are rolled back on failure.
    static func restoreSecrets(_ secrets: [String: String]) throws {
        var originals: [(SecretSlot, String?)] = []
        do {
            for slot in secretSlots where secrets[slot.id] != nil {
                let previous = try readSecret(slot)
                originals.append((slot, previous))
                try writeSecret(secrets[slot.id]!, to: slot)
            }
        } catch {
            for (slot, previous) in originals.reversed() {
                try? writeSecret(previous, to: slot)
            }
            throw error
        }
    }

    static func restoredPreferences(_ payload: SeedbedBackupPayload, root: URL) throws
        -> [String: Any] {
        let decoded = try PropertyListSerialization.propertyList(from: payload.preferences,
                                                                 format: nil)
        guard var preferences = decoded as? [String: Any] else {
            throw Failure.invalidArchive
        }
        // Paths from another Mac cannot select this Mac's library or Python.
        preferences["LibraryRoot"] = root.path
        if let python = preferences["PythonPath"] as? String,
           !FileManager.default.isExecutableFile(atPath: python) {
            preferences.removeValue(forKey: "PythonPath")
        }
        return preferences
    }

    private static func validate(_ payload: SeedbedBackupPayload) throws {
        guard payload.version == 1 else { throw Failure.unsupportedVersion }
        guard payload.files["models.toml"] != nil else { throw Failure.missingModels }
        guard payload.files.keys.allSatisfy(allowed) else { throw Failure.unsafePath }
        guard Set(payload.secrets.keys).isSubset(of: Set(secretSlots.map(\.id)))
        else { throw Failure.invalidArchive }
        guard payload.files.values.reduce(0, { $0 + $1.count }) <= maxArchiveBytes
        else { throw Failure.tooLarge }
    }

    private static func allowed(_ path: String) -> Bool {
        let parts = path.split(separator: "/", omittingEmptySubsequences: false)
        guard !parts.isEmpty, parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }),
              !path.contains("\\"), !path.contains("\0") else { return false }
        if parts.count == 1 { return dataFiles.contains(path) }
        return dataDirectories.contains(String(parts[0]))
    }

    private static func deriveKey(password: String, salt: Data) throws -> SymmetricKey {
        var bytes = [UInt8](repeating: 0, count: 32)
        let keyLength = bytes.count
        let result = password.withCString { passwordBytes in
            salt.withUnsafeBytes { saltBytes in
                bytes.withUnsafeMutableBytes { keyBytes in
                    CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2), passwordBytes,
                                        password.utf8.count,
                                        saltBytes.bindMemory(to: UInt8.self).baseAddress!,
                                        salt.count, CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256),
                                        310_000, keyBytes.bindMemory(to: UInt8.self).baseAddress!,
                                        keyLength)
                }
            }
        }
        guard result == kCCSuccess else { throw Failure.invalidArchive }
        return SymmetricKey(data: bytes)
    }

    private static func query(_ slot: SecretSlot) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: slot.service,
         kSecAttrAccount as String: slot.account]
    }

    private static func readSecret(_ slot: SecretSlot) throws -> String? {
        var request = query(slot)
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(request as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = item as? Data,
              let value = String(data: data, encoding: .utf8) else { throw Failure.keychain }
        return value
    }

    private static func writeSecret(_ value: String?, to slot: SecretSlot) throws {
        let base = query(slot)
        guard let value else {
            let status = SecItemDelete(base as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else {
                throw Failure.keychain
            }
            return
        }
        let data = Data(value.utf8)
        let update = SecItemUpdate(base as CFDictionary,
                                   [kSecValueData as String: data] as CFDictionary)
        if update == errSecSuccess { return }
        guard update == errSecItemNotFound else { throw Failure.keychain }
        var add = base
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        guard SecItemAdd(add as CFDictionary, nil) == errSecSuccess else {
            throw Failure.keychain
        }
    }
}
