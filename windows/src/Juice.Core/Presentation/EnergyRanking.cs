using Juice.Core.Attribution;
using Juice.Core.Storage;

namespace Juice.Core.Presentation;

/// <summary>One row of the top energy users list, ranked and scaled.</summary>
/// <remarks>
/// Members are <c>init</c> with defaults rather than <c>required</c> for the reason
/// recorded in <see cref="EnergyChartSeries"/>.
/// </remarks>
public sealed record EnergyRankingRow
{
    /// <summary>Stable key used to group processes into one app.</summary>
    public string AppId { get; init; } = string.Empty;

    /// <summary>Name shown in the list.</summary>
    public string DisplayName { get; init; } = string.Empty;

    /// <summary>Energy attributed to this row over the period.</summary>
    public double WattHours { get; init; }

    /// <summary>
    /// Average draw implied by that energy, over the time actually recorded.
    /// </summary>
    /// <remarks>
    /// Divided by the recorded time rather than by the length of the period, because a
    /// period that was only half recorded would otherwise halve every app's apparent
    /// draw. Zero when nothing was recorded, which is the one case where there is no
    /// average to state.
    /// </remarks>
    public double Watts { get; init; }

    /// <summary>
    /// True for the platform row: display, radios and regulator loss, which is measured
    /// energy that belongs to no app.
    /// </summary>
    public bool IsPlatform { get; init; }

    /// <summary>Share of the heaviest app row, from 0 to 1, for the ranking bar.</summary>
    public double BarFraction { get; init; }

    /// <summary>Process ids that contributed, so the view can find an icon.</summary>
    public IReadOnlyList<int> ProcessIds { get; init; } = [];
}

/// <summary>A ranked list of energy users with the totals that frame it.</summary>
public sealed record EnergyRanking
{
    /// <summary>Rows in descending order, with the platform row last when present.</summary>
    public IReadOnlyList<EnergyRankingRow> Rows { get; init; } = [];

    /// <summary>Total system energy measured across the period.</summary>
    public double SystemWattHours { get; init; }

    /// <summary>Length of the period the rows describe.</summary>
    public TimeSpan Window { get; init; }

    /// <summary>
    /// Fraction of the period Juice was actually recording, from 0 to 1.
    /// </summary>
    /// <remarks>
    /// One for a live ranking, which is measured over an interval that by definition was
    /// recorded end to end.
    /// </remarks>
    public double Coverage { get; init; } = 1;

    /// <summary>True when there is nothing to rank.</summary>
    public bool IsEmpty => Rows.Count == 0;

    /// <summary>A ranking of nothing, for the paths that have no data to offer.</summary>
    public static EnergyRanking Empty { get; } = new();

    /// <summary>
    /// A sentence stating how much of the period was recorded, or nothing when all of it
    /// was.
    /// </summary>
    /// <remarks>
    /// The same rule the charts follow: a partially recorded period is never presented as
    /// a complete one. A total over a week that was only recorded for two days is a true
    /// number about two days and a badly misleading one about a week, and the difference
    /// is only visible if it is written down.
    /// </remarks>
    public string CoverageCaption()
    {
        if (Coverage >= 0.99) return string.Empty;
        if (Coverage <= 0) return "Nothing was recorded in this period.";

        return $"Recorded for {Coverage:P0} of this period.";
    }
}

/// <summary>
/// Builds the top energy users list, from either the live attribution window or the
/// store.
/// </summary>
/// <remarks>
/// <para>
/// Both sources come through here so that the rules the list depends on are stated once.
/// There are three, and each of them is a place the list could quietly start lying.
/// </para>
/// <para>
/// Energy that no process can be held responsible for is shown as its own row rather than
/// spread across the apps above it. It is real measured energy, mostly the display, and
/// hiding it would make every app look like a larger share of the machine than it is.
/// </para>
/// <para>
/// Bars are scaled against the heaviest app, not against the heaviest row. The platform
/// row is usually the largest single consumer, so including it would squeeze every app
/// into the same short stub and destroy the ranking the list exists to show. The platform
/// row is scaled against that same app maximum and clamps at full width when it exceeds
/// it, which stays honest because it is drawn apart from the apps and its energy is
/// printed next to it either way.
/// </para>
/// <para>
/// Average watts are divided by the time actually recorded rather than by the length of
/// the period, so a week that Juice only saw two days of does not report every app at
/// two sevenths of its real draw.
/// </para>
/// </remarks>
public static class EnergyRankingBuilder
{
    /// <summary>
    /// App rows shown before the platform row.
    /// </summary>
    /// <remarks>
    /// Five is what fits the flyout without scrolling, and beyond that the numbers are
    /// small enough that the ranking is noise.
    /// </remarks>
    public const int DefaultAppLimit = 5;

    /// <summary>
    /// Identity used for the platform row.
    /// </summary>
    /// <remarks>
    /// It is not an app, so it takes a key that no executable name can produce rather
    /// than sharing the app id space and risking a collision with a real process.
    /// </remarks>
    public const string PlatformAppId = "\u0000platform";

    /// <summary>What the platform row is called in the list.</summary>
    public const string PlatformDisplayName = "System and display";

    /// <summary>Ranks the live attribution window.</summary>
    /// <param name="result">
    /// The most recent completed attribution, or null before the first one closes.
    /// </param>
    /// <param name="appLimit">How many app rows to keep.</param>
    public static EnergyRanking FromLive(AttributionResult? result, int appLimit = DefaultAppLimit)
    {
        if (result is null || result.End <= result.Start) return EnergyRanking.Empty;

        var window = result.End - result.Start;
        var hours = window.TotalHours;
        if (hours <= 0) return EnergyRanking.Empty;

        var apps = new List<EnergyRankingRow>();

        foreach (var app in result.Apps.Take(appLimit))
        {
            if (app.TotalWattHours <= 0) continue;

            apps.Add(new EnergyRankingRow
            {
                AppId = app.AppId,
                DisplayName = app.DisplayName,
                WattHours = app.TotalWattHours,
                Watts = app.Watts,
                ProcessIds = app.ProcessIds,
            });
        }

        return Assemble(apps, result.PlatformWattHours, result.SystemWattHours, window, hours, coverage: 1);
    }

    /// <summary>Ranks a stored period.</summary>
    /// <param name="apps">Per-app totals for the period, heaviest first.</param>
    /// <param name="buckets">
    /// System hour buckets across the period, including the unrecorded hours, which is
    /// what makes the coverage figure meaningful.
    /// </param>
    /// <param name="window">The period the caller asked for, not the extent of the data.</param>
    /// <param name="appLimit">How many app rows to keep.</param>
    public static EnergyRanking FromHistory(
        IReadOnlyList<DailyAppEnergy> apps,
        IReadOnlyList<HourBucket> buckets,
        TimeSpan window,
        int appLimit = DefaultAppLimit)
    {
        ArgumentNullException.ThrowIfNull(apps);
        ArgumentNullException.ThrowIfNull(buckets);

        var systemWattHours = 0.0;
        var platformWattHours = 0.0;
        var coveredSeconds = 0.0;

        foreach (var bucket in buckets)
        {
            systemWattHours += bucket.SystemWattHours;
            platformWattHours += bucket.PlatformWattHours;
            coveredSeconds += bucket.CoveredSeconds;
        }

        var coveredHours = coveredSeconds / 3600.0;
        var coverage = window > TimeSpan.Zero
            ? Math.Clamp(coveredSeconds / window.TotalSeconds, 0, 1)
            : 0;

        var rows = new List<EnergyRankingRow>();

        foreach (var app in apps.Take(appLimit))
        {
            if (app.WattHours <= 0) continue;

            rows.Add(new EnergyRankingRow
            {
                AppId = app.AppId,
                DisplayName = app.DisplayName,
                WattHours = app.WattHours,
                Watts = coveredHours > 0 ? app.WattHours / coveredHours : 0,
            });
        }

        return Assemble(rows, platformWattHours, systemWattHours, window, coveredHours, coverage);
    }

    /// <summary>
    /// Appends the platform row and scales every bar, which is the part both sources have
    /// to agree on.
    /// </summary>
    private static EnergyRanking Assemble(
        List<EnergyRankingRow> apps,
        double platformWattHours,
        double systemWattHours,
        TimeSpan window,
        double measuredHours,
        double coverage)
    {
        // Scaled on energy rather than on watts so the two sources agree. Within a single
        // period every row covers the same measured time, so the two ratios are the same
        // number, and energy is the quantity that was actually accumulated.
        var heaviestApp = RankingShare.Heaviest(apps.Select(row => row.WattHours));

        var rows = new List<EnergyRankingRow>(apps.Count + 1);

        foreach (var app in apps)
        {
            rows.Add(app with { BarFraction = RankingShare.Of(app.WattHours, heaviestApp) });
        }

        if (platformWattHours > 0)
        {
            rows.Add(new EnergyRankingRow
            {
                AppId = PlatformAppId,
                DisplayName = PlatformDisplayName,
                WattHours = platformWattHours,
                Watts = measuredHours > 0 ? platformWattHours / measuredHours : 0,
                IsPlatform = true,
                BarFraction = RankingShare.Of(platformWattHours, heaviestApp),
            });
        }

        return new EnergyRanking
        {
            Rows = rows,
            SystemWattHours = systemWattHours,
            Window = window,
            Coverage = coverage,
        };
    }
}
