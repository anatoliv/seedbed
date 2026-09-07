import SwiftUI

/// Lexical ranking for the manual, ported from `promptlib/match.py`.
///
/// **Why this is a second implementation rather than a call into promptlib**,
/// which is the thing this search was asked to avoid, and it is worth stating
/// plainly because that instinct was right in general.
///
/// 1. **Help has to work when Python does not.** `LibraryClient` resolves an
///    interpreter by probing for `tomllib`, and `LibraryError.noPython` is a
///    state this app really reaches: an app launched from Finder inherits a
///    minimal PATH, which on a Mac with Xcode installed resolves `python3` to a
///    3.9. That is defect 4 in the learning log, and it is also an entry in
///    Help called "Nothing loads at all". A search box that goes dark in exactly
///    the situation that sends someone to Help is the wrong trade.
/// 2. **Per keystroke, a subprocess is the wrong shape.** A warm
///    `python3 -m promptlib match` costs about 60ms of process spawn and import
///    before it scores anything, over a corpus of 56 static topics compiled into
///    this binary. There is nothing to load and nothing to keep in sync.
///
/// **What keeps the two from drifting**, since duplication without a guard is
/// how this goes wrong: `tests/test_manual_search_parity.py` reads this file and
/// `promptlib/match.py` and fails if the shared constants stop agreeing. The
/// names below are deliberately the same as the Python ones so that test can
/// find them, and so a reader of either file recognises the other.
///
/// The semantic pass is deliberately **not** ported. See `ManualSearch.decision`.
enum ManualSearch {
    /// Below this a hit is noise: an ask sharing one common word with a body.
    /// Same value as `match.FLOOR_SCORE`.
    static let FLOOR_SCORE = 0.08

    /// Same weights as `match.FIELD_WEIGHTS`, for the three fields a manual
    /// topic has. A topic's term is its title, its section is its category, and
    /// its prose plus any worked example is its body.
    static let FIELD_WEIGHTS: [String: Double] = [
        "title": 3.0,
        "category": 1.5,
        "body": 1.0,
    ]

    /// Same set as `match.STOPWORDS`.
    static let STOPWORDS: Set<String> = [
        "a", "about", "an", "and", "any", "anything", "are", "as", "at", "be", "by",
        "can", "do", "find", "for", "from", "get", "give", "have", "help", "i", "in",
        "is", "it", "like", "looking", "me", "my", "need", "of", "on", "one", "or",
        "please", "prompt", "prompts", "seed", "should", "some", "something", "that",
        "the", "then", "there", "this", "to", "use", "using", "want", "was", "what",
        "which", "with", "would", "you", "your",
    ]

    /// A hit below this fraction of the best hit is dropped from the list the
    /// window shows.
    ///
    /// Not a parity constant, and deliberately not applied inside `rank`. The
    /// Python matcher's caller is an agent that wants the alternatives; a person
    /// reading a result list wants the answer and is made less confident by six
    /// weak rows under it. Measured on real asks: "why does enter not paste"
    /// returned 8 hits of which 2 were relevant, and this cuts it to 3. "token"
    /// goes from 11 to the 4 topics that are actually about tokens.
    static let RELATIVE_CUTOFF = 0.4

    /// The decision this search was asked to record, kept next to the code it
    /// is about: **lexical only, no semantic fallback, for the manual.**
    ///
    /// Over 56 topics the lexical pass has an answer for every ask I could
    /// think of, and a search box that is instant on every keystroke is worth
    /// more than one that is occasionally cleverer and sometimes takes a second.
    /// The semantic layer stays where it earns its cost: `find_prompt`, where
    /// the corpus is the user's own prose, the wording overlap is genuinely
    /// poor, and the caller is an agent that can wait.
    static let decision = "lexical only"

    // MARK: - Scoring

    /// Lowercase; anything that is not a letter or a digit becomes a space.
    static func normalise(_ text: String) -> String {
        var words: [String] = []
        var current = ""
        for character in text.lowercased() {
            if character.isLetter || character.isNumber {
                current.append(character)
            } else if !current.isEmpty {
                words.append(current)
                current = ""
            }
        }
        if !current.isEmpty { words.append(current) }
        return words.joined(separator: " ")
    }

    static func tokens(_ text: String, dropStopwords: Bool = true) -> Set<String> {
        let words = normalise(text).split(separator: " ").map(String.init)
        if !dropStopwords { return Set(words) }
        let kept = Set(words.filter { !STOPWORDS.contains($0) })
        // An ask made entirely of stopwords still has to match something rather
        // than everything, so keep the words instead of nothing.
        return kept.isEmpty ? Set(words) : kept
    }

    /// Character trigrams of the normalised text, padded so short strings match.
    static func trigrams(_ text: String) -> Set<String> {
        let padded = Array("  \(normalise(text))  ")
        guard padded.count >= 3 else { return [] }
        var result: Set<String> = []
        for index in 0...(padded.count - 3) {
            result.insert(String(padded[index..<(index + 3)]))
        }
        return result
    }

    static func dice(_ a: Set<String>, _ b: Set<String>) -> Double {
        if a.isEmpty || b.isEmpty { return 0 }
        return 2 * Double(a.intersection(b).count) / Double(a.count + b.count)
    }

    /// How well one field answers the ask, in 0...1.
    ///
    /// Two signals, because each fails where the other works. Token overlap says
    /// "these are the same words" and is blind to a typo or a plural. Trigram
    /// similarity survives both and is blind to word order.
    static func fieldScore(ask: String, askTokens: Set<String>,
                           askTrigrams: Set<String>, value: String) -> Double {
        let normalised = normalise(value)
        if normalised.isEmpty { return 0 }
        if normalised == normalise(ask) { return 1 }
        let overlap = askTokens.isEmpty
            ? 0
            : Double(askTokens.intersection(tokens(value)).count) / Double(askTokens.count)
        return 0.6 * overlap + 0.4 * dice(askTrigrams, trigrams(value))
    }

    /// One topic with the evidence for it.
    struct Hit: Identifiable {
        let topic: ManualTopic
        let score: Double
        /// The field that contributed most, so a result can say what matched.
        let matchedOn: String
        var id: String { topic.id }
    }

    /// Every topic scored against the ask, best first, noise dropped.
    static func rank(_ ask: String, in topics: [ManualTopic] = Manual.topics) -> [Hit] {
        let trimmed = ask.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        let askTokens = tokens(trimmed)
        let askTrigrams = trigrams(trimmed)
        let weightTotal = FIELD_WEIGHTS.values.reduce(0, +)

        var hits: [Hit] = []
        for topic in topics {
            let values = [
                "title": topic.term,
                "category": topic.section,
                "body": [topic.detail, topic.example ?? ""].joined(separator: "\n"),
            ]
            var fields: [String: Double] = [:]
            for (name, value) in values {
                fields[name] = fieldScore(ask: trimmed, askTokens: askTokens,
                                          askTrigrams: askTrigrams, value: value)
            }
            let total = fields.reduce(0.0) { $0 + FIELD_WEIGHTS[$1.key]! * $1.value }
            let score = total / weightTotal
            guard score >= FLOOR_SCORE else { continue }
            let best = fields.max { lhs, rhs in
                lhs.value == rhs.value ? lhs.key > rhs.key : lhs.value < rhs.value
            }
            hits.append(Hit(topic: topic, score: score, matchedOn: best?.key ?? ""))
        }
        // Ties break on id so the order is stable between runs.
        hits.sort { $0.score == $1.score ? $0.topic.id < $1.topic.id : $0.score > $1.score }
        return hits
    }
}

extension ManualSearch {
    /// What the window shows: the ranking, with the tail of weak hits cut.
    static func results(for ask: String, in topics: [ManualTopic] = Manual.topics) -> [Hit] {
        let hits = rank(ask, in: topics)
        guard let best = hits.first else { return [] }
        return hits.filter { $0.score >= best.score * RELATIVE_CUTOFF }
    }
}

// MARK: - The field and the results

/// The search field at the top of the Info window.
///
/// Not `.searchable`, for the reason a sibling app's help view gives: it wants a
/// navigation container this window does not have. A plain `TextField` in a
/// styled capsule behaves the same and does not drag a `NavigationSplitView` in
/// behind it.
struct ManualSearchField: View {
    @Binding var query: String
    /// Set only while a PAGE is showing over a live query, so the field can say
    /// the search is still there. Nil while the results themselves are showing,
    /// where a count would just restate what is on screen.
    var resultCount: Int?
    var onReturnToResults: () -> Void = {}

    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: Tokens.Space.row6) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            // Short enough for the sidebar it now lives in. "Search Help and the
            // FAQ" fit the 560pt reading column and truncates to "Search Help
            // and the" at 178pt, which reads as a bug in the field rather than
            // as a label that is too long. Reference uses "Search Help & FAQ" for
            // the same reason.
            TextField("Search Help & FAQ", text: $query)
                .textFieldStyle(.plain)
                .font(Tokens.FontScale.body)
                .focused($focused)
                // Return goes back to the results rather than only dropping
                // focus: it is the obvious way back once you have read the hit
                // you opened.
                .onSubmit { focused = false; onReturnToResults() }
            if let count = resultCount {
                Button {
                    onReturnToResults()
                } label: {
                    Text(count == 1 ? "1 result" : "\(count) results")
                        .seedbedChip(tint: Tokens.accent)
                }
                .buttonStyle(.plain)
                .help("Back to the results for this search")
            }
            if !query.isEmpty {
                Button {
                    query = ""
                    focused = true
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Clear the search")
                // Escape is how a Mac user clears a search field, and the panel
                // is not on screen to steal it here.
                .keyboardShortcut(.cancelAction)
            }
        }
        .padding(.horizontal, Tokens.Space.tight)
        .padding(.vertical, Tokens.Space.row6)
        .background(
            RoundedRectangle(cornerRadius: Tokens.Radius.control)
                .fill(Tokens.searchInputBackground)
        )
        .overlay(
            RoundedRectangle(cornerRadius: Tokens.Radius.control)
                .stroke(Tokens.searchInputBorder, lineWidth: 0.5)
        )
    }
}

/// What the reading column shows while the search field has something in it.
struct ManualSearchResults: View {
    let query: String
    /// Called with the page a result lives on, so a hit is one click from being
    /// read in place.
    var open: (InfoPage) -> Void

    private var hits: [ManualSearch.Hit] { ManualSearch.results(for: query) }

    var body: some View {
        if hits.isEmpty {
            VStack(alignment: .leading, spacing: Tokens.Space.medium) {
                SectionHeader("Nothing matches \"\(query)\"")
                Caption("Help covers the keys, the words this app uses, and what to do when "
                        + "something looks wrong. The FAQ covers the MCP server and the "
                        + "library itself. Try a shorter word, or open a page and read it.")
            }
        } else {
            SectionHeader(hits.count == 1 ? "1 result" : "\(hits.count) results")
            VStack(alignment: .leading, spacing: Tokens.Space.medium) {
                ForEach(hits) { hit in
                    Button { open(hit.topic.page) } label: {
                        VStack(alignment: .leading, spacing: Tokens.Space.row) {
                            HStack(spacing: Tokens.Space.row6) {
                                Image(systemName: hit.topic.page.symbol)
                                    .font(Tokens.FontScale.nano)
                                    .foregroundStyle(Tokens.accent)
                                Text("\(hit.topic.page.title) · \(hit.topic.section)")
                                    .font(Tokens.FontScale.tiny)
                                    .foregroundStyle(.secondary)
                            }
                            Text(hit.topic.term)
                                .font(Tokens.FontScale.small)
                                .fixedSize(horizontal: false, vertical: true)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            Caption(Self.snippet(hit.topic.detail))
                        }
                        .padding(.vertical, Tokens.Space.row)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    /// The first sentence or so, because a result list is for choosing between
    /// answers rather than for reading one.
    static func snippet(_ detail: String, limit: Int = 150) -> String {
        let flat = detail.split(separator: "\n").joined(separator: " ")
            .trimmingCharacters(in: .whitespaces)
        guard flat.count > limit else { return flat }
        var cut = String(flat.prefix(limit))
        if let space = cut.lastIndex(of: " ") { cut = String(cut[..<space]) }
        // "…." reads as a typo. Trailing punctuation is what the ellipsis
        // replaces, not something it follows.
        while let last = cut.last, ".,;:".contains(last) { cut.removeLast() }
        return cut + "…"
    }
}
