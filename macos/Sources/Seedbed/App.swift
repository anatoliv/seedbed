import AppKit
import SwiftUI

/// Seedbed — a menu-bar app that puts the prompt library one keystroke away.
///
/// No Dock icon, no window until summoned. ⌥⌘P opens a floating panel over
/// whatever you are working in; pick a model and its tailored prompt is on the
/// clipboard. The library itself is owned by the `promptlib` Python package in
/// the same repository; this is only a front end to it.

/// A panel that can take keyboard focus. `.nonactivatingPanel` alone cannot
/// become key, and without key status nothing types.
final class HUDPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

@MainActor
final class AppController: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private var panel: HUDPanel!
    private var model: HUDModel!
    private var hotKey: GlobalHotKey?
    private var flashReset: DispatchWorkItem?
    private var libraryWindow: NSWindow?
    private var libraryModel: LibraryModel?
    /// The MCP endpoint. Owned here rather than by a window, because it has to
    /// run whether or not any window is open — an agent asking for a prompt has
    /// no way to open one first.
    private var mcp: MCPServer!
    /// Which page the manual is showing. Held here, not in the view, so the
    /// menu can open the window ON a page while it is already open.
    private let infoModel = InfoModel()
    /// Whether the status-item menu is on screen, so an asynchronous reload
    /// knows whether there is anything to correct.
    private var menuIsOpen = false
    /// Which settings pane is showing, for the same reason as `infoModel`.
    private let settingsModel = SettingsModel()
    /// Held for the process lifetime, not built on demand: Sparkle's scheduled
    /// background checks belong to the controller, and a controller created
    /// inside the menu action would be deallocated the moment the check
    /// finished, so an installed copy would only ever update when someone
    /// remembered to ask.
    private lazy var updater = Updater()

    private static let rootKey = "LibraryRoot"
    static let mcpEnabledKey = "MCPEnabled"
    static let mcpPortKey = "MCPPort"

    static var mcpPort: UInt16 {
        let stored = UserDefaults.standard.integer(forKey: mcpPortKey)
        return stored > 0 && stored <= 65535 ? UInt16(stored) : MCPConstants.defaultPort
    }

    private var root: URL {
        if let saved = UserDefaults.standard.string(forKey: Self.rootKey), !saved.isEmpty {
            return URL(fileURLWithPath: saved)
        }
        return LibraryClient.defaultRoot
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)   // menu bar only, no Dock tile

        // First, so a crash in anything below is the kind of crash that gets
        // reported. Starts only if the user opted in AND this build carries a
        // DSN; both are false by default, so this is a no-op on a self-built
        // copy. See CrashReporting.
        CrashReporting.start()

        // Sends one event and exits, so the wiring can be checked against the
        // real Sentry project instead of inferred from it having compiled.
        if ProcessInfo.processInfo.environment["SEEDBED_TEST_SENTRY"] == "1" {
            CrashReporting.captureTestEvent()
            NSApp.terminate(nil)
            return
        }

        // Prints what "Check for Updates…" would say and exits. The text now
        // branches on whether this copy was built from the checkout or
        // installed from a release, and an alert is not a thing this project
        // verifies by screenshotting. Run it from the bundle in build/ and
        // again from a copy outside the tree: the instructions must differ.
        if ProcessInfo.processInfo.environment["SEEDBED_CHECK_UPDATES"] == "1" {
            let result = Updates.check(root: root)
            print("bundle: \(Bundle.main.bundleURL.path)")
            print("root:   \(root.path)")
            print("\n\(result.title)\n\n\(result.detail)")
            NSApp.terminate(nil)
            return
        }

        model = HUDModel(client: LibraryClient(root: root))
        model.onClose = { [weak self] in self?.hide() }
        model.onOpenLibrary = { [weak self] in self?.openLibrary() }
        model.onEditPrompt = { [weak self] id in self?.openLibrary(selecting: id) }
        model.onCopied = { [weak self] message, shouldPaste in
            self?.flashCopied(message)
            if shouldPaste { self?.pasteIntoPreviousApp() }
        }

        buildStatusItem()
        buildPanel()

        mcp = MCPServer(client: LibraryClient(root: root))
        syncMCPServer()

        refreshEnhancerSummary()
        hotKey = GlobalHotKey { [weak self] in self?.toggle() }
        if hotKey == nil {
            // Another app owns ⌥⌘P. Say so rather than looking broken.
            statusItem.button?.toolTip = "Seedbed — ⌥⌘P is taken by another app; use the menu"
        }
        // Off the main thread, before the first library call needs it: the
        // probe is up to seven process spawns and the first caller pays for
        // them. See LibraryClient.resolvedPython.
        LibraryClient.warmUpInterpreter()
        model.reload()

        // Prints the menu and exits. The menu can only be opened by clicking,
        // so this is the only way to check it builds without driving the mouse.
        // NOTE for whoever reads this dump: run it from the BUNDLED app,
        // `build/Seedbed.app/Contents/MacOS/Seedbed`, not from
        // `.build/debug/Seedbed`. An unbundled SPM binary has no bundle
        // identifier, so it reads a different `UserDefaults` domain and every
        // preference-driven line (the MCP status, the paste warning) is absent.
        // The menu then looks like it has regressed when only the defaults have.
        if ProcessInfo.processInfo.environment["SEEDBED_DUMP_MENU"] == "1" {
            // Off the main thread's back: the reload posts its result to the
            // main actor, so sleeping here would block the very thing being
            // waited for and the dump would always report an empty library.
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
                let menu = NSMenu()
                self.populate(menu)
                for item in menu.items {
                    let mark = item.state == .on ? "✓ " : (item.isSeparatorItem ? "" : "  ")
                    print(item.isSeparatorItem ? "  ---"
                          : "\(mark)\(item.title)\(item.isEnabled ? "" : "   [disabled]")"
                            + (item.submenu != nil ? "  ▸" : "")
                            + (item.image != nil ? "   [HAS IMAGE]" : ""))
                }
                NSApp.terminate(nil)
            }
        }

        // Prints every topic in the manual and exits. Reading the copy is the
        // whole verification for a copy change, and doing it by opening a window
        // and screenshotting it is what failed repeatedly in the build session.
        // Also reports which topics carry a worked example, because "explains a
        // rule where it should show one" is exactly what the manual rewrite was about, and
        // a count is the only cheap way to see it drift back.
        if ProcessInfo.processInfo.environment["SEEDBED_DUMP_MANUAL"] == "1" {
            var withExample = 0
            for section in Manual.sections {
                print("\n## [\(section.page.title)] \(section.title)")
                for topic in section.topics {
                    print("\n### \(topic.term)")
                    print(topic.detail)
                    if let example = topic.example {
                        withExample += 1
                        print("\n    ```")
                        for line in example.split(separator: "\n", omittingEmptySubsequences: false) {
                            print("    \(line)")
                        }
                        print("    ```")
                    }
                }
            }
            let total = Manual.topics.count
            print("\n\(total) topics, \(withExample) with a worked example, "
                  + "\(total - withExample) without")
            NSApp.terminate(nil)
            return
        }

        // Runs one manual search and exits, so the ranking can be checked
        // against real asks without opening a window and typing into it.
        if let ask = ProcessInfo.processInfo.environment["SEEDBED_SEARCH_MANUAL"], !ask.isEmpty {
            let hits = ManualSearch.results(for: ask)
            print("ask: \(ask)   (\(ManualSearch.decision), \(hits.count) hits)")
            for hit in hits {
                print(String(format: "  %.3f  [%@ · %@]  %@  (matched on %@)",
                             hit.score, hit.topic.page.title, hit.topic.section,
                             hit.topic.term, hit.matchedOn))
            }
            NSApp.terminate(nil)
            return
        }

        // Say what changed, once per version, after the UI is up. `consume`
        // records the baseline either way, so a first run stays quiet and the
        // same release is never announced twice.
        if WhatsNewAnnouncer.consume() {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { self.openWhatsNew() }
        }

        // Opens the library window straight away. Exists so the window can be
        // looked at without driving the keyboard, which is how the last two
        // layout defects were found.
        switch ProcessInfo.processInfo.environment["SEEDBED_OPEN_LIBRARY"] ?? "" {
        case "1", "compare": openLibrary()
        case "enhancer":     openSettings(.building)
        case "models":       openSettings(.models)
        case "mcp":          openSettings(.mcp)
        case "settings":     openSettings(.general)
        case "whatsnew":     openWhatsNew()
        case "faq":          openFAQ()
        case "help":         openHelp()
        // The search field with a query already in it. Typing into a window is
        // the one verification route this project will not use: synthetic
        // keystrokes reached another session's prompt during the build, which is
        // a real hazard and not a theoretical one.
        case "search":
            infoModel.query = ProcessInfo.processInfo.environment["SEEDBED_MANUAL_QUERY"] ?? "token"
            openHelp()
        // Searches, then navigates to a page, which is the state the search's
        // "the query survives a page change" is actually about. The first
        // implementation cleared the query here and claimed it did not; this
        // exists so the claim is checkable rather than asserted.
        case "searchnav":
            infoModel.query = ProcessInfo.processInfo.environment["SEEDBED_MANUAL_QUERY"] ?? "token"
            openHelp()
            infoModel.open(.faq)
        case "gettingstarted": openInfo(.gettingStarted)
        case "about":        openInfo(.about)
        // Opens Settings → Building, then swaps the library out from under it
        // after 3s, which is what "Choose library folder…" does minus the
        // NSOpenPanel this project will not drive. The pane used to
        // keep reading and WRITING the old checkout. Point it at a library with
        // a different enhancer.toml and the difference is on screen.
        case "retarget":
            openSettings(.building)
            if let path = ProcessInfo.processInfo.environment["SEEDBED_RETARGET_ROOT"] {
                DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                    let url = URL(fileURLWithPath: path)
                    UserDefaults.standard.set(path, forKey: Self.rootKey)
                    self.model.client = LibraryClient(root: url)
                    self.model.reload()
                    self.refreshEnhancerSummary()
                    print("retargeted to \(path)")
                }
            }
        // The panel itself, which otherwise needs ⌥⌘P or a click in the menu
        // bar — neither of which a headless check can do. Same reason as above.
        case "panel":        show()
        default: break
        }
    }

    private func buildStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        setBrandStatusImage(on: statusItem.button)

        // A real menu on the status item, rebuilt each time it opens. The
        // previous version put an action on the button and called performClick
        // to raise the menu, which re-enters that same action — so the menu
        // never appeared. The panel is reached by ⌥⌘P and by the menu's first
        // item, which is also how Reference does it.
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
    }

    /// Rebuilt on every open so the counts, the stale warning and the toggle
    /// states are current rather than whatever they were at launch.
    ///
    /// The reload is asynchronous and the menu has to be drawn now, so the first
    /// open after launch used to show the startup numbers and never correct
    /// them: you would read "4 renders stale" from a library that had since
    /// been rebuilt. Now the status lines are rewritten in
    /// place when the reload lands, if the menu is still open.
    ///
    /// **Only their titles change, and only the disabled ones.** Rebuilding the
    /// whole menu underneath an open one would cancel whatever the pointer was
    /// highlighting, which is a worse fault than a stale number.
    func menuNeedsUpdate(_ menu: NSMenu) {
        refreshEnhancerSummary()
        populate(menu)
        model.reload { [weak self, weak menu] in
            guard let self, let menu, self.menuIsOpen else { return }
            self.refreshStatusLines(in: menu)
        }
    }

    func menuWillOpen(_ menu: NSMenu) { menuIsOpen = true }
    func menuDidClose(_ menu: NSMenu) { menuIsOpen = false }

    /// Rewrite the disabled state lines of an already-open menu.
    ///
    /// Matched by position rather than by title: they are the leading run of
    /// disabled items, which `populate` writes first and nothing else adds to.
    private func refreshStatusLines(in menu: NSMenu) {
        let fresh = statusLines()
        for (item, title) in zip(menu.items.prefix(while: { !$0.isEnabled && !$0.isSeparatorItem }),
                                 fresh) where item.title != title {
            item.title = title
        }
    }

    private func buildPanel() {
        panel = HUDPanel(contentRect: NSRect(x: 0, y: 0, width: 480, height: 420),
                         styleMask: [.titled, .fullSizeContentView, .resizable, .nonactivatingPanel],
                         backing: .buffered, defer: false)
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.minSize = NSSize(width: 420, height: 260)
        panel.isMovableByWindowBackground = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.standardWindowButton(.closeButton)?.isHidden = true
        panel.standardWindowButton(.miniaturizeButton)?.isHidden = true
        panel.standardWindowButton(.zoomButton)?.isHidden = true
        // The panel must size itself to the list, not the other way round: a
        // fixed height clipped the last row behind the footer, which reads as a
        // missing prompt rather than as a too-small window.
        // Sized by the user, not by the content: `.preferredContentSize` fights
        // a resizable window, snapping it back on every reload.
        panel.contentView = NSHostingView(rootView: HUDView(model: model))
        panel.setFrameAutosaveName("SeedbedPanel")
        if panel.frame.origin == .zero { panel.center() }

        // Clicking away dismisses. Without this the panel has no obvious exit —
        // esc works, but nothing on screen says so, and clicking the window you
        // actually want to paste into just leaves it floating.
        NotificationCenter.default.addObserver(
            forName: NSWindow.didResignKeyNotification, object: panel, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                // A sheet becoming key makes the panel resign key. Without this
                // guard, opening the fill form dismissed the panel and took the
                // form with it — the window simply vanished mid-interaction.
                // The delete confirmation is the same shape of problem, hence
                // the same shape of guard.
                guard self.panel.attachedSheet == nil,
                      self.model.filling == nil,
                      self.model.pendingDelete == nil else { return }
                self.hide()
            }
        }
    }

    /// A checkmark in the menu bar for a moment after a copy.
    ///
    /// The panel closes the instant the clipboard is set — that is the point, so
    /// the paste can follow immediately — which leaves nowhere to show a
    /// confirmation. The status item is the one piece of this app that is always
    /// on screen, so it carries the receipt.
    private func flashCopied(_ message: String) {
        guard let button = statusItem.button else { return }
        flashReset?.cancel()
        button.image = NSImage(systemSymbolName: "checkmark.circle.fill",
                               accessibilityDescription: message)
        button.image?.isTemplate = true
        button.toolTip = message

        let reset = DispatchWorkItem { [weak self] in
            guard let self, let button = self.statusItem.button else { return }
            self.setBrandStatusImage(on: button)
            button.toolTip = nil
        }
        flashReset = reset
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.8, execute: reset)
    }

    /// The custom mark is deliberately simpler than the full app icon. At
    /// menu-bar scale the two leaves and two text rows are the useful detail;
    /// AppKit recolors the alpha mask for light, dark and high-contrast bars.
    private func setBrandStatusImage(on button: NSStatusBarButton?) {
        guard let button else { return }
        let image = NSImage(named: "SeedbedMenuBar")
            ?? NSImage(systemSymbolName: "leaf.fill",
                       accessibilityDescription: "Seedbed prompt library")
        image?.isTemplate = true
        image?.size = NSSize(width: 18, height: 18)
        image?.accessibilityDescription = "Seedbed prompt library"
        button.image = image
    }

    /// Return focus to the app that was front before the panel opened, and send
    /// it ⌘V. Without Accessibility permission this cannot work at all, so say
    /// so once and leave the text on the clipboard.
    private func pasteIntoPreviousApp() {
        let target = Paster.previousApp?.localizedName ?? "the previous app"
        Paster.paste { [weak self] outcome in
            guard let self else { return }
            switch outcome {
            case .pasted:
                self.statusItem.button?.toolTip = "Pasted into \(target)"
            case .noPermission:
                self.model.show(
                    "Copied. To paste automatically, allow Seedbed under "
                    + "Privacy & Security → Accessibility.", isError: true)
                self.show()
                Paster.requestPermission()
            case .noTarget:
                self.model.show("Copied — no app to paste into.", isError: true)
            }
        }
    }

    // MARK: - Showing and hiding

    private func toggle() {
        panel.isVisible ? hide() : show()
    }

    private func show() {
        Paster.rememberFrontmost()
        model.query = ""
        model.selection = 0
        model.clearStatus()
        model.reload()
        if !panel.setFrameUsingName("SeedbedPanel") { positionUnderMenuBar() }
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
    }

    private func hide() {
        panel.orderOut(nil)
    }

    /// Centred horizontally on the active screen, a little below the menu bar —
    /// where a summoned panel is expected, rather than wherever it last sat.
    private func positionUnderMenuBar() {
        guard let screen = NSScreen.main else { return }
        let frame = panel.frame
        let visible = screen.visibleFrame
        let origin = NSPoint(x: visible.midX - frame.width / 2,
                             y: visible.maxY - frame.height - 40)
        panel.setFrameOrigin(origin)
    }

    // MARK: - Menu

    /// The whole app in one menu, in Reference's shape: what it is doing, the
    /// things you do most, the things you configure, then about/updates/help,
    /// then quit.
    /// The disabled lines at the top of the menu: what the app is doing right
    /// now. Built here rather than inline so an open menu can be corrected
    /// against the same list it was drawn from.
    /// The lead sentence of an error, for a menu item that has one line.
    ///
    /// Split on ". " rather than "." — the message this exists for is
    /// "No Python 3.11+ found. Install one (brew install python)…", and a split
    /// on the bare period cuts it at "No Python 3". The full text stays in the
    /// panel's status bar, which has room for the remedy.
    private static func firstSentence(of message: String) -> String {
        let lead = message.range(of: ". ").map { String(message[..<$0.lowerBound]) + "." }
                   ?? message
        return lead.count <= 64 ? lead : String(lead.prefix(63)) + "…"
    }

    private func statusLines() -> [String] {
        var lines: [String] = []
        let prompts = model.prompts.count
        let models = model.allModels.count
        lines.append("Seedbed — \(prompts) prompt\(prompts == 1 ? "" : "s") · "
                     + "\(models) model\(models == 1 ? "" : "s")")
        // A library that could not be READ counts as zero of everything, and
        // "0 prompts · 0 models" is indistinguishable from an empty one. On a
        // Mac with no Python 3.11+ that is the entire diagnosis the menu offers,
        // while the CLI on the same machine says exactly what is wrong. Found by
        // installing the DMG on a second Mac on 2026-09-05, which is what §4 of
        // the learning log had been asking for.
        if model.statusIsError, !model.status.isEmpty {
            lines.append("⚠︎ \(Self.firstSentence(of: model.status))")
        }
        if let summary = enhancerSummary {
            lines.append("Builds with: \(summary)")
        }
        let stale = model.staleCount
        if stale > 0 {
            lines.append("⚠︎ \(stale) render\(stale == 1 ? "" : "s") stale or missing")
        }
        // The server has no window of its own, so the menu is the only place it
        // can say it is up, and "switched on but not running" is the state that
        // most needs telling: a failed bind is otherwise silent.
        if UserDefaults.standard.bool(forKey: Self.mcpEnabledKey) {
            lines.append(mcp?.isRunning == true
                         ? "MCP: serving agents on 127.0.0.1:\(Self.mcpPort)"
                         : "⚠︎ MCP: switched on but not running")
        }
        return lines
    }

    private func populate(_ menu: NSMenu) {
        menu.removeAllItems()

        // State first, then the few things you actually come here to do, then
        // the two windows that hold everything else. This menu carried 21 items
        // and 5 state lines before the settings and the manual each got a window
        // of their own, which is well past the point where you read it rather
        // than scan it.
        for line in statusLines() { menu.addItem(disabled: line) }
        if Paster.isEnabled && !Paster.hasPermission {
            let fix = menu.addItem(withTitle: "⚠︎ Needs Accessibility permission to paste…",
                                   action: #selector(openGeneralSettings), keyEquivalent: "")
            fix.target = self
        }

        menu.addItem(.separator())
        let open = menu.addItem(withTitle: "Show Prompts…", action: #selector(openFromMenu),
                                keyEquivalent: "p")
        open.keyEquivalentModifierMask = [.command, .option]
        open.target = self
        let library = menu.addItem(withTitle: "Library…", action: #selector(openLibraryFromMenu),
                                   keyEquivalent: "l")
        library.target = self
        let rebuild = menu.addItem(withTitle: "Rebuild Everything Stale…",
                                   action: #selector(refresh), keyEquivalent: "")
        rebuild.target = self
        rebuild.isEnabled = model.staleCount > 0

        menu.addItem(.separator())
        let settings = menu.addItem(withTitle: "Settings…", action: #selector(openSettingsFromMenu),
                                    keyEquivalent: ",")
        settings.target = self
        let help = menu.addItem(withTitle: "Help & FAQ", action: #selector(openHelp),
                                keyEquivalent: "")
        help.target = self
        let updates = menu.addItem(withTitle: "Check for Updates…", action: #selector(checkForUpdates),
                                   keyEquivalent: "")
        updates.target = self

        menu.addItem(.separator())
        // Routed through our own method rather than `terminate:`. macOS
        // decorates items carrying that standard selector with a system icon,
        // and setting `image = nil` does not stop it — the decoration is applied
        // after. An unrecognised action gets no icon, and still quits.
        let quit = menu.addItem(withTitle: "Quit Seedbed", action: #selector(quitApp),
                                keyEquivalent: "q")
        quit.target = self
    }

    /// Cached so building the menu never blocks on a subprocess. Stored on the
    /// model rather than here so the About page, which lives in a window built
    /// once and reused, follows it.
    private var enhancerSummary: String? { model.enhancerSummary }

    private func refreshEnhancerSummary() {
        let client = model.client
        Task.detached {
            let summary = (try? client.enhancerConfig())?.summary
            await MainActor.run { self.model.enhancerSummary = summary }
        }
    }

    /// Everything there is to configure: one window, four panes. Before this it
    /// was three sheets on the library window plus five items in this menu, and
    /// one setting lived in two of those at once.
    func openSettings(_ page: SettingsPage) {
        settingsModel.page = page
        InfoWindows.shared.show("settings", title: "Seedbed Settings",
                                size: NSSize(width: Tokens.Size.settings.width,
                                             height: Tokens.Size.settings.height),
                                minSize: NSSize(width: Tokens.Size.settingsMin.width,
                                                height: Tokens.Size.settingsMin.height)) {
            SettingsWindowView(
                model: self.settingsModel,
                server: self.mcp,
                library: self.model,
                onSyncMCP: { self.syncMCPServer() },
                onReloadLibrary: { self.model.reload() },
                onRevealLibrary: { self.revealRoot() },
                onChooseLibrary: { self.chooseRoot() })
                .environment(\.textScale, .reading)
        }
    }

    @objc private func openSettingsFromMenu() { openSettings(.general) }
    @objc private func openGeneralSettings() { openSettings(.general) }
    @objc private func openModelsEditor() { openSettings(.models) }
    @objc private func openEnhancerEditor() { openSettings(.building) }
    @objc private func openMCPSettings() { openSettings(.mcp) }

    /// The manual: one window, five pages, opened on whichever one was asked
    /// for. It used to be five separate windows at four different widths.
    func openInfo(_ page: InfoPage) {
        infoModel.page = page
        InfoWindows.shared.show("info", title: "Seedbed",
                                size: NSSize(width: Tokens.Size.info.width,
                                             height: Tokens.Size.info.height),
                                minSize: NSSize(width: Tokens.Size.infoMin.width,
                                                height: Tokens.Size.infoMin.height)) {
            InfoWindowView(model: self.infoModel,
                           library: self.model,
                           openLibrary: { self.openLibrary() },
                           openSettings: { self.openSettings(.general) })
                // This window is the one made of prose — the manual, the FAQ,
                // the release notes, About. Declared once here rather than at
                // every Text inside it, and it is the only surface that opts
                // in: the picker and the library stay compact on purpose.
                .environment(\.textScale, .reading)
        }
    }

    @objc private func openAbout() { openInfo(.about) }
    @objc private func openWelcome() { openInfo(.gettingStarted) }
    @objc private func openHelp() { openInfo(.help) }
    @objc private func openFAQ() { openInfo(.faq) }
    @objc private func openWhatsNew() { openInfo(.whatsNew) }

    @objc private func toggleLaunchAtLogin() {
        if let problem = LaunchAtLogin.set(!LaunchAtLogin.isEnabled) {
            let alert = NSAlert()
            alert.messageText = "Could not change the login item"
            alert.informativeText = problem
            alert.runModal()
        }
    }

    /// Two kinds of copy, two meanings of "update", and the menu item routes.
    ///
    /// A copy built out of the checkout gets the git answer: the repository has
    /// commits this build does not, here they are, rebuild. Offering that copy a
    /// signed release from the feed would replace the build under development
    /// with whatever last shipped.
    ///
    /// An installed copy gets Sparkle, because it has no toolchain and no
    /// checkout of its own to compare against — `Updates.check` would tell it
    /// only that some directory it does not own is behind.
    @objc private func checkForUpdates() {
        if !Updates.wasBuiltFrom(root), updater.canCheck {
            updater.checkForUpdates()
            return
        }
        let result = Updates.check(root: root)
        let alert = NSAlert()
        alert.messageText = result.title
        alert.informativeText = result.detail
        alert.addButton(withTitle: "OK")
        if result.behind > 0 {
            alert.addButton(withTitle: "Open in Finder")
        }
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertSecondButtonReturn {
            NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: root.path)
        }
    }

    private func modelsMenu() -> NSMenu {
        let menu = NSMenu()
        let known = model.allModels
        for entry in known {
            let item = menu.addItem(withTitle: entry.name, action: #selector(toggleModel(_:)),
                                    keyEquivalent: "")
            item.target = self
            item.representedObject = entry.id
            item.state = ModelFilter.isVisible(entry.id) ? .on : .off
        }
        if known.isEmpty {
            menu.addItem(disabled: "No models loaded")
        } else {
            menu.addItem(.separator())
            let all = menu.addItem(withTitle: "Show All", action: #selector(showAllModels),
                                   keyEquivalent: "")
            all.target = self
        }
        return menu
    }

    @objc private func toggleModel(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        ModelFilter.toggle(id, allKnown: model.allModels.map(\.id))
        model.reload()
    }

    @objc private func showAllModels() {
        ModelFilter.showAll()
        model.reload()
    }

    @objc private func togglePaste() {
        Paster.isEnabled.toggle()
        if Paster.isEnabled && !Paster.hasPermission { Paster.requestPermission() }
    }

    @objc private func openAccessibility() {
        Paster.openAccessibilitySettings()
    }

    /// The big window: browse, edit, compare. One instance, reused.
    @objc func openLibraryFromMenu() { openLibrary() }

    func openLibrary(selecting id: String? = nil) {
        if let window = libraryWindow {
            if let id { libraryModel?.pendingSelection = id }
            libraryModel?.reload()
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            return
        }
        let libModel = LibraryModel(client: model.client)
        libModel.onOpenSettings = { [weak self] page in self?.openSettings(page) }
        // Set before the view appears and its `onAppear` reload runs, so the
        // reload lands on the prompt asked for rather than on the first one.
        libModel.pendingSelection = id
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1040, height: 640),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered, defer: false)
        window.title = "Seedbed Library"
        // The library is a working surface — a list beside an editor — so its
        // rows and model chips stay on the compact ramp while its forms and
        // prose read at window sizes. See TextScale.
        window.contentView = NSHostingView(
            rootView: LibraryView(model: libModel).environment(\.textScale, .reading))
        window.setFrameAutosaveName("PromptLibraryWindow")
        window.isReleasedWhenClosed = false
        if window.frame.origin == .zero { window.center() }

        libraryModel = libModel
        libraryWindow = window
        hide()   // the HUD panel and this window are different jobs
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    /// Brings the server in line with the settings. Called at launch and
    /// whenever the pane changes something — the enable toggle, the port, or a
    /// regenerated token, each of which needs a rebind rather than a reload.
    func syncMCPServer() {
        guard let mcp else { return }
        guard UserDefaults.standard.bool(forKey: Self.mcpEnabledKey) else {
            mcp.stop()
            return
        }
        let tokens = MCPTokenStore.ensure()
        mcp.start(port: Self.mcpPort, token: tokens.full, readOnlyToken: tokens.readOnly)
    }

    var mcpServer: MCPServer { mcp }

    @objc private func quitApp() { NSApp.terminate(nil) }

    @objc private func openFromMenu() { show() }

    @objc private func revealRoot() {
        NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: root.path)
    }

    @objc private func chooseRoot() {
        let dialog = NSOpenPanel()
        dialog.canChooseDirectories = true
        dialog.canChooseFiles = false
        dialog.allowsMultipleSelection = false
        dialog.prompt = "Use this library"
        dialog.directoryURL = root
        NSApp.activate(ignoringOtherApps: true)
        guard dialog.runModal() == .OK, let url = dialog.url else { return }
        // Refuse here rather than letting every later action fail with a Python
        // import error that says nothing about the folder you picked.
        if let reason = LibraryClient.whyNotALibrary(url) {
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = "That folder is not a Seedbed library"
            alert.informativeText = "\(url.lastPathComponent): \(reason)"
            alert.addButton(withTitle: "OK")
            alert.runModal()
            return
        }
        UserDefaults.standard.set(url.path, forKey: Self.rootKey)
        model.client = LibraryClient(root: url)
        model.reload()
    }

    /// Rebuilding calls the enhancer for every stale pair, so it can run for
    /// minutes. The panel owns the work and reports progress; this just opens it.
    @objc private func refresh() {
        show()
        model.rebuild(scope: .everything)
    }
}

@main
@MainActor
enum SeedbedApp {
    /// `NSApplication.delegate` is weak, so the controller is held here for the
    /// process lifetime; a local would be deallocated before the first event.
    private static var controller: AppController?

    static func main() {
        let app = NSApplication.shared
        let controller = AppController()
        Self.controller = controller
        app.delegate = controller
        app.run()
    }
}
