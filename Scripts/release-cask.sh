#!/usr/bin/env bash
set -euo pipefail

# Build a universal, Developer ID-signed DMG and print the checksum required by
# a Homebrew cask. This intentionally refuses ad-hoc signing: downloadable
# releases should pass Gatekeeper before a cask points users at them.
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VERSION="${VERSION:?Set VERSION, for example VERSION=0.1.0}"
SIGNING_IDENTITY="${SIGNING_IDENTITY:?Set SIGNING_IDENTITY to your Developer ID Application certificate}"
NOTARY_PROFILE="${NOTARY_PROFILE:?Set NOTARY_PROFILE to a notarytool Keychain profile}"

if [[ "$SIGNING_IDENTITY" == "-" ]]; then
    echo "A Developer ID Application certificate is required for public releases." >&2
    exit 1
fi

cd "$ROOT"
VERSION="$VERSION" SIGNING_IDENTITY="$SIGNING_IDENTITY" ARCHS="arm64 x86_64" \
    CONFIGURATION=release OUTPUT_DIR="$ROOT/dist" ./Scripts/build-app.sh
./Scripts/verify-app.sh

# Notarize and staple the app before placing it in the DMG so Gatekeeper can
# validate the copied app even when the Mac is offline.
NOTARY_DIR="$(mktemp -d /tmp/Juice-notary.XXXXXX)"
NOTARY_ZIP="$NOTARY_DIR/Juice.zip"
MOUNT_DIR=""
cleanup() {
    if [[ -n "$MOUNT_DIR" ]]; then
        hdiutil detach "$MOUNT_DIR" >/dev/null 2>&1 || true
        rmdir "$MOUNT_DIR" >/dev/null 2>&1 || true
    fi
    rm -rf "$NOTARY_DIR"
}
trap cleanup EXIT
ditto -c -k --keepParent dist/Juice.app "$NOTARY_ZIP"
xcrun notarytool submit "$NOTARY_ZIP" --keychain-profile "$NOTARY_PROFILE" --wait
xcrun stapler staple dist/Juice.app
xcrun stapler validate dist/Juice.app
spctl --assess --type execute -vv dist/Juice.app

# Package the already-notarized app, then notarize and staple the distributable
# itself. Rebuilding here would discard the app's stapled ticket.
SKIP_APP_BUILD=1 OUTPUT_DIR="$ROOT/dist" ./Scripts/create-dmg.sh
codesign --force --sign "$SIGNING_IDENTITY" --timestamp dist/Juice.dmg
codesign --verify --verbose=2 dist/Juice.dmg
xcrun notarytool submit dist/Juice.dmg --keychain-profile "$NOTARY_PROFILE" --wait
xcrun stapler staple dist/Juice.dmg
xcrun stapler validate dist/Juice.dmg
spctl --assess --type open --context context:primary-signature -vv dist/Juice.dmg

# Inspect the exact app users will copy out of the final disk image. This
# catches architecture, signing, helper-mode, or metadata drift during packing.
MOUNT_DIR="$(mktemp -d /tmp/Juice-release-mount.XXXXXX)"
hdiutil attach dist/Juice.dmg -readonly -nobrowse -mountpoint "$MOUNT_DIR" >/dev/null
./Scripts/verify-app.sh "$MOUNT_DIR/Juice.app"
spctl --assess --type execute -vv "$MOUNT_DIR/Juice.app"
hdiutil detach "$MOUNT_DIR" >/dev/null
rmdir "$MOUNT_DIR"
MOUNT_DIR=""
shasum -a 256 "dist/Juice.dmg"
