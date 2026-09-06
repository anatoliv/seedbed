# Seedbed Design System

## Which artifact wins

**`macos/Sources/Seedbed/Theme.swift` is the source of truth.** Every table below
was extracted from it on **2026-09-05** and describes the app as it is, not as
anyone intended it. Where the two disagree, the code is right and this document
is stale: fix it here rather than adjusting the code to match prose.

That rule is borrowed from a sibling app's design system, and it is the
reason to have this document at all. A design document that is allowed to
disagree with the code becomes a description of a product nobody shipped.

**It has already been tested once, and the document failed.** The tables were
first extracted on the morning of 2026-09-05; a card that afternoon added `Space.pane`,
`Space.field`, `Width.list`, `Width.librarySidebar`, the whole `Tokens.Size`
group, `FormField` and `.chromeBar()` the same afternoon, and this document was
not updated. An audit caught it before the day ended. Every table below was
re-extracted afterwards, and the check that found the gap is worth keeping:

```sh
# every token in Theme.swift should appear in this document, and vice versa
grep -oE 'static (let|var) \w+' macos/Sources/Seedbed/Theme.swift
```

The lesson is not "be more careful". It is that **a table nothing verifies goes
stale in hours**. It then happened a second time, six minutes after the first fix
was published, when `Size.settings` arrived. So the check is no longer a `grep`
somebody has to remember: `tests/test_design_doc_parity.py` runs it on every test
run, in both directions. What that test still cannot see is listed at the end of
this document.

## Visual language

Ported from Reference rather than invented, so the two apps read as siblings on
one machine. The direction is deliberate and it is not the current default taste:

- **Crisp, not rounded.** Radii top out at 8. Large radii balloon small controls,
  and almost every control here is small.
- **Flat.** No elevation, no skeuomorphic depth. A hairline or a fill does the
  separating.
- **Dense.** Space is information, not decoration. The panel exists to be read in
  two seconds.
- **Typography first.** State is carried by weight and colour before it is
  carried by a box.
- **Warm.** A terracotta accent on a neutral ground, never system blue. The
  accent was the loudest tell when Seedbed was still using the default.

## Brand identity and optical variants

For logo geometry, the SVG masters in `assets/brand/` are authoritative;
`Theme.swift` remains authoritative for UI tokens. Read
`assets/brand/README.md` before adding or changing any branded image.

Seedbed has one identity drawn at two optical sizes:

| Size and context | Drawing | Reason |
|---|---|---|
| 16–20 pt menu-bar/system chrome | Single asymmetric leaf and stem from `seedbed-menu-template.svg` | Symmetric leaves become ears and the text bed becomes a square face at this size. The image is monochrome and AppKit recolors it as a template. |
| Browser-tab favicon | The same single leaf on a terracotta tile from `seedbed-favicon.svg` | The tile carries the brand color while the leaf remains clear at 16 px. |
| 32 pt and larger app/marketing contexts | Asymmetric sprout emerging from three prompt-text rows from `seedbed-app-icon.svg` or `seedbed-mark.svg` | A dominant mature leaf and smaller new leaf remove the rabbit-ear symmetry while preserving the complete “short seed grows into a useful prompt” metaphor. |

The micro-mark is not a second logo and the full mark is not a menu-bar asset.
Never create the small asset by scaling the large one. Never replace either
with an SF Symbol except for the existing emergency fallback when the packaged
menu resource cannot be loaded. The exact placement-to-file matrix and export
procedure live in `assets/brand/README.md`, and are repeated in the agent
instructions so an agent encounters the rule before editing.

## Colour

Five tokens, plus the `OnTint` rung below. Everything else is `.primary`,
`.secondary`, `.tertiary` or a `Color.secondary.opacity(...)` fill, on purpose: a
palette that names greys is a palette that drifts.

| Token | Hex | sRGB | What it is for |
|---|---|---|---|
| `accent` | `#C7693D` | 0.78, 0.41, 0.24 | Selection, pins, the caret, active controls. The contrast-safe rendering of the brand terracotta. |
| `brandAccent` | `#F26B3A` | 0.949, 0.420, 0.227 | The pure brand terracotta. Large fills and brand moments only. |
| `positive` | `#668F5C` | 0.40, 0.56, 0.36 | Success that should not shout: a current render, a copy that worked, a running server. |
| `warning` | `#CC7D2D` | 0.800, 0.490, 0.176 | Needs attention but is not an error: a stale render, unsaved changes, the Accessibility warning triangle. Darkened on 2026-09-05 so it clears the 3:1 bar. |
| `brandWarning` | `#D98530` | 0.851, 0.522, 0.188 | The undarkened amber. Large fills only, including the What's New badge fills. |

### The third rung: text on a tint of itself

`Tokens.OnTint`, added 2026-09-05. A token drawn as **text** on a 14%
tint of itself loses contrast twice over, because the ink is the token and the
paper is a lighter version of the same token. Every What's New badge label did
exactly that and every one failed the 4.5:1 text bar.

These are the only adaptive colours in the palette, and they have to be: no
single value clears 4.5:1 on both a near-white tint and a near-black one.

| Token | Light | Dark | Ratio on its own 14% tint |
|---|---|---|---|
| `OnTint.accent` | `#A15531` (0.631, 0.333, 0.192) | `#E07645` (0.878, 0.463, 0.271) | 4.62:1 light, 4.62:1 dark |
| `OnTint.positive` | `#52734A` (0.322, 0.451, 0.290) | `#73A168` (0.451, 0.631, 0.408) | 4.61:1 light, 4.65:1 dark |
| `OnTint.warning` | `#9A5E22` (0.604, 0.369, 0.133) | `brandWarning` unchanged | 4.60:1 light, 4.74:1 dark |

`Tokens.adaptive(light:dark:)` is the escape hatch that builds them, and it is
used **only** here. Every other token clears its bar in both appearances as a
fixed value, so nothing else needs the machinery.

### Why there are two terracottas

The brand value and the rendered value differ deliberately. `brandAccent` is the
identity; `accent` is a darkened form that survives being drawn small on a light
ground. Seedbed inherited both values from Reference **without inheriting the
argument**, which is how the pair came to look like a duplicate. It is not one.

Measured against pure white on 2026-09-05:

| Token | vs white | vs dark ground | Non-text bar (3:1) |
|---|---|---|---|
| `accent` | 3.81:1 | 4.38:1 | pass |
| `brandAccent` | 3.03:1 | 5.51:1 | fills only, exempt |
| `positive` | 3.72:1 | 4.48:1 | pass |
| `warning` | 3.21:1 | 5.19:1 | pass |
| `brandWarning` | 2.86:1 | 5.83:1 | fills only, exempt |

The dark column was added on the same day. A palette of fixed values checked in
one appearance is unchecked in the other, and checking turned up two more
failures that a light-mode-only pass would have shipped (see the badge note
below).

### Contrast, and what was fixed on 2026-09-05

Following a sibling app's practice of writing down what has and has not been resolved,
because an unrecorded conflict is indistinguishable from an accident.

**Resolved.**

1. **`warning` failed the 3:1 bar for a non-text component**, at 2.86:1 against
   white, while being the tint on the Accessibility warning triangle in
   Settings. The icon that exists to catch your eye was the one below the bar.
   Fixed by darkening it to `#CC7D2D` (3.21:1) and keeping the original value as
   `brandWarning` for fills. That is the same split `accent` and `brandAccent`
   already are, which makes the pair a pattern rather than a one-off.

2. **Every What's New badge label was below the 4.5:1 text bar**, because the
   label drew the token colour as ink on a 14% tint of the same token: the ink is
   the colour and the paper is a lighter version of it. At 9pt, so the large-text
   exception did not apply.

   | Badge | Was (light) | Was (dark) | Now (light) | Now (dark) |
   |---|---|---|---|---|
   | Improved (`accent`) | 3.23:1 | 3.72:1 | 4.62:1 | 4.62:1 |
   | New (`positive`) | 3.19:1 | 3.74:1 | 4.61:1 | 4.65:1 |
   | Fixed (`brandWarning`) | 2.50:1 | 4.74:1 | 4.60:1 | 4.74:1 |

   Fixed with a third rung on the same idea, `Tokens.OnTint`: the fill keeps the
   token, the ink gets a readable form of it. The colour is already carrying the
   meaning through the fill, so the ink does not need to repeat it.

3. **A sibling app measured its identical values against warm paper; Seedbed draws
   them on the system default ground**, which is nearer white. The values were
   copied and the canvas was not, so those ratios never transferred. Every
   number in this document was recomputed here rather than quoted.

**Accepted, with the reason.**

4. **`OnTint` holds the only adaptive colours in the palette.** Everything else
   is a fixed `Color(red:green:blue:)`. That is not an oversight: a single value
   cannot clear 4.5:1 on both a near-white tint and a near-black one, and
   `accent` and `positive` were failing in dark mode as well as light. Every
   other token clears its bar in both appearances as a fixed value, so nothing
   else needs the machinery. If a future token cannot, `Tokens.adaptive` is
   there.

**How this stays true.** `tests/test_theme_contrast.py` parses the values out of
`Theme.swift` and recomputes every ratio in this section on each test run, in
both appearances. It fails if a token drops below its bar, and it fails if the
declarations change shape so it can no longer read them. Exemptions live in that
file's `DECORATIVE` map with the reason, so an exemption is a decision rather
than an omission. A number measured once and never again drifts back.

## Radius

Crisp scale. Never rounded, never pill, for containers.

| Token | Value | Applies to |
|---|---|---|
| `Radius.chip` | 3 | Status pills, badges, key caps |
| `Radius.control` | 4 | Buttons, text fields, inset value boxes |
| `Radius.card` | 6 | List rows, cards |
| `Radius.sheet` | 8 | Overlays, popovers |

## Type

**Two scales, since 2026-09-05.** This section used to say the opposite — *"There
is no separate scale for the bigger windows: a manual set in panel type reads
fine, and a second scale is a second thing to keep aligned."* That was a
prediction, and it was tested the only way a claim about reading can be: the
Seedbed manual was put beside Reference's Help window on one screen. It does
not read fine. Body text was 11pt against 13, and the difference is not subtle.

The mistake is traceable. `CompactSize` was ported from Reference, whose own
source describes it as *"for the picker — the app's densest surface, which needs
finer steps than the reading-oriented FontScale"*. The second half of that
sentence never arrived, so the dense ramp was used on every surface including
the ones made of paragraphs.

`ReadingSize` is for prose: the manual, the FAQ, release notes, About. Same
values as Reference's reading scale.

| Token | pt | Used for |
|---|---|---|
| `ReadingSize.display` | 21 | The app's own name, in SF Rounded (About) |
| `ReadingSize.title` | 20 | A page's own title, in its header |
| `ReadingSize.heading` | 15 | Section headings over prose |
| `ReadingSize.body` | 13 | Paragraphs, definition terms |
| `ReadingSize.meta` | 12 | Captions, secondary lines on a page |
| `ReadingSize.label` | 11 | Eyebrows, key caps, quoted code |
| `ReadingSize.badge` | 9 | The uppercase capsule under a page title |

**A surface picks a ramp once, not per label.** `TextScale` is a SwiftUI
environment value, `.compact` by default, and the manual window sets `.reading`
on its root. The shared components — `SectionHeader`, `Caption`,
`StackedDefinition`, `KeyCap`, `ExampleBlock` — read it. The alternative was a
reading-sized copy of each, which is how this file came to say *"Four files had
four versions of this"* about a component that had already been duplicated once.
Compact is the default deliberately: the dense surfaces are the majority, and a
surface that forgets to declare itself should not silently grow.

`CompactSize` keeps the picker, the library rows and the settings panes.

| Token | pt | Used for |
|---|---|---|
| `CompactSize.mini` | 6 | Reserved |
| `CompactSize.tiny` | 8 | Reserved |
| `CompactSize.badge` | 9 | Chip text, key hints, What's New labels |
| `CompactSize.label` | 10 | Section eyebrows, meta lines, key caps |
| `CompactSize.meta` | 11 | Secondary row text, captions, help body |
| `CompactSize.rowText` | 12 | Body-ish row text, sidebar labels |
| `CompactSize.rowTitle` | 13 | Row titles, section headings |
| `CompactSize.hero` | 27 | Empty-state and About glyphs |

## Icons

Geometry, not typography. Ported from Reference on 2026-09-05, where it had
been missing entirely — every icon here was sized off a font token, which works
until a symbol and a letter want different sizes at the same weight, and then
reads as a wrong icon rather than as a missing scale.

| Token | pt | Used for |
|---|---|---|
| `IconSize.tiny` | 9 | Disclosure chevrons, eyebrow icons |
| `IconSize.small` | 11 | Inline meta icons |
| `IconSize.medium` | 13 | Standard sidebar and toolbar icons |
| `IconSize.regular` | 18 | A prominent header or action icon |

## Chips

One padding for every pill, so badges do not diverge by a point across the app.

| Token | pt | Used for |
|---|---|---|
| `ChipPadding.h` | 6 | Horizontal inset of a chip or badge |
| `ChipPadding.v` | 2 | Vertical inset of the same |

## Space

Added 2026-09-05, after the app reached eight surfaces carrying nine
different content paddings between them. Each value is named for **what it
separates**, so choosing one is a question about the content rather than about
taste.

| Token | Value | Separates |
|---|---|---|
| `Space.page` | 20 | A window's edge from its content |
| `Space.section` | 16 | Two sections of a page |
| `Space.group` | 10 | Sibling rows inside one section |
| `Space.row` | 4 | The lines of a single row: a title from its explanation |
| `Space.control` | 8 | Controls sitting on one line |
| `Space.pane` | 14 | A **working** surface's edge from its content, and the horizontal inset of a chrome bar |
| `Space.field` | 12 | Two fields in a form |

**How to choose:** if the gap is between two things a reader would call different
topics, it is `section`. Between two things of the same kind, `group`. Inside one
thing, `row`. If the gap is horizontal and between controls, `control`. There is
no value for "a bit more than group"; if that is what a layout needs, the layout
is wrong.

**Why `pane` exists alongside `page`, since 14 and 20 look like the same
decision made twice.** They are not. The scale above was drawn for **reading**
surfaces, and a form is denser than a page of prose: putting a settings pane on
`page` was tried and reads as loose. `pane` is the working-surface inset, added
2026-09-05 by an audit, which found four files that had already converged on 14
by accident. `field` is the same story one level down: two of the four forms
already used 12, the others used 13 and 14, and nobody had decided.

## Width

Two window shapes, not seven. Every surface here is either something you read or
something you work in.

| Token | Value | Shape |
|---|---|---|
| `Width.reading` | 560 | A column of prose. Wide enough for a paragraph, narrow enough that a line does not tire the eye. |
| `Width.sidebar` | 178 | The contents list beside it |
| `Width.paged` | 738 | `sidebar + reading`: a window that is a contents list plus a reading column |
| `Width.sheet` | 460 | A sheet that asks for a few values and goes away |
| `Width.list` | 200 | A list column beside an editor |
| `Width.librarySidebar` | 240 | The library window's own sidebar. A named exemption, argued below |

**The exception, written down so it stays a decision.** The library window is
900×540 and does not use these. It holds several columns of generated prompt text
side by side for comparison, which is a genuinely different shape, and forcing it
to `reading` would make it worse. The Settings window is 820 wide for a related
reason: its Models pane is a two-column editor, not prose.

**And its sidebar stays at 240 rather than `sidebar`'s 178.** `sidebar` is right
for what it describes: the Info window's contents list, five short page names and
nothing else in the row. A library row is a two-line entry, a title over a
metadata line, with a pin glyph indented left and, on the right, either a
staleness dot or a four-button action strip that appears on hover in the same
space. That is a different shape. **The width at which titles begin to truncate
has not been measured**, so this exemption rests on the shape rather than on a
number; `UI_STYLE_AUDIT_2026-09-05.md` §3.1 says the same.

## Size

Window sizes. Named rather than converged, because four genuinely different
surfaces need four numbers, and four view bodies each holding one is how nobody
noticed there were four.

| Token | Value | Surface |
|---|---|---|
| `Size.library` | 900×540 | Up to four columns of generated prompt text side by side |
| `Size.panel` | 420×260 | The floating panel, which is a list and nothing else |
| `Size.info` | `Width.paged` × 640 | A contents list plus one reading column |
| `Size.settings` | 820×620 | Wider than `info` because the Models pane is a two-column editor rather than prose |
| `Size.infoMin` | 620×420 | How small the manual may be dragged. Reference's Help minimum |
| `Size.settingsMin` | 620×460 | The same for Settings |

**A minimum is not the opening size.** Both windows opened at a fixed frame and carried `.resizable` in their style mask, so the resize cursor appeared and the drag did nothing. They now open at `Size.info` / `Size.settings` and go down to the `*Min` pair, which is what lets the manual sit beside the thing it describes on a small screen.

`Size.settings` was the last to arrive, and it arrived last for a reason worth
knowing: it lived as a raw `820, 620` in **two** files that had to agree, with
nothing making them, so it did not look like a single number the way the other
three did. Two places holding the same literal is harder to spot than one place
holding a literal.

## Motion

| Token | Curve | Used for |
|---|---|---|
| `Motion.microCurve` | ease-out 160ms | Pointer-driven feedback: hover, selection, chip toggles |
| `Motion.paneCurve` | ease-out 200ms | In-pane reveals: overlays, toasts, fold and unfold |

One curve family. Nothing here springs or bounces.

## Shared components

In `Theme.swift`, so a heading has one definition rather than one per file.
Before these, three files drew a section heading three different ways.

| Component | Use it when |
|---|---|
| `SectionHeader` | A heading over prose, in a page of the manual |
| `SettingsGroup` | A quiet eyebrow label on a box of controls, in a settings pane |
| `Caption` | Secondary explanation under a control or heading. Always wraps, never truncates |
| `DefinitionRow` | A leading element and its explanation on one line: a key cap, a badge |
| `StackedDefinition` | The same, stacked, when the term is a sentence rather than a key |
| `KeyCap` | A keyboard key, drawn as a cap |
| `ExampleBlock` | A real artifact quoted inside prose: a command, a snippet, an error string. Monospaced, scrolls sideways rather than wrapping |
| `ManualTopicView` | One manual entry as it draws: term, meaning, and its artifact if it has one |
| `FormField` | A label over the one control it names, in a form |
| `.chromeBar()` | The inset of a header or footer strip framing a working surface. 14 call sites |

**`SectionHeader` and `SettingsGroup` deliberately look different.** One is a
heading over prose; the other is a label on a box of controls. They were drawn
identically in three files while meaning one or the other, which is the specific
confusion these two names exist to end.

**`FormField` is deliberately not `SettingsGroup` either**, and it is the same
argument one size down: `SettingsGroup` is an uppercased eyebrow over a *box* of
controls, `FormField` a sentence-case label over *one*. They looked close enough
to merge; merging them would have made every form field shout. Before it existed,
three files carried a private `field()` helper at three different spacings.

**`.chromeBar()` is a modifier rather than a view** because it wraps content
someone else composed. Ten sites did that job with the same horizontal inset and
five different vertical ones (7, 8, 9, 10, 11), not one of which was a decision
anybody made.

### Row actions

`PromptRowActions.swift` holds its own geometry, in `RowActions`, so the icons
stay square and evenly spaced wherever the strip is used.

| Token | Value |
|---|---|
| `RowActions.button` | 17 (equal frames put the icons on one line) |
| `RowActions.spacing` | 8 (tighter than Reference's 10: up to six icons) |

**There is deliberately no gutter**, and the reason is a design difference rather
than an omission. Reference's strip **overlays** the row, so whatever sits
underneath must be inset far enough to clear the icons. Seedbed's **replaces**
the trailing slot: the HUD row shows the usage badge *or* the strip, and the
library sidebar shows the staleness dot *or* the strip. Nothing is underneath,
so nothing has to move.

A `gutter` and a `maxCount` were ported across with the values and read by
nothing, while the comment above them promised a coupling that did not exist.
Removed 2026-09-05. This is the same failure as inheriting the
terracotta pair without its argument, one file over.

**A nil closure hides its button rather than disabling it.** That is how a row
says an action does not apply to it, and it does real work: the library sidebar
hides paste (there is no app you came from) and edit (you are already in the
editor) rather than showing two dead controls.

## The manual window

Ported from Reference's Help window rather than approximated, because the two
sat side by side and the differences were all in Seedbed's favour to fix:

- **The page has a header.** A symbol in the accent, the page title at
  `ReadingSize.title`, an uppercase capsule naming what kind of page it is, and a
  divider. Without it a page opened straight into its first sub-heading, so
  "Keyboard" read as the window's title rather than as one section of Help.
- **The header does not scroll.** It sits above the scroll view, so "where am I"
  stays on screen while "what does it say" moves.
- **Search is in the sidebar**, above the contents list. It was over the reading
  column, which made it look like it searched the page you were on. The sidebar
  is the column that answers "which page", and searching is the other way of
  asking that.
- **The contents list is grouped.** Five items do not need finding, but they do
  need telling apart: three teach the app, two describe this copy of it.

## The surfaces

| Surface | Shape | Job |
|---|---|---|
| HUD panel | 420×260 minimum, floating | Grab a prompt in two seconds without breaking flow |
| Library window | 900×540 | Write prompts and compare what each model made of them |
| Settings | 820×620, sidebar | General, Models, Building, MCP |
| Info | `Width.paged` × 640, sidebar | Getting Started, Help, FAQ, What's New, About |
| Fill sheet | `Width.sheet` | Ask for placeholder values on the way to a copy |

The panel and the library window are separate on purpose: the panel is for
grabbing, the window is for writing, and a 460pt strip is the wrong shape for the
second while dismiss-on-click-away is actively hostile to it.

## What is not in here yet

- There is no dark-mode table for the palette as a whole. Every token except the
  three in `OnTint` is a single value used on both canvases, which works today
  because the palette is a few accents on system greys, and will stop working the
  moment a surface colour is introduced. `OnTint` is where that already happened
  once.
- **No Swift test covers any of this**, because `macos/` has no test target
  Two Python tests guard it from the outside instead, and between
  them they cover the two ways this document has actually failed:
  - `tests/test_theme_contrast.py` parses the colour **values** out of
    `Theme.swift` and recomputes every ratio in the Colour section on each run,
    in both appearances.
  - `tests/test_design_doc_parity.py` checks that every token in `Theme.swift`
    is **named** here and that this document names no token that no longer
    exists. It was added after the tables went stale twice in one day, hours
    apart, both times because a card landed a new token and nobody came back
    here.
- **What is still unguarded: the space, width and size VALUES.** The parity test
  knows `Space.pane` is mentioned; it does not know the table says 14. If one of
  those numbers changes in `Theme.swift`, this document will quietly disagree and
  nothing will say so.
