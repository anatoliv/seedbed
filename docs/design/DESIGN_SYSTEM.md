# Seedbed Design System

## Source of truth

**`macos/Sources/Seedbed/Theme.swift` is the source of truth.** The tables in
this document were extracted from it on **2026-09-06**. Where code and prose
disagree, the code is right and this document is stale: correct the document,
then decide explicitly whether the code should change.

The shared visual contract is the reference app's current macOS token source:
`apps/reference-mac/Sources/Reference/Theme/Tokens.swift`. Seedbed vendors a parsed
snapshot at `macos/Design/reference-tokens.json`; `tests/test_reference_parity.py`
compares every shared group token-for-token. Refresh the snapshot only after a
deliberate review with `macos/Scripts/refresh-reference-spec.sh`.

Seedbed keeps its own brand artwork and product-specific window dimensions.
Everything that determines visual family—palette, surfaces, typography,
spacing, radii, icon geometry, elevation, and motion—follows Reference.

## Visual language

- Warm paper in light mode; neutral graphite in dark mode.
- Crisp, compact geometry. Containers are not pills.
- Flat content surfaces. Shadows are reserved for objects that actually float.
- Typography carries hierarchy before boxes or decoration do.
- Terracotta is the identity accent, not a substitute for every status color.
- Motion is brief and functional, with reduced-motion fallbacks.

This is specific to a prompt library: the memorable element remains Seedbed's
sprout-and-text-bed mark, while the working UI stays quiet enough that prompt
text, model state, and keyboard actions dominate.

## Native macOS palette

All fixed RGB values are sRGB. Adaptive values resolve through
`Tokens.Surface.dynamic` so a window forced to a specific appearance still
draws correctly.

| Token | Light | Dark | Role |
|---|---|---|---|
| `accent` | `#C7693D` | same | Links, focus, selection, primary controls |
| `brandAccent` | `#F26B3A` | same | Large brand fills only |
| `secondaryAccent` | `#4E8FDA` | `#5CA8FF` | Secondary model/system activity |
| `aiAccent` | `#AD74D8` | `#B87CE6` | Enhancement and AI activity |
| `positive` | `#668F5C` | same | Success/current/running |
| `warning` | `#96741B` | `#E0A84A` | Stale, degraded, needs attention |
| `danger` | `#A02F3A` | `#E8626E` | Error and destructive state drawn by the app |
| `star` | `#C8920A` | `#F0C04A` | User-chosen favourite |
| `searchHighlight` | `#F5E08A` | `#6B5A1E` | Search-result wash |

`role: .destructive` buttons remain native macOS controls. `danger` is for
text, glyphs, and strokes Seedbed draws itself.

### Surfaces

| Token | Light | Dark | Role |
|---|---|---|---|
| `Surface.canvas` | `#F7F5F3` | `#0D0E11` | Window/page ground |
| `Surface.card` | `#FCFBFA` | `#1C1C20` | Cards and row groups |
| `Surface.raised` | `#FFFFFF` | `#2C2C31` | In-window overlays and sheets |
| `Surface.sunken` | `#EFEDE8` | `#08080A` | Wells, code blocks, and text inputs |
| `Surface.rowAlternate` | `#F0EEE9` | `#14151A` | Alternating dense rows |
| `Surface.chrome` | `#F1EFEA` | `#17171B` | Headers, footers, toolbars |
| `Surface.hairline` | `#E2DED8` | `#333339` | Opaque dividers and borders |

`SeedbedDivider` overlays the system divider with `Surface.hairline`, keeping a
constant separator across unlike surfaces. Free-floating windows such as the
prompt HUD use `.ultraThinMaterial`; an opaque `Surface.raised` is only for an
overlay inside a Seedbed-owned window.

### State fills and input chrome

| Token | Value |
|---|---|
| `Fill.active` | `accent` at 10% |
| `Fill.selected` | `accent` at 16% |
| `Fill.dropTarget` | `accent` at 22% |
| `Fill.selectedBorder` | `accent` at 55% |
| `searchInputBackground` | quaternary label color at 40% |
| `searchInputBorder` | separator color at 90% |

Inline search fields use the two search tokens on `Radius.control`. Overlay
search is plain, without a bezel. Data-entry fields retain the native rounded
border when they live in a form.

## Typography

The macOS app uses Apple's native system faces exactly as Reference does: SF Pro
for interface and reading text, SF Pro Rounded for brand numerals and badges,
and SF Mono for identifiers and code. SwiftUI semantic fonts are not used;
every role is a fixed, named token.

| Token | Size | Weight/design |
|---|---:|---|
| `FontScale.display` | 32 | semibold, rounded |
| `FontScale.title` | 21 | semibold |
| `FontScale.sectionHeader` | 18 | semibold |
| `FontScale.subtitle` | 16 | regular |
| `FontScale.transcript` | 15 | regular |
| `FontScale.transcriptStrong` | 15 | medium |
| `FontScale.label` | 14 | regular |
| `FontScale.body` | 13 | regular |
| `FontScale.small` | 12 | regular |
| `FontScale.tiny` | 11 | regular |
| `FontScale.micro` | 10 | regular |
| `FontScale.nano` | 9 | regular; the floor |
| `FontScale.monoSmall` | 12 | monospaced |
| `FontScale.monoTiny` | 11 | monospaced |
| `Rounded.numeral` | 24 | bold, rounded |
| `Rounded.small` | 12 | semibold, rounded |
| `Rounded.nano` | 9 | semibold, rounded |

There is no `CompactSize` or `ReadingSize` fork. Dense HUD rows and long-form
help pages select different roles from the same Reference scale.

Use `monoSmall` and `monoTiny` directly for code, identifiers, and compact
keyboard shortcuts. Do not derive an ad-hoc monospaced face from a proportional
role with `.monospaced()`; the named roles keep both face and size aligned with
Reference. SF Symbols continue to use `IconSize` through `.font(.system(size:))`
because that call controls glyph geometry, not text typography.

## Spacing and geometry

| Token | Value | Typical role |
|---|---:|---|
| `Space.row` | 4 | Inline gap |
| `Space.row6` | 6 | Tight two-column/badge gap |
| `Space.tight` | 8 | Close controls |
| `Space.medium` | 10 | Search padding and row gaps |
| `Space.snug` | 12 | Card padding and stack spacing |
| `Space.element` | 14 | Row-cell content gap |
| `Space.regular` | 16 | Standard section spacing |
| `Space.wide` | 24 | Section gutter |
| `Space.pane` | 32 | Outer pane padding |
| `Space.hero` | 48 | Empty-state spacing |
| `Space.scene` | 64 | Whole-scene framing |
| `ChipPadding.h` | 6 | Chip horizontal padding |
| `ChipPadding.v` | 2 | Chip vertical padding |

| Token | Value | Role |
|---|---:|---|
| `Radius.chip` | 3 | Keycaps and compact rectangles |
| `Radius.control` | 4 | Fields and controls |
| `Radius.card` | 6 | Small cards and rows |
| `Radius.sheet` | 8 | Large cards and overlays |

Status chips, tags, and badges are capsules. Containers use the crisp radius
scale. Sheets never set an explicit presentation corner radius; macOS owns the
outer window curve.

## Icon geometry

| Token | pt |
|---|---:|
| `IconSize.mini` | 8 |
| `IconSize.tiny` | 9 |
| `IconSize.small` | 11 |
| `IconSize.compact` | 12 |
| `IconSize.medium` | 13 |
| `IconSize.regular` | 14 |
| `IconSize.large` | 16 |
| `IconSize.xlarge` | 22 |
| `IconSize.hero` | 32 |

Icons use this scale even though SwiftUI sizes SF Symbols through `.font`.
Typography and icon geometry are separate decisions.

## Elevation and motion

| Token | Value | Role |
|---|---|---|
| `Elevation.panel` | black 25%, radius 18, y 6 | Modal over dimmed content |
| `Elevation.popover` | black 16%, radius 9, y 3 | Popover or floating bar |

Nothing in the page plane receives a shadow. Hover may tint; it never lifts.

| Token | Value |
|---|---|
| `Motion.micro` | 0.16 s |
| `Motion.pane` | 0.20 s |
| `Motion.shell` | 0.24 s |
| `Motion.pulse` | 0.9 s |
| `Motion.shimmer` | 1.3 s |
| `Motion.microCurve` | ease-out over `micro` |
| `Motion.paneCurve` | ease-out over `pane` |
| `Motion.shellCurve` | spring, response `shell`, damping 0.86 |
| `Motion.stepCurve` | spring, response 0.34, damping 0.85 |
| `Motion.pulseCurve` | repeating ease-in-out over `pulse` |
| `Motion.reducedCurve` | ease-in-out over `micro` |

## Shared component recipes

- `SeedbedCard`: `Surface.card` or `Surface.raised`, `Space.snug` padding,
  `Radius.sheet`, and a 0.5pt `Surface.hairline` border.
- `SeedbedChip`: 10pt medium text, 6×2 padding, capsule silhouette, 14% semantic
  tint (or 12% neutral fill).
- `SeedbedDivider`: native layout behavior with an opaque warm hairline.
- `seedbedProminent`: macOS prominent button explicitly tinted `accent`.
- `chromeBar`: Reference spacing plus `Surface.chrome`.

`chromeBar` always expands before painting its background. A title or short
footer must not leave a partial-width chrome patch behind it.

The prompt-fill modal is an in-window `SeedbedModalOverlay`, not a native
SwiftUI sheet. Native sheet chrome imposes an oversized outer curve that does
not match the HUD. The overlay blocks the HUD with a 15% black scrim and draws
the 460pt `Surface.raised` panel with `Radius.sheet`, a 0.5pt hairline, and
`Elevation.panel`; header and footer remain full-width `Surface.chrome` bars.

## Help, FAQ, and release notes

The information window follows the reference app's browsable two-pane Help structure.
The fixed sidebar is the index and owns search; the detail pane owns reading.
Every detail page begins with the same 70pt two-row header as Reference: a 21pt
title and neutral type chip on the first 22pt row, followed by a 12pt
plain-language summary on the second 22pt row. The header uses `Space.regular`
horizontal and `Space.medium` vertical padding, then an opaque
`SeedbedDivider` before the scrolling content.

Long-form content is held to `Width.reading` (760pt) and uses `Space.pane`
horizontal plus `Space.wide` vertical inset. Help and FAQ use the reference app's rendered
Markdown hierarchy: 20pt section headings, 16pt topic headings, 15pt primary
answers with 4pt line spacing, and spacing rather than ornamental rules between
topics. Release notes use the narrower `Width.releaseNotes` (680pt), a 20pt
inter-card gap, 16pt inset, 6pt radius, `primary` at 4% for the fill, and
`primary` at 8% for the stroke. Change copy is primary 12pt text; the newest
entry uses the reference app's solid positive Latest badge, while New / Improved / Fixed
retain the positive, secondary-accent, and warning palette.

The information window keeps one deliberate Seedbed brand layer over that
shared structure: page-header glyphs and the selected What's New navigation
glyph use the contrast-safe terracotta `accent`; headings and release copy keep
the reference app's primary ink so their weight and edge contrast match. What's New is the first
unsectioned sidebar row, ahead of the long guide index; About alone remains in
the trailing “This build” section. This makes release notes discoverable at the
window's opening height and keeps Help, FAQ, and What's New visibly Seedbed.

Help content must describe the current library rather than a remembered one.
Model totals and worked-example word counts are checked against `models.toml`
and the rendered files by `tests/test_help_content_freshness.py`.

## Product-specific dimensions

These are Seedbed layout decisions rather than shared visual tokens.

| Token | Value |
|---|---|
| `Width.reading` | 760 |
| `Width.releaseNotes` | 680 |
| `Width.sidebar` | 268 |
| `Width.paged` | 1028 computed |
| `Width.sheet` | 460 |
| `Width.list` | 200 |
| `Width.librarySidebar` | 240 |
| `Size.library` | 900 × 540 |
| `Size.panel` | 420 × 260 |
| `Size.info` | 1040 × 660 |
| `Size.infoMin` | 760 × 420 |
| `Size.settings` | 820 × 620 |
| `Size.settingsMin` | 620 × 460 |

## Web adapter

The local web UI uses the reference app's shared browser tokens rather than pretending
the native and browser renderers are identical. It bundles the reference app's licensed
Inter variable font and JetBrains Mono, uses the Paper/Midnight palettes from
`reference/shared/tokens`, the 4px spacing scale, 4/6/8/12px radii, and
150/200/240ms motion. `prefers-color-scheme` and `prefers-reduced-motion` are
honored for normal visits. For deterministic visual QA, `?appearance=dark` and
`?appearance=light` override only the current page and never change the user's
system appearance.

## Brand identity

Design parity does not replace Seedbed's identity. Brand geometry is governed
by `assets/brand/README.md`: the single-leaf template remains the menu-bar and
favicon micro-mark, while the asymmetric sprout rising from prompt-text rows
remains the app and large-mark asset. Never scale one optical variant into the
other.

## Verification contract

- `tests/test_reference_parity.py` proves every shared native token matches the
  vendored Reference source and rejects a parallel compact type scale.
- `tests/test_design_doc_parity.py` proves every declared token is named here
  and that this document does not name removed tokens.
- `tests/test_theme_contrast.py` resolves adaptive palette values against the
  real Reference canvases in both appearances.
- `tests/test_web_design_parity.py` holds the local web UI to the reference app's browser
  palette, fonts, radii, and reduced-motion contract.
- `macos/Scripts/make-app.sh` must rebuild the app bundle before visual review.
- `macos/Scripts/window-shot.sh` captures the app window itself. Review the HUD,
  Library, Info, and Settings in light and dark appearances at their actual
  opening sizes; compilation is not visual evidence.
