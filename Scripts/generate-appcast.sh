#!/usr/bin/env bash
set -euo pipefail

# Generate the signed Sparkle appcast from the release archives in dist/. The
# private EdDSA key is deliberately never read from the repository: by default
# Sparkle reads it from the release machine's Keychain, or CI can provide it
# through SPARKLE_PRIVATE_ED_KEY.
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ARCHIVES_DIR="${APPCAST_ARCHIVES_DIR:-$ROOT/dist}"
DOWNLOAD_URL_PREFIX="${APPCAST_DOWNLOAD_URL_PREFIX:?Set APPCAST_DOWNLOAD_URL_PREFIX to the versioned GitHub release asset URL prefix}"
RELEASE_PAGE_URL="${APPCAST_RELEASE_PAGE_URL:-https://github.com/EClinick/juice/releases}"
GENERATE_APPCAST="${SPARKLE_GENERATE_APPCAST:-$ROOT/.build/artifacts/sparkle/Sparkle/bin/generate_appcast}"

if [[ ! -d "$ARCHIVES_DIR" ]]; then
    echo "Release archive directory does not exist: $ARCHIVES_DIR" >&2
    exit 1
fi

# Fetch Sparkle's binary tools if this is the first appcast generated from a
# fresh checkout. The app build itself also performs this step.
if [[ ! -x "$GENERATE_APPCAST" ]]; then
    swift build >/dev/null
fi

if [[ ! -x "$GENERATE_APPCAST" ]]; then
    echo "Could not locate Sparkle's generate_appcast tool: $GENERATE_APPCAST" >&2
    exit 1
fi

args=(
    --download-url-prefix "$DOWNLOAD_URL_PREFIX"
    --link "$RELEASE_PAGE_URL"
    --maximum-versions 3
    --auto-prune-update-files
    "$ARCHIVES_DIR"
)

if [[ -n "${SPARKLE_PRIVATE_ED_KEY:-}" ]]; then
    printf '%s' "$SPARKLE_PRIVATE_ED_KEY" | "$GENERATE_APPCAST" --ed-key-file - "${args[@]}"
else
    "$GENERATE_APPCAST" "${args[@]}"
fi
