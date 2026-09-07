import AppKit
import SwiftUI

/// Seedbed's rendering of the Reference design language.
///
/// The source vocabulary is Reference's `Theme/Tokens.swift`: warm paper and
/// graphite canvases, restrained terracotta, crisp geometry, dense spacing,
/// typography-led hierarchy, and shadows only for surfaces that truly float.
/// Product-specific window dimensions live here too, but the shared token
/// groups intentionally use Reference's names and values without translation.
enum Tokens {
    // MARK: Colors

    /// Primary accent — selection, active controls, pins. A WCAG-AA-safe
    /// rendering of the brand terracotta (~#C7693D): safe for small fills,
    /// strokes and text chips.
    static let accent = Color(red: 0.78, green: 0.41, blue: 0.24)

    /// Pure brand terracotta (#F26B3A) — large fills and brand moments only,
    /// never small text or strokes (fails AA there).
    static let brandAccent = Color(red: 0.949, green: 0.420, blue: 0.227)

    /// Speaker/system counter-accent. Seedbed uses it for secondary model
    /// activity where terracotta would be confused with the primary action.
    static let secondaryAccent = Surface.dynamic(light: 0x4E_8F_DA, dark: 0x5C_A8_FF)

    /// AI/enhancement accent.
    static let aiAccent = Surface.dynamic(light: 0xAD_74_D8, dark: 0xB8_7C_E6)

    /// Muted positive (moss/sage) — success that should not shout.
    static let positive = Color(red: 0.40, green: 0.56, blue: 0.36)

    /// Warning is amber-gold rather than orange so it cannot be confused with
    /// terracotta. Dark mode needs the brighter half of the pair.
    static let warning = Surface.dynamic(light: 0x96_74_1B, dark: 0xE0_A8_4A)

    /// Errors and destructive state. Buttons with `role: .destructive` remain
    /// native; this is for glyphs, text, and strokes Seedbed draws itself.
    static let danger = Surface.dynamic(light: 0xA0_2F_3A, dark: 0xE8_62_6E)

    /// Starred/favourite state and search-hit wash.
    static let star = Surface.dynamic(light: 0xC8_92_0A, dark: 0xF0_C0_4A)
    static let searchHighlight = Surface.dynamic(light: 0xF5_E0_8A, dark: 0x6B_5A_1E)

    enum Fill {
        static let selected = Color.promptAccent.opacity(0.16)
        static let active = Color.promptAccent.opacity(0.10)
        static let dropTarget = Color.promptAccent.opacity(0.22)
        static let selectedBorder = Color.promptAccent.opacity(0.55)
    }

    enum Surface {
        static let canvas = dynamic(light: 0xF7_F5_F3, dark: 0x0D_0E_11)
        static let card = dynamic(light: 0xFC_FB_FA, dark: 0x1C_1C_20)
        static let raised = dynamic(light: 0xFF_FF_FF, dark: 0x2C_2C_31)
        static let sunken = dynamic(light: 0xEF_ED_E8, dark: 0x08_08_0A)
        static let rowAlternate = dynamic(light: 0xF0_EE_E9, dark: 0x14_15_1A)
        static let chrome = dynamic(light: 0xF1_EF_EA, dark: 0x17_17_1B)
        static let hairline = dynamic(light: 0xE2_DE_D8, dark: 0x33_33_39)

        static func dynamic(light: UInt32, dark: UInt32) -> Color {
            Color(nsColor: NSColor(name: nil) { appearance in
                let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
                return nsColor(isDark ? dark : light)
            })
        }

        static func nsColor(_ hex: UInt32) -> NSColor {
            NSColor(
                srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
                green: CGFloat((hex >> 8) & 0xFF) / 255,
                blue: CGFloat(hex & 0xFF) / 255,
                alpha: 1
            )
        }
    }

    static let searchInputBackground = Color(nsColor: .quaternaryLabelColor).opacity(0.4)
    static let searchInputBorder = Color(nsColor: .separatorColor).opacity(0.9)

    enum Space {
        static let row: CGFloat = 4
        static let row6: CGFloat = 6
        static let tight: CGFloat = 8
        static let medium: CGFloat = 10
        static let snug: CGFloat = 12
        static let element: CGFloat = 14
        static let regular: CGFloat = 16
        static let wide: CGFloat = 24
        static let pane: CGFloat = 32
        static let hero: CGFloat = 48
        static let scene: CGFloat = 64
    }

    enum ChipPadding {
        static let h: CGFloat = 6
        static let v: CGFloat = 2
    }

    enum Radius {
        static let chip: CGFloat = 3
        static let control: CGFloat = 4
        static let card: CGFloat = 6
        static let sheet: CGFloat = 8
    }

    enum Elevation {
        static let panel = (color: Color.black.opacity(0.25), radius: 18.0, y: 6.0)
        static let popover = (color: Color.black.opacity(0.16), radius: 9.0, y: 3.0)
    }

    enum IconSize {
        static let mini: CGFloat = 8
        static let tiny: CGFloat = 9
        static let small: CGFloat = 11
        static let compact: CGFloat = 12
        static let medium: CGFloat = 13
        static let regular: CGFloat = 14
        static let large: CGFloat = 16
        static let xlarge: CGFloat = 22
        static let hero: CGFloat = 32
    }

    enum FontScale {
        static let display: Font = rounded(size: 32, weight: .semibold)
        static let title: Font = sans(size: 21, weight: .semibold)
        static let sectionHeader: Font = sans(size: 18, weight: .semibold)
        static let subtitle: Font = sans(size: 16)
        static let transcript: Font = sans(size: 15)
        static let transcriptStrong: Font = sans(size: 15, weight: .medium)
        static let label: Font = sans(size: 14)
        static let body: Font = sans(size: 13)
        static let small: Font = sans(size: 12)
        static let tiny: Font = sans(size: 11)
        static let micro: Font = sans(size: 10)
        static let nano: Font = sans(size: 9)
        static let monoSmall: Font = mono(size: 12)
        static let monoTiny: Font = mono(size: 11)

        private static func sans(size: CGFloat, weight: Font.Weight = .regular) -> Font {
            .system(size: size, weight: weight, design: .default)
        }

        private static func mono(size: CGFloat) -> Font {
            .system(size: size, design: .monospaced)
        }

        static func rounded(size: CGFloat, weight: Font.Weight = .regular) -> Font {
            .system(size: size, weight: weight, design: .rounded)
        }

        enum Rounded {
            static let nano: Font = rounded(size: 9, weight: .semibold)
            static let small: Font = rounded(size: 12, weight: .semibold)
            static let numeral: Font = rounded(size: 24, weight: .bold)
        }
    }

    enum Motion {
        static let micro: Double = 0.16
        static let pane: Double = 0.20
        static let shell: Double = 0.24
        static let microCurve: Animation = .easeOut(duration: micro)
        static let paneCurve: Animation = .easeOut(duration: pane)
        static let shellCurve: Animation = .spring(response: shell, dampingFraction: 0.86)
        static let stepCurve: Animation = .spring(response: 0.34, dampingFraction: 0.85)
        static let pulse: Double = 0.9
        static let shimmer: Double = 1.3
        static let pulseCurve: Animation = .easeInOut(duration: pulse)
            .repeatForever(autoreverses: true)
        static let reducedCurve: Animation = .easeInOut(duration: micro)
    }
}

extension Color {
    /// Terse alias for the most-used token.
    static var promptAccent: Color { Tokens.accent }
}

/// An opaque hairline that keeps the same colour across every surface.
struct SeedbedDivider: View {
    var body: some View {
        Divider().overlay(Tokens.Surface.hairline)
    }
}

/// Reference's canonical card recipe, named for this app at the call site.
struct SeedbedCard: ViewModifier {
    enum Elevation {
        case flat
        case raised

        var fill: Color {
            switch self {
            case .flat: Tokens.Surface.card
            case .raised: Tokens.Surface.raised
            }
        }
    }

    var elevation: Elevation = .flat
    var padding: CGFloat = Tokens.Space.snug
    var radius: CGFloat = Tokens.Radius.sheet

    func body(content: Content) -> some View {
        content
            .padding(padding)
            .background(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .fill(elevation.fill)
            )
            .overlay(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .strokeBorder(Tokens.Surface.hairline, lineWidth: 0.5)
            )
    }
}

struct SeedbedChip: ViewModifier {
    var tint: Color?
    var fillOpacity: Double = 0.14

    func body(content: Content) -> some View {
        content
            .font(Tokens.FontScale.micro.weight(.medium))
            .foregroundStyle(tint ?? Color.secondary)
            .padding(.horizontal, Tokens.ChipPadding.h)
            .padding(.vertical, Tokens.ChipPadding.v)
            .background(
                Capsule(style: .continuous)
                    .fill((tint ?? Color.secondary).opacity(tint == nil ? 0.12 : fillOpacity))
            )
            .fixedSize()
    }
}

extension View {
    func seedbedCard(
        _ elevation: SeedbedCard.Elevation = .flat,
        padding: CGFloat = Tokens.Space.snug,
        radius: CGFloat = Tokens.Radius.sheet
    ) -> some View {
        modifier(SeedbedCard(elevation: elevation, padding: padding, radius: radius))
    }

    func seedbedChip(tint: Color? = nil, fillOpacity: Double = 0.14) -> some View {
        modifier(SeedbedChip(tint: tint, fillOpacity: fillOpacity))
    }

    func seedbedProminent(_ tint: Color = Tokens.accent) -> some View {
        buttonStyle(.borderedProminent).tint(tint)
    }

    func seedbedCanvas() -> some View {
        background(Tokens.Surface.canvas)
    }

    func seedbedChrome() -> some View {
        background(Tokens.Surface.chrome)
    }
}

// MARK: - Space and structure
//
// Added after the app grew from one panel to eight surfaces in a week and each
// new one picked its own numbers: nine different content paddings and seven
// different window widths, none of them decisions anybody made. Colour, radius
// and type were in one place from the start and never drifted, which is the
// argument for putting these here too.

extension Tokens {
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
        /// `sidebar` (244) is the reading-navigation width. A library row is a
        /// title over a metadata line, with
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
        /// A sidebar plus one reading column. The 860x640 product canvas stays
        /// Seedbed-specific while its typography, surfaces and controls use the
        /// shared Reference system.
        static var info: CGSize { CGSize(width: Width.paged, height: 640) }
        /// How small those windows may be dragged.
        ///
        /// A minimum equal to the opening size is not a minimum — it is a fixed
        /// window wearing a resize cursor. Seedbed opens Help at 860x640 and
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
    case compact
    case reading

    // Reference uses one named scale across dense and reading surfaces. Keeping
    // this environment value avoids churn in the window hosts while ensuring
    // both cases resolve to the same typography roles.
    var heading: Font { Tokens.FontScale.sectionHeader }
    var body: Font    { Tokens.FontScale.body }
    var meta: Font    { Tokens.FontScale.small }
    var label: Font   { Tokens.FontScale.tiny }
    var code: Font    { Tokens.FontScale.monoTiny }
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
/// Uses Reference's fixed page-header recipe, which is the piece Seedbed's manual
/// was missing rather than doing differently. Without it a page opens
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
    let subtitle: String
    @ViewBuilder let content: Content

    init(title: String, symbol: String, badge: String, subtitle: String,
         @ViewBuilder content: () -> Content) {
        self.title = title
        self.symbol = symbol
        self.badge = badge
        self.subtitle = subtitle
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: Tokens.Space.row6) {
                HStack(spacing: Tokens.Space.tight) {
                    Image(systemName: symbol)
                        .font(.system(size: Tokens.IconSize.xlarge, weight: .medium))
                        .foregroundStyle(Tokens.accent)
                    Text(title)
                        .font(Tokens.FontScale.title)
                        .foregroundStyle(.primary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: Tokens.Space.tight)
                    Text(badge.uppercased())
                        .tracking(0.5)
                        .seedbedChip()
                }
                Text(subtitle)
                    .font(Tokens.FontScale.small)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, Tokens.Space.regular)
            .padding(.vertical, Tokens.Space.medium)
            SeedbedDivider()
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
            .font(scale.heading)
            .foregroundStyle(Tokens.accent)
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
        VStack(alignment: .leading, spacing: Tokens.Space.medium) {
            Text(title.uppercased())
                .font(scale.label.weight(.semibold))
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
            .font(scale.meta)
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
        HStack(alignment: .top, spacing: Tokens.Space.tight) {
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
            Text(term).font(scale.body.weight(.semibold))
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            Text(detail)
                .font(scale.body)
                .lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// A key cap, as the Help window draws one.
struct KeyCap: View {
    @Environment(\.textScale) private var scale
    static let defaultWidth: CGFloat = 74
    let key: String
    var width: CGFloat = Self.defaultWidth

    var body: some View {
        Text(key)
            .font(Tokens.FontScale.monoTiny)
            .padding(.horizontal, Tokens.ChipPadding.h)
            .padding(.vertical, Tokens.ChipPadding.v)
            .background(RoundedRectangle(cornerRadius: Tokens.Radius.control)
                .fill(Tokens.Surface.sunken))
            .overlay(RoundedRectangle(cornerRadius: Tokens.Radius.control)
                .stroke(Tokens.Surface.hairline, lineWidth: 0.5))
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
                .font(scale.code)
                .textSelection(.enabled)
                .fixedSize(horizontal: true, vertical: true)
                .padding(.horizontal, Tokens.Space.tight)
                .padding(.vertical, Tokens.Space.tight)
        }
        .background(RoundedRectangle(cornerRadius: Tokens.Radius.control)
            .fill(Tokens.Surface.sunken))
        .overlay(RoundedRectangle(cornerRadius: Tokens.Radius.control)
            .stroke(Tokens.Surface.hairline, lineWidth: 0.5))
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
                    .padding(.leading, topic.key == nil ? 0 : KeyCap.defaultWidth + Tokens.Space.tight)
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
            .padding(.vertical, Tokens.Space.medium)
            .background(Tokens.Surface.chrome)
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
                .font(scale.label.weight(.medium))
                .foregroundStyle(.secondary)
            content
        }
    }
}
