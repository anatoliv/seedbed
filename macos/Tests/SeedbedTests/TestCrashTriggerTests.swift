import AppKit
import XCTest
@testable import Seedbed

/// The gates in front of a deliberate crash, asked as values.
///
/// A trigger like this is only ever run once per machine per release, by hand,
/// and it destroys the process when it works. So the part worth testing is not
/// the crash: it is everything that decides whether the crash happens, which is
/// exactly the part that cannot be observed afterwards. `TestCrash.decision` and
/// `TestCrash.menuItemIsVisible` exist as values for that reason.
final class TestCrashTriggerTests: XCTestCase {
    // MARK: The launch argument

    func testAnOrdinaryLaunchIsNotACrashRequest() {
        // The arguments a real launch carries, including the ones AppKit adds.
        let ordinary = ["/Applications/Seedbed.app/Contents/MacOS/Seedbed",
                        "-NSDocumentRevisionsDebugMode", "YES"]
        XCTAssertEqual(TestCrash.decision(arguments: ordinary,
                                          isConfigured: true,
                                          isReportingEnabled: true,
                                          isBeingDebugged: false),
                       .notRequested)
    }

    func testThisTestRunIsNotACrashRequest() {
        // The suite runs inside a process that would die if this were wrong, so
        // asking the real arguments is both the honest question and a harmless
        // one: the answer is a value, and nothing acts on it here.
        XCTAssertEqual(TestCrash.decision(arguments: ProcessInfo.processInfo.arguments,
                                          isConfigured: true,
                                          isReportingEnabled: true,
                                          isBeingDebugged: false),
                       .notRequested)
    }

    func testTheArgumentMustBeTheWholeArgument() {
        // A prefix or a substring must not arm it. `--crash-testing` is a
        // plausible future flag and would be a very bad way to find out.
        for near in ["--crash", "--crash-testing", "crash-test", "--crash_test",
                     "--Crash-Test", "-crash-test"] {
            XCTAssertEqual(TestCrash.decision(arguments: ["Seedbed", near],
                                              isConfigured: true,
                                              isReportingEnabled: true,
                                              isBeingDebugged: false),
                           .notRequested,
                           "\(near) armed the trigger")
        }
    }

    func testTheArgumentArmsTheTriggerOnAReportingBuild() {
        XCTAssertEqual(TestCrash.decision(arguments: ["Seedbed", TestCrash.launchArgument],
                                          isConfigured: true,
                                          isReportingEnabled: true,
                                          isBeingDebugged: false),
                       .crash)
    }

    func testABuildThatCannotReportRefusesTheArgument() {
        // This is the state of every copy built out of the checkout, so it is
        // the state a stranger who finds the flag in the source will be in.
        XCTAssertEqual(TestCrash.decision(arguments: ["Seedbed", TestCrash.launchArgument],
                                          isConfigured: false,
                                          isReportingEnabled: true,
                                          isBeingDebugged: false),
                       .refusedNoProvider)
    }

    func testADebuggerRefusesTheArgumentEvenOnAReportingBuild() {
        XCTAssertEqual(TestCrash.decision(arguments: ["Seedbed", TestCrash.launchArgument],
                                          isConfigured: true,
                                          isReportingEnabled: true,
                                          isBeingDebugged: true),
                       .refusedDebugger)
    }

    func testTheDiagnosticsToggleBeingOffRefusesTheArgument() {
        // A crash is not delivered by the process that crashes. The report is
        // written to disk and sent by the NEXT launch, which starts the SDK only
        // if the toggle is on, so firing with it off destroys the app and
        // produces nothing.
        XCTAssertEqual(TestCrash.decision(arguments: ["Seedbed", TestCrash.launchArgument],
                                          isConfigured: true,
                                          isReportingEnabled: false,
                                          isBeingDebugged: false),
                       .refusedNotEnabled)
    }

    func testTheMissingProviderIsReportedBeforeTheToggle() {
        // Both wrong at once. The provider is the one that cannot be fixed from
        // Settings, so it is the one worth saying.
        XCTAssertEqual(TestCrash.decision(arguments: ["Seedbed", TestCrash.launchArgument],
                                          isConfigured: false,
                                          isReportingEnabled: false,
                                          isBeingDebugged: false),
                       .refusedNoProvider)
    }

    func testTheMissingProviderIsReportedBeforeTheDebugger() {
        // Both are wrong at once. The one worth saying is the one the operator
        // can do something about from where they are standing: a build with no
        // DSN will not report however the debugger is arranged.
        XCTAssertEqual(TestCrash.decision(arguments: ["Seedbed", TestCrash.launchArgument],
                                          isConfigured: false,
                                          isReportingEnabled: true,
                                          isBeingDebugged: true),
                       .refusedNoProvider)
    }

    // MARK: The hidden menu item

    func testTheItemIsAbsentFromAMenuOpenedNormally() {
        XCTAssertFalse(TestCrash.menuItemIsVisible(modifiers: [], isConfigured: true))
    }

    func testOnlyOptionRevealsTheItem() {
        for other: NSEvent.ModifierFlags in [.command, .shift, .control, .function,
                                             [.command, .shift]] {
            XCTAssertFalse(TestCrash.menuItemIsVisible(modifiers: other, isConfigured: true),
                           "\(other) revealed the item")
        }
        XCTAssertTrue(TestCrash.menuItemIsVisible(modifiers: .option, isConfigured: true))
    }

    func testOptionHeldAlongsideOtherKeysStillRevealsTheItem() {
        // Caps lock and the numeric-pad flag ride along on their own; requiring
        // Option and nothing else would make the gesture fail for reasons
        // nobody could see.
        XCTAssertTrue(TestCrash.menuItemIsVisible(modifiers: [.option, .capsLock],
                                                  isConfigured: true))
        XCTAssertTrue(TestCrash.menuItemIsVisible(modifiers: [.option, .shift],
                                                  isConfigured: true))
    }

    func testABuildThatCannotReportNeverShowsTheItem() {
        XCTAssertFalse(TestCrash.menuItemIsVisible(modifiers: .option, isConfigured: false))
        XCTAssertFalse(TestCrash.menuItemIsVisible(modifiers: [], isConfigured: false))
    }

    func testTheTitlePromisesTheConfirmationThatFollows() {
        // House rule, and the reason the rebuild item grew a dialog: an ellipsis
        // means the command asks before it acts.
        XCTAssertTrue(TestCrash.menuItemTitle.hasSuffix("…"), TestCrash.menuItemTitle)
    }

    // MARK: The crash itself, proved without running it

    func testTheCrashFunctionIsPresentUnderTheNameTheStackWillShow() {
        // Looked up by name rather than called. `@_cdecl` is what makes the
        // lookup possible and is also what fixes the spelling an operator reads
        // in the symbolicated stack, so proving the symbol exists proves both.
        // RTLD_DEFAULT is not imported into Swift; -2 is its value on Darwin.
        let global = UnsafeMutableRawPointer(bitPattern: -2)
        XCTAssertNotNil(dlsym(global, "seedbedTestCrash"),
                        "seedbedTestCrash is not in the binary under that name, so a "
                        + "symbolicated crash would not name it")
    }

    func testTheFaultAddressCannotBeMapped() {
        // What makes the crash deterministic rather than lucky. macOS leaves the
        // first page unmapped so that a null-ish dereference faults, and a
        // non-zero address keeps the fault a bad access rather than a Swift
        // runtime trap on a nil pointer, which carries a different exception
        // type and no frame of ours on top.
        XCTAssertGreaterThan(TestCrash.faultAddress, 0)
        XCTAssertLessThan(TestCrash.faultAddress, Int(getpagesize()))
    }

    func testTheDebuggerQuestionAnswersWithoutADebugger() throws {
        // The suite normally runs untraced, and then the honest answer is false.
        // Under a debugger the answer flips and the trigger refuses, which is
        // the behaviour being asserted, so the case is skipped rather than
        // failed: a red suite for someone stepping through it would be a lie
        // about the code.
        if TestCrash.isBeingDebugged() {
            throw XCTSkip("this run is traced, which is the state the trigger refuses")
        }
        XCTAssertFalse(TestCrash.isBeingDebugged())
    }
}
