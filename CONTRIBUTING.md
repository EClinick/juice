# Contributing to Juice

Thanks for your interest in contributing.

## Building and testing

```bash
swift build

# Tests need the full Xcode toolchain (the Testing framework is not in
# Command Line Tools).
make test
```

For end-to-end testing against the installed privileged helper, use `make dev-probe`, or `./.build/debug/JuiceXPCProbe --app <bundle-id>` for the per-app breakdown path.
Probe binaries must be re-signed after every build (`make dev-probe` does this for you) because the helper validates client signatures.

## Code conventions

- Match the style of the surrounding code.
- Pure logic (energy math, rollups, insights, breakdowns) belongs in `Sources/JuiceCore` where the test suite can reach it; the `Juice` executable target is not importable by tests.
- No emojis in product UI or code; app rows use real icons via NSWorkspace and system indicators use SF Symbols.

## Documentation conventions

- Never use the em-dash character; use a plain "-" instead.
- In Markdown, put each full sentence on its own line.

## The privileged helper is special

`Sources/JuiceHelper` runs as root.
Any change to it or to the XPC surface (`Sources/JuiceXPCShared`) needs extra scrutiny: keep the helper minimal, keep it read-only, fail closed, and do not widen the API surface without a strong reason.

## Displayed numbers are sacred

Juice's core promise is that displayed energy values are true.
Changes touching energy math, rollup logic, or chart rendering must be verified against raw powerlog data (independent SQL over the source database), not just against unit tests.
Charts must stay honest: axes pinned to the requested window, recording gaps rendered as gaps, no interpolation across missing data.
