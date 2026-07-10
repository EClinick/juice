#!/bin/bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
REPO="${REPO:-EClinick/juice}"
TAP_REPO="${TAP_REPO:-EClinick/homebrew-tap}"
RELEASE_BRANCH="${RELEASE_BRANCH:-master}"
SIGNING_IDENTITY="${SIGNING_IDENTITY:-Developer ID Application: Ethan Clinick (U2MBGTFZM5)}"
NOTARY_PROFILE="${NOTARY_PROFILE:-JuiceNotary}"
DRY_RUN="${DRY_RUN:-0}"
VERSION="${VERSION:-}"
TAG="v${VERSION}"
DMG_PATH="$ROOT_DIR/dist/Juice.dmg"
APPCAST_PATH="$ROOT_DIR/dist/appcast.xml"
LATEST_APPCAST_URL="https://github.com/$REPO/releases/latest/download/appcast.xml"

die() {
    echo "error: $*" >&2
    exit 1
}

require_command() {
    command -v "$1" >/dev/null 2>&1 || die "Required command not found: $1"
}

is_strictly_newer_version() {
    local candidate_major candidate_minor candidate_patch
    local current_major current_minor current_patch

    IFS=. read -r candidate_major candidate_minor candidate_patch <<< "$1"
    IFS=. read -r current_major current_minor current_patch <<< "$2"

    if (( 10#$candidate_major != 10#$current_major )); then
        (( 10#$candidate_major > 10#$current_major ))
    elif (( 10#$candidate_minor != 10#$current_minor )); then
        (( 10#$candidate_minor > 10#$current_minor ))
    else
        (( 10#$candidate_patch > 10#$current_patch ))
    fi
}

wait_for_public_appcast_version() {
    local url="$1"
    local destination="$2"
    local expected_version="$3"
    local attempt
    local published_version

    for attempt in 1 2 3 4 5 6 7 8 9 10; do
        if curl -fsSL "$url" -o "$destination" && xmllint --noout "$destination" 2>/dev/null; then
            published_version="$(xmllint --xpath 'string((//*[local-name()="item"]/*[local-name()="shortVersionString"])[1])' "$destination")"
            if [[ "$published_version" == "$expected_version" ]]; then
                return 0
            fi
        fi
        sleep 2
    done

    return 1
}

[[ -n "$VERSION" ]] || die "Set VERSION, for example: make publish VERSION=0.1.2"
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || \
    die "VERSION must be a stable semantic version such as 0.1.2"
[[ "$DRY_RUN" == "0" || "$DRY_RUN" == "1" ]] || die "DRY_RUN must be 0 or 1"

for command in awk cmp codesign curl ditto gh git grep hdiutil lipo make otool perl plutil rg ruby security sed shasum spctl strings swift xcrun xmllint; do
    require_command "$command"
done

cd "$ROOT_DIR"
[[ "$(git rev-parse --show-toplevel)" == "$ROOT_DIR" ]] || die "Run this from the Juice repository"
[[ -z "$(git status --porcelain)" ]] || die "The working tree must be clean before publishing"
[[ "$(git branch --show-current)" == "$RELEASE_BRANCH" ]] || \
    die "Publishing is only allowed from the $RELEASE_BRANCH branch"

echo "Running release preflight for Juice $VERSION..."
gh auth status >/dev/null
[[ "$(gh api "repos/$REPO" --jq '.permissions.push')" == "true" ]] || \
    die "GitHub account does not have push access to $REPO"
[[ "$(gh api "repos/$TAP_REPO" --jq '.permissions.push')" == "true" ]] || \
    die "GitHub account does not have push access to $TAP_REPO"
git fetch --quiet origin "$RELEASE_BRANCH" --tags

LOCAL_HEAD="$(git rev-parse HEAD)"
REMOTE_HEAD="$(git rev-parse "origin/$RELEASE_BRANCH")"
[[ "$LOCAL_HEAD" == "$REMOTE_HEAD" ]] || \
    die "Local $RELEASE_BRANCH must exactly match origin/$RELEASE_BRANCH"

if git show-ref --verify --quiet "refs/tags/$TAG" || \
    git ls-remote --exit-code --tags origin "refs/tags/$TAG" >/dev/null 2>&1; then
    die "Tag $TAG already exists"
fi

if gh release view "$TAG" --repo "$REPO" >/dev/null 2>&1; then
    die "GitHub release $TAG already exists"
fi

security find-identity -v -p codesigning | grep -F "\"$SIGNING_IDENTITY\"" >/dev/null || \
    die "Developer ID signing identity is unavailable: $SIGNING_IDENTITY"
xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" >/dev/null || \
    die "Notary Keychain profile is unavailable: $NOTARY_PROFILE"
if [[ -z "${SPARKLE_PRIVATE_ED_KEY:-}" ]]; then
    security find-generic-password \
        -s "https://sparkle-project.org" \
        -a "ed25519" >/dev/null 2>&1 || \
        die "Sparkle EdDSA signing key is unavailable in Keychain"
fi

TEMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/juice-publish.XXXXXX")"
trap 'rm -rf "$TEMP_DIR"' EXIT

curl -fsSL "$LATEST_APPCAST_URL" -o "$TEMP_DIR/latest-appcast.xml" || \
    die "Could not download the latest public appcast"
xmllint --noout "$TEMP_DIR/latest-appcast.xml"

LATEST_VERSION="$(xmllint --xpath 'string((//*[local-name()="item"]/*[local-name()="shortVersionString"])[1])' "$TEMP_DIR/latest-appcast.xml")"
LATEST_BUILD="$(xmllint --xpath 'string((//*[local-name()="item"]/*[local-name()="version"])[1])' "$TEMP_DIR/latest-appcast.xml")"
[[ "$LATEST_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "Latest appcast has an invalid version: $LATEST_VERSION"
[[ "$LATEST_BUILD" =~ ^[0-9]+$ ]] || die "Latest appcast has an invalid build number: $LATEST_BUILD"
is_strictly_newer_version "$VERSION" "$LATEST_VERSION" || \
    die "VERSION $VERSION must be newer than the latest public version $LATEST_VERSION"

BUILD_NUMBER="${BUILD_NUMBER:-$((10#$LATEST_BUILD + 1))}"
[[ "$BUILD_NUMBER" =~ ^[0-9]+$ ]] || die "BUILD_NUMBER must be an integer"
(( 10#$BUILD_NUMBER > 10#$LATEST_BUILD )) || \
    die "BUILD_NUMBER $BUILD_NUMBER must be greater than the latest public build $LATEST_BUILD"

echo "  Repository:       $REPO"
echo "  Commit:           $LOCAL_HEAD"
echo "  Version:          $LATEST_VERSION -> $VERSION"
echo "  Build:            $LATEST_BUILD -> $BUILD_NUMBER"
echo "  Signing identity: $SIGNING_IDENTITY"
echo "  Notary profile:   $NOTARY_PROFILE"
echo "  Homebrew tap:     $TAP_REPO"

if [[ "$DRY_RUN" == "1" ]]; then
    echo "Preflight passed. DRY_RUN=1, so no artifacts or releases were created."
    exit 0
fi

echo "Running tests..."
make test

echo "Building, signing, notarizing, and stapling the release..."
VERSION="$VERSION" \
BUILD_NUMBER="$BUILD_NUMBER" \
SIGNING_IDENTITY="$SIGNING_IDENTITY" \
NOTARY_PROFILE="$NOTARY_PROFILE" \
    "$ROOT_DIR/Scripts/release-cask.sh"

[[ -f "$DMG_PATH" ]] || die "Release build did not produce $DMG_PATH"
DMG_SHA256="$(shasum -a 256 "$DMG_PATH" | awk '{print $1}')"

echo "Generating the signed Sparkle appcast..."
APPCAST_DOWNLOAD_URL_PREFIX="https://github.com/$REPO/releases/download/$TAG/" \
APPCAST_RELEASE_PAGE_URL="https://github.com/$REPO/releases/tag/$TAG" \
    "$ROOT_DIR/Scripts/generate-appcast.sh"

[[ -f "$APPCAST_PATH" ]] || die "Appcast generation did not produce $APPCAST_PATH"
xmllint --noout "$APPCAST_PATH"

APPCAST_VERSION="$(xmllint --xpath 'string((//*[local-name()="item"]/*[local-name()="shortVersionString"])[1])' "$APPCAST_PATH")"
APPCAST_BUILD="$(xmllint --xpath 'string((//*[local-name()="item"]/*[local-name()="version"])[1])' "$APPCAST_PATH")"
APPCAST_URL="$(xmllint --xpath 'string((//*[local-name()="item"][1]/*[local-name()="enclosure"])[1]/@url)' "$APPCAST_PATH")"
APPCAST_SIGNATURE="$(xmllint --xpath 'string((//*[local-name()="item"][1]/*[local-name()="enclosure"])[1]/@*[local-name()="edSignature"])' "$APPCAST_PATH")"

[[ "$APPCAST_VERSION" == "$VERSION" ]] || die "Appcast version is $APPCAST_VERSION, expected $VERSION"
[[ "$APPCAST_BUILD" == "$BUILD_NUMBER" ]] || die "Appcast build is $APPCAST_BUILD, expected $BUILD_NUMBER"
[[ "$APPCAST_URL" == "https://github.com/$REPO/releases/download/$TAG/Juice.dmg" ]] || \
    die "Appcast download URL is incorrect: $APPCAST_URL"
[[ -n "$APPCAST_SIGNATURE" ]] || die "The appcast does not contain a Sparkle EdDSA signature"

echo "Preparing the Homebrew cask update..."
TAP_DIR="$TEMP_DIR/homebrew-tap"
gh repo clone "$TAP_REPO" "$TAP_DIR" -- --quiet
CASK_PATH="$TAP_DIR/Casks/juice.rb"
[[ -f "$CASK_PATH" ]] || die "Homebrew cask not found: Casks/juice.rb"

VERSION="$VERSION" DMG_SHA256="$DMG_SHA256" perl -0pi -e \
    's/^  version "[^"]+"/  version "$ENV{VERSION}"/m; s/^  sha256 "[^"]+"/  sha256 "$ENV{DMG_SHA256}"/m' \
    "$CASK_PATH"
grep -F "version \"$VERSION\"" "$CASK_PATH" >/dev/null || die "Failed to update the cask version"
grep -F "sha256 \"$DMG_SHA256\"" "$CASK_PATH" >/dev/null || die "Failed to update the cask checksum"
(cd "$TAP_DIR" && git diff --check && ruby -c Casks/juice.rb >/dev/null)
(cd "$TAP_DIR" && git add Casks/juice.rb && git commit -m "Update Juice to $VERSION" >/dev/null)

echo "Creating GitHub release $TAG..."
gh release create "$TAG" \
    "$DMG_PATH" \
    "$APPCAST_PATH" \
    --repo "$REPO" \
    --target "$RELEASE_BRANCH" \
    --title "Juice $VERSION" \
    --generate-notes

echo "Publishing the Homebrew cask update..."
(cd "$TAP_DIR" && git push origin HEAD)

echo "Verifying public release assets..."
PUBLIC_DIR="$TEMP_DIR/public"
mkdir -p "$PUBLIC_DIR"
gh release download "$TAG" --repo "$REPO" --dir "$PUBLIC_DIR" --pattern Juice.dmg --pattern appcast.xml
PUBLIC_SHA256="$(shasum -a 256 "$PUBLIC_DIR/Juice.dmg" | awk '{print $1}')"
[[ "$PUBLIC_SHA256" == "$DMG_SHA256" ]] || die "Published DMG checksum does not match the notarized artifact"
cmp -s "$APPCAST_PATH" "$PUBLIC_DIR/appcast.xml" || die "Published appcast does not match the generated appcast"

wait_for_public_appcast_version "$LATEST_APPCAST_URL" "$TEMP_DIR/public-latest-appcast.xml" "$VERSION" || \
    die "The latest appcast URL did not become available"

TAP_CASK_CONTENT="$(gh api -H "Accept: application/vnd.github.raw+json" "repos/$TAP_REPO/contents/Casks/juice.rb")"
grep -F "version \"$VERSION\"" <<< "$TAP_CASK_CONTENT" >/dev/null || die "Published cask has the wrong version"
grep -F "sha256 \"$DMG_SHA256\"" <<< "$TAP_CASK_CONTENT" >/dev/null || die "Published cask has the wrong checksum"

echo
echo "Juice $VERSION (build $BUILD_NUMBER) is published."
echo "Release: https://github.com/$REPO/releases/tag/$TAG"
echo "DMG SHA-256: $DMG_SHA256"
