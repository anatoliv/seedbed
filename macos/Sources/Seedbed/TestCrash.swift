import AppKit
import Darwin
import Foundation

/// The deliberate crash, and the two gates in front of it.
///
/// **Why a real crash and not `SentrySDK.capture`.** The thing being proved is
/// the crash path: the signal handler catching a fault, a report written to
/// disk while the process is dying, and that report being sent on the next
/// launch and symbolicated back to a Seedbed function. A captured message
/// exercises none of that, which is why `captureTestEvent` in `CrashReporting`
/// could pass while the crash handler was never installed.
///
/// **What sentry-cocoa actually catches.** `SentryCrashMonitorType.h` in the
/// pinned 8.58.4 checkout installs four monitors: Mach exception, POSIX signal,
/// uncaught C++ exception, uncaught `NSException`. `seedbedTestCrash()` writes
/// to an address in the first page of the address space, which the kernel never
/// maps, so the fault is `EXC_BAD_ACCESS` and the Mach exception monitor takes
/// it with the faulting frame on top. `abort()` follows as a backstop, because
/// a compiler that somehow elided the store would otherwise leave the app
/// running and the operator waiting for an event that is never coming; `SIGABRT`
/// is caught by the signal monitor.
///
/// **Two gates, and neither is the reporting toggle.** The trigger is inert
/// unless this build carries a complete reporting configuration, so a copy
/// built out of the checkout cannot be made to crash by anyone who finds the
/// argument. It also refuses while a debugger is attached, because a traced
/// process gives its exceptions to the debugger and the report would never be
/// written.
enum TestCrash {
    /// The launch argument that arms the trigger.
    ///
    /// A `--flag` rather than a `-Key value` pair on purpose: the second form is
    /// AppKit's argument domain for `UserDefaults`, so it would leave a value
    /// visible to every `bool(forKey:)` in the app and read as a preference
    /// rather than as a one-shot request.
    static let launchArgument = "--crash-test"

    /// The address `seedbedTestCrash()` writes to.
    ///
    /// Not zero: `UnsafeMutablePointer(bitPattern: 0)` is `nil`, so a zero here
    /// would trap on the force-unwrap instead, and a Swift runtime trap carries
    /// a different exception type and no useful message once the app is
    /// optimized. Any address below the page size does the job, because macOS
    /// leaves the first page unmapped precisely so that dereferencing a null-ish
    /// pointer faults.
    static let faultAddress = 1

    /// What a launch should do about the argument. A value rather than a branch,
    /// because the only way to test a branch that ends in a crash is to crash.
    enum Decision: Equatable {
        /// The argument is absent. Every ordinary launch, and every test run.
        case notRequested
        /// Asked for, but this build has no reporting configuration, so the
        /// crash would go nowhere.
        case refusedNoProvider
        /// Asked for, but the Diagnostics toggle is off. The crash would be
        /// written and never sent, because sending happens on the next launch
        /// and the next launch would not start the SDK.
        case refusedNotEnabled
        /// Asked for, but a debugger owns this process's exceptions.
        case refusedDebugger
        /// Asked for, and the report will be written and sent on the next launch.
        case crash
    }

    /// Four questions, in the order the answers are useful.
    ///
    /// The Diagnostics toggle is in here even though this trigger is an explicit
    /// request and does not need the toggle to start the SDK for itself. A crash
    /// is not delivered by the process that crashes: sentry-cocoa writes the
    /// report to disk and sends it on the following launch, and that launch
    /// starts the SDK only if the toggle is on. Firing with it off destroys the
    /// app and produces nothing, which is the most expensive way to learn a
    /// setting was off.
    static func decision(arguments: [String],
                         isConfigured: Bool,
                         isReportingEnabled: Bool,
                         isBeingDebugged: Bool) -> Decision {
        guard arguments.contains(launchArgument) else { return .notRequested }
        guard isConfigured else { return .refusedNoProvider }
        guard isReportingEnabled else { return .refusedNotEnabled }
        guard !isBeingDebugged else { return .refusedDebugger }
        return .crash
    }

    /// Whether the status-item menu shows the trigger this time it opens.
    ///
    /// Read from the modifiers held at the moment the menu is built, so the item
    /// exists only for someone who already knows to hold Option. The provider
    /// gate is repeated here rather than left to the action: an item that is
    /// visible and then refuses is an invitation to keep trying it.
    static func menuItemIsVisible(modifiers: NSEvent.ModifierFlags,
                                  isConfigured: Bool) -> Bool {
        isConfigured && modifiers.contains(.option)
    }

    /// The title of that item. An ellipsis because a confirmation follows, which
    /// is what an ellipsis promises.
    static let menuItemTitle = "Send a Test Crash Report…"

    /// `P_TRACED` from `sys/proc.h`, which the Swift importer does not carry
    /// through. Written as the literal it is, next to the name it has in C.
    private static let processIsTraced: Int32 = 0x0000_0800

    /// Whether a debugger is attached to this process, by the documented sysctl
    /// route. Any failure answers "no": a broken query must not be able to
    /// silently disarm the trigger on a machine with no debugger anywhere near
    /// it.
    static func isBeingDebugged() -> Bool {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()]
        guard sysctl(&mib, u_int(mib.count), &info, &size, nil, 0) == 0 else { return false }
        return (info.kp_proc.p_flag & processIsTraced) != 0
    }
}

/// Crashes this process on purpose, from a frame named after what it is.
///
/// `@_cdecl` fixes the symbol name. Without it the symbol is Swift's mangled
/// form, which changes shape with the compiler and cannot be looked up by name
/// from a test. With it there is one spelling, `seedbedTestCrash`, that the test
/// suite can prove is present and that an operator can look for in the
/// symbolicated stack.
///
/// Deliberately not `@inline(__always)`: the whole value of this function is
/// that it has a frame of its own.
@_cdecl("seedbedTestCrash")
@inline(never)
public func seedbedTestCrash() {
    // The unmapped write. Forced through a pointer built from a stored value so
    // that no amount of optimization can constant-fold it into a trap with a
    // different exception type.
    let address = UnsafeMutablePointer<UInt8>(bitPattern: TestCrash.faultAddress)!
    address.pointee = 0
    // Unreachable in practice. Present so that "the store did not fault" fails
    // loudly as SIGABRT instead of quietly as a running app.
    abort()
}
