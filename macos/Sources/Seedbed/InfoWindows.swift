import AppKit
import SwiftUI

/// Presents the app's windows that are read rather than worked in.
///
/// One presenter, and now one window: the manual used to be five separate ones
/// (About, Getting Started, Help, FAQ, What's New) at four different widths.
/// Reusing a window rather than stacking copies was always right; presenting one
/// instead of five is the part that was wrong.
@MainActor
final class InfoWindows {
    static let shared = InfoWindows()
    private var windows: [String: NSWindow] = [:]

    static var version: String {
        let short = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"
        return "\(short) (\(build))"
    }

    func show<Content: View>(_ key: String, title: String, size: NSSize,
                             minSize: NSSize? = nil,
                             @ViewBuilder content: () -> Content) {
        if let existing = windows[key] {
            NSApp.activate(ignoringOtherApps: true)
            existing.makeKeyAndOrderFront(nil)
            return
        }
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered, defer: false)
        window.title = title
        window.contentView = NSHostingView(rootView: content())
        // Say it to the window as well as to the content. The style mask has
        // always had `.resizable`; what stopped it was content pinned to an
        // exact frame, and once that is a minimum the window still needs a floor
        // of its own or it can be dragged smaller than what it is showing.
        // The floor, not the opening size — those are different numbers and
        // setting the second as the first is what makes a "resizable" window
        // refuse to get smaller.
        window.contentMinSize = minSize ?? size
        window.isReleasedWhenClosed = false
        window.center()
        windows[key] = window
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }
}

/// The reference page, rendered from `Manual`.
///
/// The copy used to be seven arrays of string literals in this file. It moved to
/// `Manual.swift` when the rewrite had to add a worked example to
/// most entries and search had to be able to rank them: both want the
/// text as data, and neither wants it interleaved with layout.
struct HelpPage: View {
    var body: some View {
        ForEach(Manual.sections(on: .help)) { section in
            SectionHeader(section.title)
            VStack(alignment: .leading, spacing: Tokens.Space.group) {
                ForEach(section.topics) { ManualTopicView(topic: $0) }
            }
            if section.id != Manual.sections(on: .help).last?.id { Divider() }
        }
    }
}

extension NSMenu {
    /// A greyed status line, as Reference's menu uses for state you read
    /// rather than click.
    @discardableResult
    func addItem(disabled title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        addItem(item)
        return item
    }
}
