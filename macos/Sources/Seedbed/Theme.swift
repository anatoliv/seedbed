import AppKit
import SwiftUI

/// The same design language as Reference, so the two apps read as siblings.
///
/// Ported from `Reference/Sources/Reference/Theme.swift` rather than
/// re-invented: the terracotta accent, the crisp radius scale and the compact
/// type sizes are what make that app recognisable, and a second tool on the same
/// machine should not look like it came from somewhere else.
enum Tokens {
    // MARK: Colors

    /// Primary accent — selection, active controls, pins. A WCAG-AA-safe
    /// rendering of the brand terracotta (~#C7693D): safe for small fills,
    /// strokes and text chips.
    static let accent = Color(red: 0.78, green: 0.41, blue: 0.24)

    /// Pure brand terracotta (#F26B3A) — large fills and brand moments only,
    /// never small text or strokes (fails AA there).
    static let brandAccent = Color(red: 0.949, green: 0.420, blue: 0.227)

    /// Muted positive (moss/sage) — success that shouldn't shout: a current
    /// render, a copy that worked.
    static let positive = Color(red: 0.40, green: 0.56, blue: 0.36)

    /// Caution amber, for the things you have to be able to SEE: the stale dot,
    /// the unsaved-changes mark, the Accessibility warning triangle. **3.21:1
    /// against white**, which clears the 3:1 bar WCAG sets for a non-text
    /// component.
    ///
    /// It used to be `brandWarning` below, at 2.86:1, which does not. Seedbed
    /// took Reference's palette values but not its canvas: a sibling app measured
    /// these against warm paper and Seedbed draws them on the system ground,
    /// which is nearer white, so the inherited ratios never transferred. The
    /// icon whose entire job is to catch your eye was the one below the bar.
    /// Darkening it is the same split `accent` and `brandAccent` already are,
    /// which makes the pair a pattern rather than a one-off.
    static let warning = Color(red: 0.800, green: 0.490, blue: 0.176)

    /// The undarkened amber (#D98530), for large fills and brand moments only.
    /// Never a stroke, an icon or text: it fails the 3:1 bar on white.
    static let brandWarning = Color(red: 0.851, green: 0.522, blue: 0.188)

    // MARK: On a tint of itself
    //
    // The third rung of the same idea as `accent` / `brandAccent`. A token drawn
    // as TEXT on a 14% tint of itself loses contrast twice over: the ink is the
    // token and the paper is a lighter version of the same token. Every What's
    // New badge label did exactly that and every one of them was below the
    // 4.5:1 text bar (Improved 3.23:1, New 3.19:1, Fixed 2.50:1), at 9pt, so
    // the large-text exception did not apply either.
    //
    // These are the only adaptive colours in the palette, and they have to be.
    // A single value cannot clear 4.5:1 on both grounds: darkening for white
    // makes it worse on the dark tint, and `accent` and `positive` were failing
    // in dark mode too (3.72:1 and 3.74:1). Every ratio below was computed, not
    // eyeballed, and `tests/test_theme_contrast.py` recomputes them.

    /// Text on a 14% tint of the same colour. Both appearances clear 4.5:1.
    enum OnTint {
        /// 4.62:1 on #F7EAE4 (light), 4.62:1 on #362822 (dark).
        static let accent = adaptive(light: Color(red: 0.631, green: 0.333, blue: 0.192),
                                     dark: Color(red: 0.878, green: 0.463, blue: 0.271))
        /// 4.61:1 on #EAEFE8 (light), 4.65:1 on #282E27 (dark).
        static let positive = adaptive(light: Color(red: 0.322, green: 0.451, blue: 0.290),
                                       dark: Color(red: 0.451, green: 0.631, blue: 0.408))
        /// 4.60:1 on #FAEEE2 (light), 4.74:1 on #382C21 (dark). The dark value
        /// is the brand amber unchanged: it was already readable there.
        static let warning = adaptive(light: Color(red: 0.604, green: 0.369, blue: 0.133),
                                      dark: brandWarning)
    }

    /// A colour that follows the appearance.
    ///
    /// `Color(red:green:blue:)` is a fixed value, so a palette built from it
    /// looks correct in whichever mode it was checked in and is unchecked in the
    /// other. This is the escape hatch, used only where one value provably
    /// cannot serve both.
    static func adaptive(light: Color, dark: Color) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
                ? NSColor(dark) : NSColor(light)
        })
    }

    // MARK: Radius — crisp scale (never rounded/pill for containers)

    /// SF Symbol sizing for icon-only images — geometry, not typography.
    ///
    /// Ported wholesale from Reference. Its absence is why every icon here was
    /// sized off a font token, which works until a symbol and a letter want
    /// different sizes at the same weight, and then reads as a wrong icon rather
    /// than as a missing scale.
    enum IconSize {
        static let tiny: CGFloat = 9     // disclosure chevrons, eyebrow icons
        static let small: CGFloat = 11   // inline meta icons
        static let medium: CGFloat = 13  // standard sidebar / toolbar icon
        static let regular: CGFloat = 18 // prominent header / action icon
    }

    /// Chip and pill padding, kept in lockstep so badges do not diverge by a
    /// point across the app. Reference's values.
    enum ChipPadding {
        static let h: CGFloat = 6
        static let v: CGFloat = 2
    }

    enum Radius {
        static let chip: CGFloat = 3     // status pills, badges
        static let control: CGFloat = 4  // buttons, text fields, key caps
        static let card: CGFloat = 6     // cards, list rows
        static let sheet: CGFloat = 8    // overlays, popovers
    }

    // MARK: Type — compact scale, matching the picker's density

    /// The reading ramp, for surfaces made of prose: the manual, the FAQ, the
    /// release notes, About.
    ///
    /// **Seedbed ported Reference's `CompactSize` and then used it everywhere**,
    /// including on pages people read paragraphs from. That ramp is described in
    /// its own source as being "for the picker — the app's densest surface,
    /// which needs finer steps than the reading-oriented FontScale", and the
    /// second half of that sentence never arrived here. Put the two Help windows
    /// side by side and the difference is not subtle: 11pt body against 13.
    ///
    /// Same values as Reference's reading scale, and the same reason for CGFloat
    /// rather than `Font` — call sites keep their own `weight:` and `design:`.
    enum ReadingSize {
        static let display: CGFloat = 21  // the app's own name, in SF Rounded
        static let title: CGFloat = 20    // the page's own title, in its header
        static let heading: CGFloat = 15  // section headings over prose
        static let body: CGFloat = 13     // paragraphs, definitions
        static let meta: CGFloat = 12     // captions, secondary lines
        static let label: CGFloat = 11    // eyebrows, key caps, code
        static let badge: CGFloat = 9     // the uppercase capsule under a title
    }

    enum CompactSize {
        static let mini: CGFloat = 6
        static let tiny: CGFloat = 8
        static let badge: CGFloat = 9     // chip text, key hints
        static let label: CGFloat = 10    // section eyebrows, meta lines
        static let meta: CGFloat = 11     // secondary row text
        static let rowText: CGFloat = 12  // body-ish row text
        static let rowTitle: CGFloat = 13 // titles
        static let hero: CGFloat = 27     // empty-state glyph
    }

    // MARK: Motion — 160–240ms ease-out, one shared curve family

    enum Motion {
        /// Pointer-driven feedback: hover, selection, chip toggles.
        static let microCurve: Animation = .easeOut(duration: 0.16)
        /// In-pane reveals: overlays, toasts, fold/unfold.
        static let paneCurve: Animation = .easeOut(duration: 0.20)
    }
}

extension Color {
    /// Terse alias for the most-used token, as in Reference.
    static var promptAccent: Color { Tokens.accent }
}

// MARK: - Space and structure
//
// Added after the app grew from one panel to eight surfaces in a week and each
// new one picked its own numbers: nine different content paddings and seven
// different window widths, none of them decisions anybody made. Colour, radius
// and type were in one place from the start and never drifted, which is the
// argument for putting these here too.

extension Tokens {
    /// The spacing scale. Each value has one job, named, so choosing between
    /// them is a question about what the gap separates rather than about taste.
    enum Space {
        /// Inset from a window's edge to its content.
        ///
        /// 28, which is Reference's `Space.pane` — the padding its Help and
        /// Settings panes use. This was 20, and once the type ramps matched that
        /// 8pt was most of what still made the two windows feel unlike each
        /// other: the same words in the same size, sitting closer to the edge.
        static let page: CGFloat = 28
        /// Between two sections of a page.
        static let section: CGFloat = 16
        /// Between sibling rows inside one section.
        static let group: CGFloat = 10
        /// Between the lines of a single row: a title and its explanation.
        static let row: CGFloat = 4
        /// Between controls sitting on one line.
        static let control: CGFloat = 8
        /// Inset for a WORKING surface: a form, an editor, and the horizontal
        /// inset of a chrome bar. Tighter than `page` on purpose. The original
        /// scale was drawn for reading surfaces and had a real gap here, and
        /// forcing a settings pane to `page` would be the wrong kind of
        /// consistency. Four files had already converged on this number by
        /// accident; this names it.
        static let pane: CGFloat = 14
        /// Between fields in a form. Two of the four forms already used 12; the
        /// others used 13 and 14, which nobody decided.
        static let field: CGFloat = 12
    }

    /// Window and column widths.
    ///
    /// Two, not seven. A surface here is either something you read or something
    /// you work in, and the library window is the only genuinely different one
    /// because it holds several columns of generated text side by side.
    enum Width {
        /// A column of prose. Wide enough for a paragraph, narrow enough that a
        /// line does not tire the eye.
        static let reading: CGFloat = 616
        /// The contents list beside it.
        static let sidebar: CGFloat = 244
        /// A window that is a sidebar plus a reading column.
        static var paged: CGFloat { sidebar + reading }
        /// A sheet that asks for a few values and goes away.
        static let sheet: CGFloat = 460
        /// A list column beside an editor.
        static let list: CGFloat = 200
        /// The library window's own sidebar, and a deliberate exemption from
        /// `sidebar` above.
        ///
        /// `sidebar` (178) is right for the Info window's contents list: five
        /// short page names. A library row is a title over a metadata line, with
        /// a pin glyph indented left and, on the right, either a staleness dot
        /// or a four-button action strip (copy, rebuild, pin, delete) that
        /// appears on hover in the same space. The title is `.lineLimit(1)`, so
        /// everything that strip needs comes out of the title's width.
        ///
        /// The width at which titles begin to truncate has NOT been measured, so
        /// this rests on the shape rather than on a number. Written down as a
        /// constant so it reads as a decision rather than as a value nobody got
        /// round to converting.
        static let librarySidebar: CGFloat = 240
    }

    /// Window sizes, named rather than converged.
    ///
    /// Four genuinely different surfaces, so four numbers. They live here
    /// because four view bodies each holding one was how nobody noticed there
    /// were four. `settings` was the last to arrive and the hardest to spot,
    /// because it was a literal duplicated across TWO files that had to agree.
    enum Size {
        /// Up to four columns of generated prompt text side by side.
        static let library = CGSize(width: 900, height: 540)
        /// The floating panel, which is a list and nothing else.
        static let panel = CGSize(width: 420, height: 260)
        /// A sidebar plus one reading column. 860x640 with a 244 sidebar, which
        /// is Reference's Help window exactly.
        static var info: CGSize { CGSize(width: Width.paged, height: 640) }
        /// How small those windows may be dragged.
        ///
        /// A minimum equal to the opening size is not a minimum — it is a fixed
        /// window wearing a resize cursor. Reference opens Help at 860x640 and
        /// lets it go to 620x420, so a reader on a small screen can put it
        /// beside the thing they are reading about.
        static let infoMin = CGSize(width: 620, height: 420)
        static let settingsMin = CGSize(width: 620, height: 460)
        /// Wider than `info` because the Models pane is a two-column editor
        /// rather than prose. It was the one window size still written as a raw
        /// literal, in two files that had to agree and nothing making them.
        static let settings = CGSize(width: 820, height: 620)
    }
}

/// A section heading inside a page of prose: Help, the FAQ, release notes.
/// Which type ramp the shared components draw at.
///
/// The alternative was a reading-sized copy of `SectionHeader`, `Caption`,
/// `StackedDefinition`, `KeyCap` and `ExampleBlock`, which is how this file
/// came to say "Four files had four versions of this" about a component that
/// had been duplicated once. One component, one environment value, set on the
/// window that reads rather than on every call site inside it.
enum TextScale {
    case compact   // rows, chips, the picker: the dense surfaces
    case reading   // pages of prose: the manual, FAQ, release notes, About

    var heading: CGFloat { self == .reading ? Tokens.ReadingSize.heading : Tokens.CompactSize.rowTitle }
    var body: CGFloat    { self == .reading ? Tokens.ReadingSize.body    : Tokens.CompactSize.rowText }
    var meta: CGFloat    { self == .reading ? Tokens.ReadingSize.meta    : Tokens.CompactSize.meta }
    var label: CGFloat   { self == .reading ? Tokens.ReadingSize.label   : Tokens.CompactSize.label }
    var code: CGFloat    { self == .reading ? Tokens.ReadingSize.label   : Tokens.CompactSize.badge }
}

private struct TextScaleKey: EnvironmentKey {
    /// Compact by default: the dense surfaces are the majority, and a surface
    /// that forgets to declare itself should not silently grow.
    static let defaultValue: TextScale = .compact
}

extension EnvironmentValues {
    var textScale: TextScale {
        get { self[TextScaleKey.self] }
        set { self[TextScaleKey.self] = newValue }
    }
}

/// The top of a page in the manual: what you are reading, and what kind of thing
/// it is.
///
/// Ported from Reference's `detailScaffold`, which is the piece Seedbed's
/// manual was missing rather than doing differently. Without it a page opens
/// straight into its first sub-heading, so "Keyboard" reads as the title of the
/// window rather than as one section of Help, and nothing on screen says which
/// of the five pages you are on except the sidebar selection.
///
/// The divider matters as much as the title: it holds a fixed header above a
/// scrolling body, so the answer to "where am I" stays put while the answer to
/// "what does it say" moves.
struct PageHeader<Content: View>: View {
    let title: String
    let symbol: String
    let badge: String
    @ViewBuilder let content: Content

    init(title: String, symbol: String, badge: String,
         @ViewBuilder content: () -> Content) {
        self.title = title
        self.symbol = symbol
        self.badge = badge
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: Tokens.Space.row) {
                HStack(spacing: Tokens.Space.control) {
                    Image(systemName: symbol)
                        .font(.system(size: Tokens.IconSize.regular, weight: .medium))
                        .foregroundStyle(Tokens.accent)
                    Text(title)
                        .font(.system(size: Tokens.ReadingSize.title, weight: .semibold))
                        .fixedSize(horizontal: false, vertical: true)
                }
                Text(badge.uppercased())
                    .font(.system(size: Tokens.ReadingSize.badge, weight: .bold))
                    .tracking(0.5)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, Tokens.ChipPadding.h)
                    .padding(.vertical, Tokens.ChipPadding.v + 1)
                    .background(Color.secondary.opacity(0.10), in: Capsule())
            }
            .padding(.horizontal, Tokens.Space.page)
            .padding(.top, Tokens.Space.page)
            .padding(.bottom, Tokens.Space.section - 4)
            Divider()
            content
        }
    }
}

struct SectionHeader: View {
    @Environment(\.textScale) private var scale
    let title: String
    init(_ title: String) { self.title = title }

    var body: some View {
        Text(title)
            .font(.system(size: scale.heading, weight: .semibold))
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// A group of controls in a settings pane, under a quiet eyebrow.
///
/// Deliberately a different shape from `SectionHeader`: a settings group is a
/// label on a box of controls, and a page section is a heading over prose. They
/// looked the same in three files while meaning different things.
struct SettingsGroup<Content: View>: View {
    @Environment(\.textScale) private var scale
    let title: String
    @ViewBuilder let content: Content

    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Tokens.Space.group) {
            Text(title.uppercased())
                .font(.system(size: scale.label, weight: .semibold))
                .foregroundStyle(.secondary)
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Secondary explanation under a control or a heading. Always wraps: the reason
/// these lines exist is that they say something a label could not fit, so a
/// truncated one is worse than none.
struct Caption: View {
    @Environment(\.textScale) private var scale
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(.system(size: scale.meta))
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// A term and what it means: a keyboard shortcut, an FAQ question, a glossary
/// entry, a line of release notes. Four files had four versions of this.
struct DefinitionRow<Leading: View>: View {
    let detail: String
    @ViewBuilder let leading: Leading

    var body: some View {
        HStack(alignment: .top, spacing: Tokens.Space.control) {
            leading
            Caption(detail)
        }
    }
}

/// The stacked form of the same thing: a bold term with its explanation below,
/// which is what reads better when the term is a sentence rather than a key.
struct StackedDefinition: View {
    @Environment(\.textScale) private var scale
    let term: String
    let detail: String

    var body: some View {
        VStack(alignment: .leading, spacing: Tokens.Space.row) {
            Text(term).font(.system(size: scale.body, weight: .semibold))
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            Caption(detail)
        }
    }
}

/// A key cap, as the Help window draws one.
struct KeyCap: View {
    @Environment(\.textScale) private var scale
    let key: String
    var width: CGFloat = 74

    var body: some View {
        Text(key)
            .font(.system(size: scale.label, design: .monospaced))
            .padding(.horizontal, 5).padding(.vertical, 2)
            .background(RoundedRectangle(cornerRadius: Tokens.Radius.control)
                .fill(Color.secondary.opacity(0.15)))
            .frame(width: width, alignment: .leading)
    }
}

/// A real artifact quoted inside a page of prose: a command, a snippet of
/// configuration, an error string the app actually prints.
///
/// Monospaced and set apart, because the whole point of quoting one is that the
/// reader can tell it apart from the sentence explaining it. Scrolls sideways
/// rather than wrapping: a wrapped command line is a command line you cannot
/// copy correctly.
struct ExampleBlock: View {
    @Environment(\.textScale) private var scale
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            Text(text)
                .font(.system(size: scale.code, design: .monospaced))
                .textSelection(.enabled)
                .fixedSize(horizontal: true, vertical: true)
                .padding(.horizontal, Tokens.Space.control)
                .padding(.vertical, Tokens.Space.group - 3)
        }
        .background(RoundedRectangle(cornerRadius: Tokens.Radius.control)
            .fill(Color.secondary.opacity(0.09)))
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// One manual entry as it draws on a page: the term, what it means, and the
/// artifact if there is one.
struct ManualTopicView: View {
    let topic: ManualTopic

    var body: some View {
        VStack(alignment: .leading, spacing: Tokens.Space.row) {
            if let key = topic.key {
                DefinitionRow(detail: topic.detail) { KeyCap(key: key) }
            } else {
                StackedDefinition(term: topic.term, detail: topic.detail)
            }
            if let example = topic.example {
                ExampleBlock(example)
                    .padding(.top, Tokens.Space.row)
                    .padding(.leading, topic.key == nil ? 0 : 74 + Tokens.Space.control)
            }
        }
    }
}


/// The inset of a chrome bar: a header or footer strip that frames a working
/// surface.
///
/// Ten sites across five files did this with the same horizontal inset and
/// **five different vertical ones** (7, 8, 9, 10, 11). Not one of those five was
/// a decision anybody made, and there is no version of the app where the
/// difference between a 7pt and an 11pt footer means something. One modifier so
/// it stays one decision.
extension View {
    func chromeBar() -> some View {
        padding(.horizontal, Tokens.Space.pane)
            .padding(.vertical, Tokens.Space.group)
    }
}


/// A label over the one control it names.
///
/// `ModelsEditor` and `EnhancerEditor` each carried a private `field()` helper
/// with the same body, written twice before `Theme.swift` had a home for it.
///
/// Deliberately NOT `SettingsGroup`, which looked close enough to merge and is
/// not: that is an uppercased eyebrow over a BOX of controls, and this is a
/// sentence-case label over ONE. Merging them would have made every form field
/// shout.
struct FormField<Content: View>: View {
    @Environment(\.textScale) private var scale
    let label: String
    @ViewBuilder let content: Content

    init(_ label: String, @ViewBuilder content: () -> Content) {
        self.label = label
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Tokens.Space.row) {
            Text(label)
                .font(.system(size: scale.label, weight: .medium))
                .foregroundStyle(.secondary)
            content
        }
    }
}
