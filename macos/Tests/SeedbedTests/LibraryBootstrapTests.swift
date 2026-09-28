import Foundation
import XCTest
@testable import Seedbed

final class LibraryBootstrapTests: XCTestCase {
    private var sandbox: URL!
    private var common: URL { sandbox.appendingPathComponent("Support/LibraryData") }
    private var previous: URL { sandbox.appendingPathComponent("Support/Library") }
    private var legacy: URL { sandbox.appendingPathComponent("Projects/seedbed") }

    override func setUpWithError() throws {
        sandbox = FileManager.default.temporaryDirectory
            .appendingPathComponent("seedbed-bootstrap-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: sandbox, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: sandbox)
    }

    private func makeLibrary(at root: URL) throws {
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("promptlib"), withIntermediateDirectories: true)
        try "".write(to: root.appendingPathComponent("promptlib/__init__.py"),
                     atomically: true, encoding: .utf8)
        try "[models]\n".write(to: root.appendingPathComponent("models.toml"),
                               atomically: true, encoding: .utf8)
    }

    private func git(_ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0, "git \(arguments.joined(separator: " "))")
    }

    func testEmptyDefaultIsClonedIntoAUsableLibrary() throws {
        try FileManager.default.createDirectory(at: common, withIntermediateDirectories: true)
        var calls = 0
        let result = try LibraryBootstrap.ensureDefaultLibrary(
            commonRoot: common, previousRoot: previous, legacyRoot: legacy
        ) { destination in
            calls += 1
            try self.makeLibrary(at: destination)
        }
        XCTAssertEqual(result.path.split(separator: "/"), common.path.split(separator: "/"))
        XCTAssertEqual(calls, 1)
        XCTAssertTrue(LibraryClient.isLibrary(common))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(
            atPath: common.deletingLastPathComponent().path), ["LibraryData"])
    }

    func testLegacyEditsAreCopiedWithoutChangingTheCheckout() throws {
        try makeLibrary(at: legacy)
        let enhancer = legacy.appendingPathComponent("enhancer.toml")
        try "[enhancer]\nmodel = \"local\"\n".write(to: enhancer,
                                                     atomically: true, encoding: .utf8)
        try FileManager.default.createDirectory(at: legacy.appendingPathComponent("prompts"),
                                                withIntermediateDirectories: true)
        let prompt = legacy.appendingPathComponent("prompts/local.md")
        try "local edit".write(to: prompt, atomically: true, encoding: .utf8)
        let result = try LibraryBootstrap.ensureDefaultLibrary(
            commonRoot: common, previousRoot: previous, legacyRoot: legacy
        ) { _ in XCTFail("A valid library must not be cloned over") }
        XCTAssertEqual(result.standardizedFileURL.path, common.standardizedFileURL.path)
        XCTAssertEqual(try String(contentsOf: common.appendingPathComponent("prompts/local.md")),
                       "local edit")
        XCTAssertEqual(try String(contentsOf: prompt), "local edit")
        XCTAssertEqual(try String(contentsOf: common.appendingPathComponent("enhancer.toml")),
                       try String(contentsOf: enhancer))
        XCTAssertFalse(FileManager.default.fileExists(atPath: common.appendingPathComponent(".git").path))
    }

    func testRealGitCloneCreatesAUsableDataLibrary() throws {
        let source = sandbox.appendingPathComponent("source")
        try makeLibrary(at: source)
        try git(["init", "-q", source.path])
        try git(["-C", source.path, "add", "."])
        try git(["-C", source.path, "-c", "user.name=Seedbed Test",
                 "-c", "user.email=test@example.invalid", "commit", "-qm", "fixture"])

        let result = try LibraryBootstrap.ensureDefaultLibrary(
            commonRoot: common, previousRoot: previous, legacyRoot: legacy
        ) { destination in
            try LibraryBootstrap.cloneRepository(into: destination, from: source.path)
            XCTAssertNil(LibraryClient.whyNotALibrary(destination))
        }
        XCTAssertEqual(result.path.split(separator: "/"), common.path.split(separator: "/"))
        XCTAssertTrue(LibraryClient.isLibrary(result))
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: result.appendingPathComponent(".git").path))
    }

    func testExistingWorkIsNeverReplacedAndFailedCloneLeavesNoPartialLibrary() throws {
        try FileManager.default.createDirectory(at: common, withIntermediateDirectories: true)
        let work = common.appendingPathComponent("my-prompt.md")
        try "keep me".write(to: work, atomically: true, encoding: .utf8)
        XCTAssertThrowsError(try LibraryBootstrap.ensureDefaultLibrary(
            commonRoot: common, previousRoot: previous, legacyRoot: legacy
        ) { _ in XCTFail("Must not clone into occupied folder") })
        XCTAssertEqual(try String(contentsOf: work), "keep me")

        try FileManager.default.removeItem(at: common)
        XCTAssertThrowsError(try LibraryBootstrap.ensureDefaultLibrary(
            commonRoot: common, previousRoot: previous, legacyRoot: legacy
        ) { destination in
            try FileManager.default.createDirectory(at: destination,
                                                    withIntermediateDirectories: true)
            throw LibraryBootstrap.Failure.clone("offline")
        })
        XCTAssertFalse(FileManager.default.fileExists(atPath: common.path))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(
            atPath: common.deletingLastPathComponent().path), [])
    }
}
