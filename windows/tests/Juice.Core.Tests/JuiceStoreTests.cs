using Juice.Core.Attribution;
using Juice.Core.Storage;
using Xunit;

namespace Juice.Core.Tests;

public class JuiceStoreTests : IDisposable
{
    private readonly string _path = Path.Combine(Path.GetTempPath(), $"juice-test-{Guid.NewGuid():N}.db");
    private JuiceStore? _store;

    private JuiceStore Store => _store ??= JuiceStore.Open(_path);

    private static AttributionResult Interval(
        DateTimeOffset start, DateTimeOffset end, double systemWh, double platformWh, params (string Id, double Cpu, double Gpu)[] apps)
        => new()
        {
            Start = start,
            End = end,
            SystemWattHours = systemWh,
            PlatformWattHours = platformWh,
            Apps = apps.Select(a => new AppEnergy
            {
                AppId = a.Id,
                DisplayName = a.Id,
                CpuWattHours = a.Cpu,
                GpuWattHours = a.Gpu,
            }).ToList(),
        };

    [Fact]
    public void RecordsAndAggregatesEnergyIntoHourBuckets()
    {
        var hour = JuiceStore.AlignToHour(DateTimeOffset.Now);

        Store.RecordInterval(Interval(hour.AddMinutes(5), hour.AddMinutes(6), 1.0, 0.4, ("edge", 0.6, 0.0)));
        Store.RecordInterval(Interval(hour.AddMinutes(10), hour.AddMinutes(11), 2.0, 0.8, ("edge", 1.2, 0.0)));

        var buckets = Store.SystemEnergyBetween(hour, hour.AddHours(1));
        var bucket = Assert.Single(buckets);

        Assert.Equal(3.0, bucket.SystemWattHours, 6);
        Assert.Equal(1.2, bucket.PlatformWattHours, 6);
        Assert.Equal(120, bucket.CoveredSeconds, 3);

        var apps = Store.AppEnergyBetween(hour, hour.AddHours(1));
        Assert.Equal(1.8, Assert.Single(apps).CpuWattHours, 6);
    }

    /// <summary>
    /// The rule that makes charts honest. An hour that was never recorded must come back
    /// as a zero-coverage bucket, not be absent, so a renderer draws a gap rather than
    /// joining the neighbouring points across it.
    /// </summary>
    [Fact]
    public void UnrecordedHours_AreReturnedWithZeroCoverage()
    {
        var start = JuiceStore.AlignToHour(DateTimeOffset.Now).AddHours(-5);

        Store.RecordInterval(Interval(start.AddMinutes(1), start.AddMinutes(3), 5.0, 1.0, ("a", 4.0, 0.0)));

        var buckets = Store.SystemEnergyBetween(start, start.AddHours(5));

        Assert.Equal(5, buckets.Count);
        Assert.True(buckets[0].CoveredSeconds > 0);
        Assert.All(buckets.Skip(1), b => Assert.Equal(0, b.CoveredSeconds));
        Assert.All(buckets.Skip(1), b => Assert.False(b.IsPlottable));
    }

    [Fact]
    public void PartiallyCoveredHour_IsNotPlottableAndIsNotExtrapolated()
    {
        var hour = JuiceStore.AlignToHour(DateTimeOffset.Now);

        // Only one minute of a sixty minute hour.
        Store.RecordInterval(Interval(hour.AddMinutes(1), hour.AddMinutes(2), 0.5, 0.1, ("a", 0.4, 0.0)));

        var bucket = Assert.Single(Store.SystemEnergyBetween(hour, hour.AddHours(1)));

        Assert.False(bucket.IsPlottable);
        Assert.Equal(60.0 / 3600.0, bucket.Coverage, 6);

        // Average watts describes only the covered part; the stored energy is not scaled
        // up to a full hour.
        Assert.Equal(0.5, bucket.SystemWattHours, 6);
        Assert.Equal(30.0, bucket.AverageWatts!.Value, 3);
    }

    /// <summary>
    /// A gap longer than the continuity window means the machine slept. The accumulated
    /// energy is real but unattributable to any hour, so it must be dropped rather than
    /// dumped into whichever bucket contained the wake-up.
    /// </summary>
    [Fact]
    public void IntervalsLongerThanTheContinuityWindow_AreRejected()
    {
        var start = JuiceStore.AlignToHour(DateTimeOffset.Now).AddHours(-8);

        var accepted = Store.RecordInterval(Interval(start, start.AddHours(6), 400.0, 100.0, ("a", 300.0, 0.0)));

        Assert.False(accepted);
        Assert.All(
            Store.SystemEnergyBetween(start, start.AddHours(8)),
            b => Assert.Equal(0, b.SystemWattHours));
    }

    [Fact]
    public void IntervalsSpanningAnHourBoundary_AreSplitProportionally()
    {
        var hour = JuiceStore.AlignToHour(DateTimeOffset.Now);

        // Two minutes: one in the previous hour, one in this one.
        Store.RecordInterval(Interval(hour.AddMinutes(-1), hour.AddMinutes(1), 2.0, 0.0, ("a", 2.0, 0.0)));

        var buckets = Store.SystemEnergyBetween(hour.AddHours(-1), hour.AddHours(1));

        Assert.Equal(2, buckets.Count);
        Assert.Equal(1.0, buckets[0].SystemWattHours, 6);
        Assert.Equal(1.0, buckets[1].SystemWattHours, 6);
        Assert.Equal(60, buckets[0].CoveredSeconds, 3);
        Assert.Equal(60, buckets[1].CoveredSeconds, 3);
    }

    [Fact]
    public void CoverageNeverExceedsTheHour()
    {
        var hour = JuiceStore.AlignToHour(DateTimeOffset.Now);

        // Overlapping intervals must not accumulate more than 3600 seconds of coverage.
        for (var i = 0; i < 40; i++)
        {
            Store.RecordInterval(Interval(hour.AddMinutes(i), hour.AddMinutes(i + 2), 1.0, 0.0, ("a", 1.0, 0.0)));
        }

        var bucket = Assert.Single(Store.SystemEnergyBetween(hour, hour.AddHours(1)));
        Assert.True(bucket.CoveredSeconds <= 3600.0);
        Assert.Equal(1.0, bucket.Coverage, 6);
    }

    [Fact]
    public void TopApps_RanksByTotalEnergy()
    {
        var hour = JuiceStore.AlignToHour(DateTimeOffset.Now);

        Store.RecordInterval(Interval(hour.AddMinutes(1), hour.AddMinutes(2), 10, 1,
            ("small", 1.0, 0.0), ("big", 5.0, 1.0)));

        var top = Store.TopApps(hour, hour.AddHours(1));

        Assert.Equal("big", top[0].AppId);
        Assert.Equal(6.0, top[0].WattHours, 6);
        Assert.Equal("small", top[1].AppId);
    }

    [Fact]
    public void PruneDropsOldBatterySamplesButKeepsEnergyHistory()
    {
        var now = DateTimeOffset.Now;
        var hour = JuiceStore.AlignToHour(now).AddHours(-1);

        Store.RecordInterval(Interval(hour, hour.AddMinutes(1), 1.0, 0.0, ("a", 1.0, 0.0)));

        Store.RecordBatterySample(new Power.PowerSample
        {
            Timestamp = now.AddDays(-120),
            Tier = Power.PowerSourceTier.Battery,
            BatteryPercent = 50,
            OnAc = false,
        });
        Store.RecordBatterySample(new Power.PowerSample
        {
            Timestamp = now.AddDays(-1),
            Tier = Power.PowerSourceTier.Battery,
            BatteryPercent = 60,
            OnAc = false,
        });

        var removed = Store.Prune(now);

        Assert.Equal(1, removed);
        Assert.Single(Store.BatteryBetween(now.AddDays(-200), now));
        Assert.Equal(1.0, Store.SystemEnergyBetween(hour, hour.AddHours(1))[0].SystemWattHours, 6);
    }

    [Fact]
    public void HistorySurvivesReopening()
    {
        var hour = JuiceStore.AlignToHour(DateTimeOffset.Now);
        Store.RecordInterval(Interval(hour.AddMinutes(1), hour.AddMinutes(2), 7.0, 0.0, ("a", 7.0, 0.0)));

        _store!.Dispose();
        _store = null;

        Assert.Equal(7.0, Store.SystemEnergyBetween(hour, hour.AddHours(1))[0].SystemWattHours, 6);
    }

    public void Dispose()
    {
        _store?.Dispose();
        try { File.Delete(_path); } catch (IOException) { }
        GC.SuppressFinalize(this);
    }
}
