import AppKit
import SwiftUI
import XCTest
@testable import Seedbed

@MainActor
final class InfoNavigationTests: XCTestCase {
    func testExplicitPagesClearGuideAndResultsButPreserveQuery() {
        for page in [InfoPage.help, .about, .whatsNew] {
            let model = InfoModel()
            model.open(guide: "what-it-is")
            model.query = "Nothing about the seed changes"
            XCTAssertTrue(model.searching)
            model.open(page)
            XCTAssertEqual(model.page, page)
            XCTAssertNil(model.guide)
            XCTAssertNil(model.topic)
            XCTAssertFalse(model.searching)
            XCTAssertEqual(model.query, "Nothing about the seed changes")
            XCTAssertEqual(model.windowTitle, page.windowTitle)
        }
    }

    func testGuideBodyIsIndexedAndOpensTheMatchingGuide() throws {
        let query = "Nothing about the seed changes"
        let hit = try XCTUnwrap(ManualSearch.results(for: query).first {
            $0.entry.destination == .guide("what-it-is")
        })
        let model = InfoModel()
        model.query = query
        model.open(hit.entry.destination)
        XCTAssertEqual(model.guide, "what-it-is")
        XCTAssertFalse(model.searching)
        XCTAssertEqual(model.query, query)
        XCTAssertEqual(model.windowTitle, "What Seedbed is · Seedbed Guide")
    }

    func testFAQHitOpensItsExactTopicAndReturningToResultsPreservesQuery() throws {
        let query = "Where are the tokens kept?"
        let hit = try XCTUnwrap(ManualSearch.results(for: query).first)
        let topic = try XCTUnwrap(Manual.topics.first { $0.term == query })
        XCTAssertEqual(hit.entry.destination, .topic(page: .faq, id: topic.id))
        let model = InfoModel()
        model.query = query
        model.open(hit.entry.destination)
        XCTAssertEqual(model.page, .faq)
        XCTAssertEqual(model.topic, topic.id)
        XCTAssertFalse(model.searching)
        model.browsing = false
        XCTAssertTrue(model.searching)
        XCTAssertEqual(model.query, query)
        model.open(guide: "first-prompt")
        XCTAssertNil(model.topic)
    }

    func testEveryGuideIsReachableByItsTitleEvenWhenHelpHasTheSameTitle() {
        for guide in Guide.pages {
            XCTAssertTrue(ManualSearch.results(for: guide.title).contains {
                $0.entry.destination == .guide(guide.id)
            }, guide.title)
        }
    }

    func testWhitespaceDoesNotHideSelectedContent() {
        let model = InfoModel()
        model.open(.about)
        model.query = " \n "
        XCTAssertFalse(model.searching)
        XCTAssertEqual(model.windowTitle, "About Seedbed")
    }

    func testNativeWindowTitleChangesWithoutReopening() {
        let view = InfoWindowTitle.TitleView()
        view.title = "Seedbed Help"
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 80),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = view
        XCTAssertEqual(window.title, "Seedbed Help")
        view.title = "About Seedbed"
        XCTAssertEqual(window.title, "About Seedbed")
        view.title = "Search Seedbed Help"
        XCTAssertEqual(window.title, "Search Seedbed Help")
    }
}
