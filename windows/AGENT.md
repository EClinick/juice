# Windows port instructions

Rules for anyone, human or agent, working in `windows/`.
The root `AGENT.md` covers the macOS release process and still applies to that tree.

## Build the architecture you are running on

Development machines for this port are frequently ARM64, because Snapdragon X Copilot+ PCs are among the machines most likely to carry the Energy Meter device the hardware power source depends on.

While iterating, build only the host architecture:

```powershell
dotnet build windows\src\Juice.App\Juice.App.csproj -p:Platform=ARM64
```

Cross-compiled slices ship, but they are a packaging step.
An x64 build on an ARM64 machine is identical code that cannot be meaningfully run there, so building it after every edit buys nothing.

Running it is worse than useless for this app specifically.
An emulated process burns materially more CPU, and Juice attributes energy by share of processor time, so an emulated build measures the emulator rather than the app.

## Verify in proportion to the change

Verification cost dominates this codebase if it is not budgeted, because a WinUI build is slow and packaging plus launching is slower.

While iterating:

- build the changed project for the host architecture
- run filtered tests when you changed covered logic, for example `--filter "FullyQualifiedName~Tray"`
- do not build other architectures, do not build the whole solution, do not run the full suite

Once, immediately before reporting:

- build the remaining architecture
- build the solution
- run the full test suite

Registering an MSIX and launching it is expensive.
Batch changes and pay that cost once, rather than after every edit.

## Push decisions out of the view

Anything that can be decided without a window belongs in `Juice.Core`, where it is covered by fast headless tests.

This is the same rule the macOS tree follows, and here it is also the single most effective way to avoid slow visual verification.
Battery severity bands, ranking bar normalisation, chart axis and gap rules, tray label budgets and surface tint strength all live in the core library for this reason.

## Never drive the real input stack

Do not use UI Automation input synthesis to verify anything.
`winapp ui click` uses mouse simulation and `winapp ui focus` calls `SetFocus`, and both steal input from whoever is using the machine.

Read-only commands (`inspect`, `search`, `get-property`, `screenshot`) and pattern-based ones (`invoke`, `set-value`, `scroll`) do not touch the OS input queue and are fine.
`winapp ui screenshot` is the right tool for checking something visual.

## Materials follow surface lifetime

Acrylic for transient light-dismiss surfaces, which here means the tray flyout.
Mica for long-lived windows, which here means settings.

Do not configure backdrops from code-behind.
The declarative form derives its colours from the theme correctly, and hand-tuning tint and luminosity opacity without also supplying a per-theme tint colour produces a panel that ignores the system theme entirely.

Consult the `winui-design` skill before changing anything visual.
Its review checklist forbids code-behind for styles, colours and layout, and would have prevented that mistake.

## Displayed numbers are sacred

The macOS rule applies unchanged, and there is a command for it here.

`juice verify` compares the hardware energy accumulator against the integral of the platform's own power counter.
These are genuinely independent derivations, from different counters and different arithmetic, which is the entire point.

If you change how watts are derived, make sure the audit still integrates `CounterWatts` and not the possibly accumulator-derived `Watts`.
An audit that compares a number against itself passes by construction and is worse than no audit, because it looks like evidence.

## Conventions

Never use the em-dash character, in code, comments, XAML or documentation.
Use a plain `-`.

No emojis in product UI or code.
App rows use real extracted icons and system indicators use Segoe Fluent glyphs.

Versions are `major.minor.build.0`, defined once in `windows/Directory.Build.props`.
The revision stays 0 because the Microsoft Store reserves it.
