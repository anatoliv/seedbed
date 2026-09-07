import AppKit
import Security
import SwiftUI

/// The five pages of the app's manual.
///
/// They used to be five separate windows at four different widths, each laid out
/// its own way and each reached by its own menu item. Every one of them is a page
/// of the same document, and someone reading Help who wants the FAQ should not
/// have to close a window, open a menu and know the other page's name.
enum InfoPage: String, CaseIterable, Identifiable {
    case gettingStarted, help, faq, whatsNew, about

    var id: String { rawValue }

    var title: String {
        switch self {
        case .gettingStarted: return "Getting Started"
        case .help:           return "Help"
        case .faq:            return "FAQ"
        case .whatsNew:       return "What's New"
        case .about:          return "About"
        }
    }

    /// The capsule under the title follows Reference's metadata-chip recipe. It
    /// badges a topic with its category; these five pages are the categories,
    /// so the badge says what kind of reading each one is rather than repeating
    /// its name.
    var badge: String {
        switch self {
        case .gettingStarted: return "Overview"
        case .help:           return "Reference"
        case .faq:            return "Reference"
        case .whatsNew:       return "Release notes"
        case .about:          return "This build"
        }
    }

    var subtitle: String {
        switch self {
        case .gettingStarted: return "The shortest path from a seed to a prompt you can paste."
        case .help:           return "Shortcuts, workflow, vocabulary, and troubleshooting."
        case .faq:            return "Straight answers about agents, security, and your library."
        case .whatsNew:       return "Every Seedbed release, newest first."
        case .about:          return "Version, library, and runtime details for this build."
        }
    }

    var symbol: String {
        switch self {
        case .gettingStarted: return "sparkles"
        case .help:           return "questionmark.circle"
        case .faq:            return "text.bubble"
        case .whatsNew:       return "sparkles"
        case .about:          return "info.circle"
        }
    }

    /// Reference distinguishes the release-notes destination from its page
    /// heading: a megaphone in navigation, sparkles over the releases.
    var sidebarSymbol: String {
        self == .whatsNew ? "megaphone" : symbol
    }
}

/// Which page is showing. A published object rather than view state, because
/// the menu and the launch hooks have to be able to open the window *on* a page
/// while it is already open.
@MainActor
final class InfoModel: ObservableObject {
    @Published var page: InfoPage = .help

    /// What is in the search field. Lives here rather than in the view so it
    /// survives a page change and the window being closed and reopened, which is
    /// what the search was asked for.
    ///
    /// Editing it always returns you to the results. That is why `browsing` is
    /// reset here rather than at the call sites: a reader who types is looking
    /// for something, whatever they were reading a moment ago.
    @Published var query: String = "" {
        didSet { if query != oldValue { browsing = false } }
    }

    /// True when the reader has picked a page and wants to READ it, even though
    /// their query is still in the field.
    ///
    /// Without this the two halves of the spec contradict each other. "The query
    /// survives a page change" and "results show while the field has text"
    /// cannot both hold, because selecting Help while a query stands would show
    /// results rather than Help. The first version resolved that by clearing the
    /// query on every navigation, which quietly dropped the requirement and then
    /// claimed to meet it. This keeps both: the text stays, the page shows, and
    /// typing or pressing Return goes back to the results.
    @Published var browsing = false

    /// Which guide page is showing, if one is. The five built-in pages and the
    /// thirty guide pages share one sidebar, so exactly one of these is in
    /// force: setting either clears the other.
    @Published var guide: String?

    /// Go to a page and read it, keeping the query for when you want it back.
    func open(_ page: InfoPage) {
        self.page = page
        self.guide = nil
        browsing = true
    }

    func open(guide id: String) {
        self.guide = id
        browsing = true
    }

    /// What the sidebar's selection binds to. A guide id and an `InfoPage`
    /// raw value cannot collide, so one string identifies either.
    var selection: String {
        get { guide ?? page.rawValue }
        set {
            if let p = InfoPage(rawValue: newValue) { open(p) } else { open(guide: newValue) }
        }
    }
}

struct InfoWindowView: View {
    @ObservedObject var model: InfoModel
    /// Observed rather than snapshotted, so About follows a changed library
    /// folder or a reconfigured enhancer instead of showing what was true the
    /// first time this window opened.
    @ObservedObject var library: HUDModel
    var openLibrary: () -> Void
    var openSettings: () -> Void

    private func row(_ page: InfoPage) -> some View {
        Label {
            Text(page.title)
        } icon: {
            Image(systemName: page.sidebarSymbol)
                .foregroundStyle(page == .whatsNew ? Tokens.accent : Color.primary)
        }
        .font(Tokens.FontScale.body)
        .tag(page.rawValue)
    }

    /// The scrolling half of a page, under the fixed header.
    @ViewBuilder private func pageBody<C: View>(
        maxWidth: CGFloat = Tokens.Width.reading,
        @ViewBuilder _ content: () -> C
    ) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Tokens.Space.regular) {
                content()
            }
            .frame(maxWidth: maxWidth, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, Tokens.Space.pane)
            .padding(.vertical, Tokens.Space.wide)
        }
    }

    var body: some View {
        HStack(spacing: 0) {
            // The search field lives in the SIDEBAR, above the contents, which
            // is where Reference puts it and where a reader looks for it: the
            // sidebar is the "how do I find a page" column, and searching is the
            // other way of answering that question. It sat over the reading
            // column before, which made it look like it searched the page.
            VStack(spacing: 0) {
                ManualSearchField(query: $model.query,
                                  resultCount: model.browsing ? resultCount : nil,
                                  onReturnToResults: { model.browsing = false })
                    .padding(Tokens.Space.medium)
                SeedbedDivider()
                List(selection: Binding(get: { model.selection },
                                        set: { model.selection = $0 ?? InfoPage.help.rawValue })) {
                    // Reference keeps What's New above the long help index. Putting
                    // it after Seedbed's 35 guide pages made the release notes
                    // disappear below the initial viewport at the normal window
                    // size, which is indistinguishable from not shipping them.
                    row(.whatsNew)
                    // The guide is what the sidebar is FOR. Before this it
                    // listed five pages, one of which was a table of key caps,
                    // and everything the app can do was inside them. Reference
                    // likewise gives each subject a page, so a reader
                    // browses rather than scrolls.
                    Section("Start here") {
                        ForEach([InfoPage.gettingStarted, .help, .faq]) { row($0) }
                    }
                    ForEach(Guide.categories, id: \.name) { category in
                        Section(category.name) {
                            ForEach(Guide.pages(in: category.name)) { page in
                                Label(page.title, systemImage: category.symbol)
                                    .font(Tokens.FontScale.body)
                                    .tag(page.id)
                            }
                        }
                    }
                    Section("This build") {
                        row(.about)
                    }
                }
                .listStyle(.sidebar)
                .scrollContentBackground(.hidden)
            }
            .frame(width: Tokens.Width.sidebar)
            SeedbedDivider()
            Group {
                if searching {
                    PageHeader(title: "Search",
                               symbol: "magnifyingglass",
                               badge: "\(resultCount ?? 0) result\(resultCount == 1 ? "" : "s")",
                               subtitle: "Results across Help, FAQ, and the full guide.") {
                        pageBody { ManualSearchResults(query: model.query) { model.open($0) } }
                    }
                } else if let id = model.guide,
                          let entry = Guide.pages.first(where: { $0.id == id }) {
                    PageHeader(title: entry.title,
                               symbol: Guide.symbol(for: entry.category),
                               badge: "Guide",
                               subtitle: entry.category) {
                        pageBody { GuideMarkdown(entry.body) }
                    }
                } else {
                    PageHeader(title: model.page.title,
                               symbol: model.page.symbol,
                               badge: model.page.badge,
                               subtitle: model.page.subtitle) {
                        pageBody(maxWidth: model.page == .whatsNew
                            ? Tokens.Width.releaseNotes
                            : Tokens.Width.reading) { page }
                    }
                }
            }
            // The reading column grows with the window; the sidebar does not.
            // A wider window should give the prose more room, which is the only
            // reason to widen this one.
            .frame(minWidth: Tokens.Size.infoMin.width - Tokens.Width.sidebar, maxWidth: .infinity)
        }
        // A minimum, not a size. A fixed frame here pinned the window no matter
        // what the style mask said: `.resizable` was already set and the drag
        // simply did nothing, because SwiftUI content of an exact size cannot be
        // asked for another one.
        .frame(minWidth: Tokens.Size.infoMin.width, idealWidth: Tokens.Size.info.width,
               maxWidth: .infinity,
               minHeight: Tokens.Size.infoMin.height, idealHeight: Tokens.Size.info.height,
               maxHeight: .infinity)
        .background(Tokens.Surface.canvas)
        .tint(Tokens.accent)
    }

    /// A query of only whitespace is not a search, and blanking the page for one
    /// looks like the window broke. `browsing` is the other half: the reader has
    /// gone to a page, and their query is being kept rather than acted on.
    private var searching: Bool {
        !model.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !model.browsing
    }

    /// Only computed while a page is showing over a live query, which is the one
    /// case where the reader needs telling that their search is still there.
    private var resultCount: Int? {
        guard !model.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return nil }
        return ManualSearch.results(for: model.query).count
    }

    @ViewBuilder private var page: some View {
        switch model.page {
        case .gettingStarted:
            GettingStartedPage(openLibrary: openLibrary, openSettings: openSettings)
        case .help:      HelpPage()
        case .faq:       FAQPage()
        case .whatsNew:  WhatsNewPage()
        case .about:     AboutPage(libraryPath: library.client.root.path,
                                   enhancer: library.enhancerSummary ?? "not read yet")
        }
    }
}

// MARK: - Pages

struct GettingStartedPage: View {
    var openLibrary: () -> Void
    var openSettings: () -> Void

    var body: some View {
        SectionHeader("Three ideas, and then it is just ⌥⌘P")
        VStack(alignment: .leading, spacing: Tokens.Space.regular) {
            step(1, "Keep the prompt short",
                 "You write a seed, \"fix this bug and test\". That is all you maintain. Put "
                 + "{{PLACEHOLDER}} anywhere you will fill in a value later.")
            step(2, "The library writes the long version",
                 "For each model you target, the enhancer reads that model's prompting "
                 + "guidance and expands your seed into a prompt shaped for it. The same seed "
                 + "becomes prose for one model and numbered steps for another.")
            step(3, "Grab it in two seconds",
                 "⌥⌘P anywhere, type to filter, ⏎ to paste it into whatever you were working "
                 + "in. If the prompt has placeholders you are asked for them first, with "
                 + "your previous answers on a menu.")
        }
        SeedbedDivider()
        SectionHeader("Worth doing once")
        HStack(spacing: Tokens.Space.tight) {
            Button("Open Settings…", action: openSettings)
            Button("Open the library…", action: openLibrary)
        }
        Caption("Out of the box it builds with the Claude Code CLI already on this machine, so "
                + "nothing needs a key. Grant Accessibility permission when asked and ⏎ will "
                + "paste rather than only copy.")
    }

    private func step(_ number: Int, _ title: String, _ body: String) -> some View {
        HStack(alignment: .top, spacing: Tokens.Space.tight) {
            Text("\(number)")
                .font(Tokens.FontScale.body.weight(.medium))
                .frame(width: 20, height: 20)
                .background(Circle().fill(Tokens.accent.opacity(0.18)))
            VStack(alignment: .leading, spacing: Tokens.Space.row) {
                Text(title).font(Tokens.FontScale.body.weight(.medium))
                Caption(body)
            }
        }
        .seedbedCard(padding: Tokens.Space.regular, radius: Tokens.Radius.card)
    }
}

/// What this copy's own signature says, read at runtime instead of assumed.
///
/// The About page asserted "locally, not notarized, built on this machine"
/// unconditionally. That is false on every copy installed from the release DMG,
/// which is Developer ID signed, notarized and stapled before it is published —
/// and About is the one screen a cautious user opens to check exactly this. A
/// hardcoded claim about a security property is worse than no claim.
enum BuildProvenance {
    /// True when the running copy satisfies the Developer ID requirement, which
    /// is what Gatekeeper evaluates. Locally built copies are ad-hoc or
    /// development-signed and do not.
    static var isDeveloperIDSigned: Bool {
        var code: SecCode?
        guard SecCodeCopySelf(SecCSFlags(), &code) == errSecSuccess, let code else { return false }
        var requirement: SecRequirement?
        let text = "anchor apple generic and certificate leaf[field.1.2.840.113635.100.6.1.13] exists"
        guard SecRequirementCreateWithString(text as CFString, SecCSFlags(), &requirement) == errSecSuccess,
              let requirement else { return false }
        return SecCodeCheckValidity(code, SecCSFlags(), requirement) == errSecSuccess
    }

    /// Says only what was checked, and nothing more. Notarization is a separate
    /// property and is not verified here, so this does not mention it: a build
    /// made on this Mac is Developer ID signed too, and claiming Gatekeeper
    /// approval on that basis would be the same kind of overstatement the
    /// hardcoded string was.
    static var summary: String {
        isDeveloperIDSigned ? "Developer ID signed" : "locally built, not Developer ID signed"
    }
}

struct AboutPage: View {
    let libraryPath: String
    let enhancer: String

    var body: some View {
        HStack(spacing: Tokens.Space.snug) {
            // The app's own icon, read from the bundle, so it can never drift
            // from what Finder shows. This was `text.badge.star`, a borrowed
            // SF Symbol — and About art is one of the four places the brand
            // rules reserve for the full terracotta tile. The one screen whose
            // job is to say what this app is was showing a glyph belonging to
            // no product at all.
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .interpolation(.high)
                .frame(width: 48, height: 48)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: Tokens.ChipPadding.v) {
                Text("Seedbed").font(Tokens.FontScale.display)
                Text("Version \(InfoWindows.version)")
                    .font(Tokens.FontScale.small).foregroundStyle(.secondary)
            }
            Spacer()
        }
        Text("A prompt library that keeps a short seed and generates the long, model-tailored "
             + "version of it. The app is a front end; the library itself is plain markdown in "
             + "a git repository.")
            .font(Tokens.FontScale.body)
            .fixedSize(horizontal: false, vertical: true)
        SeedbedDivider()
        VStack(alignment: .leading, spacing: Tokens.Space.medium) {
            row("Library", libraryPath)
            row("Builds with", enhancer)
            row("Signature", BuildProvenance.summary)
        }
        SeedbedDivider()
        // Every network call this app can make, named. The previous wording said
        // there was none beyond the enhancer and the guidance fetch, which
        // omitted the Sparkle update check an installed copy makes on its own
        // schedule, and predated crash reporting entirely.
        Caption("No account and no analytics. Over the network: the model endpoint you "
                + "configure, the documentation it fetches, and an update check against "
                + "seedbed.dev. Crash reporting is off unless you turn it on in Settings, "
                + "and never carries prompt text.")
    }

    private func row(_ label: String, _ value: String) -> some View {
        HStack(alignment: .top, spacing: Tokens.Space.tight) {
            Text(label).font(Tokens.FontScale.small)
                .foregroundStyle(.secondary).frame(width: 78, alignment: .leading)
            Text(value).font(Tokens.FontScale.small).textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
