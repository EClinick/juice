using Juice.Core.Power;

namespace Juice.Core.Presentation;

/// <summary>One component of the machine's draw, sized for a stacked usage bar.</summary>
public sealed record RailSegment
{
    /// <summary>Which rail this is, or <see cref="PowerRail.System"/> for the remainder.</summary>
    public PowerRail Rail { get; init; }

    /// <summary>What the segment is called in the legend.</summary>
    public string Label { get; init; } = string.Empty;

    /// <summary>Watts on this component.</summary>
    public double Watts { get; init; }

    /// <summary>Share of <see cref="RailBreakdown.TotalWatts"/>, from 0 to 1.</summary>
    public double Fraction { get; init; }

    /// <summary>
    /// True for the segment that carries whatever the metered rails did not account for.
    /// </summary>
    /// <remarks>
    /// It is a difference between two measurements rather than a rail of its own, which
    /// is worth distinguishing because it is the one segment the hardware does not report
    /// directly.
    /// </remarks>
    public bool IsRemainder { get; init; }
}

/// <summary>
/// The machine's draw split across the rails the hardware meters separately.
/// </summary>
/// <remarks>
/// <para>
/// This is the measurement the macOS version has no counterpart for. A Mac reports one
/// system figure; an Energy Meter device reports the processor clusters, the graphics and
/// the neural engine as separate rails, so the split here is metered rather than
/// apportioned.
/// </para>
/// <para>
/// Everything the split cannot account for is stated as its own segment rather than being
/// spread across the rails, which is the same rule the app ranking follows for energy no
/// process can be held responsible for.
/// </para>
/// </remarks>
public sealed record RailBreakdown
{
    /// <summary>Segments in a fixed order, with the remainder last when present.</summary>
    public IReadOnlyList<RailSegment> Segments { get; init; } = [];

    /// <summary>What the fractions are taken against, in watts.</summary>
    public double TotalWatts { get; init; }

    /// <summary>
    /// Power the external supply is delivering, or null when nothing meters it.
    /// </summary>
    /// <remarks>
    /// Deliberately not a segment. The supply rail is what comes in from the charger,
    /// which on a charging machine is larger than what the machine consumes, because the
    /// difference is going into the battery. Adding it to a bar of consumers would double
    /// count every watt in it.
    /// </remarks>
    public double? SupplyWatts { get; init; }

    /// <summary>
    /// True when the segments add up to the system reading, so the bar is the whole
    /// machine rather than a part of it.
    /// </summary>
    /// <remarks>
    /// False when there is no system reading to compare against, and false when the rails
    /// add up to more than it. The second case is real: rails and the system rail are read
    /// from the same counter set but describe slightly different instants, so a fast
    /// transient can leave the parts exceeding the whole by a fraction of a watt. Rather
    /// than scaling the segments down to fit, which would misstate every rail, the bar
    /// says it is a partial view and the caption below it says so in words.
    /// </remarks>
    public bool CoversWholeSystem { get; init; }

    /// <summary>True when there is nothing metered to draw.</summary>
    public bool IsEmpty => Segments.Count == 0;

    /// <summary>A breakdown of nothing, for machines with no rail metering.</summary>
    public static RailBreakdown Empty { get; } = new();

    /// <summary>
    /// A sentence saying what the bar covers.
    /// </summary>
    /// <remarks>
    /// Never silent. A stacked bar looks like a whole whatever it actually is, so the one
    /// case where it is not the whole machine has to be stated rather than inferred from
    /// the segment widths.
    /// </remarks>
    public string Caption()
    {
        if (IsEmpty) return string.Empty;

        return CoversWholeSystem
            ? "Metered separately by the hardware."
            : "Metered rails only. They do not account for the whole machine.";
    }
}

/// <summary>Builds the rail breakdown from a live sample.</summary>
public static class RailBreakdownBuilder
{
    /// <summary>
    /// Rails that are components of the machine's own draw, in the order they are drawn.
    /// </summary>
    /// <remarks>
    /// Fixed rather than derived from the sample, so the bar does not reorder itself
    /// between readings when one rail overtakes another. A ranked bar would be redrawn
    /// every couple of seconds on an idle machine, where the CPU and GPU rails trade
    /// places over hundredths of a watt.
    /// </remarks>
    private static readonly (PowerRail Rail, string Label)[] Components =
    [
        (PowerRail.Cpu, "Processor"),
        (PowerRail.Gpu, "Graphics"),
        (PowerRail.Npu, "Neural engine"),
    ];

    /// <summary>
    /// Smallest remainder worth stating, in watts.
    /// </summary>
    /// <remarks>
    /// Half of the precision the flyout prints, so the bar never carries a segment that
    /// displays as 0.0 W. Below this the rails have accounted for the system reading as
    /// closely as the display can express.
    /// </remarks>
    private const double RemainderFloorWatts = 0.05;

    /// <summary>
    /// Splits a reading across the rails that were actually metered.
    /// </summary>
    /// <param name="sample">The latest reading, or null before there is one.</param>
    /// <remarks>
    /// A rail that the machine does not meter is absent, not zero. A laptop with no
    /// discrete graphics rail shows two segments, and inventing a third at zero watts
    /// would be a claim that the hardware reported one.
    /// </remarks>
    public static RailBreakdown Build(PowerSample? sample)
    {
        if (sample is null) return RailBreakdown.Empty;

        var measured = new List<(PowerRail Rail, string Label, double Watts)>();
        var sum = 0.0;

        foreach (var (rail, label) in Components)
        {
            if (sample.WattsFor(rail) is not { } watts) continue;
            if (double.IsNaN(watts) || watts < 0) continue;

            measured.Add((rail, label, watts));
            sum += watts;
        }

        if (measured.Count == 0) return RailBreakdown.Empty;

        var supply = sample.WattsFor(PowerRail.Supply);
        if (supply is { } s && (double.IsNaN(s) || s < 0)) supply = null;

        var system = sample.SystemWatts;
        if (system is { } sys && (double.IsNaN(sys) || sys < 0)) system = null;

        // The system reading is the denominator only when it is at least as large as the
        // parts. When it is not, the parts are the honest denominator and the breakdown
        // says it is partial rather than quietly rescaling a measurement to fit.
        var covers = system is { } total && total >= sum;
        var denominator = covers ? system!.Value : sum;

        var segments = new List<RailSegment>(measured.Count + 1);

        foreach (var (rail, label, watts) in measured)
        {
            segments.Add(new RailSegment
            {
                Rail = rail,
                Label = label,
                Watts = watts,
                Fraction = RankingShare.Of(watts, denominator),
            });
        }

        var remainder = covers ? denominator - sum : 0;

        if (remainder >= RemainderFloorWatts)
        {
            segments.Add(new RailSegment
            {
                Rail = PowerRail.System,

                // The same name the app ranking gives the energy no process owns, because
                // it is the same quantity: the system reading less what the compute rails
                // account for. Two names for one thing on one panel would read as two
                // different measurements.
                Label = EnergyRankingBuilder.PlatformDisplayName,
                Watts = remainder,
                Fraction = RankingShare.Of(remainder, denominator),
                IsRemainder = true,
            });
        }

        return new RailBreakdown
        {
            Segments = segments,
            TotalWatts = denominator,
            SupplyWatts = supply,
            CoversWholeSystem = covers,
        };
    }
}
