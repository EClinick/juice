# Releasing Juice

`make app` produces `dist/Juice.app`, and `make dmg` produces a Finder-ready
`dist/Juice.dmg`. Both commands use an ad-hoc signature unless a signing
identity is supplied.

## One-time Sparkle setup

Generate an EdDSA key pair on the release Mac:

```bash
swift build
.build/artifacts/sparkle/Sparkle/bin/generate_keys
```

Keep the generated private key in Keychain (or a CI secret store) only. Copy
the printed public key into `Packaging/Juice-Info.plist` as `SUPublicEDKey`.
The public key is expected to be in the app bundle; it cannot sign releases.

To rotate the key, first ship a transitional release containing the new public
key, but sign that release's appcast with the old private key. Only after users
can install that transitional release may later appcasts be signed with the new
private key. Retain the old private key until the transition is complete.

## Developer ID build

1. Create or download a **Developer ID Application** certificate in Xcode or
   Keychain Access, then confirm it is available with:

   ```bash
   security find-identity -v -p codesigning
   ```

2. Store App Store Connect credentials in a `notarytool` Keychain profile, then
   build, verify, notarize, and staple the release with the certificate's exact
   name:

   ```bash
   SIGNING_IDENTITY="Developer ID Application: Your Name (TEAMID)" \
   NOTARY_PROFILE="juice-notary" \
   VERSION=1.0.0 BUILD_NUMBER=1 make release-cask
   ```

   The release command verifies the bundled SMAppService daemon, notarizes and
   staples Juice.app, packages that exact app without rebuilding it, then
   notarizes and staples the DMG. Apps containing launch daemons must be
   notarized; do not publish a `make dmg` development artifact.

3. Sign the release with Sparkle. Juice's EdDSA public key is embedded in its
   Info.plist; its private counterpart must remain in the release machine's
   Keychain or CI secret store. Generate the feed from the final notarized and
   stapled DMG:

   ```bash
   make appcast \
     APPCAST_DOWNLOAD_URL_PREFIX="https://github.com/EClinick/juice/releases/download/v1.0.0/"
   ```

   `generate_appcast` reads the private key from the release machine's
   Keychain (or `SPARKLE_PRIVATE_ED_KEY` in CI), creates `dist/appcast.xml`,
   and adds each DMG's `sparkle:edSignature`. Do not publish an unsigned
   appcast.

4. Upload the final DMG and `appcast.xml` to the GitHub release. The stable
   appcast URL is:

   ```text
   https://github.com/EClinick/juice/releases/latest/download/appcast.xml
   ```

   Sparkle uses that signed feed for both automatic updates and the app's
   manual “Check for Updates…” action, so Homebrew users do not need to run
   `brew update` to receive a newer Juice version.

## Homebrew cask

Juice is distributed through the `EClinick/homebrew-tap` cask repository. After
uploading the notarized `Juice.dmg` to a versioned GitHub release, calculate the
checksum and update `Casks/juice.rb` in that tap:

```bash
VERSION=1.0.0 \
SIGNING_IDENTITY="Developer ID Application: Your Name (TEAMID)" \
NOTARY_PROFILE="juice-notary" \
make release-cask
```

The cask must use the GitHub release asset URL and the printed SHA-256. This
keeps `brew install --cask EClinick/tap/juice` reproducible and tamper-evident.

The release helper derives its own Team ID and only accepts XPC connections
from a `com.eclinick.juice` app signed by that same team. It is bundled under
`Contents/Library/HelperTools`, described by the plist under
`Contents/Library/LaunchDaemons`, and registered through `SMAppService`.
`make dev-helper-install` remains only for running the raw SwiftPM executable.
Before testing a packaged app, run `make dev-helper-uninstall`; the legacy job
uses the same Mach service and otherwise invalidates the test. Perform the final
registration, admin-approval, reboot, and update checks from a clean macOS VM.
