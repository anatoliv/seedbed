import Foundation
import XCTest

/// Test suites must not outlive the test process.
final class ThrowawayDefaultsTests: XCTestCase {
    private let uuid = "0F1E2D3C-4B5A-6978-8796-A5B4C3D2E1F0"
    private let fm = FileManager.default

    private func scratchDirectory() throws -> URL {
        let dir = fm.temporaryDirectory.appendingPathComponent("seedbed-throwaway-\(UUID().uuidString)")
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return dir
    }

    func testOnlyNamespacedUUIDSuitesCountAsThrowaway() {
        let ns = ThrowawayDefaults.namespace
        XCTAssertTrue(ThrowawayDefaults.isThrowawayPlist("\(ns)port-collision.\(uuid).plist"))

        // The app's own preferences, the old un-namespaced test form (left for the owner to
        // clear, never swept), a fixed name, and a near miss are all left alone.
        XCTAssertFalse(ThrowawayDefaults.isThrowawayPlist("net.amnesia.seedbed.plist"))
        XCTAssertFalse(ThrowawayDefaults.isThrowawayPlist("net.amnesia.seedbed.tests.\(uuid).plist"))
        XCTAssertFalse(ThrowawayDefaults.isThrowawayPlist("\(ns)port-collision.plist"))
        XCTAssertFalse(ThrowawayDefaults.isThrowawayPlist("\(ns)port-collision\(uuid).plist"))
        XCTAssertFalse(ThrowawayDefaults.isThrowawayPlist("\(ns)port-collision.\(uuid).plist.bak"))
    }

    /// A stub left by a killed run is swept by the next one, and nothing else is.
    func testTheSweepRemovesOnlyStaleThrowawayPlists() throws {
        let dir = try scratchDirectory()
        let ns = ThrowawayDefaults.namespace
        let stale = dir.appendingPathComponent("\(ns)port-collision.\(uuid).plist")
        let fresh = dir.appendingPathComponent("\(ns)port-collision.\(UUID().uuidString).plist")
        let legacy = dir.appendingPathComponent("net.amnesia.seedbed.tests.\(uuid).plist")
        let app = dir.appendingPathComponent("net.amnesia.seedbed.plist")
        for url in [stale, fresh, legacy, app] {
            XCTAssertTrue(fm.createFile(atPath: url.path, contents: Data("{}".utf8)))
        }
        let old = Date().addingTimeInterval(-3 * 60 * 60)
        for url in [stale, legacy, app] {
            try fm.setAttributes([.modificationDate: old], ofItemAtPath: url.path)
        }

        XCTAssertEqual(ThrowawayDefaults.sweepStale(in: dir, olderThan: ThrowawayDefaults.staleAge), 1)
        XCTAssertFalse(fm.fileExists(atPath: stale.path), "a stale throwaway plist should go")
        XCTAssertTrue(fm.fileExists(atPath: fresh.path), "a suite a running test may use must stay")
        XCTAssertTrue(fm.fileExists(atPath: legacy.path), "the old namespace is never swept")
        XCTAssertTrue(fm.fileExists(atPath: app.path), "the app's own preferences must stay")
    }

    /// The stub `cfprefsd` writes after exit is removed by a cleaner that outlives the
    /// process, and it deletes only throwaway plists, whatever it is handed.
    func testTheLateCleanerRemovesOnlyThrowawayPlists() throws {
        let dir = try scratchDirectory()
        let stub = dir.appendingPathComponent("\(ThrowawayDefaults.namespace)port-collision.\(UUID().uuidString).plist")
        let other = dir.appendingPathComponent("net.amnesia.seedbed.plist")
        for url in [stub, other] {
            XCTAssertTrue(fm.createFile(atPath: url.path, contents: Data("{}".utf8)))
        }

        ThrowawayDefaults.removeLater([stub.path, other.path], after: 1)

        let deadline = Date().addingTimeInterval(10)
        while fm.fileExists(atPath: stub.path), Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        }
        XCTAssertFalse(fm.fileExists(atPath: stub.path), "the cleaner should delete the stub")
        XCTAssertTrue(fm.fileExists(atPath: other.path), "a path that is not a throwaway plist must survive")
    }

    /// The exit hook empties each suite this process made and deletes its file.
    func testRemoveAllDeletesTheSuitesThisProcessMade() {
        let (name, defaults) = ThrowawayDefaults.suite("guard")
        XCTAssertTrue(name.hasPrefix(ThrowawayDefaults.namespace + "guard."))
        defaults.set("x", forKey: "k")
        defaults.synchronize()
        let url = ThrowawayDefaults.preferencesDirectory.appendingPathComponent("\(name).plist")
        let deadline = Date().addingTimeInterval(5)
        while !fm.fileExists(atPath: url.path), Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        XCTAssertTrue(fm.fileExists(atPath: url.path), "the suite should reach disk")

        ThrowawayDefaults.removeAll()

        XCTAssertFalse(fm.fileExists(atPath: url.path))
        XCTAssertNil(defaults.object(forKey: "k"))
    }
}
