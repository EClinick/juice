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
ARCHS="${ARCHS:-arm64 x86_64}"

DEVELOPMENT_BUILD="${DEVELOPMENT_BUILD:-1}"
[[ "$DEVELOPMENT_BUILD" == "0" || "$DEVELOPMENT_BUILD" == "1" ]] || {
    echo "DEVELOPMENT_BUILD must be 0 or 1" >&2
    exit 1
}

if [[ "$DEVELOPMENT_BUILD" == "1" ]]; then
    APP_BUNDLE_NAME="Juice Dev.app"
    APP_DISPLAY_NAME="Juice Dev"
    APP_BUNDLE_ID="com.eclinick.juice.dev"
    HELPER_LABEL="com.eclinick.juice.dev.helper"
    DAEMON_PLIST="$ROOT/Packaging/com.eclinick.juice.dev.helper.plist"
    BUILD_VARIANT="dev"
else
    APP_BUNDLE_NAME="Juice.app"
    APP_DISPLAY_NAME="Juice"
    APP_BUNDLE_ID="com.eclinick.juice"
    HELPER_LABEL="com.eclinick.juice.helper"
    DAEMON_PLIST="$ROOT/Packaging/com.eclinick.juice.helper.plist"
    BUILD_VARIANT="production"
fi

APP_PATH="$OUTPUT_DIR/$APP_BUNDLE_NAME"
BUILD_ROOT="${BUILD_ROOT:-$ROOT/.build/app-bundle-$BUILD_VARIANT}"
SWIFT_FLAGS=()
if [[ "$DEVELOPMENT_BUILD" == "1" ]]; then
    SWIFT_FLAGS+=(-Xswiftc -DDEV_BUILD)
fi
if [[ "$SIGNING_IDENTITY" == "-" ]]; then
    SWIFT_FLAGS+=(-Xswiftc -DDEV_HELPER)
fi

cd "$ROOT"
APP_BINARIES=()
HELPER_BINARIES=()
SPARKLE_FRAMEWORK=""
for arch in $ARCHS; do
    arch_build_path="$BUILD_ROOT/$CONFIGURATION-$arch"
    # Ad-hoc helpers have no Team ID and use the identifier-only client check.
    # DEV_BUILD independently selects the isolated app/helper/Mach identities.
    if (( ${#SWIFT_FLAGS[@]} > 0 )); then
        swift build -c "$CONFIGURATION" --arch "$arch" \
            --build-path "$arch_build_path" "${SWIFT_FLAGS[@]}"
        bin_path="$(swift build -c "$CONFIGURATION" --arch "$arch" \
            --build-path "$arch_build_path" "${SWIFT_FLAGS[@]}" --show-bin-path)"
    else
        swift build -c "$CONFIGURATION" --arch "$arch" \
            --build-path "$arch_build_path"
        bin_path="$(swift build -c "$CONFIGURATION" --arch "$arch" \
            --build-path "$arch_build_path" --show-bin-path)"
    fi
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
cp "$DAEMON_PLIST" \
    "$APP_PATH/Contents/Library/LaunchDaemons/$HELPER_LABEL.plist"
plutil -lint "$APP_PATH/Contents/Library/LaunchDaemons/$HELPER_LABEL.plist"
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

# SwiftPM linker-signs the native arm64 slice, while the cross-compiled Intel
# slice is unsigned. Strip that inherited per-slice signature before changing
# Mach-O load commands; otherwise install_name_tool can place the new rpath
# after LC_CODE_SIGNATURE in arm64. Newer static verification accepts that
# layout, but macOS 26.3 rejects the running process's dynamic signature.
codesign --remove-signature "$APP_PATH/Contents/MacOS/Juice"

# SwiftPM gives command-line executables an @loader_path rpath. App bundles
# keep frameworks in Contents/Frameworks, so add the standard app-bundle rpath
# before applying one fresh signature to the completed universal executable.
install_name_tool -add_rpath @executable_path/../Frameworks "$APP_PATH/Contents/MacOS/Juice"

/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$APP_PATH/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD_NUMBER" "$APP_PATH/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $APP_BUNDLE_ID" "$APP_PATH/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleDisplayName $APP_DISPLAY_NAME" "$APP_PATH/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleName $APP_DISPLAY_NAME" "$APP_PATH/Contents/Info.plist"

# The public key is part of the source Info.plist, while the matching private
# key remains only in the release machine's Keychain. Never give locally
# ad-hoc-signed builds a production feed: they cannot safely replace a user's
# installed app. APPCAST_URL is overridable for signed staging releases.
if [[ "$SIGNING_IDENTITY" == "-" || "$DEVELOPMENT_BUILD" == "1" ]]; then
    /usr/libexec/PlistBuddy -c "Delete :SUFeedURL" "$APP_PATH/Contents/Info.plist"
else
    /usr/libexec/PlistBuddy -c "Set :SUFeedURL $APPCAST_URL" "$APP_PATH/Contents/Info.plist"
fi

if [[ "$SIGNING_IDENTITY" == "-" ]]; then
    codesign --force --sign - --identifier "$HELPER_LABEL" \
        "$APP_PATH/Contents/Library/HelperTools/JuiceHelper"
    codesign --force --sign - --identifier "$APP_BUNDLE_ID" "$APP_PATH"
else
    # Sign Sparkle's nested helpers from the inside out with a hardened runtime
    # and secure timestamp; --deep alone does not apply those options to every
    # nested component and is rejected by Apple's notarization service.
    SPARKLE_PATH="$APP_PATH/Contents/Frameworks/Sparkle.framework"
    SIGN_OPTIONS=(--force --sign "$SIGNING_IDENTITY" --options runtime --timestamp)
    codesign "${SIGN_OPTIONS[@]}" --identifier "$HELPER_LABEL" \
        "$APP_PATH/Contents/Library/HelperTools/JuiceHelper"
    codesign "${SIGN_OPTIONS[@]}" "$SPARKLE_PATH/Versions/Current/Autoupdate"
    codesign "${SIGN_OPTIONS[@]}" "$SPARKLE_PATH/Versions/Current/Updater.app"
    codesign "${SIGN_OPTIONS[@]}" "$SPARKLE_PATH"
    codesign "${SIGN_OPTIONS[@]}" --identifier "$APP_BUNDLE_ID" "$APP_PATH"
fi

for arch in $ARCHS; do
    lipo "$APP_PATH/Contents/MacOS/Juice" -verify_arch "$arch"
    lipo "$APP_PATH/Contents/Library/HelperTools/JuiceHelper" -verify_arch "$arch"
done
codesign --verify --strict --verbose=2 \
    "$APP_PATH/Contents/Library/HelperTools/JuiceHelper"
codesign --verify --deep --strict --verbose=2 "$APP_PATH"
echo "Built $APP_PATH"
