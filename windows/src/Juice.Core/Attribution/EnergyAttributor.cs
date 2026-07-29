using Juice.Core.Power;

namespace Juice.Core.Attribution;

/// <summary>A raw per-process resource observation taken at one instant.</summary>
public readonly record struct ProcessSample
{
    /// <summary>Operating system process id.</summary>
    public required int ProcessId { get; init; }

    /// <summary>Executable name without extension, e.g. <c>msedge</c>.</summary>
    public required string ProcessName { get; init; }

    /// <summary>Full image path when readable, otherwise null.</summary>
    public string? ExecutablePath { get; init; }

    /// <summary>Cumulative processor time consumed by the process since it started.</summary>
    public required TimeSpan TotalProcessorTime { get; init; }

    /// <summary>
    /// Sum of this process's GPU engine utilisation percentages across all engines.
    /// Taken from <c>\GPU Engine(pid_*)\Utilization Percentage</c>; may exceed 100 when
    /// several engines are busy, which is why it is normalised as a share, not a percent.
    /// </summary>
    public double GpuUtilization { get; init; }
}

/// <summary>
/// The energy Juice attributes to one app over an interval, split by the rail it came
/// from. Mirrors the CPU / GPU / Neural Engine breakdown the macOS original shows.
/// </summary>
public sealed record AppEnergy
{
    /// <summary>Stable key used to group processes into one app.</summary>
    public required string AppId { get; init; }

    /// <summary>Name shown in the UI.</summary>
    public required string DisplayName { get; init; }

    /// <summary>Energy attributed from the CPU rail.</summary>
    public double CpuWattHours { get; init; }

    /// <summary>Energy attributed from the GPU rail.</summary>
    public double GpuWattHours { get; init; }

    /// <summary>Total attributed energy.</summary>
    public double TotalWattHours => CpuWattHours + GpuWattHours;

    /// <summary>Average watts implied over the interval this record covers.</summary>
    public double Watts { get; init; }

    /// <summary>Process ids that contributed, for the detail view.</summary>
    public IReadOnlyList<int> ProcessIds { get; init; } = [];
}

/// <summary>Result of attributing one interval of measured rail energy across apps.</summary>
public sealed record AttributionResult
{
    /// <summary>Interval start (UTC).</summary>
    public required DateTimeOffset Start { get; init; }

    /// <summary>Interval end (UTC).</summary>
    public required DateTimeOffset End { get; init; }

    /// <summary>Per-app attributed energy, ordered by total descending.</summary>
    public IReadOnlyList<AppEnergy> Apps { get; init; } = [];

    /// <summary>
    /// Energy measured on the system rail that no app can be held responsible for -
    /// display backlight, radios, sensors, voltage-regulator loss. Reported separately
    /// and never silently folded into app totals.
    /// </summary>
    public double PlatformWattHours { get; init; }

    /// <summary>Total system energy measured over the interval.</summary>
    public double SystemWattHours { get; init; }
}

/// <summary>
/// Splits measured rail energy across processes.
/// </summary>
/// <remarks>
/// <para>
/// Windows exposes no per-process wattage API, but on hardware with an Energy Meter
/// the CPU and GPU rails are metered <i>separately</i>. That lets Juice avoid the usual
/// crude approach of scaling one blended number by CPU percent:
/// </para>
/// <list type="bullet">
/// <item>CPU rail energy is divided by each process's share of processor time consumed
/// during the interval.</item>
/// <item>GPU rail energy is divided by each process's share of GPU engine utilisation.</item>
/// <item>Whatever the system rail measured beyond CPU + GPU is <i>not</i> attributed to
/// any app; it is reported as platform overhead.</item>
/// </list>
/// <para>
/// The division is exact: attributed energy always sums to the measured rail energy, so
/// the app table reconciles with the hardware total rather than drifting from it.
/// </para>
/// </remarks>
public sealed class EnergyAttributor
{
    private readonly Func<ProcessSample, string> _appIdSelector;
    private readonly Func<ProcessSample, string> _displayNameSelector;

    /// <summary>Creates an attributor with optional custom app grouping.</summary>
    public EnergyAttributor(
        Func<ProcessSample, string>? appIdSelector = null,
        Func<ProcessSample, string>? displayNameSelector = null)
    {
        _appIdSelector = appIdSelector ?? (p => p.ProcessName.ToLowerInvariant());
        _displayNameSelector = displayNameSelector ?? (p => p.ProcessName);
    }

    /// <summary>
    /// Attributes the energy measured between two power samples across the processes
    /// alive for both of them.
    /// </summary>
    /// <param name="start">Sample opening the interval.</param>
    /// <param name="end">Sample closing the interval.</param>
    /// <param name="startProcesses">Process samples taken with <paramref name="start"/>.</param>
    /// <param name="endProcesses">Process samples taken with <paramref name="end"/>.</param>
    public AttributionResult Attribute(
        PowerSample start,
        PowerSample end,
        IReadOnlyList<ProcessSample> startProcesses,
        IReadOnlyList<ProcessSample> endProcesses)
    {
        var duration = end.Timestamp - start.Timestamp;
        if (duration <= TimeSpan.Zero)
        {
            return new AttributionResult { Start = start.Timestamp, End = end.Timestamp };
        }

        var cpuWh = RailEnergy(start, end, PowerRail.Cpu, duration);
        var gpuWh = RailEnergy(start, end, PowerRail.Gpu, duration);
        var sysWh = RailEnergy(start, end, PowerRail.System, duration);

        // Processor time is cumulative per process, so the delta between the two samples
        // is exactly the CPU time that process consumed inside the interval.
        var startById = startProcesses.ToDictionary(p => p.ProcessId);
        var cpuDeltas = new Dictionary<int, double>();
        var gpuWeights = new Dictionary<int, double>();

        foreach (var p in endProcesses)
        {
            var cpuSeconds = startById.TryGetValue(p.ProcessId, out var prev)
                ? (p.TotalProcessorTime - prev.TotalProcessorTime).TotalSeconds
                // A process that appeared mid-interval has consumed all of its CPU time
                // inside the interval, but never more than the interval itself.
                : Math.Min(p.TotalProcessorTime.TotalSeconds, duration.TotalSeconds);

            if (cpuSeconds > 0) cpuDeltas[p.ProcessId] = cpuSeconds;

            // GPU utilisation is instantaneous, so average the endpoints when we have both.
            var gpu = startById.TryGetValue(p.ProcessId, out var prevGpu)
                ? (p.GpuUtilization + prevGpu.GpuUtilization) / 2.0
                : p.GpuUtilization;

            if (gpu > 0) gpuWeights[p.ProcessId] = gpu;
        }

        var cpuTotal = cpuDeltas.Values.Sum();
        var gpuTotal = gpuWeights.Values.Sum();

        var byApp = new Dictionary<string, (string Name, double Cpu, double Gpu, List<int> Pids)>();

        foreach (var p in endProcesses)
        {
            var cpuShare = cpuTotal > 0 && cpuDeltas.TryGetValue(p.ProcessId, out var c)
                ? c / cpuTotal : 0.0;
            var gpuShare = gpuTotal > 0 && gpuWeights.TryGetValue(p.ProcessId, out var g)
                ? g / gpuTotal : 0.0;

            if (cpuShare <= 0 && gpuShare <= 0) continue;

            var id = _appIdSelector(p);
            var entry = byApp.TryGetValue(id, out var e)
                ? e
                : (Name: _displayNameSelector(p), Cpu: 0.0, Gpu: 0.0, Pids: new List<int>());

            entry.Cpu += cpuWh * cpuShare;
            entry.Gpu += gpuWh * gpuShare;
            entry.Pids.Add(p.ProcessId);
            byApp[id] = entry;
        }

        var hours = duration.TotalHours;
        var apps = byApp
            .Select(kv => new AppEnergy
            {
                AppId = kv.Key,
                DisplayName = kv.Value.Name,
                CpuWattHours = kv.Value.Cpu,
                GpuWattHours = kv.Value.Gpu,
                Watts = hours > 0 ? (kv.Value.Cpu + kv.Value.Gpu) / hours : 0,
                ProcessIds = kv.Value.Pids,
            })
            .OrderByDescending(a => a.TotalWattHours)
            .ToList();

        // Platform overhead is defined as everything the system rail measured that was
        // not attributed to an app, rather than as sys minus the compute rails.
        //
        // The distinction matters whenever a rail burns energy that no process claims:
        // the GPU rail draws power with no process reporting GPU utilisation, or a
        // protected process Juice cannot read consumes CPU. Defining overhead as the
        // residual guarantees the invariant that apps plus platform always equals the
        // measured system energy, so energy is never silently lost from the totals.
        var attributed = apps.Sum(a => a.TotalWattHours);
        var platform = Math.Max(0.0, sysWh - attributed);

        return new AttributionResult
        {
            Start = start.Timestamp,
            End = end.Timestamp,
            Apps = apps,
            PlatformWattHours = platform,
            SystemWattHours = sysWh,
        };
    }

    /// <summary>
    /// Energy on a rail over the interval. Uses the hardware accumulator when both
    /// samples carry one, because that captures energy Juice would otherwise lose
    /// between polls; falls back to trapezoid integration of the power readings.
    /// </summary>
    private static double RailEnergy(PowerSample start, PowerSample end, PowerRail rail, TimeSpan duration)
    {
        if (start.CumulativeWattHoursFor(rail) is { } a && end.CumulativeWattHoursFor(rail) is { } b)
        {
            var delta = b - a;
            // Accumulators reset on reboot or counter rollover; a negative delta means
            // the baseline moved, so fall through to integration rather than report a
            // negative energy.
            if (delta >= 0) return delta;
        }

        var w0 = start.WattsFor(rail);
        var w1 = end.WattsFor(rail);
        if (w0 is null && w1 is null) return 0;

        var avg = ((w0 ?? w1)!.Value + (w1 ?? w0)!.Value) / 2.0;
        return EnergyUnits.WattHoursFrom(avg, duration);
    }
}
