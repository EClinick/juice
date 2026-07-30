using Juice.Core.Attribution;
using Juice.Core.Presentation;
using Juice.Core.Storage;
using Xunit;

namespace Juice.Core.Tests;

/// <summary>
/// Covers the period switcher: how a chosen range becomes query bounds, and how the two
/// sources of a ranking are made to agree.
/// </summary>
/// <remarks>
/// The ranking is the part of the flyout most likely to start lying quietly, because the
/// platform residual, the bar scaling and the coverage figure are all arithmetic that
/// looks plausible whatever it produces. Testing it needs no window, so it is tested
/// here rather than looked at.
/// </remarks>
public class EnergyRangeTests
{
    [Fact]
    public void Session_IsLiveAndHasNoBounds()
    {
        var now = DateTimeOffset.Now;
        var window = EnergyRanges.Resolve(EnergyRange.Session, now, null);

        Assert.True(window.IsLive);
        Assert.Equal(TimeSpan.Zero, window.Duration);
    }

    /// <summary>
    /// Today has to start at the user's local midnight, not twenty four hours ago. The
    /// two are the same number only once a day and the difference is a whole evening.
    /// </summary>
    [Fact]
    public void Today_StartsAtLocalMidnight()
    {
        var now = DateTimeOffset.Now;
        var window = EnergyRanges.Resolve(EnergyRange.Today, now, now.AddDays(-3));

        Assert.False(window.IsLive);
        Assert.Equal(TimeSpan.Zero, window.From.ToLocalTime().TimeOfDay);
        Assert.Equal(now.ToLocalTime().Date, window.From.ToLocalTime().Date);
        Assert.True(window.From <= now);
        Assert.Equal(now, window.To);
    }

    [Fact]
    public void Week_IsTheRollingLastSevenDays()
    {
        var now = DateTimeOffset.Now;
        var window = EnergyRanges.Resolve(EnergyRange.Week, now, now.AddDays(-30));

        Assert.Equal(TimeSpan.FromDays(7), window.Duration);
    }

    /// <summary>
    /// "All" is bounded by what the store still holds, and pruning means that is not the
    /// day Juice was installed. Nothing may present it as one.
    /// </summary>
    [Fact]
    public void All_StartsAtTheOldestRecordedHour()
    {
        var now = DateTimeOffset.Now;
        var earliest = now.AddDays(-11);

        var window = EnergyRanges.Resolve(EnergyRange.All, now, earliest);

        Assert.Equal(earliest, window.From);
        Assert.True(window.HasRecords);
        Assert.Equal("all recorded history", window.Description);
    }

    [Fact]
    public void StoredRanges_ReportNoRecordsWhenNothingWasEverStored()
    {
        var now = DateTimeOffset.Now;

        Assert.False(EnergyRanges.Resolve(EnergyRange.Today, now, null).HasRecords);
        Assert.False(EnergyRanges.Resolve(EnergyRange.Week, now, null).HasRecords);
        Assert.False(EnergyRanges.Resolve(EnergyRange.All, now, null).HasRecords);
    }

    /// <summary>
    /// Energy no process can be held responsible for is a row of its own. Spreading it
    /// across the apps would make every one of them look like a larger share of the
    /// machine than it is.
    /// </summary>
    [Fact]
    public void LiveRanking_KeepsThePlatformResidualAsItsOwnRow()
    {
        var start = DateTimeOffset.UnixEpoch;

        var ranking = EnergyRankingBuilder.FromLive(new AttributionResult
        {
            Start = start,
            End = start.AddHours(1),
            SystemWattHours = 10,
            PlatformWattHours = 6,
            Apps =
            [
                new AppEnergy { AppId = "a", DisplayName = "A", CpuWattHours = 3, Watts = 3 },
                new AppEnergy { AppId = "b", DisplayName = "B", CpuWattHours = 1, Watts = 1 },
            ],
        });

        Assert.Equal(3, ranking.Rows.Count);
        Assert.Equal(EnergyRankingBuilder.PlatformAppId, ranking.Rows[^1].AppId);
        Assert.True(ranking.Rows[^1].IsPlatform);
        Assert.Equal(6, ranking.Rows[^1].WattHours, 9);
        Assert.Equal(10, ranking.SystemWattHours, 9);
    }

    /// <summary>
    /// Bars are scaled against the heaviest app rather than the heaviest row. The platform
    /// row is usually the largest single consumer, so including it would squeeze every app
    /// into the same stub and destroy the ranking the list exists to show.
    /// </summary>
    [Fact]
    public void Ranking_ScalesBarsAgainstTheHeaviestAppNotThePlatformRow()
    {
        var start = DateTimeOffset.UnixEpoch;

        var ranking = EnergyRankingBuilder.FromLive(new AttributionResult
        {
            Start = start,
            End = start.AddHours(1),
            SystemWattHours = 10,
            PlatformWattHours = 20,
            Apps =
            [
                new AppEnergy { AppId = "a", DisplayName = "A", CpuWattHours = 4, Watts = 4 },
                new AppEnergy { AppId = "b", DisplayName = "B", CpuWattHours = 1, Watts = 1 },
            ],
        });

        Assert.Equal(1.0, ranking.Rows[0].BarFraction, 9);
        Assert.Equal(0.25, ranking.Rows[1].BarFraction, 9);

        // The platform row exceeds the app maximum and clamps rather than rescaling
        // everything else.
        Assert.Equal(1.0, ranking.Rows[2].BarFraction, 9);
    }

    [Fact]
    public void Ranking_DropsAppsThatDrewNothingMeasurable()
    {
        var start = DateTimeOffset.UnixEpoch;

        var ranking = EnergyRankingBuilder.FromLive(new AttributionResult
        {
            Start = start,
            End = start.AddHours(1),
            SystemWattHours = 1,
            Apps =
            [
                new AppEnergy { AppId = "a", DisplayName = "A", CpuWattHours = 1, Watts = 1 },
                new AppEnergy { AppId = "b", DisplayName = "B", CpuWattHours = 0, Watts = 0 },
            ],
        });

        Assert.Single(ranking.Rows);
    }

    [Fact]
    public void LiveRanking_IsEmptyBeforeTheFirstWindowCloses()
    {
        Assert.True(EnergyRankingBuilder.FromLive(null).IsEmpty);
        Assert.Equal(string.Empty, EnergyRanking.Empty.CoverageCaption());
    }

    /// <summary>
    /// Apps past the visible top go to the disclosure rather than being discarded, so a
    /// user who suspects something specific can check whether it is there.
    /// </summary>
    [Fact]
    public void Ranking_KeepsTheAppsPastTheTopForTheDisclosure()
    {
        var ranking = EnergyRankingBuilder.FromLive(
            LiveApps(8),
            appLimit: 2,
            overflowLimit: 4);

        Assert.Equal(2, ranking.Rows.Count);
        Assert.True(ranking.HasOverflow);
        Assert.Equal(4, ranking.OverflowRows.Count);
        Assert.Equal("app3", ranking.OverflowRows[0].AppId);

        // Sixth, seventh and eighth were not asked for and are not counted anywhere.
        Assert.Equal(3 + 1.5 + 0.75 + 0.375, ranking.OverflowWattHours, 9);
    }

    /// <summary>
    /// Opening the disclosure continues the ranking rather than restarting it, so the
    /// bars stay comparable with the rows above them.
    /// </summary>
    [Fact]
    public void Ranking_ScalesDisclosedBarsAgainstTheSameHeaviestApp()
    {
        var ranking = EnergyRankingBuilder.FromLive(
            LiveApps(4),
            appLimit: 1,
            overflowLimit: 4);

        Assert.Equal(1.0, ranking.Rows[0].BarFraction, 9);
        Assert.Equal(0.5, ranking.OverflowRows[0].BarFraction, 9);
        Assert.Equal(0.25, ranking.OverflowRows[1].BarFraction, 9);
    }

    [Fact]
    public void Ranking_HasNoDisclosureWhenEveryAppIsAlreadyVisible()
    {
        var ranking = EnergyRankingBuilder.FromLive(LiveApps(3));

        Assert.False(ranking.HasOverflow);
        Assert.Empty(ranking.OverflowRows);
        Assert.Equal(0, ranking.OverflowWattHours, 9);
    }

    /// <summary>
    /// A stored period is disclosed the same way, so the two sources cannot drift apart
    /// in what the disclosure contains.
    /// </summary>
    [Fact]
    public void HistoricalRanking_DisclosesTheSameWayTheLiveOneDoes()
    {
        var hour = DateTimeOffset.UnixEpoch;

        var buckets = new List<HourBucket>
        {
            Bucket(hour, systemWh: 10, platformWh: 0, coveredSeconds: 3600),
        };

        var apps = new List<DailyAppEnergy>
        {
            new() { Day = "1970-01-01", AppId = "a", DisplayName = "A", WattHours = 4 },
            new() { Day = "1970-01-01", AppId = "b", DisplayName = "B", WattHours = 2 },
            new() { Day = "1970-01-01", AppId = "c", DisplayName = "C", WattHours = 1 },
        };

        var ranking = EnergyRankingBuilder.FromHistory(
            apps,
            buckets,
            TimeSpan.FromHours(1),
            appLimit: 1,
            overflowLimit: 2);

        Assert.Single(ranking.Rows);
        Assert.Equal(2, ranking.OverflowRows.Count);
        Assert.Equal(3, ranking.OverflowWattHours, 9);
        Assert.Equal(3, ranking.OverflowWatts, 9);
    }

    /// <summary>
    /// An attribution result with a known number of apps, each drawing half of the one
    /// above it, so both the split and the bar scaling are checkable by hand.
    /// </summary>
    private static AttributionResult LiveApps(int count)
    {
        var start = DateTimeOffset.UnixEpoch;
        var apps = new List<AppEnergy>();
        var watts = 12.0;

        for (var i = 1; i <= count; i++)
        {
            apps.Add(new AppEnergy
            {
                AppId = $"app{i}",
                DisplayName = $"App {i}",
                CpuWattHours = watts,
                Watts = watts,
            });

            watts /= 2;
        }

        return new AttributionResult
        {
            Start = start,
            End = start.AddHours(1),
            SystemWattHours = 100,
            Apps = apps,
        };
    }

    /// <summary>
    /// A period Juice only saw part of must not report every app at a fraction of its real
    /// draw, so the average is taken over the time recorded rather than over the period.
    /// </summary>
    [Fact]
    public void HistoricalRanking_AveragesOverTheTimeRecordedNotThePeriod()
    {
        var hour = DateTimeOffset.UnixEpoch;

        // Two fully recorded hours inside a four hour period.
        var buckets = new List<HourBucket>
        {
            Bucket(hour, systemWh: 10, platformWh: 4, coveredSeconds: 3600),
            Bucket(hour.AddHours(1), systemWh: 10, platformWh: 4, coveredSeconds: 3600),
            Bucket(hour.AddHours(2), systemWh: 0, platformWh: 0, coveredSeconds: 0),
            Bucket(hour.AddHours(3), systemWh: 0, platformWh: 0, coveredSeconds: 0),
        };

        var apps = new List<DailyAppEnergy>
        {
            new() { Day = "1970-01-01", AppId = "a", DisplayName = "A", WattHours = 6 },
        };

        var ranking = EnergyRankingBuilder.FromHistory(apps, buckets, TimeSpan.FromHours(4));

        Assert.Equal(0.5, ranking.Coverage, 9);
        Assert.Equal(20, ranking.SystemWattHours, 9);

        // Six watt-hours over the two hours recorded, not over the four asked for.
        Assert.Equal(3, ranking.Rows[0].Watts, 9);
        Assert.Equal(4, ranking.Rows[^1].Watts, 9);
    }

    /// <summary>
    /// A total over a period that was only half recorded is a true number about half a
    /// period and a badly misleading one about a whole period. The difference is only
    /// visible if it is written down.
    /// </summary>
    [Fact]
    public void HistoricalRanking_AdmitsAPartiallyRecordedPeriod()
    {
        var hour = DateTimeOffset.UnixEpoch;

        var buckets = new List<HourBucket>
        {
            Bucket(hour, systemWh: 10, platformWh: 4, coveredSeconds: 3600),
            Bucket(hour.AddHours(1), systemWh: 0, platformWh: 0, coveredSeconds: 0),
        };

        var ranking = EnergyRankingBuilder.FromHistory([], buckets, TimeSpan.FromHours(2));

        Assert.Contains("50", ranking.CoverageCaption(), StringComparison.Ordinal);
    }

    [Fact]
    public void FullyRecordedPeriodsSayNothingAboutCoverage()
    {
        var hour = DateTimeOffset.UnixEpoch;

        var buckets = new List<HourBucket>
        {
            Bucket(hour, systemWh: 10, platformWh: 4, coveredSeconds: 3600),
        };

        var ranking = EnergyRankingBuilder.FromHistory([], buckets, TimeSpan.FromHours(1));

        Assert.Equal(string.Empty, ranking.CoverageCaption());
    }

    private static HourBucket Bucket(
        DateTimeOffset hourStart,
        double systemWh,
        double platformWh,
        double coveredSeconds) => new()
        {
            HourStart = hourStart,
            SystemWattHours = systemWh,
            PlatformWattHours = platformWh,
            CoveredSeconds = coveredSeconds,
        };
}
