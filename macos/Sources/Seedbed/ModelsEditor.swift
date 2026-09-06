import SwiftUI

/// Adding and configuring target models.
///
/// A model here is a prompting profile, not an API connection: an id, a display
/// name, the documentation that says how to prompt it, and a note. Nothing in
/// this sheet causes a call to that vendor — the enhancer is configured
/// separately — so adding one is cheap and reversible.
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
        if let first = fresh.first { select(first.id) } else { selection = nil }
    }

    func select(_ id: String) {
        guard let entry = models.first(where: { $0.id == id }) else { return }
        selection = id
        isNew = false
        draftID = entry.id
        draftName = entry.name
        draftFamily = entry.family
        draftNotes = entry.notes
        draftGuides = entry.guides.joined(separator: "\n")
    }

    func startNew() {
        selection = nil
        isNew = true
        draftID = ""; draftName = ""; draftFamily = ""; draftNotes = ""; draftGuides = ""
    }

    var canSave: Bool {
        !draftID.trimmingCharacters(in: .whitespaces).isEmpty
            && !draftName.trimmingCharacters(in: .whitespaces).isEmpty
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
    /// Nil when this is a pane in the Settings window rather than a sheet:
    /// a window with a close button does not also need a Done button.
    var onDone: (() -> Void)?

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Models").font(.system(size: Tokens.ReadingSize.heading, weight: .semibold))
                Spacer()
                if let onDone { Button("Done", action: onDone).keyboardShortcut(.defaultAction) }
            }
            .chromeBar()
            Divider()

            HStack(spacing: 0) {
                list.frame(width: Tokens.Width.list)
                Divider()
                form.frame(maxWidth: .infinity)
            }

            Divider()
            HStack(spacing: Tokens.Space.control) {
                if model.busy { ProgressView().controlSize(.small) }
                Text(model.status)
                    .font(.system(size: Tokens.ReadingSize.meta))
                    .foregroundStyle(model.statusIsError ? Color.red : .secondary)
                    .lineLimit(1)
                Spacer()
            }
            .chromeBar()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var list: some View {
        VStack(spacing: 0) {
            List(model.models, selection: Binding(
                get: { model.selection },
                set: { if let id = $0 { model.select(id) } })
            ) { entry in
                VStack(alignment: .leading, spacing: Tokens.Space.row) {
                    Text(entry.name).font(.system(size: Tokens.ReadingSize.body, weight: .medium)).lineLimit(1)
                    Text(entry.id).font(.system(size: Tokens.ReadingSize.label, design: .monospaced))
                        .foregroundStyle(.secondary).lineLimit(1)
                }
                .tag(entry.id)
            }
            Divider()
            HStack(spacing: Tokens.Space.control) {
                Button { model.startNew() } label: { Image(systemName: "plus") }
                Button { model.remove() } label: { Image(systemName: "minus") }
                    .disabled(model.selection == nil || model.busy)
                Spacer()
            }
            .buttonStyle(.borderless)
            .chromeBar()
        }
    }

    private var form: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Tokens.Space.field) {
                FormField("Model id, used in file paths and on the chips") {
                    TextField("claude-opus-5", text: $model.draftID)
                        .textFieldStyle(.roundedBorder)
                        .disabled(!model.isNew)
                        .font(.system(size: Tokens.ReadingSize.body, design: .monospaced))
                }
                FormField("Display name") {
                    TextField("Claude Opus 5", text: $model.draftName)
                        .textFieldStyle(.roundedBorder)
                }
                FormField("Family: free text that groups related models") {
                    TextField("claude", text: $model.draftFamily)
                        .textFieldStyle(.roundedBorder).frame(maxWidth: Tokens.Width.list)
                }
                FormField("Prompting guidance: one URL or file path per line") {
                    TextEditor(text: $model.draftGuides)
                        .font(.system(size: Tokens.ReadingSize.meta, design: .monospaced))
                        .frame(height: 70)
                        .padding(4)
                        .overlay(RoundedRectangle(cornerRadius: Tokens.Radius.card)
                            .stroke(Color.secondary.opacity(0.3), lineWidth: 1))
                }
                FormField("Notes, always part of this model's guidance") {
                    TextEditor(text: $model.draftNotes)
                        .font(.system(size: Tokens.ReadingSize.meta))
                        .frame(height: 60)
                        .padding(4)
                        .overlay(RoundedRectangle(cornerRadius: Tokens.Radius.card)
                            .stroke(Color.secondary.opacity(0.3), lineWidth: 1))
                }
                HStack {
                    Button(model.isNew ? "Add model" : "Save changes") { model.save() }
                        .disabled(!model.canSave)
                        .buttonStyle(.borderedProminent)
                    Text("Changing guidance or notes makes every render for this model stale.")
                        .font(.system(size: Tokens.ReadingSize.label)).foregroundStyle(.secondary)
                }
            }
            .padding(Tokens.Space.pane)
        }
    }
}
