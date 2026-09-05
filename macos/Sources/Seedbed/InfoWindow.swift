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

    /// Go to a page and read it, keeping the query for when you want it back.
    func open(_ page: InfoPage) {
        self.page = page
        browsing = true
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

    var body: some View {
        HStack(spacing: 0) {
            List(selection: Binding(get: { model.page },
                                    set: { model.open($0 ?? .help) })) {
                ForEach(InfoPage.allCases) { page in
                    Label(page.title, systemImage: page.symbol)
                        .font(.system(size: Tokens.CompactSize.rowText))
                        .tag(page)
                }
            }
            .listStyle(.sidebar)
            .frame(width: Tokens.Width.sidebar)
            Divider()
            VStack(spacing: 0) {
                // Above the scroll view, not inside it: a search field that
                // scrolls away is one you have to scroll back up to reach, and
                // the whole point of it is that you reach for it first.
                ManualSearchField(query: $model.query,
                                  resultCount: model.browsing ? resultCount : nil,
                                  onReturnToResults: { model.browsing = false })
                    .padding(.horizontal, Tokens.Space.page)
                    .padding(.top, Tokens.Space.group)
                    .padding(.bottom, Tokens.Space.group)
                Divider()
                ScrollView {
                    VStack(alignment: .leading, spacing: Tokens.Space.section) {
                        if searching {
                            ManualSearchResults(query: model.query) { model.open($0) }
                        } else {
                            page
                        }
                    }
                    .padding(Tokens.Space.page)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .frame(width: Tokens.Width.reading)
        }
        .frame(width: Tokens.Size.info.width, height: Tokens.Size.info.height)
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
                .font(.system(size: Tokens.CompactSize.meta, weight: .bold))
                .frame(width: 20, height: 20)
                .background(Circle().fill(Tokens.accent.opacity(0.18)))
            VStack(alignment: .leading, spacing: Tokens.Space.row) {
                Text(title).font(.system(size: Tokens.CompactSize.rowText, weight: .semibold))
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
                Text("Seedbed").font(.system(size: Tokens.CompactSize.heading, weight: .semibold))
                Text("Version \(InfoWindows.version)")
                    .font(.system(size: Tokens.CompactSize.meta)).foregroundStyle(.secondary)
            }
            Spacer()
        }
        Text("A prompt library that keeps a short seed and generates the long, model-tailored "
             + "version of it. The app is a front end; the library itself is plain markdown in "
             + "a git repository.")
            .font(.system(size: Tokens.CompactSize.rowText))
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
            Text(label).font(.system(size: Tokens.CompactSize.meta, weight: .medium))
                .foregroundStyle(.secondary).frame(width: 78, alignment: .leading)
            Text(value).font(.system(size: Tokens.CompactSize.meta)).textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
