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
    var onExportBackup: () -> Void
    var onImportBackup: () -> Void

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
            .frame(width: Tokens.Width.settingsSidebar)
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
                            onChoose: onChooseLibrary,
                            onExportBackup: onExportBackup,
                            onImportBackup: onImportBackup)
                .id(library.client.root)
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
    var onExportBackup: () -> Void
    var onImportBackup: () -> Void

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
    /// Re-read when a start attempt settles, which happens off the main thread
    /// after the toggle has already moved.
    @State private var crashStatus = CrashReporting.currentStatus
    /// Same shape again: Sparkle owns this value and persists it, so mirroring
    /// it into `@AppStorage` would be a second source for one setting.
    @State private var automaticUpdates = Updater.shared?.automaticallyChecks ?? false

    var body: some View {
        VStack(spacing: 0) {
            WorkingHeader(title: "General", subtitle: "Your library, clipboard, and app preferences.")
            SeedbedDivider()
            ScrollView {
                VStack(alignment: .leading, spacing: Tokens.Space.wide) {
                    SettingsGroup("Library folder") {
                        Caption("Your prompts, renders, model profiles, and building settings live here.")
                        Text(libraryPath).font(Tokens.FontScale.monoSmall)
                            .textSelection(.enabled).lineLimit(nil)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(Tokens.Space.tight).background(Tokens.Surface.sunken)
                            .clipShape(RoundedRectangle(cornerRadius: Tokens.Radius.control))
                        HStack(spacing: Tokens.Space.tight) {
                            Button("Reveal in Finder", action: onReveal)
                            Button("Choose library…", action: onChoose)
                        }
                        Caption("Choosing a folder switches libraries. Future edits and settings are saved there.")
                    }
                    SeedbedDivider()
                    SettingsGroup("Backup and restore") {
                        Caption("Export prompts, renders, models, settings, and Seedbed's Keychain secrets in one encrypted file.")
                        ViewThatFits(in: .horizontal) {
                            HStack(spacing: Tokens.Space.tight) { backupButtons }
                            VStack(alignment: .leading, spacing: Tokens.Space.tight) { backupButtons }
                        }
                        DisclosureGroup("What to know before restoring") {
                            SettingsBullets([
                                ("Export encrypted backup…", "keep the password separately. Seedbed cannot recover it."),
                                ("Import encrypted backup…", "creates a new library folder and activates the backup's settings and secrets on this Mac. Your current library stays on disk."),
                            ]).padding(.top, Tokens.Space.tight)
                        }.font(Tokens.FontScale.small)
                    }
                    SeedbedDivider()
                    SettingsGroup("Clipboard and startup") {
                        VStack(alignment: .leading, spacing: Tokens.Space.row) {
                            Toggle("Paste into the app you came from", isOn: $pasteEnabled)
                                .onChange(of: pasteEnabled) { _, new in
                                    Paster.isEnabled = new
                                    if new && !Paster.hasPermission { Paster.requestPermission() }
                                    hasAccessibility = Paster.hasPermission
                                }
                            Caption("When enabled, Return copies and pastes. Hold Shift to copy only.")
                        }
                        if pasteEnabled && !hasAccessibility {
                            Label("Accessibility permission is needed to paste. Copying still works.", systemImage: "exclamationmark.triangle")
                                .font(Tokens.FontScale.small).foregroundStyle(Tokens.warning)
                            Button("Open Privacy & Security…") { Paster.openAccessibilitySettings() }
                        }
                        VStack(alignment: .leading, spacing: Tokens.Space.row) {
                            Toggle("Open Seedbed at login", isOn: $launchAtLogin)
                                .onChange(of: launchAtLogin) { _, new in
                                    if let problem = LaunchAtLogin.set(new) {
                                        launchProblem = problem
                                        launchAtLogin = LaunchAtLogin.isEnabled
                                    } else { launchProblem = "" }
                                }
                            Caption("Starts in the menu bar after login, without opening a window.")
                            if !launchProblem.isEmpty {
                                Text(launchProblem).font(Tokens.FontScale.small).foregroundStyle(Tokens.danger)
                            }
                        }.padding(.top, Tokens.Space.tight)
                    }
                    SeedbedDivider()
                    if Updater.shared?.canCheck == true {
                        SettingsGroup("Updates") {
                            Toggle("Check for updates automatically", isOn: $automaticUpdates)
                                .onChange(of: automaticUpdates) { _, new in
                                    Updater.shared?.automaticallyChecks = new
                                }
                            Caption("Checks seedbed.dev for a signed update. You can also check from the menu bar.")
                        }
                    }
                    SettingsGroup("Diagnostics") {
                        Toggle("Send crash reports", isOn: $crashReporting)
                            .disabled(!CrashReporting.isConfigured)
                            .onChange(of: crashReporting) { _, new in
                                UserDefaults.standard.set(new, forKey: CrashReporting.enabledKey)
                                CrashReporting.apply(enabled: new)
                                crashStatus = CrashReporting.currentStatus
                            }
                        if let notice = CrashReporting.settingsNotice(for: crashStatus) {
                            Label(notice, systemImage: "exclamationmark.triangle")
                                .font(Tokens.FontScale.small).foregroundStyle(Tokens.warning)
                        }
                        Caption(CrashReporting.isConfigured
                            ? "Off by default. Reports include the stack trace, app version, and macOS version."
                            : "Crash reporting is unavailable in this build.")
                        Caption("Prompts, renders, placeholder values, and tokens are never sent. Home folder paths are shortened to a tilde.")
                    }
                }
                .font(Tokens.FontScale.body)
                .frame(maxWidth: Tokens.Width.reading, alignment: .leading)
                .padding(Tokens.Space.wide)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .onAppear {
            pasteEnabled = Paster.isEnabled
            launchAtLogin = LaunchAtLogin.isEnabled
            hasAccessibility = Paster.hasPermission
            crashReporting = CrashReporting.isEnabled
            crashStatus = CrashReporting.currentStatus
            automaticUpdates = Updater.shared?.automaticallyChecks ?? false
        }
        .onReceive(NotificationCenter.default.publisher(for: CrashReporting.statusDidChange)) { _ in
            crashStatus = CrashReporting.currentStatus
        }
    }

    @ViewBuilder private var backupButtons: some View {
        Button("Export encrypted backup…", action: onExportBackup)
        Button("Import encrypted backup…", action: onImportBackup)
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
        ModelsEditor(model: editor, onDone: nil)
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
