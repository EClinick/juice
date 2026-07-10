# Releasing Juice

`make app` produces `dist/Juice.app`, and `make dmg` produces a Finder-ready
`dist/Juice.dmg`. Both commands use an ad-hoc signature unless a signing
identity is supplied.

## Developer ID build

1. Create or download a **Developer ID Application** certificate in Xcode or
   Keychain Access, then confirm it is available with:

   ```bash
   security find-identity -v -p codesigning
   ```

2. Build the disk image with the certificate's exact name:

   ```bash
   SIGNING_IDENTITY="Developer ID Application: Your Name (TEAMID)" \
   VERSION=1.0.0 BUILD_NUMBER=1 make dmg
   ```

3. Submit `dist/Juice.dmg` to Apple's notary service, then staple the approved
   ticket before distribution.

## Homebrew cask

Juice is distributed through the `EClinick/homebrew-tap` cask repository. After
uploading the notarized `Juice.dmg` to a versioned GitHub release, calculate the
checksum and update `Casks/juice.rb` in that tap:

```bash
VERSION=1.0.0 \
SIGNING_IDENTITY="Developer ID Application: Your Name (TEAMID)" \
make release-cask
```

The cask must use the GitHub release asset URL and the printed SHA-256. This
keeps `brew install --cask EClinick/tap/juice` reproducible and tamper-evident.

The release helper derives its own Team ID and only accepts XPC connections
from a `com.eclinick.juice` app signed by that same team. The current
`make dev-helper-install` workflow remains for local development; it is not a
shipping installer. A production installer should register the daemon through
`SMAppService` and surface macOS's approval flow to the user.
