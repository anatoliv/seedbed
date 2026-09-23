import XCTest
@testable import Seedbed

final class NewPromptTests: XCTestCase {
    func testTheFirstScaffoldUsesThePlainName() {
        XCTAssertEqual(LibraryModel.nextNewPromptID(existing: []), "new-prompt")
    }

    func testCreationUsesTheFirstNameThatDoesNotExistOnDisk() {
        let existing: Set<String> = ["new-prompt", "new-prompt-2", "new-prompt-4"]
        XCTAssertEqual(LibraryModel.nextNewPromptID(existing: existing), "new-prompt-3")
    }

    func testAnUnrelatedPromptDoesNotConsumeAScaffoldName() {
        XCTAssertEqual(
            LibraryModel.nextNewPromptID(existing: ["fix-bug-and-test"]),
            "new-prompt"
        )
    }

    @MainActor
    func testTheActionCreatesBesideAnExistingScaffoldWithoutOverwritingIt() async throws {
        let files = FileManager.default
        let root = files.temporaryDirectory
            .appendingPathComponent("seedbed-new-prompt-\(UUID().uuidString)", isDirectory: true)
        try files.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? files.removeItem(at: root) }

        var repository = URL(fileURLWithPath: #filePath)
        for _ in 0..<4 { repository.deleteLastPathComponent() }
        try files.copyItem(at: repository.appendingPathComponent("promptlib"),
                           to: root.appendingPathComponent("promptlib"))
        try """
            [models."local-test"]
            name = "Local test"
            family = "local"
            guides = []
            notes = "No network guidance."
            """.write(to: root.appendingPathComponent("models.toml"),
                       atomically: true, encoding: .utf8)

        let prompts = root.appendingPathComponent("prompts", isDirectory: true)
        try files.createDirectory(at: prompts, withIntermediateDirectories: true)
        let original = """
            +++
            title = "Keep this prompt"
            targets = ["local-test"]
            tags = []
            +++
            do not overwrite me
            """
        let originalURL = prompts.appendingPathComponent("new-prompt.md")
        try original.write(to: originalURL, atomically: true, encoding: .utf8)

        let model = LibraryModel(client: LibraryClient(root: root))
        model.newPrompt()
        let createdURL = prompts.appendingPathComponent("new-prompt-2.md")
        for _ in 0..<200 {
            if !model.busy, files.fileExists(atPath: createdURL.path),
               model.selection == "new-prompt-2" { break }
            try await Task.sleep(nanoseconds: 50_000_000)
        }

        XCTAssertEqual(try String(contentsOf: originalURL, encoding: .utf8), original)
        XCTAssertTrue(files.fileExists(atPath: createdURL.path))
        XCTAssertEqual(model.selection, "new-prompt-2")
        XCTAssertFalse(model.statusIsError, model.status)
    }
}
