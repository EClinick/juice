using System.Text.Json;
using System.Text.Json.Serialization;
using Juice.Core.Attribution;
using Juice.Core.Cost;
using Juice.Core.Power;
using Juice.Platform.Windows;

namespace Juice.Cli;

/// <summary>
/// Command line front end for Juice.
/// </summary>
/// <remarks>
/// <para>
/// This exists for two reasons. It gives scripts and AI tooling a machine-readable view
/// of the same measurements the GUI shows, via <c>--json</c> on every command. And it is
/// the audit path required by the repository rule that displayed numbers must be
/// verified against the raw source: <c>juice verify</c> re-derives energy independently
/// and reports the disagreement.
/// </para>
/// </remarks>
public static class Program
{
    private static readonly JsonSerializerOptions Json = new()
    {
        WriteIndented = true,
        DefaultIgnoreCondition = JsonIgnoreCondition.WhenWritingNull,
    };

    /// <summary>
    /// Below this, a battery is maintaining charge rather than charging. A full battery
    /// on AC trickles a few tens of milliwatts, and reporting that as "charging at 0.0 W"
    /// is worse than saying nothing.
    /// </summary>
    private const double ChargingThresholdWatts = 0.5;

    /// <summary>Entry point.</summary>
    public static int Main(string[] args)
    {
        var json = args.Contains("--json", StringComparer.OrdinalIgnoreCase);
        var command = args.FirstOrDefault(a => !a.StartsWith('-'))?.ToLowerInvariant() ?? "now";

        try
        {
            return command switch
            {
                "now" => Now(json),
                "top" => Top(args, json),
                "sources" => Sources(json),
                "verify" => Verify(args, json),
                "help" or "--help" or "-h" => Help(),
                _ => Unknown(command),
            };
        }
        catch (Exception ex)
        {
            Console.Error.WriteLine($"juice: {ex.Message}");
            return 1;
        }
    }

    private static int Help()
    {
        Console.WriteLine("""
            juice - what is eating your battery, and what it costs

            Usage:
              juice now                 Current system power draw
              juice top [--seconds N]   Top energy users over a sampling window
              juice sources             Power sources available on this machine
              juice verify [--seconds N] Audit energy accumulators against integrated power

            Options:
              --json                    Machine-readable output
              --seconds N               Sampling window length (default 10)
            """);
        return 0;
    }

    private static int Unknown(string command)
    {
        Console.Error.WriteLine($"juice: unknown command '{command}'. Try 'juice help'.");
        return 2;
    }

    private static int Now(bool json)
    {
        using var source = CompositePowerSource.CreateDefault();

        // The hardware power counters average since the previous read, so a one-shot
        // command has to establish a baseline and let a measurable interval elapse.
        source.Prime(TimeSpan.FromMilliseconds(700));

        if (source.Read() is not { } sample)
        {
            if (json) Console.WriteLine("""{"available":false}""");
            else Console.Error.WriteLine("juice: no power source available on this machine.");
            return 1;
        }

        if (json)
        {
            Console.WriteLine(JsonSerializer.Serialize(new
            {
                available = true,
                timestamp = sample.Timestamp,
                tier = sample.Tier.ToString(),
                systemWatts = sample.SystemWatts,
                cpuWatts = sample.WattsFor(PowerRail.Cpu),
                gpuWatts = sample.WattsFor(PowerRail.Gpu),
                npuWatts = sample.WattsFor(PowerRail.Npu),
                supplyWatts = sample.WattsFor(PowerRail.Supply),
                onAc = sample.OnAc,
                batteryPercent = sample.BatteryPercent,
                chargeWatts = sample.ChargeWatts,
            }, Json));
            return 0;
        }

        Console.WriteLine($"Draw       {PowerFormatter.Watts(sample.SystemWatts)}   ({sample.Tier})");
        WriteRail("CPU", sample.WattsFor(PowerRail.Cpu));
        WriteRail("GPU", sample.WattsFor(PowerRail.Gpu));
        WriteRail("NPU", sample.WattsFor(PowerRail.Npu));
        WriteRail("Supply", sample.WattsFor(PowerRail.Supply));

        if (sample.BatteryPercent is { } percent)
        {
            var state = sample.OnAc
                ? sample.ChargeWatts is { } cw && cw >= ChargingThresholdWatts
                    ? $"charging at {cw:0.0} W"
                    : "plugged in"
                : "on battery";
            Console.WriteLine($"Battery    {percent:0}%   ({state})");
        }

        return 0;
    }

    private static void WriteRail(string label, double? watts)
    {
        if (watts is { } w) Console.WriteLine($"{label,-10} {w,6:0.00} W");
    }

    private static int Sources(bool json)
    {
        using var composite = CompositePowerSource.CreateDefault();
        using var processes = new ProcessSampler();

        var entries = composite.Sources
            .Select(s => new { tier = s.Tier.ToString(), available = s.IsAvailable, description = s.Description })
            .ToList();

        if (json)
        {
            Console.WriteLine(JsonSerializer.Serialize(new
            {
                selected = composite.Tier.ToString(),
                sources = entries,
                gpuPerProcess = processes.GpuCountersAvailable,
                nativeProcessTable = processes.UsingNativeProcessTable,
            }, Json));
            return 0;
        }

        Console.WriteLine($"Selected tier: {composite.Tier}");
        foreach (var e in entries)
        {
            Console.WriteLine($"  [{(e.available ? "x" : " ")}] {e.tier,-13} {e.description}");
        }

        Console.WriteLine($"  [{(processes.GpuCountersAvailable ? "x" : " ")}] per-process GPU utilisation");
        return 0;
    }

    private static int Top(string[] args, bool json)
    {
        var seconds = ReadSeconds(args, 10);

        using var source = CompositePowerSource.CreateDefault();
        using var sampler = new ProcessSampler();

        // Prime both: PDH rate counters yield nothing until collected twice.
        sampler.Sample();
        var first = source.Read();
        var firstProcesses = sampler.Sample().ToList();

        Thread.Sleep(TimeSpan.FromSeconds(seconds));

        var second = source.Read();
        var secondProcesses = sampler.Sample().ToList();

        if (first is null || second is null)
        {
            Console.Error.WriteLine("juice: could not measure power on this machine.");
            return 1;
        }

        var result = new EnergyAttributor().Attribute(first, second, firstProcesses, secondProcesses);
        var rate = new BundledRateTable().ResolveFor(RegionResolver.CurrentRegionCode());

        var top = result.Apps.Take(15).ToList();

        if (json)
        {
            Console.WriteLine(JsonSerializer.Serialize(new
            {
                start = result.Start,
                end = result.End,
                systemWattHours = result.SystemWattHours,
                platformWattHours = result.PlatformWattHours,
                rate = new { rate.PricePerKwh, rate.Currency, rate.RegionCode, estimate = rate.IsEstimate },
                apps = top.Select(a => new
                {
                    a.AppId,
                    a.DisplayName,
                    a.Watts,
                    a.TotalWattHours,
                    a.CpuWattHours,
                    a.GpuWattHours,
                    annualCost = CostCalculator.AnnualCostOfSustainedWatts(a.Watts, rate),
                }),
            }, Json));
            return 0;
        }

        Console.WriteLine($"Measured {PowerFormatter.Energy(result.SystemWattHours)} over {seconds}s");
        Console.WriteLine($"Rate {rate.PricePerKwh:0.000} {rate.Currency}/kWh ({rate.RegionName}{(rate.IsEstimate ? ", estimate" : "")})");
        Console.WriteLine();
        Console.WriteLine($"{"App",-28}{"W",8}{"CPU W",10}{"GPU W",10}{"$/yr",10}");

        foreach (var app in top)
        {
            var annual = CostCalculator.AnnualCostOfSustainedWatts(app.Watts, rate);
            var cpuW = app.CpuWattHours / ((result.End - result.Start).TotalHours);
            var gpuW = app.GpuWattHours / ((result.End - result.Start).TotalHours);
            Console.WriteLine($"{Truncate(app.DisplayName, 27),-28}{app.Watts,8:0.00}{cpuW,10:0.00}{gpuW,10:0.00}{annual,10:0.00}");
        }

        Console.WriteLine();
        Console.WriteLine($"{"System and display",-28}{result.PlatformWattHours / (result.End - result.Start).TotalHours,8:0.00}");
        return 0;
    }

    private static int Verify(string[] args, bool json)
    {
        var seconds = ReadSeconds(args, 30);

        using var meter = new EnergyMeterPowerSource(new WmiBatteryStateReader());
        if (!meter.IsAvailable)
        {
            Console.Error.WriteLine("juice: this machine has no hardware energy meter to verify.");
            return 1;
        }

        var audit = EnergyAudit.Run(meter, TimeSpan.FromSeconds(seconds));

        if (json)
        {
            Console.WriteLine(JsonSerializer.Serialize(audit, Json));
            return 0;
        }

        Console.WriteLine($"Window            {audit.Seconds:0.0} s");
        Console.WriteLine($"Accumulator       {audit.AccumulatorWattHours:0.000000} Wh");
        Console.WriteLine($"Integrated power  {audit.IntegratedWattHours:0.000000} Wh");
        Console.WriteLine($"Disagreement      {audit.PercentDifference:0.000} %");
        Console.WriteLine();
        Console.WriteLine(audit.Passed
            ? "PASS - the energy accumulator and the power counter agree."
            : "FAIL - the two derivations disagree by more than the tolerance.");

        return audit.Passed ? 0 : 1;
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
