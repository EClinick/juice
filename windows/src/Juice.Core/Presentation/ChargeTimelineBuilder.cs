using Juice.Core.Storage;

namespace Juice.Core.Presentation;

/// <summary>A single plotted point on the charge timeline, in chart space.</summary>
/// <param name="X">Horizontal position from 0 to 1 across the window.</param>
/// <param name="Y">Charge from 0 to 1, where 1 is full.</param>
/// <param name="Timestamp">When the sample was taken.</param>
/// <param name="OnAc">True when running on external power.</param>
public readonly record struct TimelinePoint(double X, double Y, DateTimeOffset Timestamp, bool OnAc);

/// <summary>
/// A run of consecutive points with no recording gap inside it.
/// </summary>
/// <remarks>
/// Segments exist so the renderer never has to decide what to do about a gap. Each
/// segment becomes its own figure, so a break in recording shows as a break in the line
/// instead of a straight interpolation across hours the machine was off.
/// </remarks>
public sealed record TimelineSegment
{
    /// <summary>Points in the run, ordered by time.</summary>
    public IReadOnlyList<TimelinePoint> Points { get; init; } = [];
}

/// <summary>A period spent on external power, for shading behind the line.</summary>
/// <param name="StartX">Left edge from 0 to 1.</param>
/// <param name="EndX">Right edge from 0 to 1.</param>
public readonly record struct ChargingBand(double StartX, double EndX);

/// <summary>The charge timeline, resolved into chart space.</summary>
/// <remarks>
/// Members are <c>init</c> with defaults rather than <c>required</c> because the WinUI
/// XAML type-info generator emits a parameterless construction for any type reachable
/// from an <c>x:Bind</c> path, which <c>required</c> members reject at compile time.
/// <see cref="ChargeTimelineBuilder"/> is the only intended producer and always sets
/// every member.
/// </remarks>
public sealed record ChargeTimeline
{
    /// <summary>Left edge of the axis, pinned to the requested window.</summary>
    public DateTimeOffset Start { get; init; }

    /// <summary>Right edge of the axis, pinned to the requested window.</summary>
    public DateTimeOffset End { get; init; }

    /// <summary>Runs of continuous recording. Gaps between them are genuine gaps.</summary>
    public IReadOnlyList<TimelineSegment> Segments { get; init; } = [];

    /// <summary>Periods on external power, for shading.</summary>
    public IReadOnlyList<ChargingBand> ChargingBands { get; init; } = [];

    /// <summary>Number of breaks in recording inside the window.</summary>
    public int GapCount { get; init; }

    /// <summary>True when there is nothing to draw.</summary>
    public bool IsEmpty => Segments.Count == 0;

    /// <summary>Total number of plotted points.</summary>
    public int PointCount => Segments.Sum(s => s.Points.Count);

    /// <summary>Caption stating what the timeline does and does not cover.</summary>
    /// <remarks>
    /// Refers to the charted window rather than "this period" for the same reason
    /// <see cref="EnergyChartSeries.CoverageCaption"/> does: the period switcher above
    /// governs the ranking, not this chart, and the heading already names the window.
    /// </remarks>
    public string CoverageCaption()
    {
        if (IsEmpty) return "No battery history in the charted hours.";
        if (GapCount == 0) return "Continuous recording across the charted hours.";

        var breaks = GapCount == 1 ? "1 break" : $"{GapCount} breaks";
        return $"{breaks} in recording, shown as gaps in the line.";
    }
}

/// <summary>
/// Turns stored battery samples into a timeline that can be drawn as an area chart.
/// </summary>
/// <remarks>
/// <para>
/// The visual target is the Windows Settings battery levels chart, because that is the
/// idiom a Windows user already recognises for this data. One thing is deliberately
/// different: Settings draws a single continuous line across the whole period, including
/// stretches it has no data for, whereas Juice breaks the line.
/// </para>
/// <para>
/// That difference is not cosmetic. A laptop shut for two days would otherwise be drawn
/// as a straight line sloping gently between the charge it had when it closed and the
/// charge it had when it opened, which asserts a discharge curve that was never observed.
/// Splitting into segments at every gap makes the missing period visible as missing.
/// </para>
/// <para>
/// Coordinates are normalised to 0..1 in both axes so the renderer can scale to whatever
/// size it has without this code knowing anything about pixels.
/// </para>
/// </remarks>
public static class ChargeTimelineBuilder
{
    /// <summary>
    /// Largest interval between consecutive samples that still counts as continuous.
    /// </summary>
    /// <remarks>
    /// Battery samples are written about once a minute, so a few minutes of slack absorbs
    /// scheduling jitter and brief cadence changes. Beyond that the machine was asleep or
    /// Juice was not running, and the line must break.
    /// </remarks>
    public static readonly TimeSpan MaxSampleGap = TimeSpan.FromMinutes(10);

    /// <summary>Builds a timeline for the window.</summary>
    /// <param name="samples">Battery samples, in any order.</param>
    /// <param name="from">Window start, which becomes the axis left edge.</param>
    /// <param name="to">Window end, which becomes the axis right edge.</param>
    public static ChargeTimeline Build(
        IReadOnlyList<BatteryPoint> samples,
        DateTimeOffset from,
        DateTimeOffset to)
    {
        var span = (to - from).TotalSeconds;

        if (span <= 0)
        {
            return new ChargeTimeline
            {
                Start = from,
                End = from,
                Segments = [],
                ChargingBands = [],
                GapCount = 0,
            };
        }

        var ordered = samples
            .Where(s => s.Timestamp >= from && s.Timestamp <= to)
            .OrderBy(s => s.Timestamp)
            .ToList();

        var segments = new List<TimelineSegment>();
        var bands = new List<ChargingBand>();
        var current = new List<TimelinePoint>();
        var gaps = 0;

        BatteryPoint? previous = null;
        double? bandStart = null;

        foreach (var sample in ordered)
        {
            var x = Math.Clamp((sample.Timestamp - from).TotalSeconds / span, 0, 1);
            var y = Math.Clamp(sample.Percent / 100.0, 0, 1);

            if (previous is { } prev && sample.Timestamp - prev.Timestamp > MaxSampleGap)
            {
                // Recording broke here. Close the run rather than drawing through it, and
                // close any charging band too, since we cannot claim the machine stayed on
                // AC across a period we were not watching.
                if (current.Count > 0)
                {
                    segments.Add(new TimelineSegment { Points = current });
                    current = [];
                }

                if (bandStart is { } openBand)
                {
                    bands.Add(new ChargingBand(openBand, Math.Clamp(
                        (prev.Timestamp - from).TotalSeconds / span, 0, 1)));
                    bandStart = null;
                }

                gaps++;
            }

            current.Add(new TimelinePoint(x, y, sample.Timestamp, sample.OnAc));

            if (sample.OnAc && bandStart is null)
            {
                bandStart = x;
            }
            else if (!sample.OnAc && bandStart is { } start)
            {
                bands.Add(new ChargingBand(start, x));
                bandStart = null;
            }

            previous = sample;
        }

        if (current.Count > 0) segments.Add(new TimelineSegment { Points = current });

        if (bandStart is { } trailing && previous is { } last)
        {
            bands.Add(new ChargingBand(trailing, Math.Clamp(
                (last.Timestamp - from).TotalSeconds / span, 0, 1)));
        }

        // A single point cannot be drawn as a line. Keeping it would produce an invisible
        // segment and an inflated point count, so runs shorter than two points are dropped
        // while still having counted toward the gap tally.
        segments.RemoveAll(s => s.Points.Count < 2);

        return new ChargeTimeline
        {
            Start = from,
            End = to,
            Segments = segments,
            ChargingBands = bands.Where(b => b.EndX > b.StartX).ToList(),
            GapCount = gaps,
        };
    }
}
