import AppKit
import SwiftUI

/// Filling a prompt's `{{PLACEHOLDER}}` values before it reaches the clipboard.
///
/// The point is to never retype a project name. Each field is a text field with
/// a history menu beside it; picking from the menu is one click, and anything
/// new you type is remembered for next time.
@MainActor
final class FillModel: ObservableObject, Identifiable {
    /// `.sheet(item:)` needs identity; one fill is one prompt/model pair.
    nonisolated let id = UUID()

    @Published var values: [String: String]
    @Published var focusedIndex = 0

    let prompt: Prompt
    let target: Target
    let names: [String]
    let history: [String: [String]]

    init(prompt: Prompt, target: Target, history: [String: [String]]) {
        self.prompt = prompt
        self.target = target
        self.names = target.variables
        self.history = history
        // Pre-fill each field with the most recent value, since re-using the
        // last one is the common case — a wrong guess is one keystroke to clear.
        self.values = Dictionary(
            uniqueKeysWithValues: target.variables.map { ($0, history[$0]?.first ?? "") }
        )
    }

    var filledCount: Int { names.filter { !(values[$0] ?? "").isEmpty }.count }

    /// `--set NAME=VALUE` pairs for the CLI, skipping the blanks so an unfilled
    /// placeholder stays visible in the copied prompt rather than vanishing.
    var assignments: [String: String] {
        values.filter { !$0.value.isEmpty }
    }
}

struct FillSheet: View {
    @ObservedObject var model: FillModel
    var onCancel: () -> Void
    var onCopy: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: Tokens.Space.field) {
                    ForEach(model.names, id: \.self) { name in
                        field(name)
                    }
                }
                .padding(Tokens.Space.pane)
            }
            .frame(maxHeight: 320)
            Divider()
            footer
        }
        .frame(width: Tokens.Width.sheet)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: Tokens.Space.row) {
            Text(model.prompt.title).font(.system(size: Tokens.CompactSize.rowTitle, weight: .semibold))
            Text("\(model.names.count) value\(model.names.count == 1 ? "" : "s") for \(model.target.shortName)")
                .font(.system(size: Tokens.CompactSize.meta)).foregroundStyle(.secondary)
        }
        .chromeBar()
    }

    private func field(_ name: String) -> some View {
        VStack(alignment: .leading, spacing: Tokens.Space.row) {
            Text(name).font(.system(size: Tokens.CompactSize.label, weight: .medium, design: .monospaced))
                .foregroundStyle(.secondary)
            HStack(spacing: Tokens.Space.control) {
                TextField("", text: Binding(
                    get: { model.values[name] ?? "" },
                    set: { model.values[name] = $0 }
                ), axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .lineLimit(1...6)
                .font(.system(size: Tokens.CompactSize.rowText))

                let past = model.history[name] ?? []
                Menu {
                    if past.isEmpty {
                        Text("Nothing used yet")
                    } else {
                        ForEach(past, id: \.self) { value in
                            Button(value.count > 60 ? String(value.prefix(60)) + "…" : value) {
                                model.values[name] = value
                            }
                        }
                    }
                } label: {
                    Image(systemName: "clock.arrow.circlepath")
                }
                .menuStyle(.borderlessButton)
                .frame(width: 26)
                .disabled(past.isEmpty)
                .help(past.isEmpty ? "No previous values yet" : "Values you used before")
            }
        }
    }

    private var footer: some View {
        HStack(spacing: Tokens.Space.control) {
            Text("Blank values stay as {{NAME}} in the copied prompt")
                .font(.system(size: Tokens.CompactSize.label)).foregroundStyle(.secondary)
            Spacer()
            Button("Cancel", action: onCancel)
                .keyboardShortcut(.cancelAction)
            Button(Paster.isEnabled ? "Copy & Paste" : "Copy") { onCopy() }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
        }
        .chromeBar()
    }
}
