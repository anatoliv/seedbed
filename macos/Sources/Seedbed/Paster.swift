import AppKit
import ApplicationServices

/// Pasting the copied prompt straight into whatever you were working in.
///
/// Two things make this more than "send ⌘V". Showing the panel takes focus, so
/// the app to paste into has to be remembered *before* that happens. And posting
/// a key event to another process needs Accessibility permission, which the user
/// grants once in System Settings — until then this degrades to copy-only rather
/// than failing silently.
@MainActor
enum Paster {
    static let enabledKey = "PasteIntoFrontmost"

    /// On by default: it is the reason the feature exists. The ⇧ modifier and
    /// the menu item both turn it off.
    static var isEnabled: Bool {
        get {
            UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true
        }
        set { UserDefaults.standard.set(newValue, forKey: enabledKey) }
    }

    /// The app that was frontmost before the panel took focus.
    private(set) static var previousApp: NSRunningApplication?

    static func rememberFrontmost() {
        let front = NSWorkspace.shared.frontmostApplication
        // Never remember ourselves, or a paste would land back in the panel.
        if front?.processIdentifier != ProcessInfo.processInfo.processIdentifier {
            previousApp = front
        }
    }

    static var hasPermission: Bool { AXIsProcessTrusted() }

    /// Ask once, with the system's own dialog. Returns the state after asking.
    @discardableResult
    static func requestPermission() -> Bool {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        return AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }

    static func openAccessibilitySettings() {
        let url = URL(string:
            "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
        NSWorkspace.shared.open(url)
    }

    enum Outcome {
        case pasted
        case noPermission
        case noTarget
    }

    /// Return focus to the remembered app, then send it ⌘V.
    ///
    /// The delay is not decoration: activation is asynchronous, and a key event
    /// posted before the target is actually front goes to whatever still holds
    /// focus — which would paste a prompt into the wrong window.
    static func paste(completion: @escaping (Outcome) -> Void) {
        guard hasPermission else { return completion(.noPermission) }
        guard let target = previousApp, !target.isTerminated else { return completion(.noTarget) }

        target.activate()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) {
            sendCommandV()
            completion(.pasted)
        }
    }

    private static func sendCommandV() {
        guard let source = CGEventSource(stateID: .combinedSessionState) else { return }
        let v = CGKeyCode(9)   // kVK_ANSI_V
        guard let down = CGEvent(keyboardEventSource: source, virtualKey: v, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: v, keyDown: false)
        else { return }
        down.flags = .maskCommand
        up.flags = .maskCommand
        down.post(tap: .cgAnnotatedSessionEventTap)
        up.post(tap: .cgAnnotatedSessionEventTap)
    }
}
