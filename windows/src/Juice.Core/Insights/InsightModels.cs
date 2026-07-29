namespace Juice.Core.Insights;

/// <summary>Kind of observation, matching the macOS insight vocabulary.</summary>
public enum InsightKind
{
    /// <summary>Current drain is unusual against the machine's own baseline.</summary>
    DrainAnomaly,

    /// <summary>An app is using far more energy than it typically does.</summary>
    AppAnomaly,

    /// <summary>The largest energy consumer over the period.</summary>
    HogOfWeek,

    /// <summary>An observation about charging behaviour.</summary>
    ChargingHabit,
}

/// <summary>How much attention an insight deserves.</summary>
public enum InsightSeverity
{
    /// <summary>Worth knowing.</summary>
    Info,

    /// <summary>Worth looking at.</summary>
    Notice,

    /// <summary>Worth acting on.</summary>
    Warning,
}

/// <summary>A single generated observation.</summary>
public sealed record Insight
{
    /// <summary>
    /// Stable identifier per kind and subject, so the UI can avoid re-announcing the same
    /// observation every refresh.
    /// </summary>
    public string Id { get; init; } = string.Empty;

    /// <summary>What kind of observation this is.</summary>
    public InsightKind Kind { get; init; }

    /// <summary>Short headline.</summary>
    public string Title { get; init; } = string.Empty;

    /// <summary>Supporting sentence, including the numbers behind the claim.</summary>
    public string Detail { get; init; } = string.Empty;

    /// <summary>How much attention it deserves.</summary>
    public InsightSeverity Severity { get; init; }
}

/// <summary>Per-app energy for one day, as the insights engine consumes it.</summary>
/// <param name="Day">Local calendar day.</param>
/// <param name="AppId">Stable app key.</param>
/// <param name="DisplayName">Name for display.</param>
/// <param name="WattHours">Energy for that app on that day.</param>
public readonly record struct AppDayEnergy(DateOnly Day, string AppId, string DisplayName, double WattHours);

/// <summary>A battery observation, as the insights engine consumes it.</summary>
/// <param name="Timestamp">When it was taken.</param>
/// <param name="Percent">Charge percentage.</param>
/// <param name="OnAc">True when on external power.</param>
/// <param name="Watts">Draw at the time, when known.</param>
public readonly record struct InsightSample(DateTimeOffset Timestamp, double Percent, bool OnAc, double? Watts);
