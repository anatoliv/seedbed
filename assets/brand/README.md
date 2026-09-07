# Seedbed brand assets

The mark is a sprout growing from an ordered bed. The bed also reads as three
lines of prompt text: a short seed is cultivated into a useful result.

Seedbed has one identity with two optical variants. The detailed mark is used
where its meaning remains legible; the single-leaf micro-mark is used only in
tiny system chrome. This is the same logo system adapted to two viewing sizes,
not two interchangeable brand icons.

## Geometry that defines the mark

- The large mark has a dominant mature leaf at upper right and a smaller new
  leaf lower on the left. Their sizes, heights and angles must stay unequal.
- The stem curves gently into the bed rather than forming a centered rigid
  post between mirrored leaves.
- The bed is wider than it is tall. Its three openings are prompt-text rows;
  squaring the bed makes it read as a face.
- The micro-mark removes the bed and smaller leaf entirely. It is a single leaf
  and stem, not a miniature rendering of the large mark.

## Which asset to use

| Placement | Use | Do not use |
|---|---|---|
| Menu bar, 16–20 pt toolbar/status chrome | `seedbed-menu-template.svg` or its 1x/2x PNG exports | Full app tile, colored raster, SF Symbol |
| Finder, app bundle, permission dialog, About art | `Seedbed.icns` or `seedbed-app-icon.svg` | Single-leaf menu micro-mark |
| Marketing lockup beside “Seedbed” | `seedbed-mark.svg` | Generated concept PNG |
| Standalone marketing tile/social avatar | `seedbed-app-icon.svg` or `seedbed-app-icon-1024.png` | Menu template |
| Browser tab | `seedbed-favicon.svg`, exported as `favicon.svg` and `favicon-32.png` | Scaled-down full mark |
| Home-screen shortcut | `apple-touch-icon.png` | Menu template or ad-hoc export |

## Masters

- `seedbed-app-icon.svg` — full-color tile; use for the app, social cards and
  large marketing placements.
- `seedbed-mark.svg` — terracotta mark on transparency; use beside the Seedbed
  wordmark and on light or dark neutral backgrounds.
- `seedbed-menu-template.svg` — optically simplified monochrome mark for
  16–20 pt system chrome. It uses one asymmetric leaf, because the full
  two-leaf/three-row mark reads as a face when reduced. AppKit must treat it as
  a template image.
- `seedbed-favicon.svg` — the same single-leaf micro-mark on a terracotta tile;
  use it only for browser-tab sizes.
- `seedbed-icon-concept.png` — the generated concept exploration retained as
  provenance, not as the production master.

## Exports

- `Seedbed.icns` and `seedbed-app-icon-1024.png` — macOS bundle assets.
- `seedbed-menu-template.png` / `seedbed-menu-template@2x.png` — 18 pt menu-bar
  assets at 1x and 2x.
- `favicon.svg`, `favicon-32.png`, and `apple-touch-icon.png` — website assets.
- `seedbed-mark-512.png` — transparent general-purpose raster mark.

The public site keeps its own copies of the web assets in `site/`, which must
stay byte-identical to the ones here. The export script does not write there.

## Regenerating exports

The SVG files are the production masters. After changing either one, regenerate
all derived files from this repository root:

```sh
assets/brand/export-assets.sh
```

The export requires `rsvg-convert`, macOS `sips`, and Python 3. It also rebuilds
`Seedbed.icns`; do not hand-edit any PNG or ICNS export. Inspect the 18 pt menu
asset at native size after every geometry change. `tests/test_brand_assets.py`
guards the expected dimensions and the app/web placement mapping.

Then refresh the site's copies, because the export script does not touch them:

```sh
cp assets/brand/{seedbed-mark.svg,seedbed-app-icon.svg,favicon.svg,\
favicon-32.png,apple-touch-icon.png} site/
Scripts/make-og-image.sh          # the social card, from the app-icon master
```

and **bump the `?v=` query on every icon URL in `site/index.html` and
`site/evidence/index.html`**. The site is served with a week-long `immutable`
cache and a CDN in front of it, so an icon replaced at a stable path keeps being
served from the edge: on 2026-09-07 visitors saw the previous mark for two days
while the origin was correct. A versioned URL is a different cache key, and
`tests/test_site.py` fails any icon reference that has none.

## Color

- Brand terracotta: `#F26B3A` (large brand fills)
- Accessible terracotta: `#C7693D` (small marks and UI accents)
- Warm paper: `#FAF9F7`
- Deep charcoal: `#24211F`

Keep the mark upright, do not add leaf veins or AI sparkles, and leave clear
space around it equal to at least half the height of one text slot.
