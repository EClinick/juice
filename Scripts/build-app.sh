#!/usr/bin/env bash
set -euo pipefail

# Build a self-contained Juice.app from the Swift Package executable. The
# default ad-hoc signature is suitable for local development; pass a Developer
# ID Application identity when producing a release candidate.
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIGURATION="${CONFIGURATION:-release}"
VERSION="${VERSION:-0.1.0}"
BUILD_NUMBER="${BUILD_NUMBER:-1}"
SIGNING_IDENTITY="${SIGNING_IDENTITY:--}"
APPCAST_URL="${APPCAST_URL:-https://github.com/EClinick/juice/releases/latest/download/appcast.xml}"
OUTPUT_DIR="${OUTPUT_DIR:-$ROOT/dist}"
APP_PATH="$OUTPUT_DIR/Juice.app"
ARCHS="${ARCHS:-arm64 x86_64}"
BUILD_ROOT="${BUILD_ROOT:-$ROOT/.build/app-bundle}"

cd "$ROOT"
APP_BINARIES=()
HELPER_BINARIES=()
SPARKLE_FRAMEWORK=""
for arch in $ARCHS; do
    arch_build_path="$BUILD_ROOT/$CONFIGURATION-$arch"
    if [[ "$SIGNING_IDENTITY" == "-" ]]; then
        # Ad-hoc helpers have no Team ID. Restrict this weaker identifier-only
        # client requirement to local builds; Developer ID releases fail closed.
        swift build -c "$CONFIGURATION" --arch "$arch" \
            --build-path "$arch_build_path" -Xswiftc -DDEV_HELPER
    else
        swift build -c "$CONFIGURATION" --arch "$arch" --build-path "$arch_build_path"
    fi
    bin_path="$(swift build -c "$CONFIGURATION" --arch "$arch" \
        --build-path "$arch_build_path" --show-bin-path)"
    APP_BINARIES+=("$bin_path/Juice")
    HELPER_BINARIES+=("$bin_path/JuiceHelper")
    if [[ -z "$SPARKLE_FRAMEWORK" ]]; then
        SPARKLE_FRAMEWORK="$bin_path/Sparkle.framework"
    fi
done

if [[ ! -d "$SPARKLE_FRAMEWORK" ]]; then
    echo "Sparkle.framework was not produced by SwiftPM." >&2
    exit 1
fi

"$ROOT/Scripts/create-icon.sh"

rm -rf "$APP_PATH"
mkdir -p \
    "$APP_PATH/Contents/MacOS" \
    "$APP_PATH/Contents/Resources" \
    "$APP_PATH/Contents/Frameworks" \
    "$APP_PATH/Contents/Library/HelperTools" \
    "$APP_PATH/Contents/Library/LaunchDaemons"
cp "$ROOT/Packaging/Juice-Info.plist" "$APP_PATH/Contents/Info.plist"
cp "$ROOT/Packaging/Juice.icns" "$APP_PATH/Contents/Resources/Juice.icns"
cp "$ROOT/Packaging/com.eclinick.juice.helper.plist" \
    "$APP_PATH/Contents/Library/LaunchDaemons/com.eclinick.juice.helper.plist"
plutil -lint "$APP_PATH/Contents/Library/LaunchDaemons/com.eclinick.juice.helper.plist"
ditto "$SPARKLE_FRAMEWORK" "$APP_PATH/Contents/Frameworks/Sparkle.framework"
# Juice is not sandboxed and does not opt in to Sparkle's optional XPC
# services. Remove them from Developer ID release builds before re-signing the
# framework. Local ad-hoc builds retain Sparkle's original signed framework.
if [[ "$SIGNING_IDENTITY" != "-" ]]; then
    rm -rf "$APP_PATH/Contents/Frameworks/Sparkle.framework/Versions/Current/XPCServices"
fi
if [[ ${#APP_BINARIES[@]} -eq 1 ]]; then
    install -m 755 "${APP_BINARIES[0]}" "$APP_PATH/Contents/MacOS/Juice"
    install -m 755 "${HELPER_BINARIES[0]}" \
        "$APP_PATH/Contents/Library/HelperTools/JuiceHelper"
else
    lipo -create "${APP_BINARIES[@]}" -output "$APP_PATH/Contents/MacOS/Juice"
    lipo -create "${HELPER_BINARIES[@]}" \
        -output "$APP_PATH/Contents/Library/HelperTools/JuiceHelper"
    chmod 755 "$APP_PATH/Contents/MacOS/Juice"
    chmod 755 "$APP_PATH/Contents/Library/HelperTools/JuiceHelper"
fi

# SwiftPM gives command-line executables an @loader_path rpath. App bundles
# keep frameworks in Contents/Frameworks, so add the standard app-bundle rpath
# before signing the binary.
install_name_tool -add_rpath @executable_path/../Frameworks "$APP_PATH/Contents/MacOS/Juice"

/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$APP_PATH/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD_NUMBER" "$APP_PATH/Contents/Info.plist"

# The public key is part of the source Info.plist, while the matching private
# key remains only in the release machine's Keychain. Never give locally
# ad-hoc-signed builds a production feed: they cannot safely replace a user's
# installed app. APPCAST_URL is overridable for signed staging releases.
if [[ "$SIGNING_IDENTITY" == "-" ]]; then
    /usr/libexec/PlistBuddy -c "Delete :SUFeedURL" "$APP_PATH/Contents/Info.plist"
else
    /usr/libexec/PlistBuddy -c "Set :SUFeedURL $APPCAST_URL" "$APP_PATH/Contents/Info.plist"
fi

if [[ "$SIGNING_IDENTITY" == "-" ]]; then
    codesign --force --sign - --identifier com.eclinick.juice.helper \
        "$APP_PATH/Contents/Library/HelperTools/JuiceHelper"
    codesign --force --sign - --identifier com.eclinick.juice "$APP_PATH"
else
    # Sign Sparkle's nested helpers from the inside out with a hardened runtime
    # and secure timestamp; --deep alone does not apply those options to every
    # nested component and is rejected by Apple's notarization service.
    SPARKLE_PATH="$APP_PATH/Contents/Frameworks/Sparkle.framework"
    SIGN_OPTIONS=(--force --sign "$SIGNING_IDENTITY" --options runtime --timestamp)
    codesign "${SIGN_OPTIONS[@]}" --identifier com.eclinick.juice.helper \
        "$APP_PATH/Contents/Library/HelperTools/JuiceHelper"
    codesign "${SIGN_OPTIONS[@]}" "$SPARKLE_PATH/Versions/Current/Autoupdate"
    codesign "${SIGN_OPTIONS[@]}" "$SPARKLE_PATH/Versions/Current/Updater.app"
    codesign "${SIGN_OPTIONS[@]}" "$SPARKLE_PATH"
    codesign "${SIGN_OPTIONS[@]}" --identifier com.eclinick.juice "$APP_PATH"
fi

for arch in $ARCHS; do
    lipo "$APP_PATH/Contents/MacOS/Juice" -verify_arch "$arch"
    lipo "$APP_PATH/Contents/Library/HelperTools/JuiceHelper" -verify_arch "$arch"
done
codesign --verify --strict --verbose=2 \
    "$APP_PATH/Contents/Library/HelperTools/JuiceHelper"
codesign --verify --deep --strict --verbose=2 "$APP_PATH"
echo "Built $APP_PATH"
