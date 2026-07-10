#!/usr/bin/env bash
set -euo pipefail

# Build a universal, Developer ID-signed DMG and print the checksum required by
# a Homebrew cask. This intentionally refuses ad-hoc signing: downloadable
# releases should pass Gatekeeper before a cask points users at them.
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VERSION="${VERSION:?Set VERSION, for example VERSION=0.1.0}"
SIGNING_IDENTITY="${SIGNING_IDENTITY:?Set SIGNING_IDENTITY to your Developer ID Application certificate}"

if [[ "$SIGNING_IDENTITY" == "-" ]]; then
    echo "A Developer ID Application certificate is required for public releases." >&2
    exit 1
fi

cd "$ROOT"
VERSION="$VERSION" SIGNING_IDENTITY="$SIGNING_IDENTITY" make dmg
shasum -a 256 "dist/Juice.dmg"
