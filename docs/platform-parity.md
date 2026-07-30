# Platform parity

Juice for macOS and Juice for Windows are maintained as independent native applications.
They share product behavior and public data contracts, but they do not share application code or release versions.

## Repositories

- [EClinick/juice](https://github.com/EClinick/juice) is the canonical product and behavioral source.
- [EClinick/juice-windows](https://github.com/EClinick/juice-windows) owns the Windows implementation, packaging, CI, and releases.

The canonical JSON export contract lives in `contracts/`.
Both repositories must test their output against the same versioned fixtures before claiming support for a contract version.

## Feature workflow

Every product change must be classified as one of:

- `shared-behavior`: observable behavior that should reach both platforms.
- `macos-only`: behavior tied to macOS APIs or product surfaces.
- `windows-followup`: Windows parity work linked to a macOS change.
- `contract-change`: a change to versioned public JSON output.

A shared-behavior pull request should describe the intended cross-platform behavior.
The corresponding Windows issue or pull request should link the exact macOS pull request or release tag it implements.
If Windows intentionally differs, document that difference in the Windows parity table instead of silently drifting.

## Releases

Each repository versions, signs, publishes, and supports its own releases.
A release on one platform does not imply that the other platform is ready.
Windows downloads should only be linked from the main Juice README after the Windows repository has an independently verified installable release.
