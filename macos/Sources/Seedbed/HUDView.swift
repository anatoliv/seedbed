import AppKit
import SwiftUI

/// How the list is ordered. Pinned prompts always come first, whichever mode is
/// set — pinning is the manual override, and a sort that could bury a pinned
/// prompt would make pinning pointless.
enum SortMode: String, CaseIterable {
    case name, mostUsed, lastRefreshed, recentlyUsed

    var label: String {
        switch self {
        case .name:          return "name"
        case .mostUsed:      return "most used"
        case .lastRefreshed: return "last refreshed"
        case .recentlyUsed:  return "recent"
        }
    }

    var next: SortMode {
        let all = SortMode.allCases
        return all[((all.firstIndex(of: self) ?? 0) + 1) % all.count]
    }
}

/// Model for the panel. Loading, rendering and rebuilding all shell out to
/// Python, so they run off the main thread and publish back to it.
@MainActor
final class HUDModel: ObservableObject {
    @Published var query = ""
    @Published var selection = 0
    @Published var prompts: [Prompt] = []
    @Published var status = ""
    @Published var statusIsError = false
    @Published var statusIsGood = false
    @Published var busy = false
    @Published var sort: SortMode
    @Published var allModels: [LibraryData.ModelRef] = []
    @Published var history: [String: [String]] = [:]
    /// Set when a copy needs values before it can happen.
    @Published var filling: FillModel?
    /// Set when a delete is waiting to be confirmed. Like `filling`, this is a
    /// published flag and not just a view's `@State` because the panel's
    /// click-away dismissal has to know not to fire while it is up.
    @Published var pendingDelete: Prompt?
    /// Whether the copy in flight should also paste. Carried across the fill
    /// sheet, since the modifier was pressed before the form appeared.
    private var pendingPaste = true

    static let sortKey = "SortMode"

    /// The enhancer's one-line description, cached so building the menu never
    /// blocks on a subprocess. Lives here rather than on the controller because
    /// About displays it in a window that is built once and reused, so it has to
    /// be observable or it shows whatever was true the first time.
    @Published var enhancerSummary: String?

    /// Published because the library folder can change under it: "Choose
    /// library folder…" replaces this whole struct, and anything showing the
    /// path has to follow. `LibraryClient` is a value type, so assigning a new
    /// one is the change.
    @Published var client: LibraryClient
    var onClose: () -> Void = {}
    var onOpenLibrary: () -> Void = {}
    /// Hands one prompt to the library window. Editing is the slow work the
    /// panel is the wrong shape for, so a row's pencil moves you there rather
    /// than growing an editor inside a 460pt strip.
    var onEditPrompt: (String) -> Void = { _ in }
    /// Confirmation has to outlive the panel: the copy closes it, so a message
    /// in the footer is on screen for a few milliseconds and read by nobody.
    var onCopied: (String, Bool) -> Void = { _, _ in }

    init(client: LibraryClient) {
        self.client = client
        let saved = UserDefaults.standard.string(forKey: Self.sortKey) ?? ""
        self.sort = SortMode(rawValue: saved) ?? .name
    }

    /// Filtered, then pinned first, then by the chosen order.
    var filtered: [Prompt] {
        prompts.filter { $0.matches(query) }.sorted { a, b in
            if a.pinned != b.pinned { return a.pinned }
            switch sort {
            case .name:
                break
            case .mostUsed:
                if a.uses != b.uses { return a.uses > b.uses }
            case .lastRefreshed:
                if a.refreshed != b.refreshed { return a.refreshed > b.refreshed }
            case .recentlyUsed:
                if a.lastUsed != b.lastUsed { return a.lastUsed > b.lastUsed }
            }
            return a.title.localizedCaseInsensitiveCompare(b.title) == .orderedAscending
        }
    }

    var current: Prompt? {
        let list = filtered
        guard list.indices.contains(selection) else { return nil }
        return list[selection]
    }

    var staleCount: Int {
        prompts.reduce(0) { $0 + $1.targets.filter { $0.state != "current" }.count }
    }

    // MARK: - Loading

    /// Reload the library.
    ///
    /// `then` runs on the main actor once the new state has landed. It exists
    /// for the menu, which has to draw immediately (an empty menu is worse than
    /// a stale one) and then correct itself when the numbers arrive.
    func reload(then: (@MainActor () -> Void)? = nil) {
        Task.detached { [client] in
            do {
                let data = try client.load()
                await MainActor.run {
                    // Hidden models are dropped here, once, so everything
                    // downstream — chips, ⌘n numbering, the default target —
                    // sees the same list the user sees.
                    self.prompts = data.seeds.map { $0.visibleThrough(ModelFilter.isVisible) }
                    self.allModels = data.models
                    self.history = data.history
                    self.clampSelection()
                    if self.statusIsError { self.clearStatus() }
                    then?()
                }
            } catch {
                await MainActor.run {
                    self.show(error.localizedDescription, isError: true)
                    then?()
                }
            }
        }
    }

    // MARK: - Navigation

    func move(_ delta: Int) {
        let count = filtered.count
        guard count > 0 else { return }
        selection = max(0, min(count - 1, selection + delta))
    }

    func type(_ s: String) { query += s; selection = 0 }

    func backspace() {
        guard !query.isEmpty else { return }
        query.removeLast()
        selection = 0
    }

    private func clampSelection() {
        selection = max(0, min(max(filtered.count - 1, 0), selection))
    }

    func cycleSort() {
        sort = sort.next
        UserDefaults.standard.set(sort.rawValue, forKey: Self.sortKey)
        selection = 0
        show("Sorted by \(sort.label)")
    }

    // MARK: - Copying

    /// Copy the tailored prompt for `target`, building it first when missing.
    /// A render carrying placeholders goes through the fill sheet on the way.
    func copy(_ prompt: Prompt, target: Target, paste: Bool = true) {
        guard !busy else { return }
        if target.isUsable && !target.variables.isEmpty {
            pendingPaste = paste
            filling = FillModel(prompt: prompt, target: target, history: history)
            return
        }
        pendingPaste = paste
        busy = true
        let needsBuild = !target.isUsable
        show(needsBuild ? "Building \(target.name), about a minute…" : "Copying…")

        Task.detached { [client] in
            do {
                if needsBuild { try client.build(id: prompt.id, model: target.model) }
                let body = try client.render(id: prompt.id, model: target.model, record: true)
                let words = body.split(whereSeparator: \.isWhitespace).count
                await MainActor.run {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(body, forType: .string)
                    self.busy = false
                    let message = "Copied for \(target.name) · \(words) words"
                    self.confirm(message)
                    self.reload()
                }
            } catch {
                await MainActor.run {
                    self.busy = false
                    self.show(error.localizedDescription, isError: true)
                }
            }
        }
    }

    /// Substitute the values, copy, and remember them for next time.
    func completeFill() {
        guard let fill = filling else { return }
        filling = nil
        busy = true
        show("Copying…")
        let (id, model, values) = (fill.prompt.id, fill.target.model, fill.assignments)
        let name = fill.target.shortName
        Task.detached { [client] in
            do {
                let body = try client.fill(id: id, model: model, values: values)
                let words = body.split(whereSeparator: \.isWhitespace).count
                await MainActor.run {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(body, forType: .string)
                    self.busy = false
                    let message = "Copied for \(name) · \(words) words"
                    self.confirm(message)
                    self.reload()
                }
            } catch {
                await MainActor.run {
                    self.busy = false
                    self.show(error.localizedDescription, isError: true)
                }
            }
        }
    }

    func cancelFill() {
        filling = nil
        clearStatus()
    }

    func copyIndex(_ index: Int, paste: Bool = true) {
        guard let prompt = current, prompt.targets.indices.contains(index) else { return }
        copy(prompt, target: prompt.targets[index], paste: paste)
    }

    /// What ⏎ does, and what a row's copy and paste buttons do.
    func copyDefault(_ prompt: Prompt, paste: Bool = true) {
        guard let target = prompt.defaultTarget else { return }
        copy(prompt, target: target, paste: paste)
    }

    func copyDefault(paste: Bool = true) {
        guard let prompt = current else { return }
        copyDefault(prompt, paste: paste)
    }

    // MARK: - Pinning and rebuilding

    func togglePin() {
        guard let prompt = current else { return }
        togglePin(prompt)
    }

    func togglePin(_ prompt: Prompt) {
        Task.detached { [client] in
            do {
                try client.pin(id: prompt.id)
                await MainActor.run {
                    self.show(prompt.pinned ? "Unpinned" : "Pinned")
                    self.reload()
                }
            } catch {
                await MainActor.run { self.show(error.localizedDescription, isError: true) }
            }
        }
    }

    enum RebuildScope {
        /// A named prompt rather than "the selected one": a row's rebuild button
        /// acts on its own row, which is not necessarily the selection.
        case everything, prompt(Prompt), pair(Int)
    }

    /// Three scopes, because rebuilding the whole library to fix one prompt is
    /// minutes of LLM calls nobody asked for.
    func rebuild(scope: RebuildScope) {
        guard !busy else { return }
        let id: String?
        let model: String?
        let message: String

        switch scope {
        case .everything:
            (id, model) = (nil, nil)
            message = "Rebuilding \(staleCount) stale prompt\(staleCount == 1 ? "" : "s")…"
        case .prompt(let prompt):
            (id, model) = (prompt.id, nil)
            message = "Rebuilding \(prompt.title)…"
        case .pair(let index):
            guard let prompt = current, prompt.targets.indices.contains(index) else { return }
            (id, model) = (prompt.id, prompt.targets[index].model)
            message = "Rebuilding \(prompt.targets[index].shortName)…"
        }

        busy = true
        show(message)
        Task.detached { [client] in
            do {
                try client.rebuild(id: id, model: model)
                await MainActor.run {
                    self.busy = false
                    self.show("Rebuild finished")
                    self.reload()
                }
            } catch {
                await MainActor.run {
                    self.busy = false
                    self.show(error.localizedDescription, isError: true)
                }
            }
        }
    }

    // MARK: - Editing and deleting

    func edit(_ prompt: Prompt) { onEditPrompt(prompt.id) }

    func edit() {
        guard let prompt = current else { return }
        edit(prompt)
    }

    /// A delete throws away renders that cost real LLM calls, so it asks first —
    /// the same guard the library window has carried since it could delete at
    /// all, and the reason the confirmation names the count.
    func requestDelete(_ prompt: Prompt) {
        guard !busy else { return }
        pendingDelete = prompt
    }

    func requestDelete() {
        guard let prompt = current else { return }
        requestDelete(prompt)
    }

    func cancelDelete() { pendingDelete = nil }

    func confirmDelete() {
        guard let prompt = pendingDelete else { return }
        pendingDelete = nil
        busy = true
        show("Deleting \(prompt.title)…")
        Task.detached { [client] in
            do {
                let message = try client.remove(id: prompt.id)
                await MainActor.run {
                    self.busy = false
                    self.show(message)
                    self.reload()
                }
            } catch {
                await MainActor.run {
                    self.busy = false
                    self.show(error.localizedDescription, isError: true)
                }
            }
        }
    }

    /// Confirm a copy in three places at once, because the panel is about to
    /// close: a green line in the footer, a checkmark in the menu bar, and a
    /// short pause before dismissing so the line can actually be read.
    func confirm(_ message: String) {
        status = "✓ " + message
        statusIsError = false
        statusIsGood = true
        let paste = pendingPaste && Paster.isEnabled
        onCopied(message, paste)
        // A paste needs the panel gone at once so focus can return to the target;
        // a plain copy lingers a moment so the green line can be read.
        if paste {
            onClose()
        } else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) { [weak self] in
                self?.onClose()
            }
        }
    }

    func show(_ message: String, isError: Bool = false) {
        status = message
        statusIsError = isError
        statusIsGood = false
    }

    func clearStatus() {
        status = ""
        statusIsError = false
        statusIsGood = false
    }
}

/// Keyboard capture. A focused SwiftUI TextField swallows the arrow keys, so the
/// panel has no text field at all: an AppKit first responder takes every key and
/// the query is drawn as plain text.
struct KeyCatcher: NSViewRepresentable {
    let model: HUDModel

    func makeNSView(context: Context) -> NSView {
        let view = CatcherView()
        view.model = model
        DispatchQueue.main.async { view.window?.makeFirstResponder(view) }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async {
            guard let window = nsView.window, window.firstResponder !== nsView else { return }
            window.makeFirstResponder(nsView)
        }
    }

    final class CatcherView: NSView {
        var model: HUDModel?
        override var acceptsFirstResponder: Bool { true }

        /// kVK_ANSI_1…9 are not contiguous, hence the table.
        private static let digitKeyCodes: [UInt16: Int] = [
            18: 1, 19: 2, 20: 3, 21: 4, 23: 5, 22: 6, 26: 7, 28: 8, 25: 9,
        ]

        static func digit(forKeyCode code: UInt16) -> Int? { digitKeyCodes[code] }

        override func keyDown(with event: NSEvent) {
            // While the fill sheet or the delete confirmation is up, it owns the
            // keyboard — otherwise typing filters the list behind a dialog.
            guard let model, model.filling == nil, model.pendingDelete == nil else {
                return super.keyDown(with: event)
            }
            let flags = event.modifierFlags

            switch event.keyCode {
            case 53: model.onClose(); return                 // esc
            case 36, 76:                                     // return / enter
                model.copyDefault(paste: !flags.contains(.shift)); return
            case 125: model.move(1); return                  // down
            case 126: model.move(-1); return                 // up
            case 51:                                         // delete
                // ⌘⌫ deletes the prompt; bare ⌫ edits the query. Checked here
                // rather than in the ⌘ block below, which never sees ⌫.
                flags.contains(.command) ? model.requestDelete() : model.backspace()
                return
            default: break
            }

            let key = (event.charactersIgnoringModifiers ?? "").lowercased()
            guard flags.contains(.command) else {
                if let s = event.characters, !s.isEmpty, let first = s.first,
                   first.isLetter || first.isNumber || first == " " || first.isPunctuation {
                    model.type(s)
                }
                return
            }

            // Digits come from the key CODE, not the character. With shift held,
            // `charactersIgnoringModifiers` reports "!" rather than "1", so
            // `Int(key)` was nil and ⇧⌘1–9 fell through to the switch below and
            // was swallowed — it did nothing at all. `digit(forKeyCode:)` was
            // written for exactly this and then never called from here.
            //
            // Shift is also the modifier that means copy-without-paste, so it
            // has to reach `copyIndex`; the old call took the default and always
            // pasted.
            if let n = Self.digit(forKeyCode: event.keyCode) {
                // ⌥⌘n rebuilds that one model; ⌘n copies it, pasting unless ⇧.
                if flags.contains(.option) {
                    model.rebuild(scope: .pair(n - 1))
                } else {
                    model.copyIndex(n - 1, paste: !flags.contains(.shift))
                }
                return
            }
            switch key {
            case "r":
                if flags.contains(.shift) {
                    model.rebuild(scope: .everything)
                } else if let prompt = model.current {
                    model.rebuild(scope: .prompt(prompt))
                }
            case "d": model.togglePin()
            case "e": model.edit()
            case "s": model.cycleSort()
            case "l": model.onOpenLibrary()
            default: break   // swallowed, so a command key never types into the query
            }
        }
    }
}

struct HUDView: View {
    @ObservedObject var model: HUDModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            searchLine
            SeedbedDivider()
            if model.filtered.isEmpty {
                Text(model.prompts.isEmpty ? "No prompts yet." : "No matches.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                list
            }
            SeedbedDivider()
            footer
        }
        .frame(minWidth: Tokens.Size.panel.width, minHeight: Tokens.Size.panel.height)
        .sheet(item: $model.filling) { fill in
            FillSheet(model: fill, onCancel: { model.cancelFill() },
                      onCopy: { model.completeFill() })
        }
        // Same guard the library window has: a delete destroys renders that
        // cost real LLM calls, so the count is on screen before you agree to it.
        .confirmationDialog(
            "Delete \(model.pendingDelete?.title ?? "this prompt")?",
            isPresented: Binding(get: { model.pendingDelete != nil },
                                 set: { if !$0 { model.cancelDelete() } }),
            titleVisibility: .visible
        ) {
            Button(deleteButtonTitle, role: .destructive) { model.confirmDelete() }
            Button("Cancel", role: .cancel) { model.cancelDelete() }
        } message: {
            Text("The rendered versions cost LLM calls to make and will be deleted too.")
        }
        // Without this the window's title-bar strip is still reserved and the
        // search line sits ~40pt below the top edge, which is the empty band
        // that made the panel look broken.
        .ignoresSafeArea(.container, edges: .top)
        .background(.ultraThinMaterial)
        .tint(Tokens.accent)
        .background(KeyCatcher(model: model).frame(width: 0, height: 0))
    }

    private var deleteButtonTitle: String {
        let count = model.pendingDelete?.renderCount ?? 0
        return count == 0
            ? "Delete prompt"
            : "Delete prompt and its \(count) render\(count == 1 ? "" : "s")"
    }

    private var searchLine: some View {
        HStack(spacing: Tokens.Space.tight) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                .font(.system(size: Tokens.IconSize.compact))
            // The caret is part of the query, not a sibling of it: at the outer
            // spacing it floated a word-width away from the last letter typed.
            HStack(spacing: 1) {
                Text(model.query.isEmpty ? "Search prompts…" : model.query)
                    .foregroundStyle(model.query.isEmpty ? .secondary : .primary)
                Rectangle().fill(Tokens.accent.opacity(0.8)).frame(width: 1.5, height: 14)
            }
            Spacer(minLength: Tokens.Space.tight)
            Button { model.cycleSort() } label: {
                HStack(spacing: Tokens.Space.row) {
                    Image(systemName: "arrow.up.arrow.down").font(.system(size: Tokens.IconSize.tiny))
                    Text(model.sort.label).font(Tokens.FontScale.micro)
                }
                .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Sort order (⌘S)")
            Button { model.onClose() } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: Tokens.IconSize.compact)).foregroundStyle(.tertiary)
            }
            .buttonStyle(.plain)
            .help("Close (esc)")
        }
        .chromeBar()
    }

    private var list: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: Tokens.ChipPadding.v) {
                    ForEach(Array(model.filtered.enumerated()), id: \.element.id) { index, prompt in
                        PromptRow(model: model, prompt: prompt, selected: index == model.selection)
                            .id(prompt.id)
                            .contentShape(Rectangle())
                            .onTapGesture { model.selection = index }
                    }
                }
                .padding(.top, Tokens.Space.row6)
                .padding(.bottom, Tokens.Space.medium)
            }
            .onChange(of: model.selection) { _, new in
                let list = model.filtered
                guard list.indices.contains(new) else { return }
                withAnimation(Tokens.Motion.microCurve) { proxy.scrollTo(list[new].id, anchor: .center) }
            }
        }
    }

    private var footer: some View {
        HStack(spacing: Tokens.Space.medium) {
            if model.status.isEmpty {
                hint("↑↓", "move"); hint("⏎", "copy"); hint("⌘1–9", "model")
                hint("⌘D", "pin"); hint("⌘L", "library"); hint("esc", "close")
            } else {
                Text(model.status)
                    .font(Tokens.FontScale.tiny.weight(model.statusIsGood ? .medium : .regular))
                    .foregroundStyle(model.statusIsError ? Tokens.danger
                                     : model.statusIsGood ? Tokens.positive : Color.secondary)
                    .lineLimit(2).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: Tokens.Space.row)
            if model.busy { ProgressView().controlSize(.small) }
        }
        .chromeBar()
    }

    private func hint(_ key: String, _ label: String) -> some View {
        HStack(spacing: Tokens.Space.row) {
            Text(key).font(Tokens.FontScale.monoTiny)
                .padding(.horizontal, Tokens.ChipPadding.h)
                .padding(.vertical, Tokens.ChipPadding.v)
                .background(RoundedRectangle(cornerRadius: Tokens.Radius.chip).fill(Tokens.Surface.sunken))
                .overlay(RoundedRectangle(cornerRadius: Tokens.Radius.chip)
                    .stroke(Tokens.Surface.hairline, lineWidth: 0.5))
            Text(label).font(Tokens.FontScale.micro).foregroundStyle(.secondary)
        }
    }
}

/// One prompt on one line, with everything you can do to it on the line itself.
///
/// A view rather than a `func row(...)` on HUDView because it needs `@State` for
/// the hover, which a function returning a view cannot hold. Same shape as
/// Reference-style dense row: the trailing slot carries the usage badge at rest
/// and the action strip while the pointer is over the row.
///
/// The buttons act on THIS prompt and deliberately leave the selection where it
/// is — reaching for a row's pin should not move what ⏎ would copy.
struct PromptRow: View {
    @ObservedObject var model: HUDModel
    let prompt: Prompt
    let selected: Bool
    @State private var hovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: Tokens.Space.row) {
            HStack(spacing: Tokens.Space.row6) {
                if prompt.pinned {
                    Image(systemName: "pin.fill")
                        .font(.system(size: Tokens.IconSize.tiny)).foregroundStyle(Tokens.accent)
                }
                Text(prompt.title).font(Tokens.FontScale.body.weight(.medium)).lineLimit(1)
                Spacer(minLength: Tokens.Space.row)
                if hovering {
                    actions
                } else if prompt.uses > 0 {
                    Text("\(prompt.uses)×").font(Tokens.FontScale.nano).foregroundStyle(.tertiary)
                }
            }
            Text(prompt.body).font(Tokens.FontScale.tiny).foregroundStyle(.secondary).lineLimit(1)
            if selected { chips }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, Tokens.Space.snug)
        .padding(.vertical, Tokens.Space.tight)
        .background(selected ? Tokens.Fill.selected
                    : hovering ? Color.secondary.opacity(0.07) : .clear)
        .cornerRadius(Tokens.Radius.card)
        .padding(.horizontal, Tokens.Space.row6)
        .onHover { hovering = $0 }
    }

    private var actions: some View {
        PromptRowActions(
            targetName: prompt.defaultTarget?.shortName,
            pinned: prompt.pinned,
            renderCount: prompt.renderCount,
            onCopy: { model.copyDefault(prompt, paste: false) },
            // Hidden rather than disabled when pasting is switched off: the row
            // is saying the action does not apply, not that it failed.
            onPaste: Paster.isEnabled ? { model.copyDefault(prompt, paste: true) } : nil,
            onRebuild: { model.rebuild(scope: .prompt(prompt)) },
            onEdit: { model.edit(prompt) },
            onPin: { model.togglePin(prompt) },
            onDelete: { model.requestDelete(prompt) })
    }

    /// Chips wrap, so seven targets stack into rows instead of running off the
    /// edge. State is a coloured dot rather than words, which is what keeps them
    /// narrow enough for wrapping to work.
    private var chips: some View {
        LazyVGrid(
            columns: [GridItem(.adaptive(minimum: 116), spacing: Tokens.Space.row6,
                               alignment: .leading)],
            alignment: .leading, spacing: Tokens.Space.row
        ) {
            ForEach(Array(prompt.targets.enumerated()), id: \.element.id) { index, target in
                chip(target, shortcut: index + 1, favourite: target.model == prompt.favouriteModel)
            }
        }
        .padding(.top, Tokens.Space.row)
    }

    private func chip(_ target: Target, shortcut: Int, favourite: Bool) -> some View {
        HStack(spacing: Tokens.Space.row) {
            if shortcut <= 9 {
                Text("⌘\(shortcut)").font(Tokens.FontScale.monoTiny)
                    .foregroundStyle(.secondary)
            }
            Circle().fill(target.dotColor).frame(width: 5, height: 5)
            Text(target.shortName)
                .font(Tokens.FontScale.micro.weight(favourite ? .semibold : .regular))
                .lineLimit(1)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, Tokens.ChipPadding.h)
        .padding(.vertical, Tokens.ChipPadding.v)
        .background(Capsule().fill(Color.secondary.opacity(target.isUsable ? 0.14 : 0.06)))
        .opacity(target.isUsable ? 1 : 0.7)
        .help("\(target.name): \(target.label). ⌘\(shortcut) copies, ⌥⌘\(shortcut) rebuilds.")
        .onTapGesture { model.copy(prompt, target: target) }
    }
}
