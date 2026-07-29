namespace Juice.Core.Power;

/// <summary>How urgent the battery charge is.</summary>
public enum BatteryLevel
{
    /// <summary>There is no battery, or nothing read a charge from it.</summary>
    Unknown,

    /// <summary>Discharging and nearly empty.</summary>
    Critical,

    /// <summary>Discharging and low enough to be worth flagging.</summary>
    Low,

    /// <summary>Nothing to flag.</summary>
    Normal,
}

/// <summary>
/// Classifies battery charge, so the display only warns when a warning is actually due.
/// </summary>
/// <remarks>
/// Charge on its own is not the signal. A machine sitting at 8% on the charger is filling
/// up rather than running out, and colouring that red would be a false alarm, so the
/// warning is tied to genuinely discharging rather than to the number alone.
/// </remarks>
public static class BatteryClassifier
{
    /// <summary>Below this charge a discharging battery reads as critical.</summary>
    public const double CriticalPercent = 10;

    /// <summary>Below this charge a discharging battery is flagged, matching the shell's own low warning.</summary>
    public const double LowPercent = 20;

    /// <summary>Classifies a charge reading.</summary>
    /// <param name="percent">Charge from 0 to 100, or null when there is no reading.</param>
    /// <param name="isOnBattery">True when the machine is running the battery down.</param>
    public static BatteryLevel Classify(double? percent, bool isOnBattery)
    {
        if (percent is not { } level || double.IsNaN(level)) return BatteryLevel.Unknown;
        if (!isOnBattery) return BatteryLevel.Normal;

        if (level < CriticalPercent) return BatteryLevel.Critical;
        if (level < LowPercent) return BatteryLevel.Low;

        return BatteryLevel.Normal;
    }
}
