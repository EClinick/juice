using Juice.Core.Attribution;
using Juice.Core.Power;
using Xunit;

namespace Juice.Core.Tests;

public class EnergyAttributorTests
{
    private static readonly DateTimeOffset T0 = new(2026, 1, 1, 0, 0, 0, TimeSpan.Zero);

    private static PowerSample Sample(
        DateTimeOffset at,
        double sysWatts,
        double cpuWatts,
        double gpuWatts,
        double? sysWh = null,
        double? cpuWh = null,
        double? gpuWh = null)
        => new()
        {
            Timestamp = at,
            Tier = PowerSourceTier.HardwareRail,
            SystemWatts = sysWatts,
            Rails =
            [
                new RailReading(PowerRail.System, "sys", sysWatts, sysWh),
                new RailReading(PowerRail.Cpu, "cpu_cluster_0", cpuWatts, cpuWh),
                new RailReading(PowerRail.Gpu, "gpu", gpuWatts, gpuWh),
            ],
        };

    private static ProcessSample Process(int pid, string name, double cpuSeconds, double gpu = 0)
        => new()
        {
            ProcessId = pid,
            ProcessName = name,
            TotalProcessorTime = TimeSpan.FromSeconds(cpuSeconds),
            GpuUtilization = gpu,
        };

    [Fact]
    public void AttributedEnergy_ExactlyReconcilesWithMeasuredRailEnergy()
    {
        var start = Sample(T0, 20, 10, 2, sysWh: 100, cpuWh: 50, gpuWh: 10);
        var end = Sample(T0.AddHours(1), 20, 10, 2, sysWh: 120, cpuWh: 60, gpuWh: 12);

        var before = new[] { Process(1, "a", 0, 10), Process(2, "b", 0, 10) };
        var after = new[] { Process(1, "a", 300, 10), Process(2, "b", 100, 10) };

        var result = new EnergyAttributor().Attribute(start, end, before, after);

        // The CPU rail moved 10 Wh and the GPU rail 2 Wh, so the apps must account for
        // exactly 12 Wh between them: no more, no less.
        Assert.Equal(12.0, result.Apps.Sum(a => a.TotalWattHours), 9);

        // The system rail moved 20 Wh, so 8 Wh is platform overhead.
        Assert.Equal(20.0, result.SystemWattHours, 9);
        Assert.Equal(8.0, result.PlatformWattHours, 9);
    }

    /// <summary>
    /// The invariant the whole app table rests on: what is shown must add up to what
    /// the hardware measured.
    /// </summary>
    [Fact]
    public void AppsPlusPlatform_AlwaysEqualsMeasuredSystemEnergy()
    {
        var start = Sample(T0, 20, 10, 2, sysWh: 0, cpuWh: 0, gpuWh: 0);
        var end = Sample(T0.AddHours(1), 20, 10, 2, sysWh: 20, cpuWh: 10, gpuWh: 2);

        var before = new[] { Process(1, "a", 0, 5), Process(2, "b", 0, 0) };
        var after = new[] { Process(1, "a", 300, 5), Process(2, "b", 100, 0) };

        var result = new EnergyAttributor().Attribute(start, end, before, after);

        Assert.Equal(
            result.SystemWattHours,
            result.Apps.Sum(a => a.TotalWattHours) + result.PlatformWattHours,
            9);
    }

    /// <summary>
    /// Rail energy that no process can be held responsible for must land in the platform
    /// bucket rather than disappearing from the totals.
    /// </summary>
    [Fact]
    public void UnattributableRailEnergy_FallsIntoPlatformOverhead()
    {
        var start = Sample(T0, 20, 10, 5, sysWh: 0, cpuWh: 0, gpuWh: 0);
        var end = Sample(T0.AddHours(1), 20, 10, 5, sysWh: 20, cpuWh: 10, gpuWh: 5);

        // The GPU rail burned 5 Wh but no process reports any GPU utilisation.
        var before = new[] { Process(1, "a", 0, 0) };
        var after = new[] { Process(1, "a", 3600, 0) };

        var result = new EnergyAttributor().Attribute(start, end, before, after);

        Assert.Equal(10.0, result.Apps.Sum(a => a.TotalWattHours), 9);
        Assert.Equal(10.0, result.PlatformWattHours, 9);
        Assert.Equal(
            result.SystemWattHours,
            result.Apps.Sum(a => a.TotalWattHours) + result.PlatformWattHours,
            9);
    }

    [Fact]
    public void CpuEnergy_SplitsByShareOfProcessorTime()
    {
        var start = Sample(T0, 20, 10, 0, sysWh: 0, cpuWh: 0, gpuWh: 0);
        var end = Sample(T0.AddHours(1), 20, 10, 0, sysWh: 20, cpuWh: 10, gpuWh: 0);

        var before = new[] { Process(1, "hog", 0), Process(2, "idle", 0) };
        var after = new[] { Process(1, "hog", 300), Process(2, "idle", 100) };

        var result = new EnergyAttributor().Attribute(start, end, before, after);

        var hog = result.Apps.Single(a => a.AppId == "hog");
        var idle = result.Apps.Single(a => a.AppId == "idle");

        Assert.Equal(7.5, hog.CpuWattHours, 9);
        Assert.Equal(2.5, idle.CpuWattHours, 9);
    }

    [Fact]
    public void GpuEnergy_SplitsByGpuShare_NotByCpuShare()
    {
        var start = Sample(T0, 20, 0, 4, sysWh: 0, cpuWh: 0, gpuWh: 0);
        var end = Sample(T0.AddHours(1), 20, 0, 4, sysWh: 20, cpuWh: 0, gpuWh: 4);

        // "render" burns no CPU but all the GPU; "build" is the reverse.
        var before = new[] { Process(1, "render", 0, 0), Process(2, "build", 0, 0) };
        var after = new[] { Process(1, "render", 1, 90), Process(2, "build", 500, 0) };

        var result = new EnergyAttributor().Attribute(start, end, before, after);

        Assert.Equal(4.0, result.Apps.Single(a => a.AppId == "render").GpuWattHours, 9);
        Assert.Equal(0.0, result.Apps.Single(a => a.AppId == "build").GpuWattHours, 9);
    }

    [Fact]
    public void AccumulatorIsPreferredOverIntegratingPower()
    {
        // Power readings claim 100 W, but the accumulator only moved 1 Wh. The
        // accumulator is ground truth and must win, because it captures what actually
        // happened between polls rather than what the endpoints suggest.
        var start = Sample(T0, 100, 100, 0, sysWh: 10, cpuWh: 10, gpuWh: 0);
        var end = Sample(T0.AddHours(1), 100, 100, 0, sysWh: 11, cpuWh: 11, gpuWh: 0);

        var result = new EnergyAttributor().Attribute(
            start, end, [Process(1, "a", 0)], [Process(1, "a", 3600)]);

        Assert.Equal(1.0, result.SystemWattHours, 9);
    }

    [Fact]
    public void AccumulatorReset_FallsBackToIntegration()
    {
        // A reboot or counter rollover moves the accumulator backwards. Reporting a
        // negative energy would poison every downstream total, so integration takes over.
        var start = Sample(T0, 10, 10, 0, sysWh: 500, cpuWh: 500, gpuWh: 0);
        var end = Sample(T0.AddHours(1), 10, 10, 0, sysWh: 1, cpuWh: 1, gpuWh: 0);

        var result = new EnergyAttributor().Attribute(
            start, end, [Process(1, "a", 0)], [Process(1, "a", 3600)]);

        Assert.Equal(10.0, result.SystemWattHours, 9);
        Assert.True(result.SystemWattHours > 0);
    }

    [Fact]
    public void ProcessAppearingMidInterval_CannotClaimMoreCpuThanTheInterval()
    {
        // A process with a long lifetime that first appears in the second sample must
        // not be credited with all its historical CPU time.
        var start = Sample(T0, 10, 10, 0, sysWh: 0, cpuWh: 0, gpuWh: 0);
        var end = Sample(T0.AddSeconds(10), 10, 10, 0, sysWh: 1, cpuWh: 1, gpuWh: 0);

        var before = new[] { Process(1, "old", 0) };
        var after = new[] { Process(1, "old", 10), Process(2, "newcomer", 100_000) };

        var result = new EnergyAttributor().Attribute(start, end, before, after);

        var newcomer = result.Apps.Single(a => a.AppId == "newcomer");
        var old = result.Apps.Single(a => a.AppId == "old");

        // Capped at the interval length, so it can never dominate the split outright.
        Assert.Equal(0.5, newcomer.CpuWattHours, 9);
        Assert.Equal(0.5, old.CpuWattHours, 9);
    }

    [Fact]
    public void PlatformOverhead_IsNeverNegative()
    {
        // Some machines meter compute rails that are not fully inside the system rail.
        var start = Sample(T0, 5, 10, 5, sysWh: 0, cpuWh: 0, gpuWh: 0);
        var end = Sample(T0.AddHours(1), 5, 10, 5, sysWh: 5, cpuWh: 10, gpuWh: 5);

        var result = new EnergyAttributor().Attribute(
            start, end, [Process(1, "a", 0)], [Process(1, "a", 3600)]);

        Assert.Equal(0.0, result.PlatformWattHours);
    }

    [Fact]
    public void ProcessesGroupIntoApps()
    {
        var start = Sample(T0, 10, 10, 0, sysWh: 0, cpuWh: 0, gpuWh: 0);
        var end = Sample(T0.AddHours(1), 10, 10, 0, sysWh: 10, cpuWh: 10, gpuWh: 0);

        var before = new[] { Process(1, "msedge", 0), Process(2, "msedge", 0) };
        var after = new[] { Process(1, "msedge", 100), Process(2, "msedge", 300) };

        var result = new EnergyAttributor().Attribute(start, end, before, after);

        var app = Assert.Single(result.Apps);
        Assert.Equal(10.0, app.TotalWattHours, 9);
        Assert.Equal(2, app.ProcessIds.Count);
    }

    [Fact]
    public void NonPositiveInterval_ProducesNothing()
    {
        var start = Sample(T0, 10, 10, 0);
        var result = new EnergyAttributor().Attribute(start, start, [], []);

        Assert.Empty(result.Apps);
        Assert.Equal(0, result.SystemWattHours);
    }
}
