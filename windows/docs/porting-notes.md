# Porting notes: what macOS gives you for free

A running log of things that are a line or two of Swift on macOS and a genuine piece of engineering on Windows.

This exists for three reasons.
It stops the next person rediscovering the same holes.
It explains why some Windows files are far larger than their macOS counterparts, which otherwise looks like gold plating in review.
And it records the empirical findings that Windows does not document, which would otherwise live only in someone's terminal history.

Entries are appended as they are hit, newest at the bottom of each section.

## Live power while plugged in

**macOS:** `IOKit` `AppleSmartBattery` gives instantaneous amperage and voltage with no permissions.
The catch is that it only describes the battery, so a laptop on AC reports nothing, and the macOS app has this blind spot too.

**Windows:** the same blind spot exists in the obvious API.
`root\wmi` `BatteryStatus` reports `ChargeRate` and `DischargeRate` in milliwatts, and both read zero when a full battery sits on AC.

The way out is a genuinely better source that macOS has no equivalent of.
Machines with an ACPI Energy Meter Interface device expose an `Energy Meter` PDH counter set that meters the physical rails, and it works on AC and on battery alike.
On the development Surface it exposes eleven rails including `sys`, `cpu_cluster_0..2`, `gpu`, `psu_usb` and `usbc_total`.

So this is the one place where the Windows port is strictly ahead of the original, and it is worth the effort.
It is not universal: desktops and many cheaper laptops have no EMI device, so the battery source has to remain as a fallback and the app has to say which one it used.

## Undocumented counter units

**macOS:** powerlog columns are in nanojoules.
Undocumented by Apple, but the units are at least consistent and widely known, and the macOS code converts with a single named constant.

**Windows:** the `Energy Meter` counter units are documented nowhere at all.

They had to be established empirically.
Integrating the `Power` counter over a 117 second window and dividing the `Energy` counter delta by that integral gave 278,011 units per millijoule on `sys` and 278,010 on `psu_usb`.
Two independent rails agreeing to four significant figures is not a coincidence, and 2.78011e8 units per joule matches the 2.77778e8 picowatt-hours in a joule to within 0.08%.

So `Power` is milliwatts and `Energy` is picowatt-hours, giving `Wh = pWh / 1e12`.

The lesson is that an assumption like this must not sit unguarded in a constant.
`juice verify` re-runs the comparison against live hardware, so if a future Windows release rescales the counter the check fails immediately instead of silently corrupting every displayed watt-hour.

## Reading a counter at all

**macOS:** read the IOKit property, get a number.

**Windows:** the `Power` counters are of type `AverageCount64`, meaning each read reports the average since the previous read.
The first read of a fresh handle has no baseline and necessarily returns 0.

A continuously polling GUI never notices, because it discards one sample at startup.
A one-shot command like `juice now` reports 0 W on a machine drawing 30 W, which is the worst possible failure mode for an app whose entire promise is that displayed numbers are true.

Worse, the EMI driver only refreshes about once a second, so even a correctly primed short window can land entirely between refreshes and average to exactly zero.

The fix was to stop trusting the averaging counter and derive watts from the `Energy` accumulator delta over a measured interval instead.
The accumulator is monotonic, so any elapsed energy appears in the delta whenever it is read, and there is no interval short enough to produce a false zero.
The averaging counter is kept only as a fallback for rails that expose no accumulator.

## Per-app energy

**macOS:** powerlog records CPU, GPU and Neural Engine energy per coalition, in nanojoules, already attributed.
The hard part on macOS is only getting at it, because the database is root-only, which is what the privileged XPC helper exists for.

**Windows:** there is no per-process energy API.
None.
Task Manager's "Power usage" column is a bucketed rating derived from the Energy Estimation Engine, not a number any application can read.

Energy therefore has to be attributed rather than read.
Because the CPU and GPU rails are metered separately, the split can at least be principled: CPU rail energy is divided by each process's share of processor time, and GPU rail energy by each process's share of GPU engine utilisation.

Two invariants keep this honest.
The division is exact, so attributed energy always sums to the measured rail energy rather than drifting from it.
And energy that no process can be held responsible for is reported as platform overhead, defined as the residual so that apps plus platform always equals the measured system total.

The equivalent macOS numbers are measured; the Windows ones are measured at the rail and apportioned below it.
That difference should be stated in the UI rather than hidden.

## Grouping processes into apps

**macOS:** a coalition is an app plus all its helper processes, and the kernel maintains it.
Bundle identifiers give a stable app identity for free, and `NSWorkspace` gives a real icon.

**Windows:** processes are flat.
A browser with thirty renderer processes is thirty unrelated entries, there is no stable identity comparable to a bundle id, and extracting an icon means reading the executable's resources.

Grouping is currently by executable name, which is crude.
It gets `msedge` right and will get an Electron app wrong, since several unrelated apps ship the same host executable name.

## Diagnosing a broken package manifest

**macOS:** `Info.plist` is a plist.
A syntax error is reported as a syntax error, with a line number.

**Windows:** an XML syntax error in `Package.appxmanifest` can surface as something with no apparent connection to the manifest at all.

A comment in the manifest contained `--json`, and `--` is illegal inside an XML comment under XML 1.0 section 2.5.
The real diagnostic is `APPX1402: An XML comment cannot contain '--'`, which would have been obvious.

What actually appeared was an `MSB4018` stack trace complaining that
`System.Security.Permissions, Version=8.0.0.0` could not be loaded.
The validation task catches the `XmlException` and then throws while classifying it, because that assembly is not shipped alongside the task in the build tools package.
The underlying message is lost and the manifest is never mentioned.

Worth knowing for CI: any XML syntax error in the manifest can present as that bogus assembly load failure.
When a packaging build fails with a missing `System.Security.Permissions`, validate the manifest XML first.

## Manifest extension namespaces

**macOS:** login items are registered in code through `SMAppService`, and the surrounding plist keys are few and well documented.

**Windows:** the packaging extensions are declared in XML, and the namespace depends on whether the app is UWP or full trust, which is easy to get wrong because both forms appear in search results and only one validates.

For a full-trust desktop app, `windows.startupTask` is a `desktop:Extension` containing a `desktop:StartupTask`.
The `uap5` form of the same extension is for UWP.

`windows.appExecutionAlias` is stranger still: the extension and the alias list are `uap3`, but the alias element inside them is `desktop`.
A `uap3:ExecutionAlias` fails validation even though every surrounding element is `uap3`.

The `Executable` attribute must also name a binary that is genuinely in the package payload, which means shipping the CLI alongside the GUI if the alias is to launch the CLI.

## Building and verifying on ARM64

**macOS:** universal binaries.
One artifact contains both architectures, `swift build` produces something that runs natively on the machine you are sitting at, and Rosetta is not in the picture for your own builds.

**Windows:** architectures are separate artifacts all the way through, and the development machine's own architecture changes what "running the app" actually means.

Cross-compiling is fine. `dotnet build -p:Platform=x64` on an ARM64 machine runs the compiler natively and simply emits x64, and the x64 slice has to be built because it ships in the bundle.

Running that slice locally is the trap.
An x64 process on ARM64 executes under Prism emulation, which burns materially more CPU for the same work.

For Juice specifically that is not a performance footnote, it corrupts the measurement.
Energy is attributed to processes by their share of processor time, so an emulated build inflates its own CPU consumption, takes a larger share of the CPU rail than the native build would, and reports numbers that describe the emulator rather than the app.
A tool that measures energy has to be verified as the native binary.

So on an ARM64 development machine, build both and verify ARM64.
This matters more than it sounds, because Snapdragon X Copilot+ PCs are exactly the machines most likely to carry the EMI device that the hardware power source depends on, which makes ARM64 the primary target for this app rather than an afterthought.

The interop does port cleanly.
ARM64 Windows is LLP64 with the same structure layout as x64, so the hardcoded `SYSTEM_PROCESS_INFORMATION` field offsets are correct on both and the guard is a pointer-size check rather than an architecture check.

## Drawing a chart

**macOS:** Swift Charts ships in the SDK.
A bar chart is a declarative `Chart { BarMark(...) }`, and it arrives already themed, already accessible, and already handling axes and scaling.
VoiceOver descriptions and audio graphs come for free.

**Windows:** WinUI 3 has no charting at all.
There is no first-party equivalent, and the options are all dependencies: LiveCharts2, SkiaSharp, Win2D, or a commercial suite.

For a tray utility that has to stay small and run for weeks, pulling in a rendering engine to draw twenty-four bars is disproportionate.
So the chart is composed from primitives instead: a `Grid` with one star-width column per hour, holding a `Border` for a bar and a low `Rectangle` for a gap.

That turns out to be a reasonable trade rather than a grudging one.
Theme resources work automatically, so Light, Dark and HighContrast stay correct with no extra code.
Per-column tooltips and automation names are ordinary properties.
The cost is one element per column, which is fine for a day and wrong for a year, so anything longer than a few days has to be aggregated into daily buckets before it reaches the control.

The accessibility gap is the part with no cheap answer.
Swift Charts describes a series to VoiceOver on its own; here every column's automation name is written by hand, and there is no equivalent of an audio graph.

It also means the honesty rules cannot be delegated.
Swift Charts would happily draw whatever series it was given, and so will this, which is why axis pinning, gap columns and the refusal to interpolate all live in `EnergyChartBuilder` in the core library with tests around them, rather than in the renderer where each new chart could quietly reinvent them.

## Binding modern C# to XAML

**macOS:** SwiftUI reads Swift types directly.
A struct with non-optional stored properties is simply a struct, and the view layer has no opinion about it.

**Windows:** the WinUI XAML type-info generator emits a parameterless construction for every type reachable from an `x:Bind` path, whatever the type's own construction rules are.

Any record with `required` members therefore fails to compile the moment it is bound, with five `CS9035` errors pointing into generated code the developer never wrote.
The cause is not visible from the error, and the generated file is regenerated on every build, so editing it is not an option.

The fix is to use `init` with defaults instead of `required` on the handful of types that cross into XAML, and to rely on the single intended producer to populate them.
That is a real loss of compile-time safety, so it is worth confining to presentation types and keeping `required` everywhere the compiler can still enforce it.

`System.IO.Path` also collides with `Microsoft.UI.Xaml.Shapes.Path` under implicit usings, which any XAML drawing code hits immediately and which needs an alias.

## Removing a window border

**macOS:** an `NSPanel` without a title bar has no border.
There is nothing to remove.

**Windows:** a WinUI window that has been told to have no border and no title bar can still have `WS_BORDER`, `WS_CAPTION` and `WS_DLGFRAME` set, and still draws a light non-client frame around itself.

This one was expensive to find because the obvious explanation is wrong in a convincing way.
Windows 11 does draw a border on rounded windows, it is controlled by `DWMWA_BORDER_COLOR`, and setting it to `DWMWA_COLOR_NONE` is the documented way to remove it.
That is all true, and none of it helps, because the border in question is not that border.

The diagnostic that settled it was cheap and should have come first: log the `HRESULT` of every `DwmSetWindowAttribute` call and dump the window style bits.
Both calls returned `S_OK`, so DWM was never the problem, and the style dump showed the non-client frame still present.
Comparing `GetClientRect` against `GetWindowRect` then showed a nine pixel chrome inset, which also explained why the window was taller than its content.

The fix is to handle `WM_NCCALCSIZE` and report the whole window rectangle as client area, so no non-client frame is reserved or painted.

The lesson is not about borders.
Three rebuild, redeploy and relaunch cycles were spent testing hypotheses that a read-only probe would have eliminated in one.
Redeploy to confirm a conclusion, not to test a guess.

## Finding your own data on a packaged app

**macOS:** `~/Library/Application Support/Juice` is where the app writes and where you look.
Those are the same path.

**Windows:** they are not.

A packaged app calling `Environment.GetFolderPath(LocalApplicationData)` gets a redirected location, so a file the app believes it wrote to `%LOCALAPPDATA%\name.log` actually lands in
`%LOCALAPPDATA%\Packages\<PackageFamilyName>\LocalCache\Local\name.log`.

Checking the unredirected path shows nothing and looks exactly like the code never ran.
That mistake was made in this session and cost a round trip.
When a packaged app appears not to have written its file, check the redirected path before concluding anything.

## Reaching a material's options

**macOS:** materials are values.
`.ultraThinMaterial` and `.regularMaterial` are members of the same type, discoverable by autocomplete, usable anywhere a material is expected.

**Windows:** the option you want may exist and still be unreachable from where you are looking.

Acrylic has documented recipes, and the thin one is what the shell uses for surfaces that should show the desktop through them.
`<DesktopAcrylicBackdrop Kind="Thin" />` fails to compile with `WMC0011: Unknown member 'Kind'`, which reads exactly like the SDK not supporting it.

It does support it.
`DesktopAcrylicKind` lives in `Microsoft.InteractiveExperiences.Projection.dll` rather than `Microsoft.WinUI.dll`, and the XAML element does not project the property even though the controller does.
`MicaBackdrop.Kind` compiling while `DesktopAcrylicBackdrop.Kind` does not is the clue, and it is a misleading one, because it suggests the difference is between the two materials rather than between the element and the controller.

The way through is a small `SystemBackdrop` subclass that attaches a `DesktopAcrylicController` with `Kind` set, which keeps the material declarative at the usage site.

Worth setting only `Kind`.
Setting `TintOpacity` and `LuminosityOpacity` without also setting `TintColor` and `FallbackColor` opts the controller out of its theme-derived colours, and the result was a light panel on a fully dark system.
That failure is easy to misread as the theme being wrong somewhere, when the real cause is having partially overridden a set of values that are only coherent together.

That subclass comes with an obligation nobody tells you about.
Calling `GetDefaultSystemBackdropConfiguration` signs you up to answer `OnDefaultSystemBackdropConfigurationChanged`, and if you leave that to the base implementation it fails with `E_INVALIDARG`, which arrives in .NET as an `ArgumentException` thrown across the WinRT boundary with nothing to catch it.
The process dies.
The documentation calls the override useful "if you're using a custom SystemBackdropConfiguration", which reads as optional and is not.

The callback fires on a light or dark switch, on a high contrast switch and on an energy saver switch, so the failure only shows up on a machine where somebody actually changes one of those while the app is running.
Juice carried it for months without noticing, because the flyout read the taskbar theme once at construction and never again.
The day the flyout started following a live theme switch, every switch killed it.

The override itself has a second trap.
Passing the `target` it hands you straight back into `GetDefaultSystemBackdropConfiguration` fails with the same `E_INVALIDARG`, naming `target`.
Keep the target and `XamlRoot` from `OnTargetConnected` and use those instead.

## ReadyToRun, and how to measure it without fooling yourself

**macOS:** Swift compiles ahead of time by default.
There is no equivalent decision, and no equivalent surprise.

**Windows:** the WinUI project template enables `PublishReadyToRun` for non-Debug builds, which precompiles IL to native code.
It costs package size and buys startup time, and the interesting part of this section is how hard it turned out to be to measure either honestly.

The numbers, measured on the packages this repository actually produces.
Precompiling adds 12.6 MB on arm64 and 14.5 MB on x64.
That per-architecture figure is the one that matters, because an MSIX bundle installs only the package matching the machine, so nobody downloads the whole bundle.
This is a property of MSIX itself rather than of the Store, so it holds equally for a bundle handed out on a website or a USB key.
In exchange, median time to a responsive process falls from 160.5 ms to 138.5 ms, and process cpu time to that point falls from 187.5 ms to 171.9 ms.
The cpu figure is the jit work being skipped, which is the effect the feature exists to produce.
It is enabled.

An earlier version of this section confidently said the opposite: that precompiling made startup slower, and that the trade was therefore not worth taking.
That was wrong, and the way it was wrong is the part worth keeping.

Precompiled assemblies are not produced by an ordinary `dotnet build`.
They appear only on `publish`, or on `build` when a runtime identifier is passed, and even then they are written to an `R2R` folder under `obj` and substituted into the package at packaging time.
The build output keeps the original sizes throughout, so inspecting the folder that was packaged shows 7 MB where the package contains 17.5 MB, which looks impossible until you know where to look.

That indirection is what produced the wrong answer.
Measuring startup requires a runnable precompiled layout, and no build directory is ever one, so the layout has to be assembled by copying the `R2R` folder over a build output.
The copy that was measured included a stale `Juice.App.dll` from a differently configured build, which reintroduced a packaged-mode bootstrapper into an unpackaged layout.
Every "precompiled" run being timed was in fact crashing during startup.

It survived because the timing harness used `WaitForInputIdle`, which returns `true` for a process that has already exited.
The harness reported a clean, plausible, entirely fictional 226 ms.
Any startup measurement should assert the process is still alive at the moment it stops the clock, and should discard warm-up runs and interleave the configurations so that machine state cannot be attributed to the variable under test.

A second wrong conclusion came from the same source.
Comparing against a similar application suggested the Windows App SDK had grown between versions, since that application shipped 25 MB where this one shipped 63 MB of the same file.
`Microsoft.WinUI.dll` is 7 MB in every cached version from 1.8 through 2.3, so that was never true either.
The 63 MB file was the command line tool's own precompiled, self-contained output being read as if it belonged to the application.

One more thing follows from all this, and it is the part that generalises furthest.

ReadyToRun looks like a per-project setting, and it is not.
An MSIX layout is a single flat folder, so the application's build supplies every shared assembly in the package, and the command line tool contributes only its own four files on top.
Of those four, only `juice.dll` contains IL, so the command line project's setting decides the fate of exactly one assembly in the package.
Turning it off there moved the bundle by 50,176 bytes per architecture, which is what made this visible.

It is a package-wide decision that happens to be spelled as a project property, and the project it belongs to is whichever one supplies the shared payload.

Which is also why both projects now enable it, despite the command line tool gaining nothing measurable from precompiling on its own.
Measured in isolation it is not startup bound: median wall time for `juice now` was 2040 ms against 2050 ms over twelve interleaved runs of each, with the ranges overlapping, because every command samples hardware counters over a real time window that dwarfs any jit work.
That measurement argues about whether the package should precompile at all, and the application already settled that question by paying 12.6 MB for it.
Once that is paid, excluding one executable saves four hundredths of a percent of the package and leaves the only code unique to the command line as the single jitted assembly among precompiled ones.
The consistent choice is the cheap one.

That also corrected a wrong attribution made on the way here.
The 63 MB Windows API projection in the package is the application's, precompiled under a self-contained .NET build, not the command line tool's.
An earlier measurement had put the application's cost at 21.8 MB, but that was taken framework-dependent on .NET, which precompiles far less.
Only the comparison of the packages this script actually produces is trustworthy, because it is the only one where every other variable is held where it ships.

The lesson is not about ReadyToRun.
It is that a build feature which quietly writes its output somewhere other than the build output will defeat measurement by inspection, and that a measurement which cannot fail is not a measurement.

## Showing an app's icon

**macOS:** `NSWorkspace.icon(forFile:)`.
One call, always returns something sensible, and CONTRIBUTING.md relies on it: app rows use real icons rather than glyphs.

**Windows:** there is no single call, so it is reconstructed in three steps.
The executable path is resolved from the process id with `QueryFullProcessImageName` under `PROCESS_QUERY_LIMITED_INFORMATION`, the icon is extracted from that executable's resources with `PrivateExtractIcons` at the size the list actually renders, and the result is encoded as PNG so the platform layer stays free of XAML types.

Two things make this less reliable than the macOS equivalent, and both need a fallback in the UI.

Many executables carry no icon resource at all.
This was found the honest way: the first capability probe extracted the icon of the running process, got nothing, and looked like a bug in the interop.
It was not.
A bare .NET apphost has no icon unless `ApplicationIcon` is set, while `explorer.exe` extracted correctly on the same code path.
Console hosts and service binaries are commonly in the same position.

Packaged apps are worse.
For an MSIX or Store app the real logo lives in the package manifest as `Square44x44Logo`, and the executable's own icon is often generic or absent, so `PrivateExtractIcons` returns something that is technically valid and visually wrong.
Handling that properly means going through the package graph rather than the file, which is not yet implemented.

Extraction is also expensive enough to need a cache, keyed by path and including negative results, because the answer never changes for a given executable and the list refreshes every few seconds.
The cache from process id to path has to be invalidated periodically, since Windows recycles process ids and would otherwise eventually hand back the wrong executable.

## Sitting visually next to the taskbar

**macOS:** the menu bar hosts the item, so it inherits the correct appearance automatically.
There is nothing to match because the app is drawn by the same surface.

**Windows:** the tray icon is a bitmap the app renders itself, and the flyout is an ordinary window, so both have to be matched to the taskbar deliberately.

The trap is that Windows has two independent theme switches that users frequently set differently.
`AppsUseLightTheme` drives application chrome, while `SystemUsesLightTheme` drives the taskbar, Start and the notification area.
Light apps on a dark taskbar is a common configuration.

Anything drawn against the taskbar must follow `SystemUsesLightTheme`.
Following the app theme instead produces a tray icon that is invisible against the taskbar it sits on, which is the most common way tray utilities get this wrong.

There is a third switch as well.
`ColorPrevalence` under `HKCU\Software\Microsoft\Windows\DWM` reports whether the user enabled "Show accent color on Start and taskbar", which determines whether the taskbar is accent-tinted or neutral, and the flyout has to match that too if it is to read as an extension of the taskbar rather than a window parked next to it.
The accent itself is stored as a DWORD in ABGR order rather than the ARGB most Windows colour APIs use, so the red and blue channels have to be swapped back.

Following the taskbar theme with `RequestedTheme` on the window's root element solves the surfaces and quietly breaks the colours.
`Application.Current.Resources["AccentFillColorDefaultBrush"]` answers for the *process* theme, which follows `AppsUseLightTheme`.
On a machine set to light apps and a dark taskbar, a flyout that had correctly gone dark drew its chart bars and its hero number in the light theme's accent, on a dark surface.
Nothing in the code was obviously wrong, because the brush was fetched by name from a theme dictionary, in a function that was re-run on every `ActualThemeChanged`, and it was still the wrong dictionary every time.

There is no element-scoped equivalent of that lookup.
`{ThemeResource}` in markup resolves against the element it is set on, and code has no way to ask a `ResourceDictionary` for the entry belonging to a particular theme.
So any colour that has to follow an element theme has to be chosen in markup, which in practice means one of two shapes:

* Overlay one element per case and toggle visibility, each with its own `{ThemeResource}`. Used for the rail strips, the ranking bar fills and the hero readout.
* Take the brush as a dependency property and let the usage site pass `{ThemeResource}`. Used for the charts, which build their elements in code.

Both are more verbose than a `switch` returning a brush. Neither can be wrong.

High contrast is the same problem one level further out.
It is not a third colour scheme, it is a different contract: the accent colour is unavailable, the subtle fills collapse onto the surface colour, and opacity is overridden.
Every chart on the Juice flyout was blank in High Contrast Black, because a bar painted `AccentFillColorDefaultBrush` on a `ControlStrongFillColorDisabledBrush` track came out as background on background.
A translucent wash behind the battery line came out as a solid block over it.

The fix is a set of role-named brushes in the window's own `ThemeDictionaries`, so the markup asks for "the fill that means measured data" and one place decides what that is per scheme.
Anything that used opacity to be subtle needs the opacity itself to be a theme value, not a constant, so high contrast can turn it off.

## Showing a number in the menu bar

**macOS:** `MenuBarExtra` accepts a `Text` view.
Arbitrary width, arbitrary content, follows the system appearance automatically.

**Windows:** the notification area has no text API whatsoever.
An icon is a square bitmap of 16, 20, 24 or 32 pixels depending on DPI, and that is the entire contract.

Displaying wattage means generating the icon bitmap at runtime with the number drawn into it, which is what Core Temp and similar utilities do.
That brings in DPI queries, GDI bitmap rendering, font auto-sizing to fit roughly three glyphs, `HICON` lifetime management to avoid leaking a GDI handle every second for weeks, taskbar theme detection from the registry because the taskbar does not follow the app theme, and re-rendering on `WM_SETTINGCHANGE`.

The result is about 770 lines across `TrayIcon.cs`, `TrayIconRenderer.cs` and `NativeMethods.cs`, roughly 29% of the GUI, to do what macOS does in about five lines.

There is also an adoption problem with no macOS equivalent: Windows 11 hides newly registered tray icons in the overflow flyout by default, so a first-run app is invisible until the user pins it.

## Enumerating processes cheaply

**macOS:** the coalition data arrives pre-aggregated, so there is no per-sample enumeration cost at all.

**Windows:** the obvious approach, `Process.GetProcesses()` plus a `PerformanceCounter` per GPU engine instance, opens a handle per process and allocates several hundred counter objects on every sample.
The development machine has over 500 GPU engine instances.

For a background utility that is self-defeating, since the monitor would rank in its own top energy users.
Both halves had to be replaced with bulk APIs: one `NtQuerySystemInformation` call for the entire process table with no handles, and one PDH wildcard query for every GPU engine instance.

## Sampling without costing battery

**macOS and Windows both:** the same insight applies, and it is the thing that makes a low duty cycle safe.

Hardware energy counters are cumulative, so energy accrues whether or not the app is looking.
A longer polling interval costs resolution but never accuracy, and daily totals are identical at a one second and a sixty second cadence.

That means fast sampling is only needed while a human is watching a live number.
Per-process sampling has no such accumulator and degrades with longer intervals, so it needs its own slower cadence and is dropped entirely when the display is off.

## Packaging

**macOS:** one signed `.app` bundle, one DMG, one notarization step, one universal binary covering both architectures.

**Windows:** MSIX is per architecture.
`winapp package` produces one `.msix` each for x64 and ARM64, which then have to be combined with `makeappx bundle` into a `.msixbundle`, and the bundle signed separately.

ARM64 matters more here than it usually does, because Snapdragon X Copilot+ PCs are among the machines most likely to carry the EMI device the hardware power source depends on.

Two more wrinkles with no macOS counterpart.
Self-contained means two different runtimes, the .NET runtime via `dotnet publish --self-contained` and the Windows App SDK via `WindowsAppSDKSelfContained`, and setting only one still leaves the app unable to start on a clean machine.
And the Microsoft Store reserves the fourth version component, so versions must be `major.minor.build.0` or the submitted and published versions disagree.

## Getting the user's region

**macOS:** `Locale.current.region` and nothing else to think about.

**Windows:** `RegionInfo.CurrentRegion` works, but returns useless data when the app is built with `InvariantGlobalization=true`, which is a common default for trimmed CLI tools and was the initial setting here.
The symptom was a silently wrong electricity price rather than an exception, which is the kind of failure that survives review.

## Still open

Charts.
The macOS app has three, and CONTRIBUTING.md guards them harder than anything else in the repo: axes pinned to the requested window, recording gaps rendered as gaps, no interpolation across missing data.

The blocker was that there was nothing to plot, because history has to outlive a single process lifetime.
The SQLite store now exists and records coverage per hour alongside energy, specifically so a renderer can tell "measured, and the answer was low" from "not measured" and draw the second as a gap.
`HourBucket.IsPlottable` encodes that decision in one place rather than leaving each chart to invent its own threshold.

So the remaining work is rendering, plus wiring the app's sampling loop into the store.

Real icons for packaged apps.
Extraction reads the executable's resources, which is wrong for MSIX and Store apps whose real logo lives in the package manifest.
The current behaviour returns a generic icon rather than nothing, which is the worse failure mode because it cannot be detected and fallen back from.

Grouping processes into apps by executable name.
Correct for `msedge`, wrong for anything built on a shared host executable.
