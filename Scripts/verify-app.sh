#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_PATH="${1:-$ROOT/dist/Juice.app}"
BUILD_VARIANT="${2:-production}"
case "$BUILD_VARIANT" in
    production)
        EXPECTED_APP_ID="com.eclinick.juice"
        EXPECTED_HELPER_LABEL="com.eclinick.juice.helper"
        OPPOSITE_APP_ID="com.eclinick.juice.dev"
        OPPOSITE_HELPER_LABEL="com.eclinick.juice.dev.helper"
        ;;
    development)
        EXPECTED_APP_ID="com.eclinick.juice.dev"
        EXPECTED_HELPER_LABEL="com.eclinick.juice.dev.helper"
        OPPOSITE_APP_ID="com.eclinick.juice"
        OPPOSITE_HELPER_LABEL="com.eclinick.juice.helper"
        ;;
    *)
        echo "verify-app: build variant must be production or development" >&2
        exit 1
        ;;
esac
PLIST="$APP_PATH/Contents/Library/LaunchDaemons/$EXPECTED_HELPER_LABEL.plist"
APP_BINARY="$APP_PATH/Contents/MacOS/Juice"

fail() {
    echo "verify-app: $*" >&2
    exit 1
}

binary_contains_exact() {
    local binary="$1"
    local value="$2"
    grep -Fqx "$value" < <(strings "$binary")
}

[[ -d "$APP_PATH" ]] || fail "app bundle not found at $APP_PATH"
[[ -x "$APP_BINARY" ]] || fail "main executable is missing"
[[ -f "$PLIST" ]] || fail "bundled launch-daemon plist is missing"
plutil -lint "$PLIST" >/dev/null

label="$(/usr/libexec/PlistBuddy -c 'Print :Label' "$PLIST")"
[[ "$label" == "$EXPECTED_HELPER_LABEL" ]] || fail "unexpected daemon label: $label"

bundle_id="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$APP_PATH/Contents/Info.plist")"
[[ "$bundle_id" == "$EXPECTED_APP_ID" ]] || fail "unexpected app bundle identifier: $bundle_id"

bundle_program="$(/usr/libexec/PlistBuddy -c 'Print :BundleProgram' "$PLIST")"
[[ -n "$bundle_program" && "$bundle_program" != /* ]] || \
    fail "BundleProgram must be an app-relative path"
if /usr/libexec/PlistBuddy -c 'Print :Program' "$PLIST" >/dev/null 2>&1; then
    fail "production daemon plist must not contain a legacy absolute Program"
fi

mach_service="$(/usr/libexec/PlistBuddy \
    -c "Print :MachServices:$EXPECTED_HELPER_LABEL" "$PLIST")"
[[ "$mach_service" == "true" ]] || fail "helper Mach service is not enabled"

HELPER_BINARY="$APP_PATH/$bundle_program"
[[ -x "$HELPER_BINARY" ]] || fail "BundleProgram does not resolve to an executable"

# Verify the compile-time JuiceXPC constants, not only mutable plist/signature
# metadata. A mismatched binary would connect to the other variant's service.
for binary in "$APP_BINARY" "$HELPER_BINARY"; do
    binary_contains_exact "$binary" "$EXPECTED_APP_ID" || \
        fail "$(basename "$binary") lacks compiled app identity $EXPECTED_APP_ID"
    binary_contains_exact "$binary" "$EXPECTED_HELPER_LABEL" || \
        fail "$(basename "$binary") lacks compiled helper identity $EXPECTED_HELPER_LABEL"
    if binary_contains_exact "$binary" "$OPPOSITE_APP_ID" || \
       binary_contains_exact "$binary" "$OPPOSITE_HELPER_LABEL"; then
        fail "$(basename "$binary") contains the opposite build variant's identities"
    fi
done

app_archs="$(lipo -archs "$APP_BINARY")"
helper_archs="$(lipo -archs "$HELPER_BINARY")"
[[ "$app_archs" == "$helper_archs" ]] || \
    fail "architecture mismatch (app: $app_archs; helper: $helper_archs)"
if [[ "$BUILD_VARIANT" == "production" ]]; then
    for required_arch in arm64 x86_64; do
        lipo "$APP_BINARY" -verify_arch "$required_arch" || \
            fail "main executable is missing required architecture $required_arch"
        lipo "$HELPER_BINARY" -verify_arch "$required_arch" || \
            fail "helper is missing required architecture $required_arch"
    done
fi
for required_arch in $app_archs; do
    # The app-bundle rpath must be part of the signed Mach-O layout. A stale
    # linker signature before this rpath passes static codesign verification on
    # newer macOS versions but is rejected when the process is loaded on 26.3.
    if ! otool -arch "$required_arch" -l "$APP_BINARY" | awk '
        $1 == "cmd" {
            current_command = $2
            if ($2 == "LC_CODE_SIGNATURE") signature_line = NR
        }
        current_command == "LC_RPATH" &&
            $1 == "path" && $2 == "@executable_path/../Frameworks" {
            framework_rpath_line = NR
        }
        END {
            exit !(framework_rpath_line > 0 &&
                signature_line > framework_rpath_line)
        }
    '; then
        fail "$required_arch app-bundle rpath must precede LC_CODE_SIGNATURE"
    fi
done

codesign --verify --strict --verbose=2 "$HELPER_BINARY"
codesign --verify --deep --strict --verbose=2 "$APP_PATH"

app_signing="$(codesign -dvvv "$APP_PATH" 2>&1)"
helper_signing="$(codesign -dvvv "$HELPER_BINARY" 2>&1)"
app_identifier="$(sed -n 's/^Identifier=//p' <<<"$app_signing")"
helper_identifier="$(sed -n 's/^Identifier=//p' <<<"$helper_signing")"
[[ "$app_identifier" == "$EXPECTED_APP_ID" ]] || \
    fail "unexpected app signing identifier: $app_identifier"
[[ "$helper_identifier" == "$EXPECTED_HELPER_LABEL" ]] || \
    fail "unexpected helper signing identifier: $helper_identifier"

app_team="$(sed -n 's/^TeamIdentifier=//p' <<<"$app_signing")"
helper_team="$(sed -n 's/^TeamIdentifier=//p' <<<"$helper_signing")"
if [[ -n "$app_team" && "$app_team" != "not set" ]]; then
    [[ "$helper_team" == "$app_team" ]] || \
        fail "app/helper Team IDs differ ($app_team vs $helper_team)"
    grep -q 'flags=.*runtime' <<<"$app_signing" || fail "app lacks hardened runtime"
    grep -q 'flags=.*runtime' <<<"$helper_signing" || fail "helper lacks hardened runtime"
    strings "$HELPER_BINARY" | grep -Fq \
        'JUICE_HELPER_SECURITY_MODE=PRODUCTION_TEAM_ID_PINNED' || \
        fail "Developer ID helper was not compiled with Team ID-pinned security"
    if strings "$HELPER_BINARY" | grep -Fq \
        'JUICE_HELPER_SECURITY_MODE=DEVELOPMENT_IDENTIFIER_ONLY'; then
        fail "Developer ID helper contains the weak development security mode"
    fi
else
    strings "$HELPER_BINARY" | grep -Fq \
        'JUICE_HELPER_SECURITY_MODE=DEVELOPMENT_IDENTIFIER_ONLY' || \
        fail "ad-hoc helper was not compiled for local development"
fi

if rg -n 'Sample data - helper not connected|Visual Studio Code.*, energyWh: 56\.7' \
    "$ROOT/Sources" >/dev/null; then
    fail "production source still contains the former hardcoded sample dataset"
fi

echo "Verified $APP_PATH"
echo "Architectures: $app_archs"
echo "Signing team: ${app_team:-ad-hoc}"
