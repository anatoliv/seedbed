import AppKit
import ServiceManagement

/// "Check for Updates…" for a copy you built yourself.
///
/// There IS a Sparkle feed now, and `Updater` serves the copies installed from
/// it. This half answers for a copy built out of the checkout, where an update
/// means the repository has commits this build does not — Sparkle would offer
/// such a copy the last shipped release and quietly replace the work in
/// progress. `AppController.checkForUpdates` routes between the two.
///
/// It stays reachable for installed copies too, through the same result text,
/// because Sparkle updates an `.app` and this app is a front end: the prompts,
/// the renders and the Python that reads them are in a checkout no updater
/// touches.
@MainActor
enum Updates {
    struct Result {
        let title: String
        let detail: String
        let behind: Int
    }

    static func check(root: URL) -> Result {
        guard FileManager.default.fileExists(atPath: root.appendingPathComponent(".git").path) else {
            return Result(title: "Not a git checkout",
                          detail: "\(root.path) has no .git, so there is nothing to compare "
                                + "this build against.",
                          behind: 0)
        }
        let (fetchOK, fetchErr) = git(["fetch", "--quiet"], in: root)
        guard fetchOK else {
            return Result(title: "Could not reach the remote",
                          detail: fetchErr.isEmpty ? "git fetch failed." : fetchErr,
                          behind: 0)
        }
        let (ok, output) = git(["rev-list", "--count", "HEAD..@{upstream}"], in: root)
        guard ok, let behind = Int(output.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            return Result(title: "No upstream branch",
                          detail: "This checkout has no tracking branch to compare against.",
                          behind: 0)
        }
        if behind == 0 {
            let (_, local) = git(["log", "-1", "--format=%h %s"], in: root)
            return Result(title: "Seedbed is up to date",
                          detail: "Version \(InfoWindows.version).\nAt \(local.trimmingCharacters(in: .newlines)).",
                          behind: 0)
        }
        let (_, log) = git(["log", "--oneline", "-5", "HEAD..@{upstream}"], in: root)
        return Result(
            title: "\(behind) commit\(behind == 1 ? "" : "s") available",
            detail: "\(log.trimmingCharacters(in: .newlines))\n\n"
                  + "To take them:\n  cd \(root.path)\n  git pull\n"
                  + (wasBuiltFrom(root) ? "  macos/Scripts/make-app.sh\n\n"
                       + "The app must be rebuilt: pulling alone changes the library, "
                       + "not this binary."
                     : "\nThat updates the library, which is what most commits change. "
                       + "This copy of the app was installed rather than built here, so "
                       + "the app itself changes when a newer release is installed over "
                       + "it."),
            behind: behind)
    }

    /// Whether this running copy was built out of the library checkout, which
    /// decides what "take the update" means.
    ///
    /// A copy built here is rebuilt with `make-app.sh` and needs the Swift
    /// toolchain. A copy installed from a release DMG is in /Applications with
    /// no toolchain in sight, and telling that one to run a build script is
    /// advice it cannot follow. Compared by path prefix rather than by asking
    /// whether the app is in /Applications: the distinguishing fact is whether
    /// the binary came out of THIS checkout, and someone can keep a built copy
    /// anywhere.
    static func wasBuiltFrom(_ root: URL) -> Bool {
        let bundle = Bundle.main.bundleURL.resolvingSymlinksInPath().path
        let checkout = root.resolvingSymlinksInPath().path
        return bundle.hasPrefix(checkout.hasSuffix("/") ? checkout : checkout + "/")
    }

    private static func git(_ arguments: [String], in root: URL) -> (Bool, String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = arguments
        process.currentDirectoryURL = root
        let out = Pipe(), err = Pipe()
        process.standardOutput = out
        process.standardError = err
        do { try process.run() } catch { return (false, "could not run git") }
        let outData = out.fileHandleForReading.readDataToEndOfFile()
        let errData = err.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let text = String(data: outData, encoding: .utf8) ?? ""
        let errText = String(data: errData, encoding: .utf8) ?? ""
        return (process.terminationStatus == 0, text.isEmpty ? errText : text)
    }
}

/// Start at login, so the hot key is live without remembering to launch it.
@MainActor
enum LaunchAtLogin {
    static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    /// Returns an error message, or nil on success. Registration fails for an
    /// app that is not in /Applications on some systems, so the caller has to
    /// be able to say why rather than silently doing nothing.
    static func set(_ enabled: Bool) -> String? {
        do {
            if enabled { try SMAppService.mainApp.register() }
            else { try SMAppService.mainApp.unregister() }
            return nil
        } catch {
            return error.localizedDescription
        }
    }
}
