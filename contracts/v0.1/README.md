# Juice JSON export contract 0.1

This directory is the language-neutral contract for `juice --json=0.1`.
It defines observable output, not application implementation, storage, or measurement algorithms.

Files:

- `juice-export.schema.json`: formal JSON Schema for command output.
- `examples/now-windows.json`: measured live power with unavailable rails omitted.
- `examples/top-windows.json`: attributed energy whose totals reconcile.
- `examples/no-power-source.json`: machine-readable failure envelope.

Contract rules:

1. Every document contains `schemaVersion`, `platform`, `command`, `generatedAt`, and `ok`.
2. Consumers branch on `ok` before reading command-specific payload.
3. Unknown measurements are omitted rather than emitted as zero.
4. Measurement provenance is explicit.
5. App energy plus platform overhead equals measured system energy.
6. Cost includes the rate and whether that rate is an estimate.
7. `error.code` is stable within a schema version; `error.message` is for humans and must not be parsed.

While the contract is `0.x`, consumers should pin the exact supported version.
After `1.0`, additive fields may be introduced within the same major version and consumers must ignore fields they do not understand.
