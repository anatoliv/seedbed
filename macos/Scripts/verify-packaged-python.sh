#!/usr/bin/env bash
# Verify the app carries the current Python core and uses it for an actual build.
set -euo pipefail
cd "$(dirname "$0")/.."

APP="${1:-build/Seedbed.app}"
APP="$(cd "$APP" && pwd -P)"
RUNTIME="$APP/Contents/Resources/Python"
[[ -f "$RUNTIME/seedbed_runtime.py" ]] || {
    echo "error: $APP has no packaged Python entry point" >&2
    exit 1
}
RUNTIME="$(cd "$RUNTIME" && pwd -P)"
cmp -s Packaging/seedbed_runtime.py "$RUNTIME/seedbed_runtime.py" || {
    echo "error: packaged Python entry point differs from source" >&2
    exit 1
}
while IFS= read -r -d '' tracked_file; do
    cmp -s "../$tracked_file" "$RUNTIME/$tracked_file" || {
        echo "error: packaged $tracked_file differs from source" >&2
        exit 1
    }
done < <(git -C .. ls-files -z -- promptlib)
for asset in favicon.svg favicon-32.png apple-touch-icon.png seedbed-mark.svg; do
    cmp -s "../assets/brand/$asset" "$RUNTIME/assets/brand/$asset" || {
        echo "error: packaged $asset differs from source" >&2
        exit 1
    }
done
if find "$RUNTIME" \( -name '__pycache__' -o -name '*.pyc' \) -print -quit | grep -q .; then
    echo "error: packaged Python core contains bytecode caches" >&2
    exit 1
fi
python3 ../tests/verify_packaged_runtime.py "$APP"
