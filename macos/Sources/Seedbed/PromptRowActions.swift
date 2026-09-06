import SwiftUI

/// Geometry of a prompt row's trailing action strip — the icons revealed on
/// hover. Two numbers, and they are here rather than inline so the icons stay
/// square and evenly spaced wherever the strip is used.
///
/// **There is deliberately no `gutter`, and that is the interesting part.**
/// Reference's version of this enum has one, because its picker OVERLAYS the
/// row and whatever sits underneath has to be inset far enough to clear the
/// icons. Seedbed's strip **replaces** the trailing slot instead: the HUD row
/// shows the usage badge or the strip, never both (`HUDView.PromptRow`), and
/// the library sidebar shows the staleness dot or the strip (`SidebarRow`).
/// Nothing is underneath, so nothing has to move out of the way.
///
/// A `gutter` and a `maxCount` were ported across with the numbers and read by
/// nothing for the life of the file, while the doc comment promised a coupling
/// that did not exist — inherited along with the values, like the terracotta
/// pair, without the layout that made it true. Removed rather than wired up: if
/// this strip ever does start overlaying something, derive the inset then, from
/// the layout that needs it.
enum RowActions {
    static let button: CGFloat = 17          // equal frames put the icons on one line
    static let spacing: CGFloat = 8          // tighter than Reference's 10: up to six icons
}

/// Everything you can do to one prompt, on the prompt's own row.
///
/// Every action here already existed — as a keyboard shortcut that acted on
/// whichever row happened to be selected, or as a button in the library
/// window's header. What was missing was doing any of it to the row under the
/// pointer. So these buttons act on THEIR row and deliberately do not move the
/// selection, which is how Reference's picker behaves.
///
/// A nil closure hides its button rather than disabling it: that is how a row
/// says an action does not apply to it — pasting with "paste into the frontmost
/// app" switched off, unpinning something that was never pinned.
struct PromptRowActions: View {
    /// The model a plain copy would use, named in the help text. Nil when the
    /// prompt has no usable render yet and a copy would build one first.
    var targetName: String?
    var pinned = false
    /// How many renders a delete would destroy, named in the help text because
    /// each one cost a real LLM call.
    var renderCount = 0

    var onCopy: (() -> Void)?
    var onPaste: (() -> Void)?
    var onRebuild: (() -> Void)?
    var onEdit: (() -> Void)?
    var onPin: (() -> Void)?
    var onDelete: (() -> Void)?

    var body: some View {
        HStack(spacing: RowActions.spacing) {
            if let onCopy {
                button("doc.on.doc", copyHelp, action: onCopy)
            }
            if let onPaste {
                button("text.insert", pasteHelp, action: onPaste)
            }
            if let onRebuild {
                button("arrow.clockwise",
                       "Rebuild this prompt for every model. Minutes of LLM calls (⌘R)",
                       action: onRebuild)
            }
            if let onEdit {
                button("pencil", "Edit in the library window (⌘E)", action: onEdit)
            }
            if let onPin {
                // The pin glyph reads high in its box, as it does in Reference;
                // the half-point nudge puts it on the other icons' centre line.
                button(pinned ? "pin.slash" : "pin",
                       pinned ? "Unpin: stop sorting it first (⌘D)"
                              : "Pin: sorts first whatever the sort order (⌘D)",
                       size: Tokens.CompactSize.meta, offset: 0.5, action: onPin)
            }
            if let onDelete {
                button("trash", deleteHelp, action: onDelete)
            }
        }
    }

    private var copyHelp: String {
        guard let targetName else { return "Copy to the clipboard, building it first (⇧⏎)" }
        return "Copy the \(targetName) prompt to the clipboard (⇧⏎)"
    }

    private var pasteHelp: String {
        guard let targetName else { return "Paste into the app you came from, building it first (⏎)" }
        return "Paste the \(targetName) prompt into the app you came from (⏎)"
    }

    private var deleteHelp: String {
        renderCount == 0
            ? "Delete this prompt (⌘⌫)"
            : "Delete this prompt and its \(renderCount) render\(renderCount == 1 ? "" : "s") (⌘⌫)"
    }

    private func button(_ symbol: String, _ help: String,
                        size: CGFloat = Tokens.CompactSize.rowText,
                        offset: CGFloat = 0,
                        action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size))
                .foregroundStyle(.secondary)
                .offset(y: offset)
                .frame(width: RowActions.button, height: RowActions.button)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
    }
}
