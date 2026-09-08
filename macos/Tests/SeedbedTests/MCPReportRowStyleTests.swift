import SwiftUI
import XCTest
@testable import Seedbed

/// A failed write of the client configuration must not look like a successful
/// one.
///
/// `ClaudeConfigInstaller.Report` was added because a write that reports
/// nothing is indistinguishable from one that failed. Returning a report only
/// half solves that: the report still has to reach the screen looking different
/// depending on which happened, and until now nothing checked that it did. The
/// pane had never been observed showing either outcome, and it must not be
/// screenshotted to find out, because it renders both bearer tokens in
/// cleartext.
///
/// So the difference is checked where it lives, as a value. Nothing here writes
/// a file or calls the installer: the reports below are constructed directly,
/// which is the only way to exercise a failure without arranging for one.
final class MCPReportRowStyleTests: XCTestCase {
    private let success = ClaudeConfigInstaller.Report(
        succeeded: true,
        title: "Updated the seedbed entry in ~/.claude.json.",
        detail: "The previous version is beside it."
    )
    private let failure = ClaudeConfigInstaller.Report(
        succeeded: false,
        title: "Seedbed could not write your configuration file.",
        detail: "It was left as it was."
    )

    private func style(for report: ClaudeConfigInstaller.Report) -> MCPReportRowStyle {
        MCPReportRowStyle.forOutcome(succeeded: report.succeeded)
    }

    /// The whole point: the two outcomes do not arrive at the same row.
    func testAFailedWriteDoesNotReachTheScreenLookingLikeASuccessfulOne() {
        XCTAssertNotEqual(style(for: success), style(for: failure))
    }

    /// And they differ by shape, so the outcome survives a reader who cannot
    /// tell the two tints apart. A distinction carried by colour alone is one
    /// this pane does not have.
    func testTheOutcomeIsCarriedByTheSymbolAndNotByColourAlone() {
        XCTAssertNotEqual(style(for: success).symbol, style(for: failure).symbol)
        XCTAssertFalse(style(for: success).symbol.isEmpty)
        XCTAssertFalse(style(for: failure).symbol.isEmpty)
    }

    /// The tint is the fast signal on top of the shape, and it is also a signal
    /// of which kind of thing this is: the failure takes the same warning tint
    /// as every other warning in the pane, so one look sorts them.
    func testEachOutcomeKeepsTheTintItsKindOfNewsIsToldIn() {
        XCTAssertEqual(style(for: success).tint, Tokens.positive)
        XCTAssertEqual(style(for: failure).tint, Tokens.warning)
        XCTAssertNotEqual(style(for: success).tint, style(for: failure).tint)
    }

    /// A failure is bordered in its own tint and a success is not, which is
    /// what makes the failed row the one the eye lands on first in a pane the
    /// person is scrolling past.
    func testOnlyTheFailureIsBorderedInItsOwnTint() {
        XCTAssertNotEqual(style(for: success).border, style(for: failure).border)
        XCTAssertEqual(style(for: failure).border, Tokens.warning.opacity(0.4))
        XCTAssertEqual(style(for: success).border, Tokens.Surface.hairline)
    }

    /// The mapping reads the report's own outcome rather than anything beside
    /// it: two failures worded differently are still both failures.
    func testTheRowFollowsTheOutcomeAndNotTheWording() {
        let otherFailure = ClaudeConfigInstaller.Report(
            succeeded: false,
            title: "There is no configuration file to update.",
            detail: "Copy the configuration above in instead."
        )
        XCTAssertEqual(style(for: otherFailure), style(for: failure))
        XCTAssertNotEqual(style(for: otherFailure), style(for: success))
    }
}
