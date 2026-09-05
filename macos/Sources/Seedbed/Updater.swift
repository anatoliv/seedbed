import AppKit
import Sparkle

/// Auto-update, for the copies that can actually use it.
///
/// **Seedbed has two kinds of copy and they update differently**, which is the
/// whole reason this is not simply Sparkle's standard controller wired to a menu
/// item. A copy built out of the library checkout is rebuilt with
/// `make-app.sh`; offering it a signed release from the feed would replace the
/// build under development with whatever last shipped, silently discarding the
/// thing being worked on. A copy installed from a release DMG has no toolchain
/// and no checkout of its own, and the feed is the only way it will ever hear
/// about a new version.
///
/// So `Updates.check` still answers for a built copy, and Sparkle answers for an
/// installed one. `AppController` routes between them.
///
/// **What Sparkle does not update, and it is most of the product.** This app is
/// a front end: the prompts, the renders and the Python that reads them live in
/// a git checkout, and Sparkle replaces an `.app` bundle. An installed copy that
/// has auto-updated is still pointing at whatever the checkout was last pulled
/// to, and still needs a Python 3.11+ that no updater can install. That is a
/// property of the architecture rather than a gap in this file, and it is why
/// `Updates.check` remains reachable rather than being replaced outright.
@MainActor
final class Updater {
    /// Nil when this build has no feed configured, which is every locally built
    /// copy: the tracked Info.plist carries no `SUFeedURL` value worth using
    /// until a release sets one.
    private let controller: SPUStandardUpdaterController?

    init() {
        // Sparkle reads SUFeedURL and SUPublicEDKey from the bundle. Starting
        // the updater in a bundle that has neither logs an error on every
        // launch and can present a failure dialog to someone who never asked
        // for an update, so it is not started at all.
        guard Self.isConfigured else {
            controller = nil
            return
        }
        controller = SPUStandardUpdaterController(startingUpdater: true,
                                                  updaterDelegate: nil,
                                                  userDriverDelegate: nil)
    }

    /// Whether this bundle carries a feed Sparkle can use.
    static var isConfigured: Bool {
        guard let feed = Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") as? String,
              !feed.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let key = Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") as? String,
              !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return false }
        return true
    }

    var canCheck: Bool { controller != nil }

    /// A user-initiated check.
    ///
    /// The activate is not optional. As an accessory app Seedbed is never the
    /// active application, so without it Sparkle's window opens *behind* the
    /// frontmost app and the menu item looks like it did nothing — a second
    /// click then only raises the session already running. Scheduled background
    /// checks do not come through here and stay quiet on purpose.
    func checkForUpdates() {
        NSApp.activate(ignoringOtherApps: true)
        controller?.checkForUpdates(nil)
    }
}
