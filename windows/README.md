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

## Command line

The CLI exists both for scripting and for AI tooling, so every command accepts `--json`.

```powershell
juice now                    # current draw, per rail
juice top --seconds 30       # top energy users, with cost per app
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

## Cost

Energy is measured; the price attached to it is the uncertain term, so Juice is explicit about which is which.
A region is resolved from the Windows user region with no permission prompt and no network call, and a bundled table of average residential prices turns watt-hours into money.
Every figure derived from that table is labelled an estimate.
A user-entered tariff replaces it and is not labelled an estimate, because then it is ground truth.

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
