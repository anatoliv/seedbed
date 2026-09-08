import XCTest
@testable import Seedbed

/// Where "Update my client config" writes, and the one rule that override has
/// to keep.
///
/// The button writes a real file: the MCP client configuration in the home
/// folder of whoever is running the app. That is why it had never been pressed
/// in the UI, because a test that presses it rewrites the tester's own
/// configuration. `MCPSettings.clientConfigPath` is the way out, and it is only
/// safe to add on one condition: with the variable unset, a person cannot tell
/// it is there. Everything below is that condition, plus the reading that makes
/// the override worth having.
///
/// Nothing here writes a file, and nothing here calls the installer. The
/// resolver takes its environment as an argument precisely so this can be
/// checked as a value.
final class MCPClientConfigPathTests: XCTestCase {
    private let variable = MCPSettings.clientConfigPathVariable

    /// The property everything else rests on. An unset variable must resolve to
    /// the same file the pane wrote to before the override existed.
    func testWithTheVariableUnsetTheButtonStillWritesTheRealFile() {
        XCTAssertEqual(MCPSettings.clientConfigPath(environment: [:]),
                       ClaudeConfigInstaller.defaultPath)
    }

    /// And that file is named here as well as in the installer, so a resolver
    /// that quietly started defaulting somewhere else would still be caught
    /// even if `defaultPath` moved with it.
    func testTheRealFileIsTheClaudeConfigurationInTheHomeFolder() {
        XCTAssertEqual(MCPSettings.clientConfigPath(environment: [:]),
                       (NSHomeDirectory() as NSString).appendingPathComponent(".claude.json"))
    }

    /// An exported-but-blank variable is a normal shell accident. Treated as a
    /// value it aims the write at nothing; treated as unset it writes where it
    /// always did, which is what a person with an empty export deserves.
    func testAnEmptyValueCountsAsUnset() {
        XCTAssertEqual(MCPSettings.clientConfigPath(environment: [variable: ""]),
                       ClaudeConfigInstaller.defaultPath)
    }

    /// A harness that sets other variables, which every run of this app does,
    /// does not thereby redirect the write.
    func testAnUnrelatedEnvironmentChangesNothing() {
        XCTAssertEqual(
            MCPSettings.clientConfigPath(environment: ["SEEDBED_OPEN_LIBRARY": "mcp",
                                                       "HOME": "/somewhere/else"]),
            ClaudeConfigInstaller.defaultPath
        )
    }

    /// The reading, and the reason the variable exists: a UI test can send the
    /// press somewhere it is allowed to write.
    func testASetValueIsWhereTheWriteGoes() {
        let temporary = NSTemporaryDirectory() + "seedbed-config-test/.claude.json"
        XCTAssertEqual(MCPSettings.clientConfigPath(environment: [variable: temporary]),
                       temporary)
    }

    /// Handed through exactly as given. No expansion, no normalising, nothing
    /// that could turn a harness's temp path into a path in the home folder.
    func testTheValueIsUsedVerbatim() {
        for value in ["~/.claude.json", "relative.json", "/tmp/a b/.claude.json"] {
            XCTAssertEqual(MCPSettings.clientConfigPath(environment: [variable: value]), value)
        }
    }

    /// The default argument reads the real process environment, so the pane
    /// calling `clientConfigPath()` with nothing gets the same answer this test
    /// process does. This suite never sets the variable, so that answer is the
    /// real file.
    func testTheDefaultArgumentIsThisProcessesOwnEnvironment() {
        XCTAssertNil(ProcessInfo.processInfo.environment[variable],
                     "this suite must not set \(variable); the assertion below assumes it")
        XCTAssertEqual(MCPSettings.clientConfigPath(), ClaudeConfigInstaller.defaultPath)
    }
}
