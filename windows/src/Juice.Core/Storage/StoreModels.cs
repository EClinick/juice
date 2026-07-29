namespace Juice.Core.Storage;

/// <summary>
/// One hour-aligned bucket of system energy, together with how much of that hour Juice
/// was actually recording.
/// </summary>
/// <remarks>
/// <para>
/// <see cref="CoveredSeconds"/> is what makes honest charts possible. Without it an hour
/// during which the machine was asleep and an hour during which it genuinely drew no
/// power are both stored as zero energy, and any chart drawn from that data invents a
/// flat line across a period Juice knew nothing about.
/// </para>
/// <para>
/// With it, a renderer can distinguish "measured, and the answer was low" from "not
/// measured", and draw the second as a gap.
/// </para>
/// </remarks>
public sealed record HourBucket
{
    /// <summary>Start of the hour, aligned in local time.</summary>
    public required DateTimeOffset HourStart { get; init; }

    /// <summary>Energy measured on the system rail during the covered part of the hour.</summary>
    public required double SystemWattHours { get; init; }

    /// <summary>Energy not attributable to any app.</summary>
    public required double PlatformWattHours { get; init; }

    /// <summary>Seconds of this hour during which Juice was recording.</summary>
    public required double CoveredSeconds { get; init; }

    /// <summary>Fraction of the hour that was recorded, from 0 to 1.</summary>
    public double Coverage => Math.Clamp(CoveredSeconds / 3600.0, 0, 1);

    /// <summary>
    /// True when the hour has enough coverage to be worth plotting as a value.
    /// </summary>
    /// <remarks>
    /// An hour with a few seconds of coverage would render as a near-zero bar and read
    /// as "this hour was idle", which is a lie. Below the threshold the hour should be
    /// drawn as a gap and, if a total is shown, labelled as partial.
    /// </remarks>
    public bool IsPlottable => Coverage >= 0.5;

    /// <summary>
    /// Average watts over the covered part of the hour, or null when there is too little
    /// coverage to say. Deliberately not extrapolated to a full hour.
    /// </summary>
    public double? AverageWatts => CoveredSeconds <= 0
        ? null
        : SystemWattHours / (CoveredSeconds / 3600.0);
}

/// <summary>Energy attributed to one app inside one hour.</summary>
public sealed record HourlyAppEnergy
{
    /// <summary>Start of the hour, aligned in local time.</summary>
    public required DateTimeOffset HourStart { get; init; }

    /// <summary>Stable grouping key.</summary>
    public required string AppId { get; init; }

    /// <summary>Name for display.</summary>
    public required string DisplayName { get; init; }

    /// <summary>Energy attributed from the CPU rail.</summary>
    public required double CpuWattHours { get; init; }

    /// <summary>Energy attributed from the GPU rail.</summary>
    public required double GpuWattHours { get; init; }

    /// <summary>Total attributed energy.</summary>
    public double TotalWattHours => CpuWattHours + GpuWattHours;
}

/// <summary>Energy attributed to one app over a whole day.</summary>
public sealed record DailyAppEnergy
{
    /// <summary>Local calendar day in <c>yyyy-MM-dd</c> form.</summary>
    public required string Day { get; init; }

    /// <summary>Stable grouping key.</summary>
    public required string AppId { get; init; }

    /// <summary>Name for display.</summary>
    public required string DisplayName { get; init; }

    /// <summary>Total energy for the day.</summary>
    public required double WattHours { get; init; }
}

/// <summary>A point on the battery charge timeline.</summary>
public sealed record BatteryPoint
{
    /// <summary>When the sample was taken.</summary>
    public required DateTimeOffset Timestamp { get; init; }

    /// <summary>Charge percentage.</summary>
    public required double Percent { get; init; }

    /// <summary>True when on external power.</summary>
    public required bool OnAc { get; init; }

    /// <summary>System draw at the time, when it could be measured.</summary>
    public double? Watts { get; init; }
}
