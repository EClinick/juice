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
SPARKLE_PUBLIC_ED_KEY="${SPARKLE_PUBLIC_ED_KEY:-}"
OUTPUT_DIR="${OUTPUT_DIR:-$ROOT/dist}"
APP_PATH="$OUTPUT_DIR/Juice.app"
ARCHS="${ARCHS:-arm64 x86_64}"
BUILD_ROOT="${BUILD_ROOT:-$ROOT/.build/app-bundle}"

cd "$ROOT"
BINARIES=()
SPARKLE_FRAMEWORK=""
for arch in $ARCHS; do
    arch_build_path="$BUILD_ROOT/$CONFIGURATION-$arch"
    swift build -c "$CONFIGURATION" --arch "$arch" --build-path "$arch_build_path"
    bin_path="$(swift build -c "$CONFIGURATION" --arch "$arch" \
        --build-path "$arch_build_path" --show-bin-path)"
    BINARIES+=("$bin_path/Juice")
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
mkdir -p "$APP_PATH/Contents/MacOS" "$APP_PATH/Contents/Resources" "$APP_PATH/Contents/Frameworks"
cp "$ROOT/Packaging/Juice-Info.plist" "$APP_PATH/Contents/Info.plist"
cp "$ROOT/Packaging/Juice.icns" "$APP_PATH/Contents/Resources/Juice.icns"
ditto "$SPARKLE_FRAMEWORK" "$APP_PATH/Contents/Frameworks/Sparkle.framework"
if [[ ${#BINARIES[@]} -eq 1 ]]; then
    install -m 755 "${BINARIES[0]}" "$APP_PATH/Contents/MacOS/Juice"
else
    lipo -create "${BINARIES[@]}" -output "$APP_PATH/Contents/MacOS/Juice"
    chmod 755 "$APP_PATH/Contents/MacOS/Juice"
fi

# SwiftPM gives command-line executables an @loader_path rpath. App bundles
# keep frameworks in Contents/Frameworks, so add the standard app-bundle rpath
# before signing the binary.
install_name_tool -add_rpath @executable_path/../Frameworks "$APP_PATH/Contents/MacOS/Juice"

/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$APP_PATH/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD_NUMBER" "$APP_PATH/Contents/Info.plist"

# Sparkle verifies every downloaded release with this EdDSA public key. Do not
# enable the updater in locally ad-hoc-signed builds: they cannot safely ship a
# matching signed appcast. Public releases must provide the key explicitly.
if [[ -n "$SPARKLE_PUBLIC_ED_KEY" ]]; then
    /usr/libexec/PlistBuddy -c "Add :SUFeedURL string $APPCAST_URL" "$APP_PATH/Contents/Info.plist"
    /usr/libexec/PlistBuddy -c "Add :SUPublicEDKey string $SPARKLE_PUBLIC_ED_KEY" "$APP_PATH/Contents/Info.plist"
elif [[ "$SIGNING_IDENTITY" != "-" ]]; then
    echo "SPARKLE_PUBLIC_ED_KEY is required for a signed release build." >&2
    exit 1
else
    echo "Sparkle updater disabled (set SPARKLE_PUBLIC_ED_KEY to enable it in a release build)."
fi

if [[ "$SIGNING_IDENTITY" == "-" ]]; then
    codesign --force --sign - --identifier com.eclinick.juice "$APP_PATH"
else
    codesign --force --sign "$SIGNING_IDENTITY" --options runtime --timestamp \
        --identifier com.eclinick.juice "$APP_PATH"
fi

codesign --verify --deep --strict --verbose=2 "$APP_PATH"
echo "Built $APP_PATH"
