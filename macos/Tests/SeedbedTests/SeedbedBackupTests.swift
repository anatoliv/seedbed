import Foundation
import XCTest
@testable import Seedbed

final class SeedbedBackupTests: XCTestCase {
    private let password = "correct horse battery staple"

    private func payload(files: [String: Data] = [
        "models.toml": Data("[models]\n".utf8),
        "prompts/local.md": Data("a local prompt".utf8),
        ".variables.json": Data("{\"{{NAME}}\":\"private\"}".utf8),
    ]) throws -> SeedbedBackupPayload {
        let preferences = try PropertyListSerialization.data(
            fromPropertyList: ["SortMode": "recent", "LibraryRoot": "/old/mac/library",
                               "MCPEnabled": true], format: .binary, options: 0)
        return SeedbedBackupPayload(
            version: 1, files: files, preferences: preferences,
            secrets: ["mcp-full": "a-secret-token", "chatgpt-oauth": "refresh-token"],
            launchAtLogin: true, automaticUpdates: false)
    }

    func testEncryptedRoundTripAndWrongPassword() throws {
        let original = try payload()
        let archive = try SeedbedBackup.seal(original, password: password)
        XCTAssertFalse(archive.contains(Data("a-secret-token".utf8)))
        XCTAssertFalse(archive.contains(Data("a local prompt".utf8)))
        let opened = try SeedbedBackup.open(archive, password: password)
        XCTAssertEqual(opened.files, original.files)
        XCTAssertEqual(opened.secrets, original.secrets)
        XCTAssertEqual(opened.promptCount, 1)
        XCTAssertThrowsError(try SeedbedBackup.open(archive, password: "wrong-password"))

        var changed = archive
        changed[changed.count - 1] ^= 1
        XCTAssertThrowsError(try SeedbedBackup.open(changed, password: password))
    }

    func testImportCreatesSeparateLibraryAndRewritesPathPreference() throws {
        let sandbox = FileManager.default.temporaryDirectory
            .appendingPathComponent("seedbed-backup-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: sandbox) }
        let runtime = sandbox.appendingPathComponent("runtime")
        try FileManager.default.createDirectory(
            at: runtime.appendingPathComponent("promptlib"),
            withIntermediateDirectories: true)
        try Data().write(to: runtime.appendingPathComponent("promptlib/__init__.py"))
        try Data("[models]\n".utf8).write(to: runtime.appendingPathComponent("models.toml"))
        let original = try payload()
        let imported = try SeedbedBackup.restoreFiles(original, runtimeRoot: runtime,
                                                       parent: sandbox)
        XCTAssertNotEqual(imported, runtime)
        XCTAssertTrue(LibraryClient.isLibrary(imported))
        XCTAssertEqual(try Data(contentsOf: imported.appendingPathComponent("prompts/local.md")),
                       original.files["prompts/local.md"])
        XCTAssertEqual(try Data(contentsOf: runtime.appendingPathComponent("models.toml")),
                       Data("[models]\n".utf8))
        let preferences = try SeedbedBackup.restoredPreferences(original, root: imported)
        XCTAssertEqual(preferences["LibraryRoot"] as? String, imported.path)
        XCTAssertEqual(preferences["SortMode"] as? String, "recent")
    }

    func testUnsafePathsAreRejectedBeforeWriting() throws {
        let bad = try payload(files: ["models.toml": Data("[models]\n".utf8),
                                      "prompts/../../escape.md": Data("bad".utf8)])
        XCTAssertThrowsError(try SeedbedBackup.seal(bad, password: password))
        XCTAssertThrowsError(try SeedbedBackup.seal(try payload(), password: "short"))
    }

    func testCollectionIncludesLibraryDataButNotRuntimeOrGit() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("seedbed-collect-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let files: [String: String] = [
            "models.toml": "[models]\n",
            "enhancer.toml": "[enhancer]\n",
            "prompts/one.md": "seed",
            "rendered/model/one.md": "render",
            "comparisons" + "/one.md": "comparison",
            ".cache/guides/vendor.md": "guidance",
            ".usage.json": "{}",
            ".variables.json": "{}",
            "MigratedOriginals/prompts/old.md": "old seed",
            "promptlib/cli.py": "runtime",
            ".git/config": "git metadata",
        ]
        for (path, value) in files {
            let url = root.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try Data(value.utf8).write(to: url)
        }
        let collected = try SeedbedBackup.collectFiles(from: root)
        XCTAssertEqual(Set(collected.keys), Set(files.keys).subtracting(["promptlib/cli.py",
                                                                        ".git/config"]))
        let symlink = root.appendingPathComponent("prompts/link.md")
        try FileManager.default.createSymbolicLink(at: symlink,
                                                   withDestinationURL: root.appendingPathComponent("models.toml"))
        XCTAssertThrowsError(try SeedbedBackup.collectFiles(from: root))
    }
}
