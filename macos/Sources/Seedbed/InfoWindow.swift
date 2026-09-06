import AppKit
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

    /// The capsule under the title. Reference badges a topic with its
    /// category; these five pages are the categories, so the badge says what
    /// kind of reading each one is rather than repeating its name.
    var badge: String {
        switch self {
        case .gettingStarted: return "Overview"
        case .help:           return "Reference"
        case .faq:            return "Reference"
        case .whatsNew:       return "Release notes"
        case .about:          return "This build"
        }
    }

    var symbol: String {
        switch self {
        case .gettingStarted: return "sparkles"
        case .help:           return "questionmark.circle"
        case .faq:            return "text.bubble"
        case .whatsNew:       return "gift"
        case .about:          return "info.circle"
        }
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
        Label(page.title, systemImage: page.symbol)
            .font(.system(size: Tokens.ReadingSize.body))
            .tag(page.rawValue)
    }

    /// The scrolling half of a page, under the fixed header.
    @ViewBuilder private func pageBody<C: View>(@ViewBuilder _ content: () -> C) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Tokens.Space.section) {
                content()
            }
            .padding(Tokens.Space.page)
            .frame(maxWidth: .infinity, alignment: .leading)
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
                    .padding(.horizontal, Tokens.Space.group)
                    .padding(.top, Tokens.Space.group)
                    .padding(.bottom, Tokens.Space.control)
                Divider()
                List(selection: Binding(get: { model.selection },
                                        set: { model.selection = $0 ?? InfoPage.help.rawValue })) {
                    // The guide is what the sidebar is FOR. Before this it
                    // listed five pages, one of which was a table of key caps,
                    // and everything the app can do was inside them. Reference
                    // lists fifty-three subjects and gives each a page; a reader
                    // browses rather than scrolls.
                    Section("Start here") {
                        ForEach([InfoPage.gettingStarted, .help, .faq]) { row($0) }
                    }
                    ForEach(Guide.categories, id: \.name) { category in
                        Section(category.name) {
                            ForEach(Guide.pages(in: category.name)) { page in
                                Label(page.title, systemImage: category.symbol)
                                    .font(.system(size: Tokens.ReadingSize.body))
                                    .tag(page.id)
                            }
                        }
                    }
                    Section("This build") {
                        ForEach([InfoPage.whatsNew, .about]) { row($0) }
                    }
                }
                .listStyle(.sidebar)
                .scrollContentBackground(.hidden)
            }
            .frame(width: Tokens.Width.sidebar)
            Divider()
            Group {
                if searching {
                    PageHeader(title: "Search",
                               symbol: "magnifyingglass",
                               badge: "\(resultCount) result\(resultCount == 1 ? "" : "s")") {
                        pageBody { ManualSearchResults(query: model.query) { model.open($0) } }
                    }
                } else if let id = model.guide,
                          let entry = Guide.pages.first(where: { $0.id == id }) {
                    PageHeader(title: entry.title,
                               symbol: Guide.symbol(for: entry.category),
                               badge: entry.category) {
                        pageBody { GuideMarkdown(entry.body) }
                    }
                } else {
                    PageHeader(title: model.page.title,
                               symbol: model.page.symbol,
                               badge: model.page.badge) {
                        pageBody { page }
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
        VStack(alignment: .leading, spacing: Tokens.Space.section) {
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
        Divider()
        SectionHeader("Worth doing once")
        HStack(spacing: Tokens.Space.control) {
            Button("Open Settings…", action: openSettings)
            Button("Open the library…", action: openLibrary)
        }
        Caption("Out of the box it builds with the Claude Code CLI already on this machine, so "
                + "nothing needs a key. Grant Accessibility permission when asked and ⏎ will "
                + "paste rather than only copy.")
    }

    private func step(_ number: Int, _ title: String, _ body: String) -> some View {
        HStack(alignment: .top, spacing: Tokens.Space.control) {
            Text("\(number)")
                .font(.system(size: Tokens.ReadingSize.meta, weight: .bold))
                .frame(width: 20, height: 20)
                .background(Circle().fill(Tokens.accent.opacity(0.18)))
            VStack(alignment: .leading, spacing: Tokens.Space.row) {
                Text(title).font(.system(size: Tokens.ReadingSize.body, weight: .semibold))
                Caption(body)
            }
        }
    }
}

struct AboutPage: View {
    let libraryPath: String
    let enhancer: String

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "text.badge.star")
                .font(.system(size: Tokens.CompactSize.hero)).foregroundStyle(Tokens.accent)
            VStack(alignment: .leading, spacing: 2) {
                Text("Seedbed").font(.system(size: Tokens.ReadingSize.display,
                                             weight: .semibold, design: .rounded))
                Text("Version \(InfoWindows.version)")
                    .font(.system(size: Tokens.ReadingSize.meta)).foregroundStyle(.secondary)
            }
            Spacer()
        }
        Text("A prompt library that keeps a short seed and generates the long, model-tailored "
             + "version of it. The app is a front end; the library itself is plain markdown in "
             + "a git repository.")
            .font(.system(size: Tokens.ReadingSize.body))
            .fixedSize(horizontal: false, vertical: true)
        Divider()
        VStack(alignment: .leading, spacing: Tokens.Space.group) {
            row("Library", libraryPath)
            row("Builds with", enhancer)
            row("Signed", "locally, not notarized, built on this machine")
        }
        Divider()
        Caption("Personal tool. No analytics, and no network traffic except the model endpoint "
                + "you configure and the documentation it fetches.")
    }

    private func row(_ label: String, _ value: String) -> some View {
        HStack(alignment: .top, spacing: Tokens.Space.control) {
            Text(label).font(.system(size: Tokens.ReadingSize.meta, weight: .medium))
                .foregroundStyle(.secondary).frame(width: 78, alignment: .leading)
            Text(value).font(.system(size: Tokens.ReadingSize.meta)).textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
