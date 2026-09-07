import AppKit
import SwiftUI

/// The four things there are to configure.
///
/// Before this, configuration lived in three unrelated places: three sheets on
/// the library window (Models, Build With, MCP), five items in the menu bar
/// menu, and one setting — which models are shown — in two of them at once. The
/// split was an accident of the order things were built.
enum SettingsPage: String, CaseIterable, Identifiable {
    case general, models, building, mcp

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general:  return "General"
        case .models:   return "Models"
        case .building: return "Building"
        case .mcp:      return "MCP"
        }
    }

    var symbol: String {
        switch self {
        case .general:  return "gearshape"
        case .models:   return "square.stack.3d.up"
        case .building: return "wand.and.stars"
        case .mcp:      return "network"
        }
    }
}

@MainActor
final class SettingsModel: ObservableObject {
    @Published var page: SettingsPage = .general
}

struct SettingsWindowView: View {
    @ObservedObject var model: SettingsModel
    @ObservedObject var server: MCPServer
    /// Observed, not snapshotted. `InfoWindows.show` builds this view once and
    /// caches the window, so a plain `[ModelRef]` here is frozen at whatever the
    /// library held the first time Settings was opened: empty if that was before
    /// the first reload landed, and stale forever after a model was added.
    @ObservedObject var library: HUDModel
    var onSyncMCP: () -> Void
    var onReloadLibrary: () -> Void
    var onRevealLibrary: () -> Void
    var onChooseLibrary: () -> Void

    var body: some View {
        HStack(spacing: 0) {
            List(selection: Binding(get: { model.page },
                                    set: { model.page = $0 ?? .general })) {
                ForEach(SettingsPage.allCases) { page in
                    Label(page.title, systemImage: page.symbol)
                        .font(Tokens.FontScale.body)
                        .tag(page)
                }
            }
            .listStyle(.sidebar)
            .scrollContentBackground(.hidden)
            .frame(width: Tokens.Width.sidebar)
            SeedbedDivider()
            detail.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(minWidth: Tokens.Size.settingsMin.width, idealWidth: Tokens.Size.settings.width,
               maxWidth: .infinity,
               minHeight: Tokens.Size.settingsMin.height, idealHeight: Tokens.Size.settings.height,
               maxHeight: .infinity)
        .background(Tokens.Surface.canvas)
        .tint(Tokens.accent)
    }

    @ViewBuilder private var detail: some View {
        switch model.page {
        case .general:
            // Read through the observed model rather than taken as a value:
            // the same snapshot problem as the models pane, in the one pane that shows
            // a path you can change.
            GeneralSettings(libraryPath: library.client.root.path,
                            onReveal: onRevealLibrary,
                            onChoose: onChooseLibrary)
        case .models:
            ModelsPane(library: library, onReloadLibrary: onReloadLibrary)
        case .building:
            EnhancerPane(library: library)
        case .mcp:
            MCPSettings(server: server, onChange: onSyncMCP, onDone: nil)
        }
    }
}

/// Everything that was in the menu bar menu and did not belong there.
struct GeneralSettings: View {
    let libraryPath: String
    var onReveal: () -> Void
    var onChoose: () -> Void

    /// Not `@AppStorage`: `Paster.isEnabled` owns the default, which is on, and
    /// two sources for one setting is how it ends up half-on.
    @State private var pasteEnabled = Paster.isEnabled
    @State private var launchAtLogin = LaunchAtLogin.isEnabled
    @State private var launchProblem = ""
    /// Recomputed when the pane appears, since the user grants the permission
    /// in System Settings and comes back to this window.
    @State private var hasAccessibility = Paster.hasPermission
    /// Same reason as `pasteEnabled`: `CrashReporting` owns the default, which
    /// is off, so `@AppStorage` here would be a second source for one setting.
    @State private var crashReporting = CrashReporting.isEnabled
    /// Same shape again: Sparkle owns this value and persists it, so mirroring
    /// it into `@AppStorage` would be a second source for one setting.
    @State private var automaticUpdates = Updater.shared?.automaticallyChecks ?? false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Tokens.Space.regular) {
                SettingsGroup("Pasting") {
                    Toggle("Paste into the app you came from", isOn: $pasteEnabled)
                        .onChange(of: pasteEnabled) { _, new in
                            Paster.isEnabled = new
                            if new && !Paster.hasPermission { Paster.requestPermission() }
                            hasAccessibility = Paster.hasPermission
                        }
                    SettingsBullets([
                        ("Paste into the app you came from",
                         "⏎ puts the prompt straight into whatever was frontmost when you "
                         + "summoned the panel. Turn it off and ⏎ only copies, leaving you to "
                         + "paste. Either way, holding ⇧ copies without pasting."),
                        ("Accessibility permission",
                         "sending ⌘V to another app is what macOS gates behind it, so this "
                         + "setting cannot work without it. Seedbed asks the first time you "
                         + "switch it on, and you grant it in System Settings."),
                    ])
                    if pasteEnabled && !hasAccessibility {
                        HStack(alignment: .top, spacing: Tokens.Space.tight) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundStyle(Tokens.warning)
                            VStack(alignment: .leading, spacing: Tokens.Space.row) {
                                Text("Accessibility permission is not granted")
                                    .font(Tokens.FontScale.small)
                                Caption("Sending ⌘V to another app is exactly what that "
                                        + "permission governs. Until it is granted, Seedbed "
                                        + "copies and tells you why it did not paste.")
                                Button("Open Privacy & Security…") {
                                    Paster.openAccessibilitySettings()
                                }
                            }
                        }
                    }
                }

                SettingsGroup("Starting up") {
                    Toggle("Open Seedbed at login", isOn: $launchAtLogin)
                        .onChange(of: launchAtLogin) { _, new in
                            if let problem = LaunchAtLogin.set(new) {
                                launchProblem = problem
                                launchAtLogin = LaunchAtLogin.isEnabled
                            } else {
                                launchProblem = ""
                            }
                        }
                    if !launchProblem.isEmpty {
                        Text(launchProblem)
                            .font(Tokens.FontScale.small)
                            .foregroundStyle(Tokens.danger)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    SettingsBullets([
                        ("Open Seedbed at login",
                         "registers Seedbed as a macOS login item, so the menu bar icon is "
                         + "there after a restart without you starting it. It opens to the "
                         + "menu bar only: no window appears and nothing steals focus."),
                    ])
                }

                SettingsGroup("Library folder") {
                    Text(libraryPath)
                        .font(Tokens.FontScale.monoSmall)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(Tokens.Space.row6)
                        .background(RoundedRectangle(cornerRadius: Tokens.Radius.control)
                            .fill(Tokens.Surface.sunken))
                        .overlay(RoundedRectangle(cornerRadius: Tokens.Radius.control)
                            .stroke(Tokens.Surface.hairline, lineWidth: 0.5))
                    HStack(spacing: Tokens.Space.tight) {
                        Button("Reveal in Finder", action: onReveal)
                        Button("Choose…", action: onChoose)
                        Spacer()
                    }
                    SettingsBullets([
                        ("The folder shown above",
                         "your prompts and everything generated from them, as plain markdown "
                         + "in a git repository. Seedbed is a front end to it and carries no "
                         + "prompts of its own, so without a checkout the library reads as "
                         + "empty."),
                        ("Reveal in Finder", "opens that folder, which is where you go to "
                         + "commit, push or pull it."),
                        ("Choose…", "points Seedbed at a different checkout. Everything reloads "
                         + "from the new folder, and settings you save afterwards, including "
                         + "the model registry and the enhancer, are written into it rather "
                         + "than the old one."),
                    ])
                }

                if Updater.shared?.canCheck == true {
                    SettingsGroup("Updates") {
                        Toggle("Check for updates automatically", isOn: $automaticUpdates)
                            .onChange(of: automaticUpdates) { _, new in
                                Updater.shared?.automaticallyChecks = new
                            }
                        SettingsBullets([
                            ("Check for updates automatically",
                             "Seedbed asks seedbed.dev for the signed update feed on its own "
                             + "schedule. The request says which version and which macOS you "
                             + "are on, and nothing about you. Turn it off and nothing is "
                             + "checked until you pick Check for Updates from the menu."),
                            ("What an update has to prove",
                             "every build is signed, and one that does not match the key this "
                             + "copy was built with is refused rather than installed."),
                        ])
                    }
                }

                SettingsGroup("Diagnostics") {
                    Toggle("Send crash reports", isOn: $crashReporting)
                        .disabled(!CrashReporting.isConfigured)
                        .onChange(of: crashReporting) { _, new in
                            UserDefaults.standard.set(new, forKey: CrashReporting.enabledKey)
                            CrashReporting.apply(enabled: new)
                        }
                    if CrashReporting.isConfigured {
                        SettingsBullets([
                            ("Send crash reports",
                             "off unless you turn it on. A crash then sends the stack trace, "
                             + "the app version and the macOS version, so a fault that only "
                             + "happens on your Mac can be found without you reporting it."),
                            ("What is never sent",
                             "a prompt, a render, a value you typed into a placeholder, or any "
                             + "token. Your home folder path is rewritten to a tilde before "
                             + "anything leaves this Mac, and there is no other telemetry and "
                             + "no account."),
                        ])
                    } else {
                        SettingsBullets([
                            ("Send crash reports",
                             "unavailable in this build, which was compiled without a reporting "
                             + "address. Every locally built copy is one of these. Nothing is "
                             + "sent whatever this is set to."),
                        ])
                    }
                }
            }
            .padding(Tokens.Space.pane)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .onAppear {
            pasteEnabled = Paster.isEnabled
            launchAtLogin = LaunchAtLogin.isEnabled
            hasAccessibility = Paster.hasPermission
            crashReporting = CrashReporting.isEnabled
            automaticUpdates = Updater.shared?.automaticallyChecks ?? false
        }
    }
}

/// Which models the picker and the compare columns show.
///
/// A view filter, never a delete: a hidden model keeps its renders, so hiding
/// one and changing your mind costs nothing. It used to be a menu bar submenu
/// AND a menu in the library window's header, which is one setting in two
/// places and a reliable way to end up unsure which one you last touched.
/// The Models pane, which owns its editor for the life of the window.
///
/// The editor's model is a `@StateObject` rather than something built in the
/// body, because it holds the fields you are typing into. Constructing it inline
/// meant a fresh one on every re-render, which was invisible only because this
/// pane never re-rendered. Fixing the staleness without this would have traded a
/// stale list for a form that clears itself.
struct ModelsPane: View {
    @ObservedObject var library: HUDModel
    var onReloadLibrary: () -> Void

    @StateObject private var editor: ModelsEditorModel

    init(library: HUDModel, onReloadLibrary: @escaping () -> Void) {
        self.library = library
        self.onReloadLibrary = onReloadLibrary
        _editor = StateObject(wrappedValue: ModelsEditorModel(
            models: library.allModels, client: library.client, onChange: onReloadLibrary))
    }

    var body: some View {
        VStack(spacing: 0) {
            ModelVisibility(models: library.allModels, onChange: onReloadLibrary)
            SeedbedDivider()
            ModelsEditor(model: editor, onDone: nil)
        }
        .onChange(of: library.allModels) { _, fresh in editor.adopt(fresh) }
        // Saving a model writes models.toml. Which checkout it lands in has to
        // follow the library folder, not the moment this window first opened.
        .onChange(of: library.client.root) { _, _ in editor.client = library.client }
    }
}

/// The Building pane, which owns its editor for the life of the window.
///
/// Same shape as `ModelsPane` and for the same reason: the editor's model holds
/// the fields you are typing into, so it is a `@StateObject` rather than
/// something built in the body. It also holds the client that `setEnhancer`
/// WRITES through, which is what made the retargeting bug worse than a display bug.
struct EnhancerPane: View {
    @ObservedObject var library: HUDModel
    @StateObject private var editor: EnhancerEditorModel

    init(library: HUDModel) {
        self.library = library
        _editor = StateObject(wrappedValue: EnhancerEditorModel(client: library.client))
    }

    var body: some View {
        EnhancerEditor(model: editor, onDone: nil)
            .onChange(of: library.client.root) { _, _ in editor.retarget(to: library.client) }
    }
}

struct ModelVisibility: View {
    let models: [LibraryData.ModelRef]
    var onChange: () -> Void
    /// Bumped to redraw: `ModelFilter` lives in `UserDefaults`, not in state.
    @State private var revision = 0

    var body: some View {
        VStack(alignment: .leading, spacing: Tokens.Space.medium) {
            SettingsGroup("Shown in the picker") {
                ForEach(models, id: \.id) { entry in
                    Toggle(entry.name, isOn: Binding(
                        get: { _ = revision; return ModelFilter.isVisible(entry.id) },
                        set: { _ in
                            ModelFilter.toggle(entry.id, allKnown: models.map(\.id))
                            revision += 1
                            onChange()
                        }))
                }
                HStack(spacing: Tokens.Space.tight) {
                    Button("Show all") {
                        ModelFilter.showAll()
                        revision += 1
                        onChange()
                    }
                    Spacer()
                }
                SettingsBullets([
                    ("The switches above",
                     "which models the picker and the compare columns offer. Working with two "
                     + "models today should not mean scrolling past seven."),
                    ("Hiding is not deleting",
                     "a hidden model keeps its entry in models.toml and keeps every render "
                     + "already built for it, so changing your mind costs nothing and rebuilds "
                     + "nothing. Remove one for good in the Models list below."),
                    ("Show all", "brings every model in the registry back into the picker."),
                ])
            }
        }
        .padding(Tokens.Space.pane)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
