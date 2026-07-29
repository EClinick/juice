namespace Juice.Core.Battery;

/// <summary>Battery health at a point in the machine's life.</summary>
public sealed record BatteryHealthPoint
{
    /// <summary>Start of the period this entry covers.</summary>
    public DateTimeOffset Start { get; init; }

    /// <summary>End of the period this entry covers.</summary>
    public DateTimeOffset End { get; init; }

    /// <summary>Capacity the battery had when new, in watt-hours.</summary>
    public double DesignWattHours { get; init; }

    /// <summary>Capacity the battery reaches at full charge now, in watt-hours.</summary>
    public double FullChargeWattHours { get; init; }

    /// <summary>Charge cycles completed, or null when the firmware does not report it.</summary>
    public int? CycleCount { get; init; }

    /// <summary>
    /// Remaining capacity as a fraction of design, or null when design capacity is
    /// unknown. Above 1 is possible and is not an error: a new battery frequently
    /// exceeds its nominal design capacity.
    /// </summary>
    public double? HealthFraction => DesignWattHours > 0
        ? FullChargeWattHours / DesignWattHours
        : null;
}

/// <summary>Battery health over the machine's life, plus what it means.</summary>
public sealed record BatteryHealth
{
    /// <summary>History entries, oldest first.</summary>
    public IReadOnlyList<BatteryHealthPoint> History { get; init; } = [];

    /// <summary>Most recent entry, or null when there is no history.</summary>
    public BatteryHealthPoint? Current => History.Count > 0 ? History[^1] : null;

    /// <summary>Oldest entry, or null when there is no history.</summary>
    public BatteryHealthPoint? Oldest => History.Count > 0 ? History[0] : null;

    /// <summary>
    /// Percentage points of capacity lost between the oldest and newest entries, or null
    /// when there is not enough history to say.
    /// </summary>
    /// <remarks>
    /// Deliberately not extrapolated into a predicted lifespan. Capacity loss is not
    /// linear, and a projection from a few months of data would be a guess dressed as a
    /// measurement.
    /// </remarks>
    public double? CapacityLostPercent
    {
        get
        {
            if (Oldest?.HealthFraction is not { } first) return null;
            if (Current?.HealthFraction is not { } last) return null;
            if (History.Count < 2) return null;

            return (first - last) * 100.0;
        }
    }

    /// <summary>Plain-English summary of the battery's condition.</summary>
    public string Summary()
    {
        if (Current is not { } current) return "No battery health history available.";
        if (current.HealthFraction is not { } health) return "Battery health could not be determined.";

        var percent = health * 100;
        var cycles = current.CycleCount is { } c and > 0 ? $" after {c} charge cycles" : string.Empty;

        var condition = percent switch
        {
            >= 90 => "in good health",
            >= 80 => "showing normal wear",
            >= 60 => "noticeably worn",
            _ => "significantly degraded",
        };

        return $"Battery holds {percent:0}% of its original capacity{cycles}, {condition}.";
    }
}
