import Foundation
import OSLog
import Sentry

/// Remote crash and error reporting, for builds that leave this Mac.
///
/// **Two gates, both required.** Reporting starts only when the user has turned
/// it on (Settings → Diagnostics, default OFF) *and* a DSN was baked into the
/// build at package time (`Info.plist` → `CrashReportingDSN`, injected by
/// `make-app.sh` from one gitignored source and never committed). A build with no
/// DSN cannot report no matter what the toggle says, so a locally built copy —
/// which is every copy on this machine — never phones home, and a distributed
/// copy stays silent until someone consents.
///
/// **What Seedbed must never send.** The library is prompt text: seeds, renders,
/// filled-in variable values. None of it is captured here, and the scrubbing
/// below is the second line rather than the first. The first is that nothing
/// calls `capture` with library content — `LibraryError.commandFailed` carries
/// `promptlib` stderr, which can quote a prompt, and it is deliberately reported
/// to the user in the UI and not to the reporter. The MCP bearer tokens are the other
/// thing worth losing sleep over, so a 32-or-longer hex run is redacted wherever
/// it appears.
enum CrashReporting {
    /// UserDefaults key for the opt-in toggle (app domain `net.amnesia.seedbed`).
    /// Absent or `false` keeps reporting off, which is the default state.
    static let enabledKey = "CrashReportingEnabled"

    private static let log = Logger(subsystem: "net.amnesia.seedbed", category: "diagnostics")

    static var isEnabled: Bool { UserDefaults.standard.bool(forKey: enabledKey) }

    /// How many events one launch may send, ever.
    ///
    /// A server quota is not a client-side safety boundary: it can be shared,
    /// delayed, changed, or exhausted by another project. The app therefore owns
    /// a fixed local ceiling regardless of whether the selected endpoint is
    /// Crashbox or the hosted-Sentry rollback.
    ///
    /// Twenty is chosen to be useless for a crash loop and sufficient for a
    /// crash: the first fault of a session is what gets diagnosed, and the
    /// two-thousandth repetition of it says nothing the first did not.
    static let perLaunchBudget = 20
    static let initializationWait: TimeInterval = 1
    static let canaryFlushTimeout: TimeInterval = 2

    private static let budgetLock = NSLock()
    private static var sentThisLaunch = 0
    private static let attemptGate = ReportingAttemptGate()
    private static let queue = DispatchQueue(label: "net.amnesia.seedbed.crash-reporting",
                                             qos: .utility)

    /// True while there is budget left, counting this event. `beforeSend` is
    /// called off the main thread and from more than one of them, so the
    /// counter is locked rather than hoped about.
    private static func withinBudget() -> Bool {
        budgetLock.lock()
        defer { budgetLock.unlock() }
        guard sentThisLaunch < perLaunchBudget else { return false }
        sentThisLaunch += 1
        return true
    }

    /// Whether this build could report at all — i.e. whether a DSN is baked in.
    /// The Settings pane says so, because a toggle that does nothing is worse
    /// than an absent one.
    static var isConfigured: Bool { configuration != nil }

    struct Configuration: Equatable {
        let dsn: String
        let provider: String
        let release: String
        let environment: String
    }

    /// Reporting fails closed unless packaging supplied the endpoint and all
    /// immutable identity fields together. Crashbox and hosted Sentry are
    /// mutually exclusive values of `provider`; the SDK has only one client.
    private static var configuration: Configuration? {
        configuration(from: Bundle.main.infoDictionary ?? [:])
    }

    static func configuration(from info: [String: Any]) -> Configuration? {
        func value(_ key: String) -> String? {
            guard let raw = info[key] as? String else { return nil }
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
        guard let dsn = value("CrashReportingDSN"),
              let url = URLComponents(string: dsn),
              url.scheme == "https",
              url.host?.isEmpty == false,
              url.user?.isEmpty == false,
              url.password == nil,
              url.query == nil,
              url.fragment == nil,
              !url.path.isEmpty, url.path != "/",
              let provider = value("CrashReportingProvider"),
              provider == "crashbox" || provider == "hosted-sentry",
              let release = value("CrashReportingRelease"),
              release.range(of: #"^net\.amnesia\.seedbed@[0-9a-f]{40}$"#,
                            options: .regularExpression) != nil,
              let environment = value("CrashReportingEnvironment"),
              environment.range(of: #"^[a-z0-9][a-z0-9._-]{0,63}$"#,
                                options: .regularExpression) != nil else { return nil }
        return Configuration(dsn: dsn, provider: provider,
                             release: release, environment: environment)
    }

    /// Start at launch, only if opted in. A no-op otherwise.
    static func start() {
        guard isEnabled, let configuration else { return }
        queue.async {
            guard isEnabled else { return }
            startSDKOnce(configuration)
        }
    }

    /// React to the Settings toggle without a relaunch.
    static func apply(enabled: Bool) {
        if enabled {
            guard let configuration else { return }
            queue.async { startSDKOnce(configuration) }
        } else {
            queue.async {
                SentrySDK.close()
                attemptGate.resetAfterExplicitDisable()
                log.info("crash reporting disabled by user")
            }
        }
    }

    /// Runs on the private utility queue. `ReportingAttemptGate` catches any
    /// recoverable adapter failure and permanently fuses automatic retries for
    /// this enable cycle. The application and its UI never wait for this work.
    private static func startSDKOnce(_ configuration: Configuration) {
        let outcome = attemptGate.runOnce {
            SentrySDK.start { options in
                options.dsn = configuration.dsn
                // SDK diagnostics are explicit, never a production default.
                options.debug = ProcessInfo.processInfo.environment["SEEDBED_SENTRY_DEBUG"] == "1"
                options.sendDefaultPii = false      // no IP, user ids, or bodies
                options.releaseName = configuration.release
                options.environment = configuration.environment
                options.shutdownTimeInterval = 0
                options.tracesSampleRate = 0.0      // crashes and errors only
                options.configureProfiling = { profiling in
                    profiling.sessionSampleRate = 0
                    profiling.profileAppStarts = false
                }
                options.enableAutoSessionTracking = false
                options.enableWatchdogTerminationTracking = false
                options.enableAppHangTracking = false
                options.enableAutoPerformanceTracing = false
                options.enableNetworkTracking = false
                options.enableFileIOTracing = false
                options.enableCoreDataTracing = false
                options.enableTimeToFullDisplayTracing = false
                options.enableAutoBreadcrumbTracking = false
                options.sendClientReports = false
                options.maxBreadcrumbs = 0
                options.maxCacheItems = UInt(perLaunchBudget)
                options.beforeSend = { event in
                    // Budget first: an event dropped here costs nothing, and
                    // scrubbing is wasted work on something nobody will read.
                    guard withinBudget() else { return nil }
                    return scrub(event)
                }
                options.beforeBreadcrumb = { redact($0) }
            }
        }
        switch outcome {
        case .started: log.info("crash reporting started")
        case .failed: log.error("crash reporting unavailable; application continues")
        case .idle: break
        }
    }

    /// Everything the promise on the download page says a report does not
    /// carry, applied to one event.
    ///
    /// It is a named function rather than the body of the `beforeSend` closure
    /// because a closure handed to `SentrySDK.start` can only be run by
    /// starting the SDK, and a test that starts the SDK is a test that can send
    /// something. Asked as a function it is an ordinary value question, which
    /// is the same reason `TestCrash.decision` and `configuration(from:)` are
    /// shaped the way they are. `CrashReportingScrubbingTests` runs it;
    /// `tests/test_crash_reporting.py` pins that `beforeSend` still calls it,
    /// because a scrubber nothing is wired to passes its own tests forever.
    static func scrub(_ event: Event) -> Event {
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

    /// Internal rather than private so a test can run the `beforeBreadcrumb`
    /// path, which is otherwise reachable only through a started SDK.
    static func redact(_ crumb: Breadcrumb) -> Breadcrumb {
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

    /// Brings the SDK up so that a deliberate crash is caught, and answers
    /// whether it actually came up.
    ///
    /// The crash handler is installed by `SentrySDK.start`, so a crash fired
    /// before that returns is an ordinary crash that nobody hears about. The
    /// wait is the same bounded one `captureTestEvent` uses, and for the same
    /// reason: initialization is deliberately off the main thread, so the caller
    /// has to wait for it rather than assume it.
    ///
    /// Consent works the way it already does for `captureTestEvent`. Typing
    /// `--crash-test`, or holding Option and confirming a dialog that says what
    /// is about to happen, is the explicit request that the Settings toggle
    /// exists to obtain for the automatic case. The DSN gate is not waived: with
    /// no configuration this returns false and sends nothing.
    ///
    /// Blocks the calling thread for up to `initializationWait`. Never call it
    /// from the main thread.
    static func prepareForTestCrash() -> Bool {
        guard let configuration else { return false }
        startSDKOnce(configuration)
        let deadline = Date().addingTimeInterval(initializationWait)
        while !SentrySDK.isEnabled && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.01)
        }
        return attemptGate.current() == .started && SentrySDK.isEnabled
    }

    /// Runs `work` on the private reporting queue. The test-crash trigger needs
    /// `prepareForTestCrash` off the main thread, and this is the only queue the
    /// SDK is ever started from.
    static func onReportingQueue(_ work: @escaping () -> Void) {
        queue.async(execute: work)
    }

    /// Sends one event so the wiring can be checked end to end against the real
    /// project, rather than assumed from the absence of a compiler error.
    /// Driven by `SEEDBED_TEST_CRASH_REPORTING=1`, the same way the menu dump is.
    static func captureTestEvent(completion: @escaping () -> Void) {
        queue.async {
            defer { DispatchQueue.main.async(execute: completion) }
            guard let configuration else {
                print("SEEDBED_TEST_CRASH_REPORTING: no complete reporting configuration, nothing sent.")
                return
            }
            // Show the scrubber doing its job on the two things that must never
            // leave, using the shipped function rather than a description of it.
            let sample = "opening \(NSHomeDirectory())/Library/Application Support/Seedbed/Library with token "
                       + "a1b2c3d4e5f60718293a4b5c6d7e8f90a1b2c3d4e5f60718293a4b5c6d7e8f90"
            print("SEEDBED_TEST_CRASH_REPORTING: scrubber in:  \(sample)")
            print("SEEDBED_TEST_CRASH_REPORTING: scrubber out: \(redact(sample))")

            startSDKOnce(configuration) // explicit test consent; still one attempt
            let initializationDeadline = Date().addingTimeInterval(initializationWait)
            while !SentrySDK.isEnabled && Date() < initializationDeadline {
                Thread.sleep(forTimeInterval: 0.01)
            }
            guard attemptGate.current() == .started, SentrySDK.isEnabled else {
                print("SEEDBED_TEST_CRASH_REPORTING: initialization unavailable, nothing sent.")
                return
            }
            let eventId = SentrySDK.capture(message: "Seedbed crash-reporting wiring test")
            SentrySDK.flush(timeout: canaryFlushTimeout)
            print("SEEDBED_TEST_CRASH_REPORTING: event_id=\(eventId.sentryIdString) provider=\(configuration.provider) "
                + "release=\(configuration.release) flush_completed=true")
        }
    }
}
