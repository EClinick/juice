#!/usr/bin/env bash
set -euo pipefail

# Create a simple Finder-ready disk image with a drag-to-Applications layout.
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUTPUT_DIR="${OUTPUT_DIR:-$ROOT/dist}"
STAGING_DIR="$OUTPUT_DIR/dmg-staging"
DMG_PATH="$OUTPUT_DIR/Juice.dmg"

"$ROOT/Scripts/build-app.sh"

rm -rf "$STAGING_DIR" "$DMG_PATH"
mkdir -p "$STAGING_DIR"
cp -R "$OUTPUT_DIR/Juice.app" "$STAGING_DIR/Juice.app"
ln -s /Applications "$STAGING_DIR/Applications"

hdiutil create -volname Juice -srcfolder "$STAGING_DIR" -ov -format UDZO "$DMG_PATH"
rm -rf "$STAGING_DIR"
echo "Built $DMG_PATH"
