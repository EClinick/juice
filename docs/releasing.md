# Releasing Juice

`make app` produces the isolated `dist/Juice Dev.app`; the release pipeline
produces `dist/Juice.app`, and `make dmg` produces a Finder-ready development
`dist/Juice Dev.dmg`. The development app target requires a Developer ID identity
for its privileged helper; `make app-adhoc` is available for packaging-only
inspection. Production `Juice.dmg` artifacts are produced only by the signed
release pipeline.

## Routine release

Once the one-time credentials below are installed on the release Mac, validate
and publish a new stable semantic version with:

```bash
DRY_RUN=1 make publish VERSION=0.1.2
make publish VERSION=0.1.2
```

`DRY_RUN=1` checks the branch, GitHub access, signing identity, notarization
profile, current public version, and proposed build number without building or
publishing anything. The full command then:

1. runs the test suite;
2. signs the app and bundled helper, notarizes and staples the app and DMG;
3. creates and validates the signed Sparkle appcast;
4. prepares the matching Homebrew cask version and SHA-256;
5. creates the GitHub tag/release and uploads `Juice.dmg` and `appcast.xml`;
6. pushes the cask update to `EClinick/homebrew-tap`; and
7. downloads the public assets again to verify their contents and checksum.

The public release is deliberately created only after all local artifacts pass
validation. If a later network write fails, inspect which remote write
succeeded before retrying; never delete or overwrite an already published tag
without first confirming that no users received it.

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
   NOTARY_PROFILE="JuiceNotary" \
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

4. `make publish` uploads the final DMG and `appcast.xml` to the GitHub release.
   The stable appcast URL is:

   ```text
   https://github.com/EClinick/juice/releases/latest/download/appcast.xml
   ```

   Sparkle uses that signed feed for both automatic updates and the app's
   manual “Check for Updates…” action, so Homebrew users do not need to run
   `brew update` to receive a newer Juice version.

## Homebrew cask

Juice is distributed through the `EClinick/homebrew-tap` cask repository.
`make publish` updates `Casks/juice.rb` with the release version and the
notarized DMG's SHA-256, validates the Ruby syntax, commits it, and pushes it
only after the GitHub release succeeds. This keeps
`brew install --cask EClinick/tap/juice` reproducible and tamper-evident.

`make release-cask` and `make appcast` are lower-level diagnostic targets. They
can recreate local artifacts but do not create the GitHub release or update the
tap; use `make publish` for normal releases.

The release helper derives its own Team ID and only accepts XPC connections
from a `com.eclinick.juice` app signed by that same team. It is bundled under
`Contents/Library/HelperTools`, described by the plist under
`Contents/Library/LaunchDaemons`, and registered through `SMAppService`.
`make dev-helper-install` remains only for running the raw SwiftPM executable.
Before testing a packaged app, run `make dev-helper-uninstall`; the legacy job
uses the same Mach service and otherwise invalidates the test. Perform the final
registration, admin-approval, reboot, and update checks from a clean macOS VM.
