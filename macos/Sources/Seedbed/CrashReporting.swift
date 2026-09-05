import Foundation
import OSLog
import Sentry

/// Remote crash and error reporting, for builds that leave this Mac.
///
/// **Two gates, both required.** Reporting starts only when the user has turned
/// it on (Settings → Diagnostics, default OFF) *and* a DSN was baked into the
/// build at package time (`Info.plist` → `SentryDSN`, injected by
/// `make-app.sh` from a gitignored source and never committed). A build with no
/// DSN cannot report no matter what the toggle says, so a locally built copy —
/// which is every copy on this machine — never phones home, and a distributed
/// copy stays silent until someone consents.
///
/// **What Seedbed must never send.** The library is prompt text: seeds, renders,
/// filled-in variable values. None of it is captured here, and the scrubbing
/// below is the second line rather than the first. The first is that nothing
/// calls `capture` with library content — `LibraryError.commandFailed` carries
/// `promptlib` stderr, which can quote a prompt, and it is deliberately reported
/// to the user in the UI and not to Sentry. The MCP bearer tokens are the other
/// thing worth losing sleep over, so a 32-or-longer hex run is redacted wherever
/// it appears.
enum CrashReporting {
    /// UserDefaults key for the opt-in toggle (app domain `net.amnesia.seedbed`).
    /// Absent or `false` keeps reporting off, which is the default state.
    static let enabledKey = "CrashReportingEnabled"

    private static let log = Logger(subsystem: "net.amnesia.seedbed", category: "diagnostics")

    static var isEnabled: Bool { UserDefaults.standard.bool(forKey: enabledKey) }

    /// Whether this build could report at all — i.e. whether a DSN is baked in.
    /// The Settings pane says so, because a toggle that does nothing is worse
    /// than an absent one.
    static var isConfigured: Bool { dsn != nil }

    private static var dsn: String? {
        guard let raw = Bundle.main.object(forInfoDictionaryKey: "SentryDSN") as? String else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// Start at launch, only if opted in. A no-op otherwise.
    static func start() {
        guard isEnabled else { return }
        startSDK()
    }

    /// React to the Settings toggle without a relaunch.
    static func apply(enabled: Bool) {
        if enabled {
            startSDK()
        } else {
            SentrySDK.close()
            log.info("crash reporting disabled by user")
        }
    }

    private static func startSDK() {
        guard let dsn else { return }       // no DSN baked in → stays off
        SentrySDK.start { options in
            options.dsn = dsn
            // The SDK is silent by default, including about a rejected DSN or a
            // transport that never sends. `SEEDBED_SENTRY_DEBUG=1` makes it say
            // so, which is the only way to tell "sent and accepted" from "sent
            // nowhere" without waiting on a dashboard that may never fill in.
            options.debug = ProcessInfo.processInfo.environment["SEEDBED_SENTRY_DEBUG"] == "1"
            options.sendDefaultPii = false          // no IP, no user ids, no bodies
            options.releaseName = release
            #if DEBUG
            options.environment = "debug"
            #else
            options.environment = "release"
            #endif
            options.tracesSampleRate = 0.0          // crashes and errors only
            options.beforeSend = { event in
                event.user = nil
                event.serverName = nil
                event.request = nil
                event.extra = nil
                if let formatted = event.message?.formatted {
                    event.message = SentryMessage(formatted: redact(formatted))
                }
                event.breadcrumbs = event.breadcrumbs?.map(redact)
                return event
            }
            options.beforeBreadcrumb = { redact($0) }
        }
        log.info("crash reporting started")
    }

    private static func redact(_ crumb: Breadcrumb) -> Breadcrumb {
        if let message = crumb.message { crumb.message = redact(message) }
        crumb.data = nil                            // arbitrary payloads, none of them needed
        return crumb
    }

    /// Replaces the home directory with `~` (it carries the account name) and
    /// any long hex run with a placeholder (that is the shape of an MCP bearer
    /// token, and a leaked one spends LLM calls).
    static func redact(_ s: String) -> String {
        var out = s
        let home = NSHomeDirectory()
        if !home.isEmpty { out = out.replacingOccurrences(of: home, with: "~") }
        return out.replacingOccurrences(of: "[0-9a-fA-F]{32,}",
                                        with: "«redacted»",
                                        options: .regularExpression)
    }

    /// `net.amnesia.seedbed@<version>+<build>` — the conventional release id, and
    /// the one `sentry-cli` associates the uploaded dSYMs with.
    private static var release: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "0"
        let build = info?["CFBundleVersion"] as? String ?? "0"
        return "net.amnesia.seedbed@\(version)+\(build)"
    }

    /// Sends one event so the wiring can be checked end to end against the real
    /// project, rather than assumed from the absence of a compiler error.
    /// Driven by `SEEDBED_TEST_SENTRY=1`, the same way the menu dump is.
    static func captureTestEvent() {
        guard isConfigured else {
            print("SEEDBED_TEST_SENTRY: no DSN baked into this build — nothing sent.")
            return
        }
        // Show the scrubber doing its job on the two things that must never
        // leave, using the shipped function rather than a description of it.
        let sample = "opening \(NSHomeDirectory())/Projects/seedbed with token "
                   + "a1b2c3d4e5f60718293a4b5c6d7e8f90a1b2c3d4e5f60718293a4b5c6d7e8f90"
        print("SEEDBED_TEST_SENTRY: scrubber in:  \(sample)")
        print("SEEDBED_TEST_SENTRY: scrubber out: \(redact(sample))")

        if !isEnabled { startSDK() }        // a test is consent for this one run
        SentrySDK.capture(message: "Seedbed Sentry wiring test")
        SentrySDK.flush(timeout: 10)
        print("SEEDBED_TEST_SENTRY: event flushed for release \(release).")
    }
}
