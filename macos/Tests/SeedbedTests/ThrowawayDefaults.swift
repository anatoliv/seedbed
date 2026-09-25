import Foundation

/// A `UserDefaults` suite for one test, gone once the test process is.
///
/// `MCPPortCollisionTests` used to mint `net.amnesia.seedbed.tests.<UUID>` per test and
/// clean up with `removePersistentDomain(forName:)`, which empties the domain and leaves
/// the file. `cfprefsd` then writes an empty `{}` plist back about ten seconds after the
/// process exits, whatever the process did first, and every run left one file per test in
/// `~/Library/Preferences` (the same leak reached 20,262 files in the app this pattern was
/// first written for). A delete made after that rewrite sticks, so cleanup happens
/// three times:
///
/// - at exit, each suite this process made is emptied and its file deleted;
/// - a detached shell then waits ``lateCleanupDelay`` and deletes the same files again,
///   which removes the stub `cfprefsd` writes after the process is gone; and
/// - the first time a process asks for a suite, every file in ``namespace`` older than
///   ``staleAge`` is removed, which catches a run that was killed before its exit ran.
///
/// Every name is ``namespace`` + label + UUID, and the sweep matches nothing else, so it
/// cannot touch the app's own preferences or a suite a concurrent run is still using.
/// `tests/test_throwaway_defaults_guard.py` refuses any other way for a test to open one.
enum ThrowawayDefaults {
    static let namespace = "net.amnesia.seedbed.tests.throwaway."

    /// The Swift suite runs in well under a minute; ten covers a slow machine.
    static let staleAge: TimeInterval = 10 * 60

    /// Well past the roughly ten seconds `cfprefsd` takes to write its stub.
    static let lateCleanupDelay: TimeInterval = 30

    /// A fresh suite named `<namespace><label>.<UUID>`, and that name.
    static func suite(_ label: String) -> (name: String, defaults: UserDefaults) {
        let name = "\(namespace)\(label).\(UUID().uuidString)"
        registry.register(name)
        return (name, UserDefaults(suiteName: name)!)
    }

    static func make(_ label: String) -> UserDefaults { suite(label).defaults }

    /// Empty and delete every suite this process made, then schedule the late delete.
    static func removeAll() {
        var paths: [String] = []
        for name in registry.drain() {
            UserDefaults(suiteName: name)?.removePersistentDomain(forName: name)
            let url = preferencesDirectory.appendingPathComponent("\(name).plist")
            try? FileManager.default.removeItem(at: url)
            paths.append(url.path)
        }
        removeLater(paths, after: lateCleanupDelay)
    }

    /// Delete `paths` again after `delay`, from a process that outlives this one.
    static func removeLater(_ paths: [String], after delay: TimeInterval) {
        let owned = paths.filter { isThrowawayPlist(URL(fileURLWithPath: $0).lastPathComponent) }
        guard !owned.isEmpty else { return }
        let cleaner = Process()
        cleaner.executableURL = URL(fileURLWithPath: "/bin/sh")
        cleaner.arguments = ["-c", "trap '' HUP INT TERM; sleep \(Int(delay.rounded(.up))); rm -f -- \"$@\"",
                             "throwaway-defaults-cleaner"] + owned
        cleaner.standardInput = FileHandle.nullDevice
        cleaner.standardOutput = FileHandle.nullDevice
        cleaner.standardError = FileHandle.nullDevice
        try? cleaner.run()
    }

    /// Remove every throwaway plist in `directory` last modified before `now - age`.
    @discardableResult
    static func sweepStale(in directory: URL, olderThan age: TimeInterval,
                           now: Date = Date()) -> Int {
        let fm = FileManager.default
        var removed = 0
        for file in (try? fm.contentsOfDirectory(atPath: directory.path)) ?? []
        where isThrowawayPlist(file) {
            let url = directory.appendingPathComponent(file)
            guard let modified = (try? fm.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date,
                  now.timeIntervalSince(modified) > age else { continue }
            if (try? fm.removeItem(at: url)) != nil { removed += 1 }
        }
        return removed
    }

    /// `<namespace><label>.<UUID>.plist`, and nothing else.
    static func isThrowawayPlist(_ file: String) -> Bool {
        guard file.hasPrefix(namespace), file.hasSuffix(".plist") else { return false }
        let stem = file.dropLast(".plist".count)
        guard stem.count > namespace.count + 37 else { return false }
        return UUID(uuidString: String(stem.suffix(36))) != nil && stem.dropLast(36).hasSuffix(".")
    }

    static var preferencesDirectory: URL {
        URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
            .appendingPathComponent("Library/Preferences", isDirectory: true)
    }

    private static let registry = Registry()

    private final class Registry: @unchecked Sendable {
        private let lock = NSLock()
        private var names: [String] = []
        private var started = false

        func register(_ name: String) {
            lock.lock()
            let first = !started
            started = true
            names.append(name)
            lock.unlock()
            guard first else { return }
            atexit { ThrowawayDefaults.removeAll() }
            ThrowawayDefaults.sweepStale(in: ThrowawayDefaults.preferencesDirectory,
                                         olderThan: ThrowawayDefaults.staleAge)
        }

        func drain() -> [String] {
            lock.lock()
            defer { lock.unlock() }
            let taken = names
            names.removeAll()
            return taken
        }
    }
}
