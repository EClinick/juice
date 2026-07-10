#!/usr/bin/env bash
set -euo pipefail

# Create a simple Finder-ready disk image with a drag-to-Applications layout.
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUTPUT_DIR="${OUTPUT_DIR:-$ROOT/dist}"
STAGING_DIR="$OUTPUT_DIR/dmg-staging"
DMG_PATH="$OUTPUT_DIR/Juice.dmg"

if [[ "${SKIP_APP_BUILD:-0}" != "1" ]]; then
    "$ROOT/Scripts/build-app.sh"
fi
[[ -d "$OUTPUT_DIR/Juice.app" ]] || {
    echo "Juice.app is missing from $OUTPUT_DIR" >&2
    exit 1
}

rm -rf "$STAGING_DIR" "$DMG_PATH"
mkdir -p "$STAGING_DIR"
# Preserve code-signing metadata and the app's stapled notarization ticket.
ditto "$OUTPUT_DIR/Juice.app" "$STAGING_DIR/Juice.app"
ln -s /Applications "$STAGING_DIR/Applications"

hdiutil create -volname Juice -srcfolder "$STAGING_DIR" -ov -format UDZO "$DMG_PATH"
rm -rf "$STAGING_DIR"
echo "Built $DMG_PATH"
