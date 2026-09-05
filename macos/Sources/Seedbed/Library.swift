import Foundation
import OSLog
import SwiftUI

/// The library, read by running the Python package that owns it.
///
/// The app deliberately does not parse `prompts/*.md` itself. Staleness, the
/// guidance cache and the enhancer live in `promptlib`, and a second
/// implementation here would drift from them — the same duplication that was
/// just removed from the CLI and the web server.

struct Target: Decodable, Identifiable, Hashable {
    let model: String
    let name: String
    let state: String      // "current" | "stale" | "missing"
    let generated: String
    let words: Int
    let variables: [String]

    var id: String { model }
    var isUsable: Bool { state != "missing" }

    var label: String {
        switch state {
        case "missing": return "not built"
        case "stale":   return "stale · \(words) words"
        default:        return "\(words) words"
        }
    }

    /// State as colour, so a chip needs no words for it and stays narrow enough
    /// that seven of them wrap tidily.
    var dotColor: Color {
        switch state {
        case "current": return .green
        case "stale":   return .orange
        default:        return .secondary.opacity(0.5)
        }
    }

    /// Vendor prefixes waste the width a chip does not have: "Claude Opus 5"
    /// reads as "Opus 5", "Llama 3.3 70B (local)" as "Llama 3.3 70B".
    var shortName: String {
        var name = self.name
        if let paren = name.firstIndex(of: "(") {
            name = String(name[..<paren]).trimmingCharacters(in: .whitespaces)
        }
        for prefix in ["Claude ", "OpenAI ", "Anthropic ", "Meta "] where name.hasPrefix(prefix) {
            name = String(name.dropFirst(prefix.count))
        }
        return name
    }
}

struct Prompt: Decodable, Identifiable, Hashable {
    let id: String
    let title: String
    let body: String
    let tags: [String]
    let category: String
    let targets: [Target]
    let pinned: Bool
    /// Where this prompt gets pasted: "agent" or "chat". It changes what the
    /// enhancer is asked to write, so it is part of staleness.
    let context: String
    let uses: Int
    let lastUsed: String
    let refreshed: String
    let favouriteModel: String
    /// "current" | "stale" | "missing" | "not-applicable"
    let comparison: String

    enum CodingKeys: String, CodingKey {
        case id, title, body, tags, category, targets, pinned, context, uses, refreshed
        case lastUsed = "last_used"
        case favouriteModel = "favourite_model"
        case comparison
    }

    /// A copy of this prompt showing only the models that pass `isVisible`.
    func visibleThrough(_ isVisible: (String) -> Bool) -> Prompt {
        Prompt(id: id, title: title, body: body, tags: tags, category: category,
               targets: ModelOrder.sorted(targets.filter { isVisible($0.model) },
                                          id: \.model),
               pinned: pinned, context: context, uses: uses, lastUsed: lastUsed,
               refreshed: refreshed, favouriteModel: favouriteModel,
               comparison: comparison)
    }

    /// The model a plain copy uses: the one you use most for this prompt, else
    /// the first that is built. With seven targets, "the first one" is rarely
    /// the one you want. Lives here rather than on either window's model
    /// because both windows have to agree on what "copy this prompt" means.
    var defaultTarget: Target? {
        targets.first { $0.model == favouriteModel && $0.isUsable }
            ?? targets.first(where: \.isUsable)
            ?? targets.first
    }

    /// How many renders a delete would destroy. Each one cost an LLM call, so
    /// the number belongs in front of anyone about to agree to it.
    var renderCount: Int { targets.filter(\.isUsable).count }

    /// Case-insensitive match over everything a person might type.
    func matches(_ query: String) -> Bool {
        guard !query.isEmpty else { return true }
        let needle = query.lowercased()
        return title.lowercased().contains(needle)
            || body.lowercased().contains(needle)
            || id.contains(needle)
            || category.lowercased().contains(needle)
            || tags.contains { $0.lowercased().contains(needle) }
    }
}

struct LibraryData: Decodable {
    let seeds: [Prompt]
    let models: [ModelRef]
    let history: [String: [String]]
    let categories: [String]
    /// Sent by `promptlib json` rather than hardcoded here, so the picker cannot
    /// drift from what the library will actually accept.
    let contexts: [ContextRef]

    struct ContextRef: Decodable, Hashable, Identifiable {
        let id: String
        let description: String

        /// Sentence-case label for a picker. Deriving it beats a second table
        /// that has to be kept in step with the ids.
        var label: String {
            switch id {
            case "agent": return "An agent with the repo open"
            case "chat":  return "A chat window with a snippet"
            default:      return id.capitalized
            }
        }
    }

    struct ModelRef: Decodable, Hashable, Identifiable {
        let id: String
        let name: String
        let family: String
        let guides: [String]
        let notes: String
    }
}

/// The order model columns appear in, left to right.
///
/// Stored rather than derived: the useful order is which models you actually
/// weigh against each other, and only you know that. Models not in the list
/// follow, in registry order, so adding one never hides it.
struct ModelOrder {
    static let key = "ModelOrder"

    static var stored: [String] {
        get { UserDefaults.standard.stringArray(forKey: key) ?? [] }
        set { UserDefaults.standard.set(newValue, forKey: key) }
    }

    static func sorted<T>(_ items: [T], id: (T) -> String) -> [T] {
        let order = stored
        guard !order.isEmpty else { return items }
        return items.enumerated().sorted { a, b in
            let rankA = order.firstIndex(of: id(a.element)) ?? Int.max
            let rankB = order.firstIndex(of: id(b.element)) ?? Int.max
            // Ties keep the original order, so unranked models stay stable.
            return rankA == rankB ? a.offset < b.offset : rankA < rankB
        }.map(\.element)
    }

    /// Move one model one place left or right within the given arrangement.
    static func move(_ id: String, by delta: Int, within current: [String]) {
        guard let index = current.firstIndex(of: id) else { return }
        let target = index + delta
        guard current.indices.contains(target) else { return }
        var next = current
        next.swapAt(index, target)
        stored = next
    }
}

/// Which models to show right now. Working with two models today should not mean
/// scrolling past seven — but the hidden ones stay in models.toml and keep their
/// renders, so this is a view filter and never destroys work.
struct ModelFilter {
    static let key = "VisibleModels"

    /// Empty means "everything", so a fresh install shows the whole registry.
    static var visible: Set<String> {
        get { Set(UserDefaults.standard.stringArray(forKey: key) ?? []) }
        set {
            UserDefaults.standard.set(Array(newValue).sorted(), forKey: key)
        }
    }

    static func isVisible(_ model: String) -> Bool {
        let set = visible
        return set.isEmpty || set.contains(model)
    }

    static func toggle(_ model: String, allKnown: [String]) {
        var set = visible
        if set.isEmpty { set = Set(allKnown) }        // start from "all shown"
        if set.contains(model) { set.remove(model) } else { set.insert(model) }
        if set.count == allKnown.count { set = [] }   // back to the "all" default
        visible = set
    }

    static func showAll() { UserDefaults.standard.removeObject(forKey: key) }
}

struct ComparisonData: Decodable {
    let id: String
    let summary: String
    let generated: String
    let state: String
}

enum LibraryError: LocalizedError {
    case rootMissing(String)
    case commandFailed(String)
    case badOutput(String)
    case noPython

    var errorDescription: String? {
        switch self {
        case .rootMissing(let detail):
            // Reason first, path last. These land in a two-line status bar, and
            // an absolute path under /private/tmp eats both lines before the
            // sentence that tells you what to do.
            return "That is not a Seedbed library: \(detail)"
        case .commandFailed(let detail):
            return detail
        case .badOutput(let detail):
            return "Could not read the library: \(detail)"
        case .noPython:
            return "No Python 3.11+ found. Install one (brew install python), or set "
                 + "the full path with: defaults write net.amnesia.seedbed PythonPath /path/to/python3"
        }
    }
}

/// Runs `python3 -m promptlib …` inside the library checkout.
struct LibraryClient {
    var root: URL

    static let defaultRoot = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Projects/seedbed")

    /// Why a library folder is a whole checkout rather than a folder of prompts.
    ///
    /// `promptlib/cli.py` sets its root from its OWN location
    /// (`Path(__file__).resolve().parent.parent`), and this app never passes
    /// `--root`. It sets the working directory instead, which works only because
    /// `python3 -m promptlib` puts the cwd on `sys.path`: the cwd decides which
    /// COPY of the package is imported, and that copy's location decides the
    /// library. So a folder without `promptlib/` is not a library, and pointing
    /// at one used to fail with `No module named promptlib` three actions later,
    /// which says nothing about what you did wrong.
    ///
    /// A symlinked `promptlib` is refused, and the reason is worth reading.
    /// `cli.py` resolves its root with `Path(__file__).resolve()`, which follows
    /// symlinks. So a folder whose `promptlib` is a link to another checkout
    /// reads and WRITES that other checkout while this app believes the library
    /// is here. Accepting it would be the retargeting failure through a different
    /// door.
    ///
    /// **`FileManager.fileExists(atPath:isDirectory:)` does not catch that**: it
    /// follows the link and reports the target's type, so a symlinked package
    /// comes back `isDirectory = true`. An earlier version of this function
    /// claimed the directory check handled symlinks and it did not; measured
    /// with `URLResourceValues` on a real symlink before this was rewritten.
    static func isLibrary(_ root: URL) -> Bool {
        whyNotALibrary(root) == nil
    }

    /// What is wrong with this folder, phrased so a person can act on it.
    ///
    /// The single definition; `isLibrary` is the boolean view of it, so the test
    /// and the message can never disagree about what a library is.
    static func whyNotALibrary(_ root: URL) -> String? {
        let package = root.appendingPathComponent("promptlib")

        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: package.path,
                                             isDirectory: &isDirectory) else {
            return "it has no promptlib/ folder. A Seedbed library is a clone of "
                 + "the seedbed repository, not a folder of prompt files."
        }
        let values = try? package.resourceValues(forKeys: [.isSymbolicLinkKey])
        if values?.isSymbolicLink == true {
            return "its promptlib/ is a symlink, so Seedbed would read and write "
                 + "the folder it points at rather than this one. Use a real "
                 + "clone."
        }
        guard isDirectory.boolValue else {
            return "its promptlib is a file, not a folder. A Seedbed library is "
                 + "a clone of the seedbed repository."
        }
        guard FileManager.default
            .fileExists(atPath: root.appendingPathComponent("models.toml").path)
        else {
            return "it has no models.toml, so there are no target models to "
                 + "build for."
        }
        return nil
    }

    /// An app launched from Finder inherits a minimal PATH (/usr/bin:/bin:...),
    /// NOT the shell's. `/usr/bin/env python3` therefore finds Xcode's Python
    /// 3.9, which has no `tomllib`, and every call fails with a traceback —
    /// while the same command works perfectly from a terminal. So the
    /// interpreter is resolved explicitly, and chosen by whether it can
    /// actually import what promptlib needs rather than by where it sits.
    static let pythonKey = "PythonPath"

    private static let candidates = [
        "/opt/homebrew/bin/python3",
        "/usr/local/bin/python3",
        "/opt/homebrew/bin/python3.14",
        "/opt/homebrew/bin/python3.13",
        "/opt/homebrew/bin/python3.12",
        "/opt/homebrew/bin/python3.11",
        "/usr/bin/python3",
    ]

    private static let log = Logger(subsystem: "net.amnesia.seedbed", category: "interpreter")

    /// Resolved once per launch; probing costs a process spawn each.
    ///
    /// **The first access decides which thread pays for up to seven synchronous
    /// process spawns**, and a lazy `static let` gives you no say in where that
    /// is. Every caller today reaches it from `Task.detached`, so it has never
    /// blocked the UI, but "every caller today" is not a property anyone
    /// maintains: the hazard is that a future refactor moves one call and the
    /// app freezes during launch, on a machine where the spawns are slow, for
    /// reasons nobody would connect to this.
    ///
    /// So it says so. `warmUpInterpreter()` makes the first access deliberate,
    /// the assertion catches a main-thread first touch in a debug build, and the
    /// log line catches it in a release one. Raised by the H1
    /// experiment: the tailored render spotted it while explaining this code and
    /// the raw seed did not.
    private static let resolvedPython: String? = {
        if Thread.isMainThread {
            log.error("""
                LibraryClient.resolvedPython was first touched on the main thread.                 It spawns up to \(candidates.count, privacy: .public) short-lived                 processes and will block the UI for as long as that takes. Call                 warmUpInterpreter() at launch, or reach it from a detached task.
                """)
            assertionFailure("resolvedPython must not be first touched on the main thread")
        }
        if let override = UserDefaults.standard.string(forKey: pythonKey),
           !override.isEmpty, canRunPromptlib(override) {
            return override
        }
        return candidates.first(where: canRunPromptlib)
    }()

    /// Resolve the interpreter off the main thread, before anything needs it.
    ///
    /// Called once at launch. Without it the first access is wherever the first
    /// library call happens to be, which is a property of the call graph rather
    /// than a decision.
    static func warmUpInterpreter() {
        Task.detached(priority: .utility) { _ = resolvedPython }
    }

    /// True when this interpreter has `tomllib`, which is the 3.11+ gate.
    private static func canRunPromptlib(_ path: String) -> Bool {
        guard FileManager.default.isExecutableFile(atPath: path) else { return false }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = ["-c", "import tomllib"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return false }
        process.waitUntilExit()
        return process.terminationStatus == 0
    }

    private func run(_ arguments: [String], timeout: TimeInterval = 600) throws -> String {
        // Checked here and not only at the picker, so every path gets the
        // explanation rather than just the one that chose the folder.
        if let reason = Self.whyNotALibrary(root) {
            throw LibraryError.rootMissing("\(reason) (\(root.lastPathComponent))")
        }
        guard let python = Self.resolvedPython else {
            throw LibraryError.noPython
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: python)
        process.arguments = ["-m", "promptlib"] + arguments
        process.currentDirectoryURL = root

        let out = Pipe(), err = Pipe()
        process.standardOutput = out
        process.standardError = err
        do { try process.run() } catch {
            throw LibraryError.commandFailed("could not start python3: \(error.localizedDescription)")
        }

        // Read before waiting: a full pipe buffer deadlocks a process that is
        // still writing, and a long render writes plenty.
        let outData = out.fileHandleForReading.readDataToEndOfFile()
        let errData = err.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            let message = String(data: errData, encoding: .utf8) ?? ""
            throw LibraryError.commandFailed(
                message.isEmpty ? "promptlib \(arguments.joined(separator: " ")) failed"
                                : message.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return String(data: outData, encoding: .utf8) ?? ""
    }

    func load() throws -> LibraryData {
        let text = try run(["json"])
        guard let data = text.data(using: .utf8) else {
            throw LibraryError.badOutput("output was not UTF-8")
        }
        do {
            return try JSONDecoder().decode(LibraryData.self, from: data)
        } catch {
            throw LibraryError.badOutput(error.localizedDescription)
        }
    }

    /// The tailored prompt itself, ready for the pasteboard. `record` bumps the
    /// copy counter in the same process, so a copy costs one spawn not two.
    func render(id: String, model: String, record: Bool = false) throws -> String {
        var arguments = ["show", id, "--model", model]
        if record { arguments.append("--record") }
        return try run(arguments).trimmingCharacters(in: .newlines)
    }

    func build(id: String, model: String) throws {
        _ = try run(["build", "--id", id, "--model", model])
    }

    /// Scoped rebuild: one pair, one prompt's models, or every stale pair.
    /// `--refresh` re-pulls the vendor guidance first, which is the point of a
    /// whole-library rebuild; a narrower one reuses the cached guidance.
    func rebuild(id: String?, model: String?) throws {
        var arguments = ["build", "--force"]
        if let id { arguments += ["--id", id] }
        if let model { arguments += ["--model", model] }
        if id == nil { arguments.append("--refresh") }
        _ = try run(arguments)
    }

    /// Write a seed. The body goes through a temporary file rather than an
    /// argument: prompts are multi-line, and quoting them across a process
    /// boundary is a bug waiting to happen.
    /// Sign in to ChatGPT. Opens a browser and blocks until the loopback
    /// callback lands or the flow times out, so it must not run on the main
    /// thread. The token never comes back through here — it goes straight into
    /// the Keychain on the Python side, and this returns only the status line.
    func codexLogin() throws -> String {
        try run(["enhancer", "login"], timeout: 360)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func codexLogout() throws -> String {
        try run(["enhancer", "logout"]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Who is signed in, or nil. Never carries a token.
    func codexWhoami() -> String? {
        guard let out = try? run(["enhancer", "whoami"]) else { return nil }
        let line = out.trimmingCharacters(in: .whitespacesAndNewlines)
        return line.hasPrefix("signed in as") ? line : nil
    }

    func save(id: String, title: String, body: String, category: String,
              targets: [String], context: String) throws -> String {
        let temp = FileManager.default.temporaryDirectory
            .appendingPathComponent("seedbed-\(UUID().uuidString).txt")
        defer { try? FileManager.default.removeItem(at: temp) }
        try body.write(to: temp, atomically: true, encoding: .utf8)

        var arguments = ["save", id, "--title", title, "--body-file", temp.path,
                         "--category", category, "--context", context]
        for target in targets { arguments += ["--target", target] }
        return try run(arguments).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Add or update a target model in models.toml.
    func saveModel(id: String, name: String, family: String,
                   guides: [String], notes: String, isNew: Bool) throws -> String {
        var arguments = [isNew ? "add" : "set", id, "--name", name,
                         "--family", family, "--notes", notes]
        for guide in guides where !guide.isEmpty { arguments += ["--guide", guide] }
        return try run(["model"] + arguments).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func removeModel(id: String) throws -> String {
        try run(["model", "remove", id]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The enhancer configuration. Key VALUES never cross this boundary — the
    /// JSON reports only whether one is stored.
    func enhancerConfig() throws -> EnhancerConfigData {
        let text = try run(["enhancer", "show", "--json"])
        guard let data = text.data(using: .utf8) else {
            throw LibraryError.badOutput("enhancer config was not UTF-8")
        }
        return try JSONDecoder().decode(EnhancerConfigData.self, from: data)
    }

    /// A nil key means "leave the stored one alone"; an empty string clears it.
    func setEnhancer(auth: String, endpoint: String, model: String, key: String?,
                     timeout: Int, fallbackEndpoint: String, fallbackModel: String,
                     fallbackKey: String?) throws -> String {
        var arguments = ["enhancer", "set", "--auth", auth, "--endpoint", endpoint,
                         "--model", model, "--timeout", String(timeout),
                         "--fallback-endpoint", fallbackEndpoint,
                         "--fallback-model", fallbackModel]
        if let key { arguments += ["--key", key] }
        if let fallbackKey { arguments += ["--fallback-key", fallbackKey] }
        return try run(arguments).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func testEnhancer() throws -> String {
        try run(["enhancer", "test"]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The written comparison of a prompt's renders. Cached by the CLI against
    /// a hash of the renders, so this is cheap unless something moved.
    func comparison(id: String, force: Bool = false) throws -> ComparisonData {
        var arguments = ["compare", id, "--json"]
        if force { arguments.append("--force") }
        let text = try run(arguments)
        guard let data = text.data(using: .utf8) else {
            throw LibraryError.badOutput("comparison was not UTF-8")
        }
        return try JSONDecoder().decode(ComparisonData.self, from: data)
    }

    /// Find the prompt an ask means, by description rather than by name.
    /// Returns the raw JSON from `promptlib match`, which the MCP server hands
    /// straight to its caller — re-shaping it here would mean two definitions
    /// of the answer.
    func match(ask: String, model: String, limit: Int, semantic: Bool,
               record: Bool) throws -> String {
        var arguments = ["match", ask, "--json", "--limit", String(limit)]
        if !semantic { arguments.append("--no-semantic") }
        if !model.isEmpty {
            arguments += ["--model", model]
            if record { arguments.append("--record") }
        }
        return try run(arguments).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func remove(id: String) throws -> String {
        try run(["remove", id]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func pin(id: String) throws {
        _ = try run(["pin", id, "--toggle"])
    }

    /// A render with its placeholders substituted. One spawn does the fill, the
    /// history write and the usage bump.
    func fill(id: String, model: String, values: [String: String]) throws -> String {
        var arguments = ["fill", id, "--model", model, "--record"]
        for (name, value) in values.sorted(by: { $0.key < $1.key }) {
            arguments += ["--set", "\(name)=\(value)"]
        }
        return try run(arguments).trimmingCharacters(in: .newlines)
    }
}
