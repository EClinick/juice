using Juice.Core.Storage;

namespace Juice.Core.Insights;

/// <summary>
/// Builds insights from what the history store holds.
/// </summary>
/// <remarks>
/// <para>
/// <see cref="InsightsEngine"/> deliberately knows nothing about storage: it takes plain
/// lists so that its rules can be tested without a database. This is the seam that joins
/// the two, and it lives in Core rather than in a front end so that every front end asks
/// the same question and gets the same answer.
/// </para>
/// <para>
/// The window is a fortnight. The engine compares an app's most recent day against its own
/// earlier days, so it needs enough history to have formed an opinion, and a machine that
/// has only run for an afternoon should produce no insights rather than confident ones
/// drawn from a single day.
/// </para>
/// </remarks>
public static class InsightsReport
{
    /// <summary>How much history the comparisons are drawn from.</summary>
    public static readonly TimeSpan Window = TimeSpan.FromDays(14);

    /// <summary>
    /// Reads the store and generates the current observations, most severe first.
    /// </summary>
    /// <param name="store">History store, or null when none could be opened.</param>
    /// <param name="now">Current instant, taken as a parameter so this can be tested.</param>
    /// <param name="currentWatts">Live draw, when known.</param>
    /// <param name="idleBaselineWatts">The machine's observed idle draw, when known.</param>
    public static IReadOnlyList<Insight> Build(
        JuiceStore? store,
        DateTimeOffset now,
        double? currentWatts = null,
        double? idleBaselineWatts = null)
    {
        if (store is null)
        {
            // Without history there is nothing to compare against, but live drain can still
            // be judged against the session's own baseline, so the engine is still asked.
            return InsightsEngine.Generate([], [], currentWatts, idleBaselineWatts);
        }

        var from = now - Window;

        var appDays = store.TopApps(from, now, limit: 200)
            .Select(row => new AppDayEnergy(
                ParseDay(row.Day),
                row.AppId,
                row.DisplayName,
                row.WattHours))
            .Where(day => day.Day != default)
            .ToList();

        var samples = store.BatteryBetween(from, now)
            .Select(point => new InsightSample(point.Timestamp, point.Percent, point.OnAc, point.Watts))
            .ToList();

        return InsightsEngine.Generate(appDays, samples, currentWatts, idleBaselineWatts);
    }

    /// <summary>
    /// Parses the store's <c>yyyy-MM-dd</c> day key.
    /// </summary>
    /// <remarks>
    /// Returns the default date for anything unparseable, which the caller drops. A corrupt
    /// row should cost one observation, not the whole report.
    /// </remarks>
    private static DateOnly ParseDay(string day)
        => DateOnly.TryParse(day, out var parsed) ? parsed : default;
}
