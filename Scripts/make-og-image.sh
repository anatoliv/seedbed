#!/usr/bin/env bash
#
# Build site/og.png, the social card, from the brand masters.
#
#   Scripts/make-og-image.sh
#
# The tile is the app icon RENDERED, not an app icon redrawn: assets/brand's
# README is explicit that new artwork must not be invented where a mapped asset
# exists, and a hand-copied path set is exactly the kind of thing that silently
# stops matching the master. So the master is rasterized and placed, and this
# script is the only way site/og.png is produced.
#
# Needs rsvg-convert (brew install librsvg), the same dependency
# assets/brand/export-assets.sh already has.
set -euo pipefail
cd "$(dirname "$0")/.."

MASTER="assets/brand/seedbed-app-icon.svg"
OUT="site/og.png"
[[ -f "$MASTER" ]] || { echo "error: missing $MASTER" >&2; exit 1; }
command -v rsvg-convert >/dev/null || { echo "error: rsvg-convert not on PATH (brew install librsvg)" >&2; exit 1; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# 672 = the 336pt tile at 2x, so the card stays crisp when a platform scales it.
rsvg-convert -w 672 -h 672 "$MASTER" -o "$WORK/tile.png"

cat > "$WORK/og.svg" <<SVG
<svg xmlns="http://www.w3.org/2000/svg" xmlns:xlink="http://www.w3.org/1999/xlink"
     width="1200" height="630" viewBox="0 0 1200 630">
  <rect width="1200" height="630" fill="#FAF9F7"/>
  <image xlink:href="tile.png" x="96" y="147" width="336" height="336"/>
  <g font-family="Helvetica Neue, Helvetica, Arial, sans-serif" fill="#24211F">
    <text x="500" y="228" font-size="40" font-weight="700" letter-spacing="-0.5">Seedbed</text>
    <text x="500" y="316" font-size="62" font-weight="700" letter-spacing="-2">Keep the short prompt.</text>
    <text x="500" y="390" font-size="62" font-weight="700" letter-spacing="-2" fill="#C7693D">Generate the long one.</text>
    <text x="500" y="452" font-size="24" fill="#6F6964">A prompt library for the Mac menu bar. Plain files, in git.</text>
    <text x="500" y="520" font-size="24" fill="#6F6964" font-family="Menlo, SF Mono, monospace">seedbed.dev</text>
  </g>
</svg>
SVG

rsvg-convert -w 1200 -h 630 "$WORK/og.svg" -o "$OUT"
echo "    wrote $OUT from $MASTER ($(du -h "$OUT" | awk '{print $1}'))"
