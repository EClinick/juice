using Juice.Core.Power;

namespace Juice.Core.Insights;

/// <summary>
/// Generates plain-English observations from a machine's own history.
/// </summary>
/// <remarks>
/// <para>
/// Every comparison is against the user's own baseline rather than any absolute figure.
/// Fifteen watts is heavy on a fanless tablet and unremarkable on a mobile workstation, so
/// an absolute threshold would be wrong on most hardware. The same applies per app: what
/// matters is that a browser is using four times its own normal energy, not that it is
/// using two watt-hours.
/// </para>
/// <para>
/// The engine is pure and deterministic. It takes history in and returns observations out,
/// with no clock and no I/O, so every rule below is directly testable.
/// </para>
/// <para>
/// It is deliberately conservative. An insight that fires on noise trains the user to
/// ignore the whole panel, so each rule requires a minimum amount of evidence before it
/// will say anything at all.
/// </para>
/// </remarks>
public static class InsightsEngine
{
    /// <summary>Days of history required before app comparisons are trusted.</summary>
    public const int MinimumBaselineDays = 3;

    /// <summary>How much above baseline counts as an anomaly.</summary>
    public const double AnomalyMultiplier = 2.0;

    /// <summary>Below this, an app is too small for a multiple to be meaningful.</summary>
    public const double MinimumInterestingWattHours = 0.5;

    /// <summary>Generates observations from the history supplied.</summary>
    /// <param name="appDays">Per-app energy by day, most recent day included.</param>
    /// <param name="samples">Battery samples covering the recent period.</param>
    /// <param name="currentWatts">Live draw, when known.</param>
    /// <param name="idleBaselineWatts">The machine's observed idle draw, when known.</param>
    public static IReadOnlyList<Insight> Generate(
        IReadOnlyList<AppDayEnergy> appDays,
        IReadOnlyList<InsightSample> samples,
        double? currentWatts = null,
        double? idleBaselineWatts = null)
    {
        var insights = new List<Insight>();

        AddDrainAnomaly(insights, currentWatts, idleBaselineWatts);
        AddAppAnomalies(insights, appDays);
        AddHogOfWeek(insights, appDays);
        AddChargingHabits(insights, samples);

        return insights
            .OrderByDescending(i => i.Severity)
            .ToList();
    }

    /// <summary>
    /// Flags a live draw well above the machine's own idle baseline.
    /// </summary>
    private static void AddDrainAnomaly(List<Insight> insights, double? currentWatts, double? baseline)
    {
        if (currentWatts is not { } watts || baseline is not { } idle || idle <= 0.5) return;

        var severity = DrainClassifier.Classify(watts, idle);
        if (severity != DrainSeverity.High) return;

        var multiple = watts / idle;

        insights.Add(new Insight
        {
            Id = "drain:current",
            Kind = InsightKind.DrainAnomaly,
            Title = $"Drawing {watts:0.0} W, about {multiple:0.0} times idle",
            Detail = $"This machine idles near {idle:0.0} W. Sustained draw at this level will "
                     + "shorten runtime noticeably.",
            Severity = InsightSeverity.Warning,
        });
    }

    /// <summary>
    /// Flags apps using far more than they typically do.
    /// </summary>
    /// <remarks>
    /// The baseline for an app excludes the day being judged, so a single very heavy day
    /// cannot raise the bar it is being measured against and hide itself.
    /// </remarks>
    private static void AddAppAnomalies(List<Insight> insights, IReadOnlyList<AppDayEnergy> appDays)
    {
        if (appDays.Count == 0) return;

        var latestDay = appDays.Max(a => a.Day);

        foreach (var group in appDays.GroupBy(a => a.AppId))
        {
            var today = group.Where(a => a.Day == latestDay).Sum(a => a.WattHours);
            var earlier = group.Where(a => a.Day < latestDay).ToList();

            if (earlier.Count < MinimumBaselineDays) continue;
            if (today < MinimumInterestingWattHours) continue;

            var baseline = earlier.Average(a => a.WattHours);
            if (baseline <= 0) continue;

            var multiple = today / baseline;
            if (multiple < AnomalyMultiplier) continue;

            var name = group.First().DisplayName;

            insights.Add(new Insight
            {
                Id = $"app:{group.Key}",
                Kind = InsightKind.AppAnomaly,
                Title = $"{name} used {multiple:0.0} times its usual energy",
                Detail = $"{PowerFormatter.Energy(today)} today against a typical "
                         + $"{PowerFormatter.Energy(baseline)} over the previous {earlier.Count} days.",
                Severity = multiple >= 4 ? InsightSeverity.Warning : InsightSeverity.Notice,
            });
        }
    }

    /// <summary>Names the largest consumer across the whole period.</summary>
    private static void AddHogOfWeek(List<Insight> insights, IReadOnlyList<AppDayEnergy> appDays)
    {
        if (appDays.Count == 0) return;

        var totals = appDays
            .GroupBy(a => a.AppId)
            .Select(g => (Name: g.First().DisplayName, Total: g.Sum(a => a.WattHours)))
            .OrderByDescending(t => t.Total)
            .ToList();

        if (totals.Count == 0 || totals[0].Total < MinimumInterestingWattHours) return;

        var overall = totals.Sum(t => t.Total);
        var share = overall > 0 ? totals[0].Total / overall : 0;

        // A leader that is barely ahead of the pack is not a story worth telling.
        if (share < 0.25) return;

        insights.Add(new Insight
        {
            Id = $"hog:{totals[0].Name}",
            Kind = InsightKind.HogOfWeek,
            Title = $"{totals[0].Name} was your biggest energy user",
            Detail = $"{PowerFormatter.Energy(totals[0].Total)}, about {share * 100:0}% of all "
                     + "attributed app energy in this period.",
            Severity = InsightSeverity.Info,
        });
    }

    /// <summary>
    /// Observes charging behaviour, specifically time spent held at full charge.
    /// </summary>
    /// <remarks>
    /// Sitting plugged in at full charge is the single habit with the clearest link to
    /// long-term capacity loss, and unlike most battery advice it is actionable. Nothing
    /// here is presented as a prediction of lifespan, which would not be supportable.
    /// </remarks>
    private static void AddChargingHabits(List<Insight> insights, IReadOnlyList<InsightSample> samples)
    {
        if (samples.Count < 2) return;

        var ordered = samples.OrderBy(s => s.Timestamp).ToList();
        var span = ordered[^1].Timestamp - ordered[0].Timestamp;
        if (span < TimeSpan.FromHours(12)) return;

        var atFullOnAc = TimeSpan.Zero;

        for (var i = 1; i < ordered.Count; i++)
        {
            var previous = ordered[i - 1];
            var gap = ordered[i].Timestamp - previous.Timestamp;

            // Only count intervals Juice was actually watching, so a machine that was off
            // does not accumulate imaginary hours on the charger.
            if (!SamplingPolicy.IsContinuous(gap)) continue;
            if (previous is { OnAc: true, Percent: >= 99 }) atFullOnAc += gap;
        }

        var fraction = atFullOnAc.TotalHours / span.TotalHours;
        if (fraction < 0.5) return;

        insights.Add(new Insight
        {
            Id = "charging:heldAtFull",
            Kind = InsightKind.ChargingHabit,
            Title = "Mostly kept plugged in at full charge",
            Detail = $"About {fraction * 100:0}% of the last {span.TotalHours:0} hours was spent "
                     + "on the charger at full. Capping the charge limit, if your machine offers it, "
                     + "reduces long-term capacity loss.",
            Severity = InsightSeverity.Info,
        });
    }
}
