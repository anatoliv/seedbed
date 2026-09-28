import AppKit
import XCTest
@testable import Seedbed

@MainActor
final class BackupPasswordEditsTests: XCTestCase {
    func testMatchingSecureFieldsUseTheActiveEditBeforeItCommits() {
        let password = NSSecureTextField()
        let confirmation = NSSecureTextField()
        let firstEditor = NSTextView()
        let activeEditor = NSTextView()
        let edits = BackupPasswordEdits()
        firstEditor.string = "sample password value"
        activeEditor.string = firstEditor.string

        edits.controlTextDidChange(Notification(
            name: NSControl.textDidChangeNotification,
            object: password,
            userInfo: ["NSFieldEditor": firstEditor]))
        edits.controlTextDidChange(Notification(
            name: NSControl.textDidChangeNotification,
            object: confirmation,
            userInfo: ["NSFieldEditor": activeEditor]))

        XCTAssertEqual(confirmation.stringValue, "")
        XCTAssertEqual(edits.value(in: password), edits.value(in: confirmation))
        XCTAssertEqual(edits.value(in: confirmation), "sample password value")
    }

    func testCommittedValueIsUsedWhenNoEditorChangeWasObserved() {
        let field = NSSecureTextField()
        field.stringValue = "autofilled password"

        XCTAssertEqual(BackupPasswordEdits().value(in: field), "autofilled password")
    }
}
