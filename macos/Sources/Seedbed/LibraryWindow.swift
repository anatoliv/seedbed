import AppKit
import SwiftUI

/// The big window: browse the library, edit a seed, and read what each model
/// made of it side by side.
///
/// Deliberately a separate surface from the HUD panel. The panel is for grabbing
/// a prompt in two seconds without breaking flow; this is for the slower work of
/// writing prompts and judging the renders, where a 460pt strip is the wrong
/// shape and dismiss-on-click-away is actively hostile.
@MainActor
final class LibraryModel: ObservableObject {
    @Published var prompts: [Prompt] = []
    @Published var allModels: [LibraryData.ModelRef] = []
    /// The context vocabulary, straight from `promptlib json`. Not a constant
    /// here, so the picker cannot offer something the library would reject.
    @Published var contexts: [LibraryData.ContextRef] = []
    @Published var categories: [String] = []
    @Published var search = ""
    @Published var categoryFilter: String?
    @Published var selection: String?
    /// A prompt the window was opened to show — from a HUD row's pencil. Held
    /// until the next reload rather than applied at once, because the seed list
    /// is loaded asynchronously and selecting an id the model has not seen yet
    /// does nothing.
    var pendingSelection: String?
    /// The prompt a delete is waiting on, and what the confirmation names. A
    /// row's trash and the sidebar's − both set it, so there is one delete path.
    @Published var pendingDelete: Prompt?
    @Published var status = ""
    @Published var statusIsError = false
    @Published var busy = false

    /// The seed being edited, held apart from `prompts` so typing does not fight
    /// a reload, and so Save is an explicit act.
    @Published var draftTitle = ""
    @Published var draftBody = ""
    @Published var draftTargets: Set<String> = []
    @Published var draftCategory = ""
    @Published var draftContext = "agent"

    /// Derived, never set by a binding. SwiftUI calls a binding's setter during
    /// first layout with the value it already has, which marked a freshly
    /// selected prompt "unsaved" before anything was typed.
    var dirty: Bool {
        guard let prompt = current else { return false }
        return draftTitle != prompt.title
            || draftBody != prompt.body
            || draftCategory != prompt.category
            || draftContext != prompt.context
            || draftTargets != Set(prompt.targets.map(\.model))
    }

    /// Render bodies for the compare columns, fetched once per selection.
    /// They are not in the library JSON on purpose — that would carry every
    /// render on every reload — so they are loaded here, off the main thread.
    @Published var bodies: [String: String] = [:]

    /// Which models are actually being rebuilt right now. Without this the UI
    /// could not tell you the scope of what it was doing, and blanking every
    /// column after one rebuild looked exactly like rebuilding all of them.
    @Published var rebuilding: Set<String> = []

    /// Bumped when the shared model filter changes, purely to redraw.
    @Published var filterRevision = 0
    /// SwiftUI honours ONE sheet per view. Two `.sheet` modifiers meant the
    /// last one won and the enhancer editor never presented, so both sheets are
    /// driven by this single value.
    /// Configuration lives in the Settings window now, not in sheets on this
    /// one. The header menu still offers it because that is where you are when
    /// you notice a model is missing.
    var onOpenSettings: (SettingsPage) -> Void = { _ in }

    @Published var comparison: ComparisonData?
    @Published var comparisonBusy = false
    /// Bumped when the column order changes, purely to redraw.
    @Published var orderRevision = 0

    var client: LibraryClient

    init(client: LibraryClient) { self.client = client }

    var current: Prompt? { prompts.first { $0.id == selection } }

    /// Search and category narrow the same list, so a filter is never invisible.
    var visiblePrompts: [Prompt] {
        prompts.filter { prompt in
            (categoryFilter == nil || prompt.category == categoryFilter)
                && prompt.matches(search)
        }
    }

    func reload(keepingDraft: Bool = false) {
        Task.detached { [client] in
            do {
                let data = try client.load()
                await MainActor.run {
                    self.prompts = data.seeds
                    self.allModels = data.models
                    self.contexts = data.contexts
                    self.categories = data.categories
                    if let wanted = self.pendingSelection,
                       data.seeds.contains(where: { $0.id == wanted }) {
                        self.pendingSelection = nil
                        self.select(wanted)
                    } else if self.selection == nil || !data.seeds.contains(where: { $0.id == self.selection }) {
                        self.pendingSelection = nil
                        self.select(data.seeds.first?.id)
                    } else if !keepingDraft {
                        self.loadDraft()
                    }
                }
            } catch {
                await MainActor.run { self.report(error.localizedDescription, isError: true) }
            }
        }
    }

    func select(_ id: String?) {
        selection = id
        loadDraft()
        loadBodies(clearFirst: true)
        comparison = nil
        loadComparison()
    }

    /// The cached comparison only. Generating one costs an LLM call, so that is
    /// an explicit act — `force` — not something a selection triggers.
    func loadComparison(force: Bool = false) {
        guard let id = selection, let prompt = current else { return }
        guard prompt.comparison != "not-applicable" else { comparison = nil; return }
        if prompt.comparison == "missing" && !force { comparison = nil; return }
        comparisonBusy = true
        Task.detached { [client] in
            let result = try? client.comparison(id: id, force: force)
            await MainActor.run {
                guard self.selection == id else { return }
                self.comparisonBusy = false
                self.comparison = result
                if force, result != nil { self.reload() }
            }
        }
    }

    /// Create a prompt and drop straight into editing it. The id is derived
    /// from the title on first save; until then it is a placeholder, because a
    /// prompt with no name cannot be written to a file.
    func newPrompt() {
        guard !busy else { return }
        var candidate = "new-prompt"
        var suffix = 2
        let taken = Set(prompts.map(\.id))
        while taken.contains(candidate) {
            candidate = "new-prompt-\(suffix)"
            suffix += 1
        }
        busy = true
        report("Creating…")
        let id = candidate
        Task.detached { [client] in
            do {
                _ = try client.save(id: id, title: "New prompt",
                                    body: "describe the task in one line",
                                    category: "", targets: [], context: "agent")
                await MainActor.run {
                    self.busy = false
                    self.report("Created. Edit it, then Save")
                    self.search = ""
                    self.categoryFilter = nil
                    self.reload()
                    // Select it once the reload has landed.
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                        self.select(id)
                    }
                }
            } catch {
                await MainActor.run {
                    self.busy = false
                    self.report(error.localizedDescription, isError: true)
                }
            }
        }
    }

    // MARK: - Row actions
    //
    // Each takes the prompt to act on rather than reading `selection`, because a
    // sidebar row's buttons act on THEIR row — which is not necessarily the one
    // being edited in the pane beside them.

    /// Delete a prompt and everything generated from it. Always routed through
    /// the confirmation, because renders cost real LLM calls and this throws
    /// them away; `pendingDelete` is what the dialog names.
    func requestDelete(_ prompt: Prompt) {
        guard !busy else { return }
        pendingDelete = prompt
    }

    func cancelDelete() { pendingDelete = nil }

    func confirmDelete() {
        guard let prompt = pendingDelete else { return }
        pendingDelete = nil
        busy = true
        report("Deleting \(prompt.title)…")
        let wasSelected = prompt.id == selection
        Task.detached { [client] in
            do {
                let message = try client.remove(id: prompt.id)
                await MainActor.run {
                    self.busy = false
                    if wasSelected { self.selection = nil }
                    self.report(message)
                    self.reload()
                }
            } catch {
                await MainActor.run {
                    self.busy = false
                    self.report(error.localizedDescription, isError: true)
                }
            }
        }
    }

    /// Copy the model this prompt is usually copied for. The compare pane's
    /// per-column Copy is the deliberate choice of a model; this is the quick one.
    func copyDefault(_ prompt: Prompt) {
        guard let target = prompt.defaultTarget, target.isUsable else {
            report("Nothing built for \(prompt.title) yet. Rebuild it first", isError: true)
            return
        }
        Task.detached { [client] in
            do {
                let body = try client.render(id: prompt.id, model: target.model, record: true)
                await MainActor.run {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(body, forType: .string)
                    self.report("Copied \(target.shortName) with placeholders left unfilled")
                    self.reload()
                }
            } catch {
                await MainActor.run { self.report(error.localizedDescription, isError: true) }
            }
        }
    }

    func togglePin(_ prompt: Prompt) {
        Task.detached { [client] in
            do {
                try client.pin(id: prompt.id)
                await MainActor.run {
                    self.report(prompt.pinned ? "Unpinned \(prompt.title)"
                                              : "Pinned \(prompt.title)")
                    self.reload(keepingDraft: true)
                }
            } catch {
                await MainActor.run { self.report(error.localizedDescription, isError: true) }
            }
        }
    }

    /// Rebuild every model of one prompt. For the selected prompt this is the
    /// header's button, which also refreshes the compare columns; for any other
    /// row there are no columns on screen to refresh.
    func rebuild(_ prompt: Prompt) {
        guard !busy else { return }
        guard prompt.id != selection else { return rebuild(model: nil) }
        busy = true
        report("Rebuilding \(prompt.title), \(prompt.targets.count) models…")
        Task.detached { [client] in
            do {
                try client.rebuild(id: prompt.id, model: nil)
                await MainActor.run {
                    self.busy = false
                    self.report("Rebuilt \(prompt.title)")
                    self.reload(keepingDraft: true)
                }
            } catch {
                await MainActor.run {
                    self.busy = false
                    self.report(error.localizedDescription, isError: true)
                }
            }
        }
    }

    func moveColumn(_ id: String, by delta: Int) {
        let current = (self.current?.targets ?? []).map(\.model)
        let arranged = ModelOrder.sorted(current, id: { $0 })
        ModelOrder.move(id, by: delta, within: arranged)
        orderRevision += 1
    }

    /// One process per built model, on a background task. Doing this from a
    /// SwiftUI body — as the first version did — spawns a subprocess on every
    /// redraw and blocks the main thread while it runs.
    /// `only` refreshes a single column and leaves the rest on screen; clearing
    /// is for a change of prompt, when the old text really is wrong.
    func loadBodies(only: String? = nil, clearFirst: Bool = false) {
        if clearFirst { bodies = [:] }
        guard let id = selection, let prompt = current else { return }
        // `only` is trusted over the cached state: after a rebuild the snapshot
        // still says "missing" (reload has not landed yet), so filtering by
        // isUsable here left the column that was just built stuck on "Loading…".
        let targets = only.map { [$0] }
            ?? prompt.targets.filter(\.isUsable).map(\.model)
        Task.detached { [client] in
            for target in targets {
                let text = (try? client.render(id: id, model: target))
                    ?? "Could not read this render."
                await MainActor.run {
                    // Selection may have moved on while this was loading.
                    guard self.selection == id else { return }
                    self.bodies[target] = text
                }
            }
        }
    }

    private func loadDraft() {
        guard let prompt = current else {
            draftTitle = ""; draftBody = ""; draftCategory = ""; draftTargets = []
            draftContext = "agent"
            return
        }
        draftTitle = prompt.title
        draftBody = prompt.body
        draftCategory = prompt.category
        draftContext = prompt.context
        draftTargets = Set(prompt.targets.map(\.model))
    }

    func save() {
        guard let id = selection, dirty, !busy else { return }
        busy = true
        report("Saving…")
        let (title, body, category) = (draftTitle, draftBody, draftCategory)
        let targets = Array(draftTargets).sorted()
        let context = draftContext
        Task.detached { [client] in
            do {
                let message = try client.save(id: id, title: title, body: body,
                                              category: category, targets: targets,
                                              context: context)
                await MainActor.run {
                    self.busy = false
                    self.report(message)
                    self.reload()
                }
            } catch {
                await MainActor.run {
                    self.busy = false
                    self.report(error.localizedDescription, isError: true)
                }
            }
        }
    }

    func rebuild(model: String?) {
        guard let id = selection, let prompt = current, !busy else { return }
        let scope = model.map { [$0] } ?? prompt.targets.map(\.model)
        let names = scope.compactMap { id in
            prompt.targets.first { $0.model == id }?.shortName
        }
        busy = true
        rebuilding = Set(scope)
        report(scope.count == 1
               ? "Rebuilding \(names.first ?? scope[0]) only…"
               : "Rebuilding \(scope.count) models: \(names.joined(separator: ", "))…")

        Task.detached { [client] in
            do {
                try client.rebuild(id: id, model: model)
                await MainActor.run {
                    self.busy = false
                    self.rebuilding = []
                    self.report(scope.count == 1
                                ? "Rebuilt \(names.first ?? scope[0])"
                                : "Rebuilt \(scope.count) models")
                    self.reload()
                    // The comparison is now stale by construction; drop it
                    // rather than showing a description of prompts that changed.
                    self.comparison = nil
                    // Only the columns that actually changed are re-read; the
                    // others keep their text rather than flashing "Loading…".
                    for target in scope { self.loadBodies(only: target) }
                }
            } catch {
                await MainActor.run {
                    self.busy = false
                    self.rebuilding = []
                    self.report(error.localizedDescription, isError: true)
                }
            }
        }
    }

    func copy(_ target: Target) {
        guard let id = selection else { return }
        Task.detached { [client] in
            do {
                let body = try client.render(id: id, model: target.model, record: true)
                await MainActor.run {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(body, forType: .string)
                    self.report("Copied \(target.shortName) with placeholders left unfilled")
                    self.reload()
                }
            } catch {
                await MainActor.run { self.report(error.localizedDescription, isError: true) }
            }
        }
    }

    /// One notion of "shown", shared with the HUD panel. Three separate model
    /// lists — per-prompt targets, quick-picker visibility, compare columns —
    /// was one too many to hold in your head; the middle one now drives both UIs.
    func toggleVisible(_ id: String) {
        ModelFilter.toggle(id, allKnown: allModels.map(\.id))
        filterRevision += 1
    }

    func showAllModels() {
        ModelFilter.showAll()
        filterRevision += 1
    }

    func report(_ message: String, isError: Bool = false) {
        status = message
        statusIsError = isError
    }
}

struct LibraryView: View {
    @ObservedObject var model: LibraryModel
    @State private var tab: Tab =
        ProcessInfo.processInfo.environment["SEEDBED_OPEN_LIBRARY"] == "compare" ? .compare : .edit

    enum Tab: String, CaseIterable, Identifiable {
        case edit = "Edit", compare = "Compare"
        var id: String { rawValue }
    }

    var body: some View {
        HStack(spacing: 0) {
            sidebar.frame(width: Tokens.Width.librarySidebar)
            Divider()
            VStack(spacing: 0) {
                header
                Divider()
                if model.prompts.isEmpty {
                    VStack(spacing: 10) {
                        Text("No prompts yet").font(.system(size: Tokens.ReadingSize.heading,
                                                            weight: .medium))
                        Text("A prompt starts as one short line. The library writes the "
                             + "long, model-shaped version.")
                            .font(.system(size: Tokens.ReadingSize.meta))
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center).frame(maxWidth: 320)
                        Button("New prompt") { model.newPrompt() }
                            .buttonStyle(.borderedProminent)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if model.current == nil {
                    Text("Select a prompt").foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if tab == .edit {
                    EditPane(model: model)
                } else {
                    ComparePane(model: model)
                }
                Divider()
                statusBar
            }
        }
        .frame(minWidth: Tokens.Size.library.width, minHeight: Tokens.Size.library.height)
        .onAppear { model.reload() }
        .confirmationDialog(
            "Delete \(model.pendingDelete?.title ?? "this prompt")?",
            isPresented: Binding(get: { model.pendingDelete != nil },
                                 set: { if !$0 { model.cancelDelete() } }),
            titleVisibility: .visible
        ) {
            Button("Delete prompt and its \(model.pendingDelete?.renderCount ?? 0) render(s)",
                   role: .destructive) { model.confirmDelete() }
            Button("Cancel", role: .cancel) { model.cancelDelete() }
        } message: {
            Text("The rendered versions cost LLM calls to make and will be deleted too.")
        }
    }

    private var sidebar: some View {
        VStack(spacing: 0) {
            filters
            Divider()
            List(selection: Binding(get: { model.selection }, set: { model.select($0) })) {
                ForEach(model.visiblePrompts) { prompt in
                    SidebarRow(model: model, prompt: prompt).tag(prompt.id)
                }
            }
            Divider()
            HStack(spacing: Tokens.Space.control) {
                Button { model.newPrompt() } label: { Image(systemName: "plus") }
                    .help("New prompt (⌘N)")
                    .disabled(model.busy)
                Button {
                    if let prompt = model.current { model.requestDelete(prompt) }
                } label: { Image(systemName: "minus") }
                    .help("Delete this prompt and everything generated from it")
                    .disabled(model.selection == nil || model.busy)
                Spacer()
                Text(model.visiblePrompts.count == model.prompts.count
                     ? "\(model.prompts.count) prompts"
                     : "\(model.visiblePrompts.count) of \(model.prompts.count)")
                    .font(.system(size: Tokens.ReadingSize.label)).foregroundStyle(.secondary)
            }
            .buttonStyle(.borderless)
            .chromeBar()
        }
    }

    private var filters: some View {
        VStack(alignment: .leading, spacing: Tokens.Space.group) {
            HStack(spacing: Tokens.Space.control) {
                Image(systemName: "magnifyingglass").font(.system(size: Tokens.ReadingSize.meta))
                    .foregroundStyle(.secondary)
                TextField("Search", text: $model.search)
                    .textFieldStyle(.plain).font(.system(size: Tokens.ReadingSize.body))
                if !model.search.isEmpty {
                    Button { model.search = "" } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary)
                    }
                    .buttonStyle(.plain)
                }
            }
            // A Picker centres itself in whatever it is given. fixedSize keeps
            // it at its content width and the Spacer holds it against the left
            // edge, in line with the search field and the rows below.
            HStack(spacing: 0) {
                Picker("", selection: $model.categoryFilter) {
                    Text("All categories").tag(String?.none)
                    ForEach(model.categories, id: \.self) { Text($0).tag(String?.some($0)) }
                }
                .labelsHidden()
                .font(.system(size: Tokens.ReadingSize.meta))
                .fixedSize()
                .disabled(model.categories.isEmpty)
                Spacer(minLength: 0)
            }
        }
        .chromeBar()
    }

    private var header: some View {
        HStack(spacing: Tokens.Space.control) {
            Picker("", selection: $tab) {
                ForEach(Tab.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 170)

            Spacer()

            Menu {
                Section("Shown in the picker and here") {
                    ForEach(model.allModels, id: \.id) { entry in
                        Toggle(entry.name, isOn: Binding(
                            get: { ModelFilter.isVisible(entry.id) },
                            set: { _ in model.toggleVisible(entry.id) }))
                    }
                }
                Divider()
                Button("Show all") { model.showAllModels() }
                Divider()
                Button("Add or configure models…") { model.onOpenSettings(.models) }
                Divider()
                Button("Build with… (the model that writes prompts)") {
                    model.onOpenSettings(.building)
                }
            } label: {
                Label("Models", systemImage: "square.stack.3d.up")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help("Hide models you are not using today. Nothing is deleted.")

            Button { model.newPrompt() } label: {
                Label("New", systemImage: "plus")
            }
            .disabled(model.busy)

            Button {
                model.rebuild(model: nil)
            } label: {
                Label(model.current.map { "Rebuild all \($0.targets.count) models" }
                      ?? "Rebuild all models", systemImage: "arrow.clockwise")
            }
            .disabled(model.busy || model.selection == nil)
            .help("Every model this prompt is built for. Minutes of LLM calls")

            if tab == .edit {
                Button("Save") { model.save() }
                    .keyboardShortcut("s")
                    .disabled(!model.dirty || model.busy)
                    .buttonStyle(.borderedProminent)
            }
        }
        .chromeBar()
    }

    private var statusBar: some View {
        HStack(spacing: Tokens.Space.control) {
            if model.busy { ProgressView().controlSize(.small) }
            Text(model.status.isEmpty ? " " : model.status)
                .font(.system(size: Tokens.ReadingSize.meta))
                .foregroundStyle(model.statusIsError ? Color.red : .secondary)
                .lineLimit(1)
            Spacer()
            if model.dirty {
                Text("unsaved changes").font(.system(size: Tokens.ReadingSize.meta)).foregroundStyle(.orange)
            }
        }
        .chromeBar()
    }
}

/// Editing the seed. Saving is explicit, and the warning about what it costs is
/// on screen before you press it: a changed body invalidates every render.
struct EditPane: View {
    @ObservedObject var model: LibraryModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Tokens.Space.field) {
                FormField("Title") {
                    TextField("", text: $model.draftTitle)
                        .textFieldStyle(.roundedBorder)
                }

                FormField("The prompt: keep it short, the enhancer expands it") {
                    TextEditor(text: $model.draftBody)
                    .font(.system(size: Tokens.ReadingSize.body, design: .monospaced))
                    .frame(minHeight: 90)
                    .padding(4)
                    .overlay(RoundedRectangle(cornerRadius: Tokens.Radius.card)
                        .stroke(Color.secondary.opacity(0.3), lineWidth: 1))
                }

                FormField("Category: groups the list and narrows search") {
                    HStack(spacing: Tokens.Space.control) {
                        TextField("e.g. Coding", text: $model.draftCategory)
                            .textFieldStyle(.roundedBorder)
                            .frame(maxWidth: 240)
                        if !model.categories.isEmpty {
                            Menu {
                                ForEach(model.categories, id: \.self) { existing in
                                    Button(existing) { model.draftCategory = existing }
                                }
                                Divider()
                                Button("None") { model.draftCategory = "" }
                            } label: {
                                Image(systemName: "chevron.down")
                            }
                            .menuStyle(.borderlessButton)
                            // .borderlessButton draws its own indicator, so the
                            // explicit chevron made two.
                            .menuIndicator(.hidden)
                            .frame(width: 20)
                        }
                    }
                }

                FormField("Where you paste it, which changes what gets built") {
                    VStack(alignment: .leading, spacing: Tokens.Space.row) {
                        Picker("", selection: $model.draftContext) {
                            ForEach(model.contexts) { context in
                                Text(context.label).tag(context.id)
                            }
                        }
                        .labelsHidden().pickerStyle(.radioGroup)
                        // The description comes from promptlib, so this can
                        // never describe a context the library would refuse.
                        if let chosen = model.contexts.first(where: { $0.id == model.draftContext }) {
                            Caption(chosen.description)
                        }
                        if let prompt = model.current, prompt.context != model.draftContext {
                            Label("Changing this makes every render of it stale. "
                                  + "rebuild after saving.",
                                  systemImage: "exclamationmark.triangle")
                                .font(.system(size: Tokens.ReadingSize.meta))
                                .foregroundStyle(Tokens.warning)
                        }
                    }
                }

                FormField("Models this prompt is built for") {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 190), alignment: .leading)],
                              alignment: .leading, spacing: Tokens.Space.group) {
                        ForEach(model.allModels, id: \.id) { entry in
                            Toggle(entry.name, isOn: Binding(
                                get: { model.draftTargets.contains(entry.id) },
                                set: { on in
                                    if on { model.draftTargets.insert(entry.id) }
                                    else { model.draftTargets.remove(entry.id) }
                                }))
                            .font(.system(size: Tokens.ReadingSize.body))
                        }
                    }
                }

                if let prompt = model.current, prompt.body != model.draftBody {
                    Label("Changing the text makes every render of it stale. Rebuild after saving.",
                          systemImage: "exclamationmark.triangle")
                        .font(.system(size: Tokens.ReadingSize.meta)).foregroundStyle(.orange)
                }

                Text("Use {{PLACEHOLDER}} for values you fill in at copy time.")
                    .font(.system(size: Tokens.ReadingSize.meta)).foregroundStyle(.secondary)
            }
            .padding(Tokens.Space.pane)
        }
    }
}

/// One column per model, so the difference between them is visible rather than
/// inferred — which is the whole reason the library is per-model at all.
struct ComparePane: View {
    @ObservedObject var model: LibraryModel

    /// Wide enough to read a rendered prompt without the lines turning into
    /// stubs. Below roughly this, a numbered-step render wraps every line.
    static let comfortableWidth = 360.0

    private var columns: [Target] {
        _ = model.filterRevision   // redraw when the filter changes
        _ = model.orderRevision    // …or the order does
        let visible = (model.current?.targets ?? []).filter { ModelFilter.isVisible($0.model) }
        return ModelOrder.sorted(visible, id: \.model)
    }

    var body: some View {
        if columns.isEmpty {
            Text("Every model for this prompt is hidden. See the Models menu.")
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            VStack(spacing: 0) {
                summaryBlock
                Divider()
                grid
            }
        }
    }

    /// What the columns have in common is obvious; how they differ is the thing
    /// you actually came to find out, and reading four long prompts side by side
    /// does not tell you.
    @ViewBuilder private var summaryBlock: some View {
        let state = model.current?.comparison ?? "not-applicable"
        if state == "not-applicable" {
            EmptyView()
        } else {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Image(systemName: "sparkles").font(.system(size: Tokens.ReadingSize.label))
                        .foregroundStyle(Tokens.accent)
                    Text("How these differ").font(.system(size: Tokens.ReadingSize.meta, weight: .semibold))
                    if state == "stale" {
                        Text("out of date").font(.system(size: Tokens.CompactSize.badge))
                            .padding(.horizontal, 5).padding(.vertical, 1)
                            .background(Capsule().fill(Color.orange.opacity(0.2)))
                    }
                    Spacer()
                    if model.comparisonBusy { ProgressView().controlSize(.small) }
                    Button(model.comparison == nil ? "Summarise" : "Regenerate") {
                        model.loadComparison(force: true)
                    }
                    .controlSize(.small)
                    .disabled(model.comparisonBusy)
                    .help("Asks the enhancer to describe the differences. One LLM call")
                }
                if let text = model.comparison?.summary, !text.isEmpty {
                    ScrollView {
                        Text(text)
                            .font(.system(size: Tokens.ReadingSize.meta))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: 150)
                } else if !model.comparisonBusy {
                    Text("Not written yet. Press Summarise.")
                        .font(.system(size: Tokens.ReadingSize.meta)).foregroundStyle(.secondary)
                }
            }
            .chromeBar()
        }
    }

    private var grid: some View {
        Group {
            GeometryReader { geometry in
                // Few models: share the width, since a fixed column left half the
                // window empty. Many: hold a readable width and scroll, because
                // squeezing seven columns into one window makes none of them
                // legible — the point of comparing is reading them.
                let count = Double(columns.count)
                let available = geometry.size.width
                let fits = Self.comfortableWidth * count <= available
                let width = fits ? (available - 1) / count : Self.comfortableWidth

                ScrollView(.horizontal) {
                    HStack(alignment: .top, spacing: 0) {
                        ForEach(columns) { target in
                            column(target, width: width)
                            Divider()
                        }
                    }
                }
                // The bar is the only cue that there is more to the right, so it
                // stays visible rather than fading out the way an overlay
                // scroller does.
                .scrollIndicators(fits ? .hidden : .visible, axes: .horizontal)
            }
        }
    }

    private func column(_ target: Target, width: Double) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 5) {
                    Circle().fill(target.dotColor).frame(width: 6, height: 6)
                    Text(target.shortName).font(.system(size: Tokens.CompactSize.rowText, weight: .semibold))
                    Spacer()
                    if model.rebuilding.contains(target.model) {
                        ProgressView().controlSize(.small)
                    }
                    // Reorder by nudging, not dragging: two clicks that always
                    // land, against a drag across a horizontally scrolling view.
                    Button { model.moveColumn(target.model, by: -1) } label: {
                        Image(systemName: "chevron.left")
                    }
                    .disabled(columns.first?.model == target.model)
                    .help("Move this column left")
                    Button { model.moveColumn(target.model, by: 1) } label: {
                        Image(systemName: "chevron.right")
                    }
                    .disabled(columns.last?.model == target.model)
                    .help("Move this column right")
                }
                .buttonStyle(.borderless)
                .font(.system(size: Tokens.CompactSize.label))
                Text(target.label + (target.generated.isEmpty ? "" : " · \(target.generated)"))
                    .font(.system(size: Tokens.CompactSize.label)).foregroundStyle(.secondary)
                if !target.variables.isEmpty {
                    Text(target.variables.map { "{{\($0)}}" }.joined(separator: " "))
                        .font(.system(size: Tokens.CompactSize.badge, design: .monospaced))
                        .foregroundStyle(Tokens.accent)
                        .lineLimit(1)
                }
                HStack(spacing: 6) {
                    Button("Copy") { model.copy(target) }
                        .disabled(!target.isUsable)
                    Button("Rebuild") { model.rebuild(model: target.model) }
                        .disabled(model.busy)
                        .help("Rebuilds only \(target.shortName)")
                }
                .font(.system(size: Tokens.CompactSize.meta))
                .controlSize(.small)
            }
            .padding(12)
            Divider()
            ScrollView {
                Text(bodyText(for: target))
                    .font(.system(size: Tokens.CompactSize.meta))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
            }
        }
        .frame(width: width)
    }

    private func bodyText(for target: Target) -> String {
        guard target.isUsable else { return "Not built yet. Press Rebuild to generate it." }
        return model.bodies[target.model] ?? "Loading…"
    }
}

/// A prompt in the sidebar, with its actions on the row.
///
/// The same strip the HUD rows carry, minus two that do not apply here and are
/// therefore hidden rather than disabled: "edit in the library" (you are in it —
/// clicking the row opens it in the pane) and "paste into the frontmost app"
/// (the app to paste into is the one the HUD panel was summoned over, and this
/// window was not summoned over anything).
struct SidebarRow: View {
    @ObservedObject var model: LibraryModel
    let prompt: Prompt
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 5) {
            if prompt.pinned {
                Image(systemName: "pin.fill").font(.system(size: Tokens.CompactSize.badge))
                    .foregroundStyle(Tokens.accent)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(prompt.title).font(.system(size: Tokens.CompactSize.rowText, weight: .medium)).lineLimit(1)
                Text((prompt.category.isEmpty ? "" : "\(prompt.category) · ")
                     + "\(prompt.targets.count) model\(prompt.targets.count == 1 ? "" : "s")"
                     + (prompt.uses > 0 ? " · \(prompt.uses)×" : ""))
                    .font(.system(size: Tokens.CompactSize.label)).foregroundStyle(.secondary)
            }
            Spacer(minLength: 4)
            if hovering {
                PromptRowActions(
                    targetName: prompt.defaultTarget?.shortName,
                    pinned: prompt.pinned,
                    renderCount: prompt.renderCount,
                    onCopy: { model.copyDefault(prompt) },
                    onRebuild: { model.rebuild(prompt) },
                    onPin: { model.togglePin(prompt) },
                    onDelete: { model.requestDelete(prompt) })
            } else if prompt.targets.contains(where: { $0.state != "current" }) {
                Circle().fill(.orange).frame(width: 5, height: 5)
                    .help("Some models are stale or not built")
            }
        }
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
    }
}
