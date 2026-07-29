namespace Juice.Core.Power;

/// <summary>
/// Formats live power for the places Juice displays it, above all the tray icon.
/// </summary>
/// <remarks>
/// <para>
/// The tray constraint drives this whole type. A Windows notification-area icon is a
/// square bitmap of 16, 20, 24 or 32 pixels depending on DPI, with no text label API of
/// any kind. Drawing a number into that bitmap leaves room for roughly two glyphs, so
/// the tray string has to be aggressively short while the tooltip carries the precision.
/// </para>
/// <para>
/// Unknown power is formatted as "-", never as "0". A machine on AC without an energy
/// meter genuinely cannot report draw, and showing 0 W would state something false.
/// </para>
/// </remarks>
public static class PowerFormatter
{
    /// <summary>Placeholder shown when draw cannot be measured.</summary>
    public const string UnknownTrayLabel = "-";

    /// <summary>
    /// Below this, a battery is maintaining charge rather than charging. A full battery
    /// on AC trickles a few tens of milliwatts, and reporting that as "charging 0.0 W" is
    /// worse than saying nothing.
    /// </summary>
    public const double ChargingThresholdWatts = 0.5;

    /// <summary>
    /// The at-most-three character string drawn into the tray icon.
    /// </summary>
    /// <remarks>
    /// Below 10 W a single digit loses too much relative precision, so one decimal is
    /// kept ("7.2"); the decimal point is narrow and costs little width. From 10 W up,
    /// the integer is enough and stays legible at 16 pixels. Three-digit draws are
    /// capped at "99+" rather than shrinking the font to illegibility.
    /// </remarks>
    public static string TrayLabel(double? watts)
    {
        if (watts is not { } w || double.IsNaN(w) || w < 0) return UnknownTrayLabel;

        if (w >= 99.5) return "99+";
        if (w >= 9.95) return Math.Round(w).ToString("0");
        return w.ToString("0.0");
    }

    /// <summary>Precise wattage for tooltips, popovers and tables.</summary>
    public static string Watts(double? watts)
        => watts is { } w && !double.IsNaN(w) && w >= 0
            ? $"{w:0.0} W"
            : "Unknown";

    /// <summary>
    /// Energy sized to the magnitude: milliwatt-hours below 1 Wh, watt-hours up to
    /// 1000, kilowatt-hours above.
    /// </summary>
    public static string Energy(double wattHours)
    {
        var magnitude = Math.Abs(wattHours);

        if (magnitude < 0.001) return "0 Wh";
        if (magnitude < 1) return $"{wattHours * 1000:0} mWh";
        if (magnitude < 1000) return $"{wattHours:0.0} Wh";
        return $"{wattHours / 1000:0.00} kWh";
    }

    /// <summary>Tooltip line combining draw, charge and remaining time.</summary>
    public static string Tooltip(PowerSample? sample, TimeSpan? remaining)
    {
        if (sample is null) return "Juice";

        var parts = new List<string> { Watts(sample.SystemWatts) };

        if (sample.BatteryPercent is { } percent) parts.Add($"{percent:0}%");

        if (sample.OnAc)
        {
            parts.Add(sample.ChargeWatts is { } cw && cw >= ChargingThresholdWatts
                ? $"charging {cw:0.0} W"
                : "plugged in");
        }
        else if (remaining is { } left && left > TimeSpan.Zero)
        {
            parts.Add($"{FormatDuration(left)} left");
        }

        return string.Join(" \u00b7 ", parts);
    }

    /// <summary>Compact hours and minutes, for example "3h 12m".</summary>
    public static string FormatDuration(TimeSpan duration)
    {
        if (duration < TimeSpan.Zero) duration = TimeSpan.Zero;

        var hours = (int)duration.TotalHours;
        var minutes = duration.Minutes;

        return hours > 0 ? $"{hours}h {minutes}m" : $"{minutes}m";
    }
}

/// <summary>How hard the machine is drawing, used to tint the tray icon.</summary>
public enum DrainSeverity
{
    /// <summary>Draw cannot be measured.</summary>
    Unknown,

    /// <summary>Idle or near-idle.</summary>
    Low,

    /// <summary>Ordinary interactive use.</summary>
    Normal,

    /// <summary>Sustained heavy draw.</summary>
    High,
}

/// <summary>Classifies draw so the tray icon can carry meaning at a glance.</summary>
/// <remarks>
/// Thresholds are relative to the machine's own observed idle draw rather than absolute
/// watts, because 15 W means something very different on a fanless tablet than on a
/// mobile workstation.
/// </remarks>
public static class DrainClassifier
{
    /// <summary>Classifies draw against a baseline idle figure.</summary>
    public static DrainSeverity Classify(double? watts, double? idleBaselineWatts)
    {
        if (watts is not { } w || w < 0) return DrainSeverity.Unknown;

        // Without a learned baseline, fall back to thresholds typical of a laptop.
        var baseline = idleBaselineWatts is { } b and > 0.5 ? b : 6.0;

        if (w <= baseline * 1.3) return DrainSeverity.Low;
        if (w <= baseline * 2.5) return DrainSeverity.Normal;
        return DrainSeverity.High;
    }
}
