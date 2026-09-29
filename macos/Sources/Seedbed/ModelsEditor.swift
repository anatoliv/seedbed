import SwiftUI

struct ModelCatalog: Decodable {
    struct Entry: Decodable, Identifiable {
        let id: String
        let name: String
        let family: String
        let provider: String
        let released: String
    }
    let models: [Entry]
    let updated: String
    let source: String
    let cached: Bool
    let warning: String
}

struct ModelDocumentation: Decodable {
    struct Source: Decodable, Identifiable {
        let url: String
        let kind: String
        var id: String { url }
    }
    let sources: [Source]
    let provider: String
    let warning: String
}

enum ModelsMetrics {
    static let listWidth: CGFloat = 220
    static let rowHeight: CGFloat = 48
    static let guidanceHeight: CGFloat = 84
}

/// Adding and configuring target models.
///
/// A model here is a prompting profile, not an API connection: an id, a display
/// name, the documentation that says how to prompt it, and a note. Nothing in
/// this sheet runs the model — the enhancer is configured separately.
/// Documentation discovery reads public vendor pages.
@MainActor
final class ModelsEditorModel: ObservableObject {
    @Published var models: [LibraryData.ModelRef]
    @Published var selection: String?
    @Published var status = ""
    @Published var statusIsError = false
    @Published var busy = false

    @Published var draftID = ""
    @Published var draftName = ""
    @Published var draftFamily = ""
    @Published var draftNotes = ""
    @Published var draftGuides = ""
    @Published var isNew = false
    @Published var catalog: ModelCatalog?
    @Published var loadingCatalog = false
    @Published var catalogError = ""
    @Published var documentation: ModelDocumentation?
    @Published var findingDocumentation = false
    @Published var documentationError = ""
    private var discoveryRevision = 0

    var hasChanges: Bool {
        if isNew { return !draftID.isEmpty || !draftName.isEmpty || !draftFamily.isEmpty || !draftGuides.isEmpty || !draftNotes.isEmpty }
        guard let entry = models.first(where: { $0.id == selection }) else { return false }
        return draftName != entry.name || draftFamily != entry.family
            || draftNotes != entry.notes || draftGuides != entry.guides.joined(separator: "\n")
    }

    var discoveryKey: String { [draftID, draftName, draftFamily].joined(separator: "|") }

    func clearDiscovery() {
        discoveryRevision += 1
        documentation = nil
        documentationError = ""
        findingDocumentation = false
    }

    func loadSuggestions(refresh: Bool = false) {
        guard !loadingCatalog else { return }
        loadingCatalog = true
        catalogError = ""
        Task.detached { [client] in
            do {
                let result = try client.modelSuggestions(refresh: refresh)
                await MainActor.run {
                    self.catalog = result
                    self.loadingCatalog = false
                }
            } catch {
                await MainActor.run {
                    self.catalogError = error.localizedDescription
                    self.loadingCatalog = false
                }
            }
        }
    }

    func useSuggestion(_ entry: ModelCatalog.Entry) {
        startNew()
        draftID = entry.id
        draftName = entry.name
        draftFamily = entry.family
    }

    func findDocumentation() {
        guard !draftID.isEmpty || !draftName.isEmpty else { return }
        discoveryRevision += 1
        let revision = discoveryRevision
        let key = discoveryKey
        let (id, name, family) = (draftID, draftName, draftFamily)
        findingDocumentation = true
        documentationError = ""
        documentation = nil
        Task.detached { [client] in
            do {
                let result = try client.modelDocumentation(id: id, name: name, family: family)
                await MainActor.run {
                    guard revision == self.discoveryRevision, key == self.discoveryKey else { return }
                    self.documentation = result
                    self.findingDocumentation = false
                }
            } catch {
                await MainActor.run {
                    guard revision == self.discoveryRevision, key == self.discoveryKey else { return }
                    self.documentationError = error.localizedDescription
                    self.findingDocumentation = false
                }
            }
        }
    }

    func addDocumentation(_ urls: [String]) {
        var sources = draftGuides.split(whereSeparator: \.isNewline).map(String.init)
        for url in urls where !sources.contains(url) { sources.append(url) }
        draftGuides = sources.joined(separator: "\n")
    }


    /// `var` for the same reason as `EnhancerEditorModel.client`: saving a model
    /// writes `models.toml`, and which checkout that lands in must follow the
    /// library folder.
    var client: LibraryClient
    var onChange: () -> Void

    init(models: [LibraryData.ModelRef], client: LibraryClient, onChange: @escaping () -> Void) {
        self.models = models
        self.client = client
        self.onChange = onChange
        if let first = models.first { select(first.id) }
    }

    /// Take a fresh list from the library without discarding what is being typed.
    ///
    /// The pane used to be handed a snapshot that never changed, so
    /// this question never came up. Now that it re-renders on a reload, the
    /// obvious fix — rebuild the editor from the new list — would throw away a
    /// half-typed model every time the library reloaded, which is worse than the
    /// bug it fixes. So: adopt the list, and touch the selection only when the
    /// old one is no longer there.
    func adopt(_ fresh: [LibraryData.ModelRef]) {
        guard fresh != models else { return }
        models = fresh
        if isNew { return }
        if let selection, fresh.contains(where: { $0.id == selection }) { return }
        if let first = fresh.first { select(first.id) } else { startNew() }
    }

    func select(_ id: String) {
        guard let entry = models.first(where: { $0.id == id }) else { return }
        clearDiscovery()
        selection = id
        isNew = false
        draftID = entry.id
        draftName = entry.name
        draftFamily = entry.family
        draftNotes = entry.notes
        draftGuides = entry.guides.joined(separator: "\n")
    }

    func startNew() {
        clearDiscovery()
        selection = nil
        isNew = true
        draftID = ""; draftName = ""; draftFamily = ""; draftNotes = ""; draftGuides = ""
    }

    var canSave: Bool {
        draftID.range(of: "^[a-zA-Z0-9][a-zA-Z0-9._-]*$", options: .regularExpression) != nil
            && !draftName.trimmingCharacters(in: .whitespaces).isEmpty
            && (!isNew || !models.contains { $0.id == draftID })
            && !busy
    }

    func save() {
        guard canSave else { return }
        busy = true
        let (id, name, family) = (draftID.trimmingCharacters(in: .whitespaces), draftName, draftFamily)
        let notes = draftNotes
        let guides = draftGuides.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        let creating = isNew
        Task.detached { [client] in
            do {
                let message = try client.saveModel(id: id, name: name, family: family,
                                                   guides: guides, notes: notes, isNew: creating)
                await MainActor.run { self.finish(message, selecting: id) }
            } catch {
                await MainActor.run { self.fail(error) }
            }
        }
    }

    func remove() {
        guard let id = selection, !busy else { return }
        busy = true
        Task.detached { [client] in
            do {
                let message = try client.removeModel(id: id)
                await MainActor.run { self.finish(message, selecting: nil) }
            } catch {
                await MainActor.run { self.fail(error) }
            }
        }
    }

    private func finish(_ message: String, selecting id: String?) {
        busy = false
        status = message
        statusIsError = false
        isNew = false
        onChange()
        Task.detached { [client] in
            guard let data = try? client.load() else { return }
            await MainActor.run {
                self.models = data.models
                if let id, data.models.contains(where: { $0.id == id }) { self.select(id) }
                else if let first = data.models.first { self.select(first.id) }
                else { self.startNew() }
            }
        }
    }

    private func fail(_ error: Error) {
        busy = false
        status = error.localizedDescription
        statusIsError = true
    }
}

struct ModelsEditor: View {
    @ObservedObject var model: ModelsEditorModel
    var onDone: (() -> Void)?
    @State private var query = ""
    @State private var browsingSuggestions = false
    @State private var visibilityRevision = 0
    @State private var confirmDiscard = false
    @State private var confirmRemove = false
    @State private var pendingAction: (() -> Void)?

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: Tokens.Space.tight) {
                Text("Models").font(Tokens.FontScale.sectionHeader)
                Spacer()
                Button { changeDraft { model.startNew() } } label: {
                    Label("Add model", systemImage: "plus")
                }
                .accessibilityIdentifier("models.add")
                if let onDone { Button("Done", action: onDone) }
            }
            .chromeBar()
            SeedbedDivider()
            HStack(spacing: 0) {
                browser.frame(width: ModelsMetrics.listWidth)
                SeedbedDivider()
                editor.frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .environment(\.textScale, .compact)
        .alert("Discard unsaved changes?", isPresented: $confirmDiscard) {
            Button("Cancel", role: .cancel) { pendingAction = nil }
            Button("Discard changes", role: .destructive) { pendingAction?(); pendingAction = nil }
        } message: { Text("Your saved model stays available. Changes in this form will be discarded.") }
        .alert("Remove this model?", isPresented: $confirmRemove) {
            Button("Cancel", role: .cancel) { }
            Button("Remove model", role: .destructive) { model.remove() }
        } message: { Text("Existing renders are kept. You can add this model again later.") }
        .task(id: model.discoveryKey) {
            model.clearDiscovery()
            guard model.isNew, !model.draftID.isEmpty, !model.draftName.isEmpty else { return }
            try? await Task.sleep(nanoseconds: 900_000_000)
            guard !Task.isCancelled else { return }
            model.findDocumentation()
        }
    }

    private func changeDraft(_ action: @escaping () -> Void) {
        if model.hasChanges { pendingAction = action; confirmDiscard = true }
        else { action() }
    }

    private var browser: some View {
        VStack(spacing: 0) {
            VStack(spacing: Tokens.Space.tight) {
                Picker("Browse models", selection: $browsingSuggestions) {
                    Text("My models").tag(false)
                    Text("Suggestions").tag(true)
                }.pickerStyle(.segmented).labelsHidden()
                TextField("Search models", text: $query)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityIdentifier("models.search")
            }.padding(Tokens.Space.snug)
            SeedbedDivider()
            ScrollView {
                LazyVStack(spacing: Tokens.Space.row) {
                    if browsingSuggestions { suggestions }
                    else {
                        ForEach(model.models.filter { matches($0.name, $0.id, $0.family) }) { entry in
                            HStack(spacing: Tokens.Space.tight) {
                                Toggle("Show \(entry.name) in the picker", isOn: Binding(
                                    get: { _ = visibilityRevision; return ModelFilter.isVisible(entry.id) },
                                    set: { _ in
                                        ModelFilter.toggle(entry.id, allKnown: model.models.map(\.id))
                                        visibilityRevision += 1
                                        model.onChange()
                                    }))
                                    .labelsHidden().toggleStyle(.checkbox)
                                Button { changeDraft { model.select(entry.id) } } label: {
                                    modelLabel(entry.name, detail: entry.family.isEmpty ? entry.id : entry.family)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                        .contentShape(Rectangle())
                                }.buttonStyle(.plain)
                            }
                            .padding(.horizontal, Tokens.Space.tight)
                            .frame(height: ModelsMetrics.rowHeight)
                            .background(model.selection == entry.id ? Tokens.Fill.selected : .clear,
                                        in: RoundedRectangle(cornerRadius: Tokens.Radius.card))
                        }
                        if model.models.isEmpty {
                            Text("Add a model, or choose one from Suggestions.")
                                .font(Tokens.FontScale.small).foregroundStyle(.secondary)
                                .padding(Tokens.Space.snug)
                        }
                    }
                }.padding(Tokens.Space.row6)
            }
            .id(browsingSuggestions)
            SeedbedDivider()
            VStack(alignment: .leading, spacing: Tokens.Space.row6) {
                if browsingSuggestions {
                    HStack {
                        Button("Refresh") { model.loadSuggestions(refresh: true) }
                            .disabled(model.loadingCatalog)
                        if model.loadingCatalog { ProgressView().controlSize(.small) }
                        Spacer()
                        Link("Models.dev", destination: URL(string: "https://models.dev")!)
                    }
                    Text(model.catalog.map { "Updated " + String($0.updated.prefix(10)) } ?? "Refreshable public catalog")
                    Text(model.catalogError.isEmpty ? (model.catalog?.warning ?? "") : model.catalogError)
                        .foregroundStyle(Tokens.warning).lineLimit(3)
                } else {
                    HStack {
                        Text("\(model.models.filter { ModelFilter.isVisible($0.id) }.count) of \(model.models.count) shown")
                        Spacer()
                        Button("Show all") {
                            ModelFilter.showAll(); visibilityRevision += 1; model.onChange()
                        }
                    }
                    Text("Uncheck to hide. Your renders stay available.")
                }
            }
            .font(Tokens.FontScale.tiny).foregroundStyle(.secondary).chromeBar()
        }
        .onChange(of: browsingSuggestions) { _, value in
            query = ""
            if value && model.catalog == nil { model.loadSuggestions() }
        }
    }

    @ViewBuilder private var suggestions: some View {
        if let catalog = model.catalog {
            ForEach(catalog.models.filter { matches($0.name, $0.id, $0.provider) }) { entry in
                let existing = model.models.contains { $0.id == entry.id }
                Button {
                    changeDraft {
                        if existing { model.select(entry.id) }
                        else { model.useSuggestion(entry) }
                    }
                } label: {
                    HStack(spacing: Tokens.Space.row6) {
                        modelLabel(entry.name, detail: "\(entry.provider) · \(entry.released)")
                        Spacer(minLength: 0)
                        Image(systemName: existing ? "checkmark" : "plus")
                            .foregroundStyle(existing ? Tokens.positive : Tokens.accent)
                    }
                    .padding(.horizontal, Tokens.Space.tight)
                    .frame(height: ModelsMetrics.rowHeight)
                    .contentShape(Rectangle())
                }.buttonStyle(.plain)
            }
        } else if !model.loadingCatalog {
            Text("Refresh to find recent text models.")
                .font(Tokens.FontScale.small).foregroundStyle(.secondary).padding(Tokens.Space.snug)
        }
    }

    private func matches(_ values: String...) -> Bool {
        query.isEmpty || values.contains { $0.localizedCaseInsensitiveContains(query) }
    }

    private func modelLabel(_ name: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: Tokens.Space.row) {
            Text(name).font(Tokens.FontScale.body.weight(.medium)).lineLimit(1)
            Text(detail).font(Tokens.FontScale.tiny).foregroundStyle(.secondary).lineLimit(1)
        }
    }

    private var editor: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: Tokens.Space.wide) {
                    VStack(alignment: .leading, spacing: Tokens.Space.row6) {
                        Text(model.isNew ? "New model" : (model.draftName.isEmpty ? "Choose a model" : model.draftName))
                            .font(Tokens.FontScale.sectionHeader)
                        Text("Choose how prompts are written for this model.")
                            .font(Tokens.FontScale.small).foregroundStyle(.secondary)
                    }
                    VStack(alignment: .leading, spacing: Tokens.Space.snug) {
                        FormField("Display name") {
                            TextField("Model name", text: $model.draftName).textFieldStyle(.roundedBorder)
                        }
                        HStack(alignment: .top, spacing: Tokens.Space.snug) {
                            FormField("Model id") {
                                TextField("model-id", text: $model.draftID).textFieldStyle(.roundedBorder)
                                    .disabled(!model.isNew).font(Tokens.FontScale.monoSmall)
                            }
                            FormField("Family") {
                                TextField("e.g. openai", text: $model.draftFamily).textFieldStyle(.roundedBorder)
                            }.frame(maxWidth: ModelsMetrics.listWidth / 2)
                        }
                        if model.isNew {
                            Text(model.models.contains { $0.id == model.draftID }
                                 ? "This id is already in your library. Choose it from My models."
                                 : "Use letters, numbers, dots, hyphens, or underscores for the id.")
                                .font(Tokens.FontScale.tiny).foregroundStyle(.secondary)
                        }
                    }
                    VStack(alignment: .leading, spacing: Tokens.Space.snug) {
                        HStack {
                            Text("Documentation").font(Tokens.FontScale.body.weight(.semibold))
                            Spacer()
                            Button("Find documentation") { model.findDocumentation() }
                                .disabled(model.findingDocumentation || model.draftName.isEmpty)
                                .accessibilityIdentifier("models.findDocumentation")
                        }
                        if model.findingDocumentation {
                            HStack { ProgressView().controlSize(.small); Text("Checking official vendor pages…") }
                                .font(Tokens.FontScale.small).foregroundStyle(.secondary)
                        }
                        if let documentation = model.documentation {
                            ForEach(documentation.sources) { source in
                                HStack(alignment: .top, spacing: Tokens.Space.tight) {
                                    VStack(alignment: .leading, spacing: Tokens.Space.row) {
                                        Text(source.kind).font(Tokens.FontScale.tiny).foregroundStyle(.secondary)
                                        if let url = URL(string: source.url) {
                                            Link(destination: url) {
                                                Text(source.url).font(Tokens.FontScale.small)
                                                    .multilineTextAlignment(.leading).lineLimit(2)
                                                    .frame(maxWidth: .infinity, alignment: .leading)
                                            }.buttonStyle(.plain).foregroundStyle(Tokens.accent)
                                        }
                                    }
                                    Spacer(minLength: 0)
                                    let added = model.draftGuides.split(whereSeparator: \.isNewline).contains(Substring(source.url))
                                    Button(added ? "Added" : "Use") { model.addDocumentation([source.url]) }
                                        .disabled(added)
                                }
                            }
                            if !documentation.warning.isEmpty {
                                Text(documentation.warning).font(Tokens.FontScale.tiny).foregroundStyle(.secondary)
                            }
                        }
                        if !model.documentationError.isEmpty {
                            Text(model.documentationError).font(Tokens.FontScale.small).foregroundStyle(Tokens.danger)
                        }
                        FormField("Guidance sources · one URL or local path per line") {
                            TextEditor(text: $model.draftGuides).font(Tokens.FontScale.monoSmall)
                                .frame(height: ModelsMetrics.guidanceHeight)
                                .padding(Tokens.Space.row).background(Tokens.Surface.sunken)
                                .overlay(RoundedRectangle(cornerRadius: Tokens.Radius.card)
                                    .stroke(Tokens.Surface.hairline, lineWidth: 1))
                        }
                    }
                    FormField("Prompting notes") {
                        TextEditor(text: $model.draftNotes).font(Tokens.FontScale.small)
                            .frame(height: ModelsMetrics.guidanceHeight)
                            .padding(Tokens.Space.row).background(Tokens.Surface.sunken)
                            .overlay(RoundedRectangle(cornerRadius: Tokens.Radius.card)
                                .stroke(Tokens.Surface.hairline, lineWidth: 1))
                    }
                    Text("Changing guidance or notes makes this model’s renders stale.")
                        .font(Tokens.FontScale.tiny).foregroundStyle(.secondary)
                }.padding(Tokens.Space.wide)
            }
            SeedbedDivider()
            HStack(spacing: Tokens.Space.tight) {
                Button(model.isNew ? "Add model" : "Save changes") { model.save() }
                    .disabled(!model.canSave || (!model.isNew && !model.hasChanges)).seedbedProminent()
                if model.busy { ProgressView().controlSize(.small) }
                Text(model.status).font(Tokens.FontScale.tiny)
                    .foregroundStyle(model.statusIsError ? Tokens.danger : .secondary).lineLimit(2)
                Spacer(minLength: 0)
                if !model.isNew && model.selection != nil {
                    Button { confirmRemove = true } label: { Image(systemName: "trash") }
                        .help("Remove model").accessibilityLabel("Remove model")
                        .disabled(model.busy).buttonStyle(.borderless)
                }
            }.chromeBar()
        }
    }
}
