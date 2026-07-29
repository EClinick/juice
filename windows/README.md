# Juice for Windows

A Windows port of Juice in C# and WinUI 3.
It answers the same question as the macOS original, using Windows' own power telemetry: what is eating your battery, how much energy each app actually used, and now what that energy costs you.

## What is different from the macOS version

Windows exposes a power source that macOS does not, and it removes the original's biggest blind spot.

On macOS, live wattage comes from the battery's discharge rate, so a laptop sitting on AC reports nothing.
Many Windows laptops, including Surface hardware and Snapdragon X Copilot+ PCs, carry an ACPI Energy Meter Interface device that meters the physical power rails directly.
Juice reads those rails through the `Energy Meter` performance counter set, so it reports true system draw **while plugged in**, not only on battery.

Better still, the CPU and GPU rails are metered separately.
That lets the Windows port reproduce the macOS CPU / GPU / Neural Engine breakdown from real hardware measurements rather than from an estimate, with the NPU rail standing in for the Neural Engine on machines that meter one.

Machines without an Energy Meter fall back to the ACPI battery discharge rate, which is real but only available on battery.
Juice never blends sources and never fabricates a number: a reading always carries the tier it came from, and unknown draw is displayed as unknown rather than as zero.

## Units

The `Energy Meter` counter units are undocumented, so they were established empirically rather than assumed.
Integrating the `Power` counter over a 117 second window and dividing the `Energy` counter delta by the integral gave 278,011 units per millijoule on the `sys` rail and 278,010 on `psu_usb`, two independent rails agreeing to four significant figures.
One joule is 2.77778e8 picowatt-hours, so `Power` is milliwatts and `Energy` is picowatt-hours, giving `Wh = pWh / 1e12`.

`juice verify` re-runs that comparison at any time.
Because the accumulator and the integrated power counter are independent derivations, agreement between them is a live check that the constant is still correct.

## Layout

```
windows/
  src/Juice.Core              Pure logic. No Windows dependencies, fully unit tested.
  src/Juice.Platform.Windows  Energy Meter rails, ACPI battery, PDH, NT process table.
  src/Juice.Cli               juice.exe, the command line and TUI front end.
  src/Juice.App               WinUI 3 tray application.
  tests/Juice.Core.Tests      xUnit suite over Juice.Core.
```

As in the macOS tree, all energy math, rollups, insights and cost logic live in the core library where tests can reach it.
The front ends only render what the core computes.

## Building and testing

```powershell
dotnet build windows/Juice.slnx

# Tests
dotnet test windows/tests/Juice.Core.Tests/Juice.Core.Tests.csproj

# A single test
dotnet test windows/tests/Juice.Core.Tests/Juice.Core.Tests.csproj --filter "FullyQualifiedName~AppsPlusPlatform"
```

Build the architecture you are running on, and verify there.
Both slices ship, so both get built at pack time, but an x64 build executed on an ARM64 machine runs under Prism emulation and burns materially more CPU for the same work.
Since Juice attributes energy to processes by their share of processor time, an emulated build inflates its own consumption and reports numbers that describe the emulator rather than the app.
On a Snapdragon X machine that means `-p:Platform=ARM64` for anything you intend to run.

## Command line

The CLI has two modes.
The default is a human-readable terminal view.
`--json` selects tools mode, for scripts and AI agents, where everything on stdout is machine-readable including failures.

```powershell
juice now                    # current draw, per rail
juice top --seconds 30       # top energy users, with cost per app
juice battery                # battery health and capacity loss over the machine's life
juice sources                # which power sources this machine has
juice verify --seconds 30    # audit the energy accumulator against integrated power
```

Example:

```
> juice top --seconds 12
Measured 86 mWh over 12s
Rate 0.170 USD/kWh (United States, estimate)

App                                W     CPU W     GPU W      $/yr
copilot                         8.86      8.86      0.00     13.20
dwm                             0.67      0.66      0.02      1.01
explorer                        0.31      0.31      0.00      0.46

System and display             13.49
```

## Tools mode

The switch is named for the encoding because that is what the ecosystem settled on, but what a consumer actually depends on is the shape being stable.
So the contract is versioned and can be pinned:

```powershell
juice now --json        # whatever this build emits
juice now --json=0.1    # fail loudly if this build cannot honour 0.1
```

Only the major version has to match, since additive changes within a major version are backwards compatible by definition.
The precedent is `git --porcelain=v2` rather than anything AI specific.

Three rules let one schema describe both platforms without either having to lie.
A quantity that was not measured is omitted rather than emitted as zero, because an unknown reading and a zero reading are different facts.
Every measurement carries its provenance, so a consumer can tell a hardware measurement from an estimate.
Every cost carries whether the price behind it was a regional average or the user's real tariff.

```json
{
  "schemaVersion": "0.1",
  "platform": "windows",
  "command": "now",
  "ok": true,
  "measurement": {
    "confidence": "measured",
    "source": "hardwareRail",
    "systemWatts": 34.688,
    "rails": { "cpu": 17.577, "gpu": 0.041, "supply": 34.639 }
  },
  "battery": { "present": true, "percent": 80, "flow": "pluggedIn" }
}
```

There is no `npu` key because this machine does not meter that rail, and no `chargeWatts` because a full battery trickling milliwatts is not charging.

Failures use the same envelope on stdout, so a caller never has to parse two formats:

```json
{
  "schemaVersion": "0.1",
  "command": "now",
  "ok": false,
  "error": { "code": "noPowerSource", "message": "No power source is available on this machine." }
}
```

Branch on `ok`, then on `error.code`, which is stable within a schema version.
The `message` is not stable and should not be parsed.
Exit codes are `0` for success, `1` for a command that ran but produced no result, and `2` for a usage error.

The schema is defined in `src/Juice.Core/Contracts/JuiceSchema.cs` and discussed in EClinick/juice#16.

## Cost

Energy is measured; the price attached to it is the uncertain term, so Juice is explicit about which is which.
A region is resolved from the Windows user region with no permission prompt and no network call, and a bundled table of average residential prices turns watt-hours into money.
Every figure derived from that table is labelled an estimate.
A user-entered tariff replaces it and is not labelled an estimate, because then it is ground truth.

## Packaging

Packaging goes through the `winapp` CLI.

```powershell
# Self-contained x64 + ARM64 bundle, signed with a generated development certificate
windows\build\pack.ps1

# Production
windows\build\pack.ps1 -CertPath .\prod.pfx -Timestamp http://timestamp.digicert.com
```

`winapp package` produces one `.msix` per architecture, so the script publishes and packages x64 and ARM64 separately and combines them with `winapp tool makeappx bundle`.
ARM64 matters more than usual here: Snapdragon X Copilot+ PCs are among the machines most likely to carry the ACPI Energy Meter device that the hardware rail power source depends on.

Packages are self-contained by default.
Two separate runtimes have to be carried, the .NET runtime via `dotnet publish --self-contained` and the Windows App SDK via `WindowsAppSDKSelfContained` and `winapp package --self-contained`, and setting only one of them still leaves the app unable to start on a clean machine.
Pass `-FrameworkDependent` for a smaller package that requires both runtimes to already be present.

The package declares an `AppExecutionAlias`, so installing it puts `juice` on the PATH for any terminal.
One bundle therefore serves both the tray application and the command line.

Versions are `major.minor.build.0`, defined once in `windows/Directory.Build.props` and stamped into the manifest at pack time.
`pack.ps1` bumps the build segment on every run, because the Store rejects a submission whose version is not strictly greater than the last one accepted, and editing it by hand is the step that gets forgotten on the second submission.
Pass `-NoBump` to repackage the same version while iterating locally.
The revision field stays 0 because the Microsoft Store reserves it and rewrites it when it repackages a submission.

## Submitting to the Store

The portal accepts the bundle directly, and for occasional releases that is the shortest path: upload `windows/artifacts/Juice_<version>.msixbundle` under Packages in Partner Center.

Submission can also be scripted, which is worth setting up once releases become frequent.
`winapp store` wraps the Microsoft Store Developer CLI, downloading it on first use.

```powershell
# Validate credentials and the bundle without submitting anything
windows\build\submit.ps1 -WhatIf

# Submit the newest bundle in windows/artifacts
windows\build\submit.ps1
```

Credentials are read from environment variables and are never stored in this repository.
They identify a Partner Center account and can publish software under it, so they belong in a secret store, in CI secrets, or in a shell session, and nowhere else.

```
JUICE_STORE_TENANT_ID       Microsoft Entra tenant containing the app registration
JUICE_STORE_SELLER_ID       Partner Center seller id
JUICE_STORE_CLIENT_ID       Microsoft Entra application (client) id
JUICE_STORE_CLIENT_SECRET   Client secret for that application
```

The API authenticates through a Microsoft Entra application rather than through the account sign-in, so an individual account that uses a personal Microsoft account has one extra step: create a tenant under Account settings, then Tenants, which Partner Center offers at no cost.
Then add the application under User management, assign it the Manager role, and collect the tenant, client and seller ids along with a key.
The key is shown once and cannot be retrieved afterwards.

Until that is set up, `submit.ps1` will stop with a message naming the missing variable, and the portal upload path remains available.

The package identity must match a product reserved in Partner Center.
`Name` is the publisher prefix joined to the reserved product name, and `Publisher` and `PublisherDisplayName` are account level and shared across every product published under the account.

## Sampling cost

A battery monitor that measurably shortens battery life is self-defeating, so Juice samples as little as it can get away with.

The hardware energy counters are cumulative, which means energy accrues whether or not Juice is looking.
A longer interval costs resolution but never accuracy: daily totals are identical at a one second and a sixty second cadence.
That makes it safe to poll slowly by default and quickly only while a window is open and someone is watching a live number.

Per-process sampling has no such accumulator and is far more expensive, so it has its own cadence and is dropped entirely when the display is off.
It reads the whole process table in one `NtQuerySystemInformation` call and all GPU engine instances in one PDH wildcard query, rather than allocating an object per process and per counter instance.

## Where it shows up

The Windows notification area has no text label API, unlike the macOS menu bar.
A tray icon is a square bitmap of 16 to 32 pixels depending on DPI, so Juice renders the current wattage into the icon itself, which leaves room for about three glyphs.
The tooltip carries the full precision and clicking opens the flyout.

Windows 11 hides newly registered tray icons in the overflow menu by default, so first run explains how to pin it.
