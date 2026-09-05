#!/usr/bin/env bash
# Regenerate every raster/bundle export from the production SVG masters.

set -euo pipefail
cd "$(dirname "$0")"

for tool in rsvg-convert sips python3; do
    if ! command -v "$tool" >/dev/null 2>&1; then
        echo "missing required export tool: $tool" >&2
        exit 1
    fi
done

rsvg-convert -w 1024 -h 1024 -o seedbed-app-icon-1024.png seedbed-app-icon.svg
rsvg-convert -w 512 -h 512 -o seedbed-mark-512.png seedbed-mark.svg
rsvg-convert -w 18 -h 18 -o seedbed-menu-template.png seedbed-menu-template.svg
rsvg-convert -w 36 -h 36 -o seedbed-menu-template@2x.png seedbed-menu-template.svg

cp seedbed-favicon.svg favicon.svg
rsvg-convert -w 32 -h 32 -o favicon-32.png seedbed-favicon.svg
rsvg-convert -w 180 -h 180 -o apple-touch-icon.png seedbed-app-icon.svg

icon_work_dir=$(mktemp -d "${TMPDIR:-/tmp}/seedbed-icons.XXXXXX")
trap 'rm -rf -- "$icon_work_dir"' EXIT
iconset_dir="$icon_work_dir/Seedbed.iconset"
mkdir -p "$iconset_dir"
sips -z 16 16 seedbed-app-icon-1024.png --out "$iconset_dir/icon_16x16.png" >/dev/null
sips -z 32 32 seedbed-app-icon-1024.png --out "$iconset_dir/icon_16x16@2x.png" >/dev/null
sips -z 32 32 seedbed-app-icon-1024.png --out "$iconset_dir/icon_32x32.png" >/dev/null
sips -z 64 64 seedbed-app-icon-1024.png --out "$iconset_dir/icon_32x32@2x.png" >/dev/null
sips -z 128 128 seedbed-app-icon-1024.png --out "$iconset_dir/icon_128x128.png" >/dev/null
sips -z 256 256 seedbed-app-icon-1024.png --out "$iconset_dir/icon_128x128@2x.png" >/dev/null
sips -z 256 256 seedbed-app-icon-1024.png --out "$iconset_dir/icon_256x256.png" >/dev/null
sips -z 512 512 seedbed-app-icon-1024.png --out "$iconset_dir/icon_256x256@2x.png" >/dev/null
sips -z 512 512 seedbed-app-icon-1024.png --out "$iconset_dir/icon_512x512.png" >/dev/null
cp seedbed-app-icon-1024.png "$iconset_dir/icon_512x512@2x.png"

python3 make-icns.py "$iconset_dir" Seedbed.icns

echo "exported Seedbed app, menu-bar and web icon assets"
