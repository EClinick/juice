#!/usr/bin/env bash
set -euo pipefail

# Create a simple Finder-ready disk image with a drag-to-Applications layout.
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUTPUT_DIR="${OUTPUT_DIR:-$ROOT/dist}"
DEVELOPMENT_BUILD="${DEVELOPMENT_BUILD:-1}"
[[ "$DEVELOPMENT_BUILD" == "0" || "$DEVELOPMENT_BUILD" == "1" ]] || {
    echo "DEVELOPMENT_BUILD must be 0 or 1" >&2
    exit 1
}
if [[ "$DEVELOPMENT_BUILD" == "1" ]]; then
    APP_NAME="Juice Dev.app"
    DMG_NAME="Juice Dev.dmg"
    VOLUME_NAME="Juice Dev"
else
    APP_NAME="Juice.app"
    DMG_NAME="Juice.dmg"
    VOLUME_NAME="Juice"
    if [[ "${SKIP_APP_BUILD:-0}" != "1" && "${SIGNING_IDENTITY:--}" == "-" ]]; then
        echo "A signing identity is required for a production-identity DMG." >&2
        exit 1
    fi
fi
STAGING_DIR="$OUTPUT_DIR/dmg-staging"
DMG_PATH="$OUTPUT_DIR/$DMG_NAME"

if [[ "${SKIP_APP_BUILD:-0}" != "1" ]]; then
    rm -rf "$OUTPUT_DIR/$APP_NAME"
    DEVELOPMENT_BUILD="$DEVELOPMENT_BUILD" "$ROOT/Scripts/build-app.sh"
fi
[[ -d "$OUTPUT_DIR/$APP_NAME" ]] || {
    echo "$APP_NAME is missing from $OUTPUT_DIR" >&2
    exit 1
}

rm -rf "$STAGING_DIR" "$DMG_PATH"
mkdir -p "$STAGING_DIR"
# Preserve code-signing metadata and the app's stapled notarization ticket.
ditto "$OUTPUT_DIR/$APP_NAME" "$STAGING_DIR/$APP_NAME"
ln -s /Applications "$STAGING_DIR/Applications"

hdiutil create -volname "$VOLUME_NAME" -srcfolder "$STAGING_DIR" -ov -format UDZO "$DMG_PATH"
rm -rf "$STAGING_DIR"
echo "Built $DMG_PATH"
