# Juice repository instructions

## Publishing a release

Use the repository's guarded end-to-end publisher for every public Juice
release:

```bash
make publish VERSION=0.1.2
```

Do not manually create the Git tag or GitHub release first. The publisher
intentionally creates the public release only after tests pass and the app,
helper, DMG, and Sparkle feed have been signed and validated.

Before publishing, validate the release machine without creating artifacts or
changing GitHub/Homebrew state:

```bash
DRY_RUN=1 make publish VERSION=0.1.2
```

The script requires:

- a clean `master` branch exactly synchronized with `origin/master`;
- GitHub CLI authentication with write access to `EClinick/juice` and
  `EClinick/homebrew-tap`;
- the Developer ID identity
  `Developer ID Application: Ethan Clinick (U2MBGTFZM5)`;
- the case-sensitive `notarytool` Keychain profile `JuiceNotary`; and
- Juice's Sparkle EdDSA private key in the release Mac's Keychain.

`Scripts/publish-release.sh` derives the next build number from the latest
public appcast, rejects duplicate or non-increasing versions, runs the tests,
builds and notarizes the release, signs the appcast, creates the GitHub release,
updates the Homebrew cask, and verifies the public DMG, feed, and cask. Never
store Apple or Sparkle private keys, passwords, or API-key contents in this
repository. Keychain profile names and signing identity names are not secrets.

Lower-level `make release-cask` and `make appcast` targets remain useful for
diagnosis, but they do not publish a complete release and should not replace
`make publish` for routine releases.
