import Foundation

/// Creates the default library on a fresh install. A library must contain the
/// Python package and model registry, so making an empty directory would only
/// turn the first launch into a permanent "no promptlib/" error.
enum LibraryBootstrap {
    static let repository = "https://github.com/anatoliv/seedbed.git"

    enum Failure: LocalizedError {
        case occupied(String)
        case clone(String)
        case invalidClone

        var errorDescription: String? {
            switch self {
            case .occupied(let path):
                return "Library setup stopped: \(path) already contains files. Choose a library in Settings."
            case .clone(let detail):
                return "Library setup failed: \(detail). Connect to the internet, or choose a clone in Settings."
            case .invalidClone:
                return "Library setup failed: the downloaded repository is not a Seedbed library."
            }
        }
    }

    static func shouldPrepare(_ preferred: URL) -> Bool {
        let path = preferred.standardizedFileURL.path
        return !LibraryClient.isLibrary(preferred)
            && (path == LibraryClient.commonRoot.standardizedFileURL.path
                || path == LibraryClient.legacyDefaultRoot.standardizedFileURL.path)
    }

    /// The clone is made beside the final folder and moved into place only
    /// after validation. A failed download cannot leave a half-built library.
    /// A valid legacy checkout wins, and an existing nonempty folder is never
    /// replaced, since it may contain work the app does not understand.
    static func ensureDefaultLibrary(
        commonRoot: URL = LibraryClient.commonRoot,
        legacyRoot: URL = LibraryClient.legacyDefaultRoot,
        clone: (URL) throws -> Void = cloneRepository
    ) throws -> URL {
        if LibraryClient.isLibrary(commonRoot) { return commonRoot }
        if LibraryClient.isLibrary(legacyRoot) { return legacyRoot }

        let files = FileManager.default
        let parent = commonRoot.deletingLastPathComponent()
        try files.createDirectory(at: parent, withIntermediateDirectories: true)
        try requireEmptyOrMissing(commonRoot)

        let staging = parent.appendingPathComponent(".Library-setup-\(UUID().uuidString)",
                                                isDirectory: true)
        defer { try? files.removeItem(at: staging) }
        try clone(staging)
        guard LibraryClient.isLibrary(staging) else { throw Failure.invalidClone }

        // Another launch may have finished while this one was cloning.
        if LibraryClient.isLibrary(commonRoot) { return commonRoot }
        if LibraryClient.isLibrary(legacyRoot) { return legacyRoot }
        try requireEmptyOrMissing(commonRoot)
        if files.fileExists(atPath: commonRoot.path) {
            try files.removeItem(at: commonRoot)
        }
        try files.moveItem(at: staging, to: commonRoot)
        return commonRoot
    }

    private static func requireEmptyOrMissing(_ root: URL) throws {
        let files = FileManager.default
        guard files.fileExists(atPath: root.path) else { return }
        let values = try root.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard values.isDirectory == true, values.isSymbolicLink != true,
              try files.contentsOfDirectory(atPath: root.path).isEmpty else {
            throw Failure.occupied(root.path)
        }
    }

    private static func cloneRepository(into destination: URL) throws {
        try cloneRepository(into: destination, from: repository)
    }

    /// The source is injectable so the real process path can be exercised with
    /// a local git repository in tests, without reaching GitHub.
    static func cloneRepository(into destination: URL, from source: String) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["-c", "credential.helper=", "clone", "--quiet",
                             source, destination.path]
        var environment = ProcessInfo.processInfo.environment
        environment["GIT_TERMINAL_PROMPT"] = "0"
        process.environment = environment
        process.standardOutput = FileHandle.nullDevice
        // A pipe read only after exit can fill and hold git open forever. Let
        // stderr drain to a temporary file while the clone runs.
        let errorFile = FileManager.default.temporaryDirectory
            .appendingPathComponent("seedbed-clone-\(UUID().uuidString).log")
        guard FileManager.default.createFile(atPath: errorFile.path, contents: nil) else {
            throw Failure.clone("could not create a temporary error log")
        }
        let errors = try FileHandle(forWritingTo: errorFile)
        defer {
            try? errors.close()
            try? FileManager.default.removeItem(at: errorFile)
        }
        process.standardError = errors
        let finished = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in finished.signal() }
        do { try process.run() } catch {
            throw Failure.clone(error.localizedDescription)
        }
        if finished.wait(timeout: .now() + 120) == .timedOut {
            process.terminate()
            process.waitUntilExit()
            throw Failure.clone("git clone timed out")
        }
        guard process.terminationStatus == 0 else {
            let detail = try? String(contentsOf: errorFile, encoding: .utf8)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            throw Failure.clone(detail?.isEmpty == false ? detail! : "git clone exited with \(process.terminationStatus)")
        }
    }
}
