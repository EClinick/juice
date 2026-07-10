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
OUTPUT_DIR="${OUTPUT_DIR:-$ROOT/dist}"
APP_PATH="$OUTPUT_DIR/Juice.app"
ARCHS="${ARCHS:-arm64 x86_64}"
BUILD_ROOT="${BUILD_ROOT:-$ROOT/.build/app-bundle}"

cd "$ROOT"
BINARIES=()
for arch in $ARCHS; do
    arch_build_path="$BUILD_ROOT/$CONFIGURATION-$arch"
    swift build -c "$CONFIGURATION" --arch "$arch" --build-path "$arch_build_path"
    bin_path="$(swift build -c "$CONFIGURATION" --arch "$arch" \
        --build-path "$arch_build_path" --show-bin-path)"
    BINARIES+=("$bin_path/Juice")
done

"$ROOT/Scripts/create-icon.sh"

rm -rf "$APP_PATH"
mkdir -p "$APP_PATH/Contents/MacOS" "$APP_PATH/Contents/Resources"
cp "$ROOT/Packaging/Juice-Info.plist" "$APP_PATH/Contents/Info.plist"
cp "$ROOT/Packaging/Juice.icns" "$APP_PATH/Contents/Resources/Juice.icns"
if [[ ${#BINARIES[@]} -eq 1 ]]; then
    install -m 755 "${BINARIES[0]}" "$APP_PATH/Contents/MacOS/Juice"
else
    lipo -create "${BINARIES[@]}" -output "$APP_PATH/Contents/MacOS/Juice"
    chmod 755 "$APP_PATH/Contents/MacOS/Juice"
fi

/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$APP_PATH/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD_NUMBER" "$APP_PATH/Contents/Info.plist"

if [[ "$SIGNING_IDENTITY" == "-" ]]; then
    codesign --force --sign - --identifier com.eclinick.juice "$APP_PATH"
else
    codesign --force --sign "$SIGNING_IDENTITY" --options runtime --timestamp \
        --identifier com.eclinick.juice "$APP_PATH"
fi

codesign --verify --deep --strict --verbose=2 "$APP_PATH"
echo "Built $APP_PATH"
