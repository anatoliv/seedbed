import AppKit
import XCTest
@testable import Seedbed

@MainActor
final class BackupPasswordFormTests: XCTestCase {
    func testExportRequiresTwoMatchingPasswordsOfSufficientLength() {
        let password = NSSecureTextField()
        let confirmation = NSSecureTextField()
        let hint = NSTextField(labelWithString: "")
        let button = NSButton(title: "Export", target: nil, action: nil)
        let form = BackupPasswordForm(password: password, confirmation: confirmation,
                                      hint: hint, submitButton: button)

        XCTAssertFalse(button.isEnabled)
        password.stringValue = "short"
        form.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification,
                                               object: password))
        XCTAssertFalse(button.isEnabled)
        XCTAssertEqual(hint.stringValue, "Use at least 12 characters.")

        password.stringValue = "sample password value"
        form.update()
        XCTAssertFalse(button.isEnabled)
        XCTAssertEqual(hint.stringValue, "Repeat your password to continue.")

        confirmation.stringValue = "different password value"
        form.update()
        XCTAssertFalse(button.isEnabled)
        XCTAssertEqual(hint.stringValue, "Passwords do not match.")

        confirmation.stringValue = password.stringValue
        form.update()
        XCTAssertTrue(button.isEnabled)
        XCTAssertEqual(form.acceptedPassword(), "sample password value")
    }

    func testImportRequiresAProvidedPassword() {
        let password = NSSecureTextField()
        let button = NSButton(title: "Continue", target: nil, action: nil)
        let form = BackupPasswordForm(password: password, confirmation: nil,
                                      hint: nil, submitButton: button)

        XCTAssertFalse(button.isEnabled)
        password.stringValue = "backup password"
        form.update()
        XCTAssertTrue(button.isEnabled)
        XCTAssertEqual(form.acceptedPassword(), "backup password")
    }

    func testRealAlertKeepsExportDisabledUntilActiveSecureEditorMatches() {
        let alert = NSAlert()
        alert.addButton(withTitle: "Export")
        alert.addButton(withTitle: "Cancel")
        let password = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 320, height: 24))
        let confirmation = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 320, height: 24))
        let hint = NSTextField(labelWithString: "")
        let fields = NSStackView()
        fields.orientation = .vertical
        fields.spacing = 8
        fields.addArrangedSubview(password)
        fields.addArrangedSubview(confirmation)
        fields.addArrangedSubview(hint)
        fields.frame = NSRect(x: 0, y: 0, width: 320, height: 82)
        let form = BackupPasswordForm(password: password, confirmation: confirmation,
                                      hint: hint, submitButton: alert.buttons[0])
        alert.accessoryView = fields
        alert.layout()
        XCTAssertFalse(alert.buttons[0].isEnabled)

        let window = alert.window
        window.makeKeyAndOrderFront(nil)
        XCTAssertTrue(window.makeFirstResponder(password))
        XCTAssertTrue(NSApp.sendAction(password.action!, to: password.target, from: password))
        XCTAssertNotNil(confirmation.currentEditor())
        XCTAssertTrue(window.makeFirstResponder(confirmation))
        let editor = try? XCTUnwrap(confirmation.currentEditor())
        XCTAssertNotNil(editor)
        password.stringValue = "sample password value"
        (editor as? NSTextView)?.insertText("sample password value",
                                           replacementRange: NSRange(location: 0, length: 0))
        XCTAssertTrue(alert.buttons[0].isEnabled)
        XCTAssertEqual(form.acceptedPassword(), "sample password value")
        window.orderOut(nil)
    }
}
