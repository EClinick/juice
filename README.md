# Juice

A macOS menu bar app that answers, at a glance: what is my battery doing, and what's eating it?

Juice surfaces the power data macOS already collects but hides from users: live drain wattage, battery health, and (coming soon) per-app energy rankings over the past days with plain-English insights.

## Status

Early development.

- [x] **M1 - Skeleton**: menu bar item with live IOKit readings (charge %, watts drawn/charging, time remaining, health, cycle count)
- [ ] **M2 - Helper**: privileged helper daemon (SMAppService + XPC) to read the system powerlog database
- [ ] **M3 - Store + UI**: local history store, per-app top-hogs list, charge timeline chart
- [ ] **M4 - Insights**: baselines, anomaly detection, charging-habit stats
- [ ] **M5 - Ship**: signed + notarized DMG, Sparkle updates

## Requirements

- macOS 14 (Sonoma) or later
- Swift 6 toolchain (Xcode 16+) to build from source

## Building and running

```bash
swift build
./.build/debug/Juice
```

The app runs as a menu bar item (no Dock icon).
Quit it from the popover's "Quit Juice" button.

## How it works

Live readings come from IOKit's `AppleSmartBattery` service, which requires no special permissions.
Historical per-app energy data will come from the root-only powerlog database at `/var/db/powerlog`, read by a minimal privileged helper that the user approves once in System Settings.
See the design doc for the full architecture.

## License

MIT
