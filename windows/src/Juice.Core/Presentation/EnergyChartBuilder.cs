using Juice.Core.Storage;

namespace Juice.Core.Presentation;

/// <summary>One column of an energy chart.</summary>
/// <remarks>
/// A gap and a measured zero are represented differently and must render differently.
/// <see cref="IsGap"/> means Juice was not recording, so there is no value to draw and
/// the renderer must leave a hole rather than a zero-height bar sitting on the axis.
/// </remarks>
public sealed record ChartBar
{
    /// <summary>Start of the hour this column covers, in local time.</summary>
    public DateTimeOffset HourStart { get; init; }

    /// <summary>Energy measured in the hour, or null when it was not recorded.</summary>
    public double? WattHours { get; init; }

    /// <summary>Average draw across the covered part of the hour, or null when unknown.</summary>
    public double? Watts { get; init; }

    /// <summary>True when there is no measurement to draw.</summary>
    public bool IsGap { get; init; }

    /// <summary>
    /// Height as a fraction of the axis maximum, from 0 to 1. Always 0 for a gap, which
    /// the renderer must distinguish from a genuine 0 by checking <see cref="IsGap"/>.
    /// </summary>
    public double HeightFraction { get; init; }

    /// <summary>
    /// True when the hour was recorded but only partially. The value is real for the
    /// portion covered and must be labelled as partial rather than presented as a whole
    /// hour, since scaling it up would be an invention.
    /// </summary>
    public bool IsPartial { get; init; }
}

/// <summary>A chart series with its axis already resolved.</summary>
/// <remarks>
/// Members are <c>init</c> with defaults rather than <c>required</c> because the WinUI
/// XAML type-info generator emits a parameterless construction for any type reachable
/// from an <c>x:Bind</c> path, which <c>required</c> members reject at compile time.
/// <see cref="EnergyChartBuilder"/> is the only intended producer and always sets every
/// member, so nothing is lost in practice.
/// </remarks>
public sealed record EnergyChartSeries
{
    /// <summary>Left edge of the axis. Pinned to the requested window, not to the data.</summary>
    public DateTimeOffset Start { get; init; }

    /// <summary>Right edge of the axis. Pinned to the requested window, not to the data.</summary>
    public DateTimeOffset End { get; init; }

    /// <summary>One column per hour across the whole window, gaps included.</summary>
    public IReadOnlyList<ChartBar> Bars { get; init; } = [];

    /// <summary>Axis maximum in watt-hours, or 0 when nothing was measured.</summary>
    public double MaxWattHours { get; init; }

    /// <summary>Total energy across the hours that were actually recorded.</summary>
    public double TotalWattHours { get; init; }

    /// <summary>Number of hours with no usable measurement.</summary>
    public int GapCount => Bars.Count(b => b.IsGap);

    /// <summary>Fraction of the window Juice was recording, from 0 to 1.</summary>
    public double Coverage => Bars.Count == 0 ? 0 : 1.0 - ((double)GapCount / Bars.Count);

    /// <summary>True when any part of the window is missing.</summary>
    public bool HasGaps => GapCount > 0;

    /// <summary>True when there is nothing at all to draw.</summary>
    public bool IsEmpty => MaxWattHours <= 0;

    /// <summary>
    /// A caption stating what the chart does and does not cover, so a partially recorded
    /// window is never presented as a complete one.
    /// </summary>
    /// <remarks>
    /// <para>
    /// The wording says "charted hours" rather than "this period" because the flyout's
    /// period switcher sits directly above this chart and does not drive it. On a machine
    /// with no stored history the old caption read "No data recorded for this period."
    /// immediately beneath a populated Session ranking, which is true of the chart and
    /// flatly contradicted by the list above it.
    /// </para>
    /// <para>
    /// It deliberately does not restate the window length. The axis is aligned down to the
    /// hour, so a 24 hour request spans 25 hourly columns for all but one minute in sixty,
    /// and <see cref="Bars"/>.Count is therefore a column count and not a duration. The
    /// heading above the chart already names the window, so repeating it here bought
    /// nothing and cost an hour of accuracy.
    /// </para>
    /// </remarks>
    public string CoverageCaption()
    {
        if (Bars.Count == 0) return "No time range selected.";
        if (GapCount == Bars.Count) return "No energy recorded in the charted hours.";
        if (GapCount == 0) return "Every charted hour recorded.";

        var hours = GapCount == 1 ? "1 hour" : $"{GapCount} hours";
        return $"{hours} not recorded, shown as gaps.";
    }
}

/// <summary>
/// Turns stored hour buckets into a chart series that cannot lie.
/// </summary>
/// <remarks>
/// <para>
/// CONTRIBUTING.md guards charts harder than anything else in the repository: axes are
/// pinned to the requested window, recording gaps render as gaps, and nothing is
/// interpolated across missing data. Those rules are enforced here rather than in the
/// renderer, so every chart in the app inherits them and none can quietly opt out.
/// </para>
/// <para>
/// Three specific temptations are closed off. The axis comes from the requested window
/// rather than from the extent of the data, so a chart of the last 24 hours that only
/// has 3 hours of data still shows 24 hours with 21 of them empty, instead of silently
/// zooming in and looking complete. Missing hours produce explicit gap columns rather
/// than being omitted, because omitting them lets a renderer join neighbouring points
/// straight across the hole. And a partially recorded hour keeps the energy actually
/// measured rather than being scaled up to a full hour, which would be inventing energy
/// that was never observed.
/// </para>
/// </remarks>
public static class EnergyChartBuilder
{
    /// <summary>
    /// Builds a series for the window, using the axis bounds requested by the caller.
    /// </summary>
    /// <param name="buckets">
    /// Stored buckets. Hours absent from this list are treated as gaps, so the caller may
    /// pass only the hours that exist.
    /// </param>
    /// <param name="from">Window start. Becomes the axis left edge after hour alignment.</param>
    /// <param name="to">Window end. Becomes the axis right edge.</param>
    public static EnergyChartSeries Build(
        IReadOnlyList<HourBucket> buckets,
        DateTimeOffset from,
        DateTimeOffset to)
    {
        var axisStart = JuiceStore.AlignToHour(from);

        if (to <= axisStart)
        {
            return new EnergyChartSeries
            {
                Start = axisStart,
                End = axisStart,
                Bars = [],
                MaxWattHours = 0,
                TotalWattHours = 0,
            };
        }

        var byHour = new Dictionary<DateTimeOffset, HourBucket>();
        foreach (var bucket in buckets)
        {
            byHour[JuiceStore.AlignToHour(bucket.HourStart)] = bucket;
        }

        // The axis maximum is taken only from hours that are actually plottable. A
        // partially covered hour holds less energy simply because less of it was
        // recorded, and letting that set the scale would flatten every real hour.
        var max = 0.0;
        foreach (var bucket in byHour.Values)
        {
            if (bucket.IsPlottable && bucket.SystemWattHours > max) max = bucket.SystemWattHours;
        }

        var bars = new List<ChartBar>();
        var total = 0.0;

        for (var hour = axisStart; hour < to; hour = hour.AddHours(1))
        {
            if (!byHour.TryGetValue(hour, out var bucket) || bucket.CoveredSeconds <= 0)
            {
                bars.Add(new ChartBar
                {
                    HourStart = hour,
                    IsGap = true,
                    HeightFraction = 0,
                    IsPartial = false,
                });
                continue;
            }

            total += bucket.SystemWattHours;

            // An hour with too little coverage is a gap for drawing purposes. Rendering a
            // two minute sample as a short bar would read as "this hour was quiet", which
            // is a claim Juice cannot support.
            if (!bucket.IsPlottable)
            {
                bars.Add(new ChartBar
                {
                    HourStart = hour,
                    WattHours = bucket.SystemWattHours,
                    Watts = bucket.AverageWatts,
                    IsGap = true,
                    HeightFraction = 0,
                    IsPartial = true,
                });
                continue;
            }

            bars.Add(new ChartBar
            {
                HourStart = hour,
                WattHours = bucket.SystemWattHours,
                Watts = bucket.AverageWatts,
                IsGap = false,
                HeightFraction = max > 0 ? Math.Clamp(bucket.SystemWattHours / max, 0, 1) : 0,
                IsPartial = bucket.Coverage < 0.99,
            });
        }

        return new EnergyChartSeries
        {
            Start = axisStart,
            End = to,
            Bars = bars,
            MaxWattHours = max,
            TotalWattHours = total,
        };
    }
}
