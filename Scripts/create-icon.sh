#!/usr/bin/env bash
set -euo pipefail

# Convert the single high-resolution source artwork into every representation
# required by macOS, then assemble the app's .icns resource.
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SOURCE="$ROOT/Assets/JuiceIcon.png"
OUTPUT="$ROOT/Packaging/Juice.icns"
WORK_DIR="$(mktemp -d)"
NORMALIZED_SOURCE="$WORK_DIR/JuiceIcon.png"
ICONSET="$WORK_DIR/Juice.iconset"

if [[ ! -f "$SOURCE" ]]; then
    echo "Missing app-icon source: $SOURCE" >&2
    exit 1
fi

trap 'rm -rf "$WORK_DIR"' EXIT
swift "$ROOT/Scripts/prepare-icon.swift" "$SOURCE" "$NORMALIZED_SOURCE"
mkdir -p "$ICONSET"

for size in 16 32 128 256 512; do
    sips -z "$size" "$size" "$NORMALIZED_SOURCE" \
        --out "$ICONSET/icon_${size}x${size}.png" >/dev/null
    retina_size=$((size * 2))
    sips -z "$retina_size" "$retina_size" "$NORMALIZED_SOURCE" \
        --out "$ICONSET/icon_${size}x${size}@2x.png" >/dev/null
done

iconutil -c icns "$ICONSET" -o "$OUTPUT"
echo "Built $OUTPUT"
