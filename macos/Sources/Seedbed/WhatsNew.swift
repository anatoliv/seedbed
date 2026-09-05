import SwiftUI

/// One line item in a release's notes.
struct WhatsNewChange: Identifiable {
    enum Kind {
        case added, improved, fixed

        var label: String {
            switch self {
            case .added:    return "New"
            case .improved: return "Improved"
            case .fixed:    return "Fixed"
            }
        }

        /// The fill behind the label, drawn at 14%.
        var tint: Color {
            switch self {
            case .added:    return Tokens.positive
            case .improved: return Tokens.accent
            // The undarkened amber: this is a fill, which is what it is for.
            case .fixed:    return Tokens.brandWarning
            }
        }

        /// The label itself. Not `tint`, because the colour is already carrying
        /// the meaning through the fill and repeating it in the ink cost every
        /// one of these badges its 4.5:1 text contrast.
        var ink: Color {
            switch self {
            case .added:    return Tokens.OnTint.positive
            case .improved: return Tokens.OnTint.accent
            case .fixed:    return Tokens.OnTint.warning
            }
        }
    }

    let id = UUID()
    let kind: Kind
    let text: String
}

/// What changed in one version.
///
/// The notes are written here rather than derived from the changelog or from
/// commit subjects. A release note is for a person who wants to know what is
/// different about the app they just rebuilt; a commit subject is for whoever
/// is reading the diff, and the two are not the same document.
struct WhatsNewRelease: Identifiable {
    let version: String
    let date: String
    let highlight: String
    let changes: [WhatsNewChange]
    var id: String { version }

    static let all: [WhatsNewRelease] = [
        WhatsNewRelease(
            version: "0.1.0",
            date: "5 September 2026",
            highlight: "Agents can now ask the library for a prompt, and every prompt "
                + "carries its actions on its own row.",
            changes: [
                WhatsNewChange(kind: .added,
                               text: "An MCP server, so Claude Code, Cursor or Claude Desktop "
                                   + "can search this library and read a prompt without you "
                                   + "copying one out. Turn it on in Settings, under MCP."),
                WhatsNewChange(kind: .added,
                               text: "Semantic ask: describe what you need in your own words "
                                   + "and the right prompt comes back, even when the wording "
                                   + "shares nothing with its title. The command line has it "
                                   + "too, as promptlib match."),
                WhatsNewChange(kind: .added,
                               text: "A read-only access token that can look prompts up but "
                                   + "can never rebuild one, so a client you do not fully "
                                   + "trust cannot spend an LLM call."),
                WhatsNewChange(kind: .added,
                               text: "Hovering a prompt reveals its actions on the row: copy, "
                                   + "paste into the app you came from, rebuild, edit, pin and "
                                   + "delete. They act on the row under the pointer, not on "
                                   + "whatever happens to be selected."),
                WhatsNewChange(kind: .added,
                               text: "⌘E opens the selected prompt in the library window, and "
                                   + "⌘⌫ deletes it after showing you how many renders that "
                                   + "throws away."),
                WhatsNewChange(kind: .improved,
                               text: "The library window's sidebar rows carry the same actions, "
                                   + "minus the two that cannot mean anything there."),
            ]),
    ]
}

/// Decides whether this launch should point out what changed.
///
/// Deliberately small, and separate from anything that presents: it records what
/// the user has already seen and answers one question, so the policy can be
/// reasoned about without a window.
///
/// A sibling app learned this the expensive way. Its What's New was pull-only — a
/// sidebar row and a deep link — so ten releases shipped across two days with no
/// announcement at all. The panel built to announce changes was the one place
/// the changes never reached anyone.
enum WhatsNewAnnouncer {
    static let lastSeenKey = "WhatsNewLastSeenVersion"

    /// True when `current` is newer than what the user has seen AND there are
    /// notes to show for it.
    ///
    /// A fresh install answers false: someone opening Seedbed for the first time
    /// wants Getting Started, not a changelog for software they have never run.
    /// That first launch simply records where they came in.
    static func shouldAnnounce(current: String, lastSeen: String?, hasNotes: Bool) -> Bool {
        guard hasNotes else { return false }
        guard let lastSeen, !lastSeen.isEmpty else { return false }
        return compare(current, lastSeen) == .orderedDescending
    }

    /// Numeric per component, so 0.1.9 sorts below 0.1.10 — a plain string
    /// compare gets that backwards, and every version series passes through it.
    static func compare(_ lhs: String, _ rhs: String) -> ComparisonResult {
        let left = lhs.split(separator: ".").map { Int($0) ?? 0 }
        let right = rhs.split(separator: ".").map { Int($0) ?? 0 }
        for index in 0 ..< max(left.count, right.count) {
            let l = index < left.count ? left[index] : 0
            let r = index < right.count ? right[index] : 0
            if l != r { return l < r ? .orderedAscending : .orderedDescending }
        }
        return .orderedSame
    }

    static var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
    }

    static func lastSeenVersion(_ defaults: UserDefaults = .standard) -> String? {
        defaults.string(forKey: lastSeenKey)
    }

    /// Called after the notes have been shown, and on a first launch to
    /// establish the baseline.
    static func markSeen(_ version: String, _ defaults: UserDefaults = .standard) {
        defaults.set(version, forKey: lastSeenKey)
    }

    /// The whole decision, for the app to call once at launch. Returns true when
    /// the notes should be put on screen; either way the baseline is recorded,
    /// so a version is announced at most once.
    static func consume(_ defaults: UserDefaults = .standard) -> Bool {
        let current = currentVersion
        guard !current.isEmpty else { return false }
        let announce = shouldAnnounce(
            current: current,
            lastSeen: lastSeenVersion(defaults),
            hasNotes: WhatsNewRelease.all.contains { $0.version == current })
        markSeen(current, defaults)
        return announce
    }
}

struct WhatsNewPage: View {
    var body: some View {
        ForEach(WhatsNewRelease.all) { release in
            VStack(alignment: .leading, spacing: Tokens.Space.group) {
                HStack(spacing: 7) {
                    Text(release.version)
                        .font(.system(size: Tokens.CompactSize.rowTitle, weight: .semibold))
                    Text(release.date)
                        .font(.system(size: Tokens.CompactSize.label))
                        .foregroundStyle(.secondary)
                }
                Text(release.highlight)
                    .font(.system(size: Tokens.CompactSize.rowText))
                    .fixedSize(horizontal: false, vertical: true)
                VStack(alignment: .leading, spacing: Tokens.Space.group) {
                    ForEach(release.changes) { change in
                        DefinitionRow(detail: change.text) {
                            Text(change.kind.label)
                                .font(.system(size: Tokens.CompactSize.badge, weight: .medium))
                                .foregroundStyle(change.kind.ink)
                                .padding(.horizontal, 5).padding(.vertical, 2)
                                .background(RoundedRectangle(cornerRadius: Tokens.Radius.chip)
                                    .fill(change.kind.tint.opacity(0.14)))
                                .frame(width: 62, alignment: .leading)
                        }
                    }
                }
            }
        }
    }
}
