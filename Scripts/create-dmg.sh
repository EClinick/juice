#!/usr/bin/env bash
set -euo pipefail

# Create a polished Finder disk image with Juice's Charge Across install layout.
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUTPUT_DIR="${OUTPUT_DIR:-$ROOT/dist}"
BACKGROUND_PATH="$ROOT/Packaging/Juice-dmg-background.png"
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
DMG_PATH="$OUTPUT_DIR/$DMG_NAME"
WORK_DIR=""
MOUNT_DIR=""
MOUNTED=0

cleanup() {
    if [[ "$MOUNTED" == "1" && -n "$MOUNT_DIR" && -d "$MOUNT_DIR" ]]; then
        hdiutil detach "$MOUNT_DIR" >/dev/null 2>&1 || true
    fi
    if [[ -n "$WORK_DIR" && -d "$WORK_DIR" ]]; then
        rm -rf "$WORK_DIR"
    fi
}
trap cleanup EXIT

if [[ "${SKIP_APP_BUILD:-0}" != "1" ]]; then
    rm -rf "$OUTPUT_DIR/$APP_NAME"
    DEVELOPMENT_BUILD="$DEVELOPMENT_BUILD" "$ROOT/Scripts/build-app.sh"
fi
[[ -d "$OUTPUT_DIR/$APP_NAME" ]] || {
    echo "$APP_NAME is missing from $OUTPUT_DIR" >&2
    exit 1
}
[[ -f "$BACKGROUND_PATH" ]] || {
    echo "DMG background is missing: $BACKGROUND_PATH" >&2
    exit 1
}

mkdir -p "$OUTPUT_DIR"
WORK_DIR="$(mktemp -d "$OUTPUT_DIR/.juice-dmg.XXXXXX")"
STAGING_DIR="$WORK_DIR/staging"
RW_DMG_PATH="$WORK_DIR/read-write.dmg"
mkdir -p "$STAGING_DIR/.background"

# Preserve code-signing metadata and the app's stapled notarization ticket.
ditto "$OUTPUT_DIR/$APP_NAME" "$STAGING_DIR/$APP_NAME"
ln -s /Applications "$STAGING_DIR/Applications"
cp "$BACKGROUND_PATH" "$STAGING_DIR/.background/background.png"

rm -f "$DMG_PATH"
hdiutil create \
    -volname "$VOLUME_NAME" \
    -srcfolder "$STAGING_DIR" \
    -ov \
    -format UDRW \
    "$RW_DMG_PATH" >/dev/null
ATTACH_OUTPUT="$(hdiutil attach \
    "$RW_DMG_PATH" \
    -readwrite \
    -noverify \
    -noautoopen)"
MOUNT_DIR="$(awk -F $'\t' '$3 ~ "^/Volumes/" { print $3 }' <<<"$ATTACH_OUTPUT" | tail -n 1)"
[[ -n "$MOUNT_DIR" && -d "$MOUNT_DIR" ]] || {
    echo "Could not determine the mounted DMG path." >&2
    exit 1
}
MOUNT_NAME="${MOUNT_DIR##*/}"
MOUNTED=1

# Finder writes this layout into the volume's .DS_Store. The real app and
# Applications alias sit over the two icon-safe zones in the background art.
if ! osascript - "$MOUNT_NAME" "$APP_NAME" "$MOUNT_DIR" <<'APPLESCRIPT'
on run arguments
    set volumeName to item 1 of arguments
    set appName to item 2 of arguments
    set mountPath to item 3 of arguments
    set backgroundImage to POSIX file (mountPath & "/.background/background.png") as alias

    with timeout of 30 seconds
        tell application "Finder"
            delay 1
            tell disk volumeName
                open
                tell container window
                    set current view to icon view
                    set toolbar visible to false
                    set statusbar visible to false
                    set bounds to {120, 120, 780, 540}
                end tell
                tell icon view options of container window
                    set arrangement to not arranged
                    set icon size to 128
                    set text size to 14
                    set background picture to backgroundImage
                end tell
                set position of item appName to {145, 215}
                set position of item "Applications" to {515, 215}
                update without registering applications
                delay 1
                close
            end tell
        end tell
    end timeout
end run
APPLESCRIPT
then
    echo "Finder could not save the DMG layout." >&2
    echo "Check the Finder error above and verify Automation permission, then retry." >&2
    exit 1
fi

sync
hdiutil detach "$MOUNT_DIR" >/dev/null
MOUNTED=0
MOUNT_DIR=""

hdiutil convert "$RW_DMG_PATH" -format UDZO -o "$DMG_PATH" >/dev/null
echo "Built $DMG_PATH"
