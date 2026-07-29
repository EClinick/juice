using System.Text.Json;
using Juice.Core.Attribution;
using Juice.Core.Battery;
using Juice.Core.Contracts;
using Juice.Core.Cost;
using Juice.Core.Power;
using Juice.Platform.Windows;

namespace Juice.Cli;

/// <summary>
/// Command line front end for Juice.
/// </summary>
/// <remarks>
/// <para>
/// There are two modes. The default is a human-readable terminal view. The
/// <c>--json</c> switch selects tools mode for scripts and AI agents, where stdout is
/// entirely machine-readable, including failures, so a caller never has to parse two
/// formats or scrape stderr to find out what went wrong.
/// </para>
/// <para>
/// The shape of that output is defined by <see cref="JuiceSchema"/> and versioned
/// independently of the command set, because the schema is the contract.
/// </para>
/// </remarks>
public static class Program
{
    private const int ExitOk = 0;
    private const int ExitFailed = 1;
    private const int ExitUsage = 2;

    /// <summary>Entry point.</summary>
    public static int Main(string[] args)
    {
        var command = args.FirstOrDefault(a => !a.StartsWith('-'))?.ToLowerInvariant() ?? "now";

        if (!TryReadJsonMode(args, out var json, out var requested))
        {
            return Fail(true, command, "schemaUnsupported",
                $"Schema '{requested}' is not supported. This build emits {JuiceSchema.Version}.",
                ExitUsage);
        }

        try
        {
            return command switch
            {
                "now" => Now(json),
                "top" => Top(args, json),
                "sources" => Sources(json),
                "battery" => Battery(json),
                "verify" => Verify(args, json),
                "help" or "--help" or "-h" => Help(),
                _ => Fail(json, command, "unknownCommand", $"Unknown command '{command}'.", ExitUsage),
            };
        }
        catch (Exception ex)
        {
            return Fail(json, command, "unexpected", ex.Message, ExitFailed);
        }
    }

    /// <summary>
    /// Parses <c>--json</c>, optionally pinned as <c>--json=0.1</c>.
    /// </summary>
    /// <remarks>
    /// <para>
    /// The switch is named for the encoding because that is what the ecosystem
    /// standardised on, but what a consumer actually depends on is the shape being
    /// stable. Allowing the version to be pinned lets a tool state the contract it was
    /// written against and be told immediately when this build cannot honour it, rather
    /// than silently misreading a changed document.
    /// </para>
    /// <para>
    /// The precedent is <c>git --porcelain=v2</c> rather than anything AI specific.
    /// Only the major version has to match: additive changes within a major version are
    /// backwards compatible by definition, since unknown properties are ignorable and
    /// absent ones were already optional.
    /// </para>
    /// </remarks>
    private static bool TryReadJsonMode(string[] args, out bool json, out string? requested)
    {
        json = false;
        requested = null;

        foreach (var arg in args)
        {
            if (arg.Equals("--json", StringComparison.OrdinalIgnoreCase))
            {
                json = true;
                continue;
            }

            if (!arg.StartsWith("--json=", StringComparison.OrdinalIgnoreCase)) continue;

            json = true;
            requested = arg["--json=".Length..];

            var wanted = requested.Split('.', 2)[0];
            var have = JuiceSchema.Version.Split('.', 2)[0];

            if (!wanted.Equals(have, StringComparison.Ordinal)) return false;
        }

        return true;
    }

    private static void Emit<T>(T document) where T : JuiceDocument
        => Console.WriteLine(JsonSerializer.Serialize(document, typeof(T), JuiceSchema.Options));

    /// <summary>
    /// Reports a failure in whichever form the caller asked for.
    /// </summary>
    /// <remarks>
    /// In tools mode the error goes to stdout inside the standard envelope so that a
    /// consumer can branch on <c>ok</c>. In human mode it goes to stderr as prose.
    /// </remarks>
    private static int Fail(bool json, string command, string code, string message, int exitCode)
    {
        if (json)
        {
            Emit(new ErrorDocument
            {
                Command = command,
                Ok = false,
                Error = new JuiceError(code, message),
            });
        }
        else
        {
            Console.Error.WriteLine($"juice: {message}");
        }

        return exitCode;
    }

    private static int Help()
    {
        Console.WriteLine($"""
            juice - what is eating your battery, and what it costs

            Usage:
              juice now                  Current system power draw
              juice top [--seconds N]    Top energy users over a sampling window
              juice sources              Power sources available on this machine
              juice verify [--seconds N] Audit energy accumulators against integrated power

            Options:
              --json[=VERSION]           Tools mode. All output machine-readable.
                                         Pin the contract with --json={JuiceSchema.Version} to be told
                                         immediately if this build cannot honour it.
              --seconds N                Sampling window length

            Exit codes:
              0  success
              1  the command ran but could not produce a result
              2  usage error
            """);
        return ExitOk;
    }

    private static MeasurementConfidence ConfidenceOf(PowerSourceTier tier) => tier switch
    {
        PowerSourceTier.HardwareRail or PowerSourceTier.Battery => MeasurementConfidence.Measured,
        PowerSourceTier.Modelled => MeasurementConfidence.Estimated,
        _ => MeasurementConfidence.Unavailable,
    };

    private static string TierName(PowerSourceTier tier) => tier switch
    {
        PowerSourceTier.HardwareRail => "hardwareRail",
        PowerSourceTier.Battery => "battery",
        PowerSourceTier.Modelled => "modelled",
        _ => "none",
    };

    /// <summary>
    /// Builds the rail block, returning null when nothing was metered so the property is
    /// omitted rather than serialised as an object full of nulls.
    /// </summary>
    private static RailsDto? RailsOf(PowerSample sample)
    {
        var cpu = sample.WattsFor(PowerRail.Cpu);
        var gpu = sample.WattsFor(PowerRail.Gpu);
        var npu = sample.WattsFor(PowerRail.Npu);
        var supply = sample.WattsFor(PowerRail.Supply);

        if (cpu is null && gpu is null && npu is null && supply is null) return null;

        return new RailsDto { Cpu = cpu, Gpu = gpu, Npu = npu, Supply = supply };
    }

    private static BatteryDto BatteryOf(PowerSample sample)
    {
        if (sample.BatteryPercent is null) return new BatteryDto { Present = false };

        var charging = sample.ChargeWatts is { } cw && cw >= PowerFormatter.ChargingThresholdWatts;

        return new BatteryDto
        {
            Present = true,
            Percent = sample.BatteryPercent,
            Flow = sample.OnAc
                ? charging ? BatteryFlow.Charging : BatteryFlow.PluggedIn
                : BatteryFlow.Discharging,
            ChargeWatts = charging ? sample.ChargeWatts : null,
        };
    }

    private static int Now(bool json)
    {
        using var source = CompositePowerSource.CreateDefault();

        // The hardware power counters average since the previous read, so a one-shot
        // command has to establish a baseline and let a measurable interval elapse.
        source.Prime(TimeSpan.FromMilliseconds(1200));

        if (source.Read() is not { } sample)
        {
            return Fail(json, "now", "noPowerSource",
                "No power source is available on this machine.", ExitFailed);
        }

        if (json)
        {
            Emit(new NowDocument
            {
                Command = "now",
                Measurement = new MeasurementDto
                {
                    Confidence = sample.SystemWatts is null
                        ? MeasurementConfidence.Unavailable
                        : ConfidenceOf(sample.Tier),
                    Source = TierName(sample.Tier),
                    SystemWatts = sample.SystemWatts,
                    Rails = RailsOf(sample),
                },
                Battery = BatteryOf(sample),
            });
            return ExitOk;
        }

        Console.WriteLine($"Draw       {PowerFormatter.Watts(sample.SystemWatts)}   ({sample.Tier})");
        WriteRail("CPU", sample.WattsFor(PowerRail.Cpu));
        WriteRail("GPU", sample.WattsFor(PowerRail.Gpu));
        WriteRail("NPU", sample.WattsFor(PowerRail.Npu));
        WriteRail("Supply", sample.WattsFor(PowerRail.Supply));

        if (sample.BatteryPercent is { } percent)
        {
            var state = sample.OnAc
                ? sample.ChargeWatts is { } cw && cw >= PowerFormatter.ChargingThresholdWatts
                    ? $"charging at {cw:0.0} W"
                    : "plugged in"
                : "on battery";
            Console.WriteLine($"Battery    {percent:0}%   ({state})");
        }

        return ExitOk;
    }

    private static void WriteRail(string label, double? watts)
    {
        if (watts is { } w) Console.WriteLine($"{label,-10} {w,6:0.00} W");
    }

    private static int Sources(bool json)
    {
        using var composite = CompositePowerSource.CreateDefault();
        using var processes = new ProcessSampler();
        using var icons = new AppIconResolver();

        var taskbar = TaskbarAppearanceReader.Read();

        // Probe icon extraction against a system binary that definitely carries an icon.
        // Probing the current process would be misleading: a bare .NET apphost has no
        // icon resource at all, so a null there says nothing about the capability.
        var iconProbe = icons.GetIconPngForPath(
            Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.Windows), "explorer.exe"));
        var iconsWork = iconProbe is { Length: > 0 };

        if (json)
        {
            Emit(new SourcesDocument
            {
                Command = "sources",
                Selected = TierName(composite.Tier),
                Sources = composite.Sources.Select(s => new SourceDto
                {
                    Name = TierName(s.Tier),
                    Confidence = ConfidenceOf(s.Tier),
                    Available = s.IsAvailable,
                    Description = s.Description,
                }).ToList(),
                Capabilities = new Dictionary<string, bool>
                {
                    ["perProcessGpu"] = processes.GpuCountersAvailable,
                    ["nativeProcessTable"] = processes.UsingNativeProcessTable,
                    ["appIcons"] = iconsWork,
                    ["taskbarLightTheme"] = taskbar.IsLightTheme,
                    ["accentOnTaskbar"] = taskbar.AccentOnTaskbar,
                },
            });
            return ExitOk;
        }

        Console.WriteLine($"Selected tier: {composite.Tier}");
        foreach (var s in composite.Sources)
        {
            Console.WriteLine($"  [{(s.IsAvailable ? "x" : " ")}] {s.Tier,-13} {s.Description}");
        }

        Console.WriteLine($"  [{(processes.GpuCountersAvailable ? "x" : " ")}] per-process GPU utilisation");
        Console.WriteLine($"  [{(processes.UsingNativeProcessTable ? "x" : " ")}] bulk process table");
        Console.WriteLine($"  [{(iconsWork ? "x" : " ")}] app icon extraction");
        Console.WriteLine();
        Console.WriteLine($"Taskbar: {(taskbar.IsLightTheme ? "light" : "dark")}, accent {(taskbar.AccentOnTaskbar ? "on" : "off")}, "
            + $"RGB({taskbar.Accent.R},{taskbar.Accent.G},{taskbar.Accent.B})");
        return ExitOk;
    }

    private static int Top(string[] args, bool json)
    {
        var seconds = ReadSeconds(args, 10);

        using var source = CompositePowerSource.CreateDefault();
        using var sampler = new ProcessSampler();

        // Both the rail counters and the PDH rate counters need a baseline before they
        // return anything meaningful.
        sampler.Sample();
        source.Prime(TimeSpan.FromMilliseconds(1200));

        var first = source.Read();

        // ProcessSampler reuses its buffer between calls, so this has to be copied.
        var firstProcesses = sampler.Sample().ToList();

        Thread.Sleep(TimeSpan.FromSeconds(seconds));

        var second = source.Read();
        var secondProcesses = sampler.Sample().ToList();

        if (first is null || second is null)
        {
            return Fail(json, "top", "noPowerSource",
                "Could not measure power on this machine.", ExitFailed);
        }

        var result = new EnergyAttributor().Attribute(first, second, firstProcesses, secondProcesses);
        var rate = new BundledRateTable().ResolveFor(RegionResolver.CurrentRegionCode());
        var hours = (result.End - result.Start).TotalHours;
        var top = result.Apps.Take(15).ToList();

        if (json)
        {
            Emit(new TopDocument
            {
                Command = "top",
                Window = new WindowDto { Start = result.Start, End = result.End },
                Energy = new EnergyTotalsDto
                {
                    SystemWattHours = result.SystemWattHours,
                    AttributedWattHours = result.Apps.Sum(a => a.TotalWattHours),
                    PlatformWattHours = result.PlatformWattHours,
                },
                Rate = new RateDto
                {
                    PricePerKwh = rate.PricePerKwh,
                    Currency = rate.Currency,
                    RegionCode = rate.RegionCode,
                    RegionName = rate.RegionName,
                    IsEstimate = rate.IsEstimate,
                },
                Apps = top.Select(a => new AppEnergyDto
                {
                    AppId = a.AppId,
                    DisplayName = a.DisplayName,
                    Watts = a.Watts,
                    WattHours = a.TotalWattHours,
                    Components = new RailsDto
                    {
                        Cpu = a.CpuWattHours,
                        Gpu = a.GpuWattHours,
                    },
                    ProcessIds = a.ProcessIds,
                    AnnualCost = CostCalculator.AnnualCostOfSustainedWatts(a.Watts, rate),
                }).ToList(),
            });
            return ExitOk;
        }

        Console.WriteLine($"Measured {PowerFormatter.Energy(result.SystemWattHours)} over {seconds}s");
        Console.WriteLine($"Rate {rate.PricePerKwh:0.000} {rate.Currency}/kWh ({rate.RegionName}{(rate.IsEstimate ? ", estimate" : "")})");
        Console.WriteLine();
        Console.WriteLine($"{"App",-28}{"W",8}{"CPU W",10}{"GPU W",10}{"$/yr",10}");

        foreach (var app in top)
        {
            var annual = CostCalculator.AnnualCostOfSustainedWatts(app.Watts, rate);
            var cpuW = hours > 0 ? app.CpuWattHours / hours : 0;
            var gpuW = hours > 0 ? app.GpuWattHours / hours : 0;
            Console.WriteLine($"{Truncate(app.DisplayName, 27),-28}{app.Watts,8:0.00}{cpuW,10:0.00}{gpuW,10:0.00}{annual,10:0.00}");
        }

        Console.WriteLine();
        var platformWatts = hours > 0 ? result.PlatformWattHours / hours : 0;
        Console.WriteLine($"{"System and display",-28}{platformWatts,8:0.00}");
        return ExitOk;
    }

    private static int Verify(string[] args, bool json)    {
        var seconds = ReadSeconds(args, 30);

        using var meter = new EnergyMeterPowerSource(new WmiBatteryStateReader());
        if (!meter.IsAvailable)
        {
            return Fail(json, "verify", "noHardwareMeter",
                "This machine has no hardware energy meter to verify.", ExitFailed);
        }

        meter.Prime(TimeSpan.FromMilliseconds(1200));
        var audit = EnergyAudit.Run(meter, TimeSpan.FromSeconds(seconds));

        if (json)
        {
            Emit(new VerifyDocument
            {
                Command = "verify",
                Ok = audit.Passed,
                Error = audit.Passed
                    ? null
                    : new JuiceError("auditFailed",
                        "The energy accumulator and the integrated power counter disagree beyond tolerance."),
                Seconds = audit.Seconds,
                AccumulatorWattHours = audit.AccumulatorWattHours,
                IntegratedWattHours = audit.IntegratedWattHours,
                PercentDifference = audit.PercentDifference,
                TolerancePercent = audit.TolerancePercent,
                SampleCount = audit.SampleCount,
                Passed = audit.Passed,
            });
            return audit.Passed ? ExitOk : ExitFailed;
        }

        Console.WriteLine($"Window            {audit.Seconds:0.0} s");
        Console.WriteLine($"Accumulator       {audit.AccumulatorWattHours:0.000000} Wh");
        Console.WriteLine($"Integrated power  {audit.IntegratedWattHours:0.000000} Wh");
        Console.WriteLine($"Disagreement      {audit.PercentDifference:0.000} %");
        Console.WriteLine();
        Console.WriteLine(audit.Passed
            ? "PASS - the energy accumulator and the power counter agree."
            : "FAIL - the two derivations disagree by more than the tolerance.");

        return audit.Passed ? ExitOk : ExitFailed;
    }

    /// <summary>
    /// Reports battery health from the Windows battery report.
    /// </summary>
    /// <remarks>
    /// This is history Juice could not reconstruct itself, because it predates the app
    /// being installed. The report needs no elevation and reaches back over the machine's
    /// whole life.
    /// </remarks>
    private static int Battery(bool json)
    {
        if (BatteryReportReader.Read() is not { } health)
        {
            return Fail(json, "battery", "noBatteryReport",
                "Could not generate a battery report on this machine.", ExitFailed);
        }

        if (health.Current is not { } current)
        {
            return Fail(json, "battery", "noBattery",
                "This machine has no battery history.", ExitFailed);
        }

        if (json)
        {
            Console.WriteLine(JsonSerializer.Serialize(new
            {
                schemaVersion = JuiceSchema.Version,
                platform = "windows",
                command = "battery",
                ok = true,
                designWattHours = current.DesignWattHours,
                fullChargeWattHours = current.FullChargeWattHours,
                healthFraction = current.HealthFraction,
                cycleCount = current.CycleCount,
                capacityLostPercent = health.CapacityLostPercent,
                historyEntries = health.History.Count,
                summary = health.Summary(),
            }, JuiceSchema.Options));
            return ExitOk;
        }

        Console.WriteLine(health.Summary());
        Console.WriteLine();
        Console.WriteLine($"Design capacity     {current.DesignWattHours,7:0.0} Wh");
        Console.WriteLine($"Full charge now     {current.FullChargeWattHours,7:0.0} Wh");

        if (current.HealthFraction is { } fraction)
        {
            Console.WriteLine($"Health              {fraction * 100,7:0.0} %");
        }

        if (current.CycleCount is { } cycles)
        {
            Console.WriteLine($"Cycles              {cycles,7}");
        }

        if (health.CapacityLostPercent is { } lost)
        {
            Console.WriteLine($"Lost since {health.Oldest!.Start:yyyy-MM-dd} {lost,7:0.0} points");
        }

        Console.WriteLine($"History entries     {health.History.Count,7}");
        return ExitOk;
    }

    private static int ReadSeconds(string[] args, int fallback)
    {
        var index = Array.FindIndex(args, a => a.Equals("--seconds", StringComparison.OrdinalIgnoreCase));
        if (index < 0 || index + 1 >= args.Length) return fallback;
        return int.TryParse(args[index + 1], out var value) && value > 0 ? value : fallback;
    }

    private static string Truncate(string value, int max)
        => value.Length <= max ? value : value[..max];
}
