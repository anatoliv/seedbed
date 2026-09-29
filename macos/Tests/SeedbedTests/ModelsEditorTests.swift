import XCTest
@testable import Seedbed

@MainActor
final class ModelsEditorTests: XCTestCase {
    private func editor() -> ModelsEditorModel {
        ModelsEditorModel(models: [LibraryData.ModelRef(id: "sample", name: "Sample", family: "custom",
            guides: ["https://example.org/guide"], notes: "My notes")],
            client: LibraryClient(root: URL(fileURLWithPath: "/tmp/unused")), onChange: {})
    }

    func testDocumentationAppendsWithoutReplacingExistingSourcesOrNotes() {
        let model = editor()
        model.addDocumentation(["https://example.org/guide", "https://example.org/new"])
        model.addDocumentation(["https://example.org/new"])
        XCTAssertEqual(model.draftGuides, "https://example.org/guide\nhttps://example.org/new")
        XCTAssertEqual(model.draftNotes, "My notes")
        XCTAssertTrue(model.hasChanges)
    }

    func testLibraryReloadPreservesUnsavedDraft() {
        let model = editor()
        model.draftName = "Edited name"
        model.adopt(model.models + [LibraryData.ModelRef(id: "other", name: "Other", family: "",
                                                       guides: [], notes: "")])
        XCTAssertEqual(model.draftName, "Edited name")
        XCTAssertEqual(model.selection, "sample")
    }

    func testSuggestionIsAnUnsavedDraftAndDoesNotChangeRegistry() {
        let model = editor()
        model.useSuggestion(ModelCatalog.Entry(id: "gpt-new", name: "GPT New", family: "openai",
                                               provider: "OpenAI", released: "2026-09-29"))
        XCTAssertTrue(model.isNew)
        XCTAssertNil(model.selection)
        XCTAssertEqual(model.models.count, 1)
        XCTAssertEqual(model.draftID, "gpt-new")
        XCTAssertTrue(model.draftGuides.isEmpty)
        XCTAssertTrue(model.hasChanges)
    }

    func testRemovingLastModelClearsItsDraft() {
        let model = editor()
        model.adopt([])
        XCTAssertTrue(model.isNew)
        XCTAssertNil(model.selection)
        XCTAssertTrue(model.draftID.isEmpty)
        XCTAssertTrue(model.draftGuides.isEmpty)
        XCTAssertFalse(model.canSave)
    }
}
