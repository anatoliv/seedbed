import Sentry
import XCTest
@testable import Seedbed

/// The promise on the download page, run rather than read.
///
/// Settings, the DMG readme, the Homebrew caveats and seedbed.dev all tell the
/// user what a crash report does not carry: a prompt, a render, a value typed
/// into a placeholder, a token, or the account name in a home-directory path.
/// Until this file existed, fifteen SDK options about bandwidth were pinned by
/// string match and none of the four lines carrying that promise were pinned at
/// all — so deleting `event.user = nil` was a green suite.
///
/// The Python side of this pins that the scrubber is still *wired in*, which is
/// the half a Swift test cannot see. This half is the transformation itself,
/// which is where the promise actually lives and where a narrowed regex or a
/// dropped assignment does its damage.
final class CrashReportingScrubbingTests: XCTestCase {

    // MARK: The home directory, which carries the account name

    func testTheHomeDirectoryCollapsesToATilde() {
        let home = NSHomeDirectory()
        let redacted = CrashReporting.redact("could not read \(home)/Library/Seedbed/Library")

        XCTAssertEqual(redacted, "could not read ~/Library/Seedbed/Library")
        XCTAssertFalse(redacted.contains(home),
                       "the home directory survived, and it names the account")
    }

    func testEveryOccurrenceGoesNotJustTheFirst() {
        // A path pair is the common shape: "copying A to B". Replacing only the
        // first leaves the account name in the message anyway.
        let home = NSHomeDirectory()
        let redacted = CrashReporting.redact("copying \(home)/a to \(home)/b")

        XCTAssertEqual(redacted, "copying ~/a to ~/b")
    }

    // MARK: Bearer tokens, which are long hex runs

    func testALongHexRunIsReplaced() {
        let token = String(repeating: "a1b2c3d4", count: 8)   // 64 characters
        let redacted = CrashReporting.redact("Authorization: Bearer \(token)")

        XCTAssertEqual(redacted, "Authorization: Bearer «redacted»")
        XCTAssertFalse(redacted.contains(token))
    }

    func testUppercaseAndMixedCaseTokensAreReplacedToo() {
        // A token printed by a different tool is the same secret in different
        // case, and a regex narrowed to [0-9a-f] would ship it.
        for token in [String(repeating: "A1B2C3D4", count: 4),
                      String(repeating: "aB3f", count: 8)] {
            let redacted = CrashReporting.redact("token=\(token) end")
            XCTAssertEqual(redacted, "token=«redacted» end", token)
        }
    }

    func testThirtyTwoIsTheBoundaryAndThirtyOneSurvives() {
        // The boundary is the part a regex edit moves, so it is the part worth
        // asserting from both sides. Thirty-one hex characters is a git-ish
        // fragment or a colour-heavy log line, not a token, and blanking it
        // would make ordinary diagnostics unreadable.
        let thirtyOne = String(repeating: "a", count: 31)
        let thirtyTwo = String(repeating: "a", count: 32)

        XCTAssertEqual(CrashReporting.redact("id \(thirtyOne)"), "id \(thirtyOne)")
        XCTAssertEqual(CrashReporting.redact("id \(thirtyTwo)"), "id «redacted»")
    }

    func testOrdinaryProseIsLeftAlone() {
        // The scrubber has to stay usable: a report scrubbed into meaninglessness
        // is a report nobody can act on, which is the failure mode opposite to
        // the one above.
        let message = "Fatal error: index out of range in LibraryStore.swift:214"
        XCTAssertEqual(CrashReporting.redact(message), message)
    }

    // MARK: What beforeSend strips from the event

    private func populatedEvent() -> Event {
        let event = Event(level: .error)
        let user = User()
        user.userId = "someone"
        user.email = "someone@example.invalid"
        user.ipAddress = "203.0.113.7"
        event.user = user
        event.serverName = "anatolis-macbook.local"
        event.request = SentryRequest()
        event.request?.url = "https://example.invalid/prompt"
        event.extra = ["prompt": "the whole seed the user was writing"]
        return event
    }

    func testTheIdentifyingFieldsAreRemoved() {
        let event = CrashReporting.scrub(populatedEvent())

        XCTAssertNil(event.user, "the report carries who")
        XCTAssertNil(event.serverName, "the report carries which machine")
        XCTAssertNil(event.request, "the report carries a URL and its headers")
        XCTAssertNil(event.extra, "extra is arbitrary and nothing here fills it deliberately")
    }

    func testTheMessageIsScrubbedRatherThanPassedThrough() {
        let event = Event(level: .error)
        let token = String(repeating: "f0", count: 20)        // 40 characters
        event.message = SentryMessage(
            formatted: "failed at \(NSHomeDirectory())/Library with \(token)")

        let formatted = CrashReporting.scrub(event).message?.formatted
        XCTAssertEqual(formatted, "failed at ~/Library with «redacted»")
    }

    func testAnEventWithNothingToScrubSurvivesIntact() {
        // The scrubber must not be a filter. An event that carries only a stack
        // trace is the event the whole feature exists to deliver.
        let event = Event(level: .fatal)
        event.message = SentryMessage(formatted: "index out of range")

        let scrubbed = CrashReporting.scrub(event)
        XCTAssertEqual(scrubbed.message?.formatted, "index out of range")
        XCTAssertEqual(scrubbed.level, SentryLevel.fatal)
    }

    // MARK: Breadcrumbs, on both paths out

    func testBreadcrumbsAttachedToAnEventAreScrubbed() {
        let event = Event(level: .error)
        let crumb = Breadcrumb(level: .info, category: "library")
        crumb.message = "reading \(NSHomeDirectory())/Library/Seedbed"
        crumb.data = ["seed": "the text of a prompt"]
        event.breadcrumbs = [crumb]

        let scrubbed = CrashReporting.scrub(event).breadcrumbs?.first
        XCTAssertEqual(scrubbed?.message, "reading ~/Library/Seedbed")
        XCTAssertNil(scrubbed?.data, "breadcrumb data is an arbitrary payload")
    }

    func testABreadcrumbOnItsOwnWayOutIsScrubbedTheSameWay() {
        // `beforeBreadcrumb` is the second path: a crumb recorded during the
        // session is scrubbed as it is stored, not only as an event ships.
        let crumb = Breadcrumb(level: .info, category: "mcp")
        crumb.message = "token " + String(repeating: "9", count: 32)
        crumb.data = ["header": "Authorization"]

        let scrubbed = CrashReporting.redact(crumb)
        XCTAssertEqual(scrubbed.message, "token «redacted»")
        XCTAssertNil(scrubbed.data)
    }
}
