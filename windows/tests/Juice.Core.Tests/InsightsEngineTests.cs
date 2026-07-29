using Juice.Core.Insights;
using Xunit;

namespace Juice.Core.Tests;

public class InsightsEngineTests
{
    private static readonly DateOnly Today = new(2026, 3, 10);
    private static readonly DateTimeOffset Start = new(2026, 3, 9, 0, 0, 0, TimeSpan.Zero);

    private static AppDayEnergy App(int daysAgo, string id, double wh)
        => new(Today.AddDays(-daysAgo), id, id, wh);

    private static InsightSample Sample(int minutes, double percent, bool onAc)
        => new(Start.AddMinutes(minutes), percent, onAc, 10);

    [Fact]
    public void HighDrainAgainstOwnBaselineIsFlagged()
    {
        var insights = InsightsEngine.Generate([], [], currentWatts: 30, idleBaselineWatts: 6);

        var drain = Assert.Single(insights, i => i.Kind == InsightKind.DrainAnomaly);
        Assert.Equal(InsightSeverity.Warning, drain.Severity);
        Assert.Contains("30.0 W", drain.Title);
    }

    /// <summary>
    /// The same wattage means different things on different hardware, so the baseline is
    /// the machine's own idle draw rather than any absolute number.
    /// </summary>
    [Fact]
    public void SameWattageIsNotFlaggedOnAThirstierMachine()
    {
        var insights = InsightsEngine.Generate([], [], currentWatts: 30, idleBaselineWatts: 25);

        Assert.DoesNotContain(insights, i => i.Kind == InsightKind.DrainAnomaly);
    }

    [Fact]
    public void AppUsingFarMoreThanUsualIsFlagged()
    {
        var days = new[]
        {
            App(4, "browser", 2.0),
            App(3, "browser", 2.0),
            App(2, "browser", 2.0),
            App(1, "browser", 2.0),
            App(0, "browser", 10.0),
        };

        var anomaly = Assert.Single(
            InsightsEngine.Generate(days, []),
            i => i.Kind == InsightKind.AppAnomaly);

        Assert.Contains("5.0 times", anomaly.Title);
        Assert.Equal(InsightSeverity.Warning, anomaly.Severity);
    }

    [Fact]
    public void AppWithoutEnoughHistoryIsNotJudged()
    {
        var days = new[] { App(1, "browser", 1.0), App(0, "browser", 20.0) };

        Assert.DoesNotContain(
            InsightsEngine.Generate(days, []),
            i => i.Kind == InsightKind.AppAnomaly);
    }

    /// <summary>
    /// A multiple of a negligible number is still negligible, so tiny apps must not
    /// generate alarming headlines.
    /// </summary>
    [Fact]
    public void TinyAppsDoNotProduceAnomalies()
    {
        var days = new[]
        {
            App(4, "tiny", 0.001),
            App(3, "tiny", 0.001),
            App(2, "tiny", 0.001),
            App(0, "tiny", 0.05),
        };

        Assert.DoesNotContain(
            InsightsEngine.Generate(days, []),
            i => i.Kind == InsightKind.AppAnomaly);
    }

    /// <summary>
    /// The day being judged must not contribute to the baseline it is judged against, or
    /// a single very heavy day would raise its own bar and hide itself.
    /// </summary>
    [Fact]
    public void TodayIsExcludedFromItsOwnBaseline()
    {
        var days = new[]
        {
            App(3, "app", 1.0),
            App(2, "app", 1.0),
            App(1, "app", 1.0),
            App(0, "app", 3.0),
        };

        var anomaly = Assert.Single(
            InsightsEngine.Generate(days, []),
            i => i.Kind == InsightKind.AppAnomaly);

        // 3.0 against a baseline of 1.0, not against an average that included the 3.0.
        Assert.Contains("3.0 times", anomaly.Title);
    }

    [Fact]
    public void BiggestConsumerIsNamed()
    {
        var days = new[]
        {
            App(1, "hog", 20.0),
            App(1, "small", 1.0),
            App(0, "small", 1.0),
        };

        var hog = Assert.Single(
            InsightsEngine.Generate(days, []),
            i => i.Kind == InsightKind.HogOfWeek);

        Assert.Contains("hog", hog.Title);
    }

    /// <summary>A leader barely ahead of the field is not a story.</summary>
    [Fact]
    public void EvenlySpreadUsageProducesNoHog()
    {
        var days = new[]
        {
            App(1, "a", 5.0), App(1, "b", 5.0), App(1, "c", 5.0),
            App(1, "d", 5.0), App(1, "e", 5.0),
        };

        Assert.DoesNotContain(
            InsightsEngine.Generate(days, []),
            i => i.Kind == InsightKind.HogOfWeek);
    }

    [Fact]
    public void TimeHeldAtFullChargeIsObserved()
    {
        var samples = new List<InsightSample>();
        for (var i = 0; i <= 24 * 60; i += 2) samples.Add(Sample(i, 100, onAc: true));

        var habit = Assert.Single(
            InsightsEngine.Generate([], samples),
            i => i.Kind == InsightKind.ChargingHabit);

        Assert.Contains("full charge", habit.Title);
    }

    /// <summary>
    /// Time the machine was off must not be counted as time on the charger, or a laptop
    /// shut in a bag all week would be accused of living on the plug.
    /// </summary>
    [Fact]
    public void GapsAreNotCountedAsTimeOnTheCharger()
    {
        var samples = new List<InsightSample>
        {
            Sample(0, 100, onAc: true),
            // A single 24 hour jump: one interval, far longer than the continuity window.
            Sample(24 * 60, 100, onAc: true),
        };

        Assert.DoesNotContain(
            InsightsEngine.Generate([], samples),
            i => i.Kind == InsightKind.ChargingHabit);
    }

    [Fact]
    public void ShortHistoryProducesNoChargingHabit()
    {
        var samples = new List<InsightSample>();
        for (var i = 0; i <= 60; i += 2) samples.Add(Sample(i, 100, onAc: true));

        Assert.DoesNotContain(
            InsightsEngine.Generate([], samples),
            i => i.Kind == InsightKind.ChargingHabit);
    }

    [Fact]
    public void NoHistoryProducesNoInsights()
        => Assert.Empty(InsightsEngine.Generate([], []));

    [Fact]
    public void MostSevereInsightsComeFirst()
    {
        var days = new[]
        {
            App(4, "browser", 1.0), App(3, "browser", 1.0),
            App(2, "browser", 1.0), App(0, "browser", 10.0),
        };

        var insights = InsightsEngine.Generate(days, [], currentWatts: 30, idleBaselineWatts: 6);

        Assert.True(insights.Count >= 2);
        Assert.Equal(InsightSeverity.Warning, insights[0].Severity);
    }
}
