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
    /// The short string drawn into the tray icon, fitted to a character budget.
    /// </summary>
    /// <remarks>
    /// <para>
    /// Below 10 W a single digit loses too much relative precision, so one decimal is
    /// kept ("7.2"); the decimal point is narrow and costs little width. From 10 W up,
    /// the integer is enough and stays legible at 16 pixels. Three-digit draws are
    /// capped rather than shrinking the font to illegibility.
    /// </para>
    /// <para>
    /// The budget exists because some icon styles spend width on a mark identifying the
    /// reading as power. Precision is what gives way when space is tight, never the mark:
    /// a number nobody can attribute to power is worth less than a rounder number they
    /// can, which is the whole problem with a bare figure in the notification area.
    /// </para>
    /// </remarks>
    /// <param name="watts">Draw, or null when unknown.</param>
    /// <param name="maxCharacters">Character budget, at least 1.</param>
    public static string TrayLabel(double? watts, int maxCharacters = 3)
    {
        if (watts is not { } w || double.IsNaN(w) || w < 0) return UnknownTrayLabel;

        if (maxCharacters >= 3)
        {
            if (w >= 99.5) return "99+";
            if (w >= 9.95) return Math.Round(w).ToString("0");
            return w.ToString("0.0");
        }

        if (maxCharacters == 2)
        {
            // No room for an overflow marker, so a very high draw pins at 99 rather than
            // spilling to three digits and being clipped.
            return w >= 99.5 ? "99" : Math.Round(w).ToString("0");
        }

        // A single character can only carry an order of magnitude honestly.
        return w >= 9.5 ? "9" : Math.Round(w).ToString("0");
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

    /// <summary>
    /// Compact elapsed time that keeps its meaning below a minute, for example "42s".
    /// </summary>
    /// <remarks>
    /// <see cref="FormatDuration"/> is written for a battery estimate, where the smallest
    /// figure worth stating is a minute and where the reading is a projection anyway. The
    /// live session window is different: it starts at zero every time the sampling loop
    /// starts, and rendering the first three quarters of a minute as "0m" told the user
    /// that nothing had been measured at the exact moment the flyout was showing them the
    /// measurement. A second is a real unit and this is the one place it is the right one.
    ///
    /// It hands off to <see cref="FormatDuration"/> at a minute rather than carrying
    /// seconds any further, because "1h 12m 3s" is precision nobody asked for.
    /// </remarks>
    public static string FormatElapsed(TimeSpan elapsed)
    {
        if (elapsed < TimeSpan.Zero) elapsed = TimeSpan.Zero;

        return elapsed < TimeSpan.FromMinutes(1)
            ? $"{(int)elapsed.TotalSeconds}s"
            : FormatDuration(elapsed);
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
