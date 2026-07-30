using Juice.Core.Power;

namespace Juice.Core.Presentation;

/// <summary>How much attention a measurement notice deserves.</summary>
public enum MeasurementNoticeSeverity
{
    /// <summary>There is nothing to say.</summary>
    None = 0,

    /// <summary>Worth knowing, and nothing is wrong.</summary>
    Informational = 1,

    /// <summary>The number the user came for is not available.</summary>
    Warning = 2,
}

/// <summary>
/// What the flyout owes the user about where its numbers came from.
/// </summary>
/// <remarks>
/// <para>
/// Juice labels readings with their tier rather than blending measured and modelled
/// figures, and the tier is not a footnote: on hardware with an Energy Meter the wattage
/// is a genuine measurement taken while plugged in, which is exactly what the macOS
/// version cannot do, and on hardware without one it is either an estimate or nothing at
/// all. Those are different claims and the difference belongs on the surface.
/// </para>
/// <para>
/// A notice is produced only when there is something to admit to. Hardware rail metering
/// is the case the app is built for, and announcing that everything is normal would train
/// the user to ignore the one place a real caveat appears.
/// </para>
/// </remarks>
public sealed record MeasurementNotice
{
    /// <summary>Short headline, or empty when there is nothing to say.</summary>
    public string Title { get; init; } = string.Empty;

    /// <summary>The explanation behind the headline.</summary>
    public string Message { get; init; } = string.Empty;

    /// <summary>How much attention it deserves.</summary>
    public MeasurementNoticeSeverity Severity { get; init; } = MeasurementNoticeSeverity.None;

    /// <summary>True when there is a notice to show.</summary>
    public bool IsPresent => Severity != MeasurementNoticeSeverity.None;

    /// <summary>Nothing to say, which is the normal case on metered hardware.</summary>
    public static MeasurementNotice None { get; } = new();

    /// <summary>
    /// Decides what the flyout says about the current source.
    /// </summary>
    /// <param name="tier">The tier the latest reading came from.</param>
    /// <param name="onAc">True when the machine is running on external power.</param>
    /// <remarks>
    /// The power state matters because the battery tier is a real measurement on battery
    /// and no measurement at all on AC, where a full battery reports zero for both rates.
    /// Saying so only in the case where it bites keeps the notice honest without nagging
    /// a machine that is currently measuring perfectly well.
    /// </remarks>
    public static MeasurementNotice For(PowerSourceTier tier, bool onAc) => tier switch
    {
        PowerSourceTier.HardwareRail => None,

        PowerSourceTier.Battery when onAc => new MeasurementNotice
        {
            Title = "Not measured while plugged in",
            Message = "This machine has no energy meter, so draw can only be measured while it is running on battery.",
            Severity = MeasurementNoticeSeverity.Informational,
        },

        PowerSourceTier.Battery => None,

        PowerSourceTier.Modelled => new MeasurementNotice
        {
            Title = "Estimated, not measured",
            Message = "There is no power meter on this machine, so watts are modelled from processor activity, calibrated against measured battery discharge.",
            Severity = MeasurementNoticeSeverity.Informational,
        },

        _ => new MeasurementNotice
        {
            Title = "Power is not being measured",
            Message = "No usable power source was found on this machine, so draw is shown as unknown rather than as a number.",
            Severity = MeasurementNoticeSeverity.Warning,
        },
    };
}

/// <summary>
/// Names the source a reading came from, in the words shown under the reading itself.
/// </summary>
/// <remarks>
/// Separate from the diagnostics report's tier names, which are written lower case to sit
/// mid sentence after a "Source:" label. Under the hero reading the same fact is a
/// statement of its own, and it is worth stating positively: measuring a machine's draw
/// while it is plugged in is the capability this port has and the macOS version does not,
/// so the line says what was measured rather than merely naming a tier.
/// </remarks>
public static class MeasurementSource
{
    /// <summary>What the flyout says the reading was measured from.</summary>
    /// <param name="tier">The tier the latest reading came from.</param>
    /// <param name="onAc">True when the machine is running on external power.</param>
    public static string Label(PowerSourceTier tier, bool onAc) => tier switch
    {
        PowerSourceTier.HardwareRail => "Measured on this machine's energy meter",
        PowerSourceTier.Battery when onAc => "Not measured while plugged in",
        PowerSourceTier.Battery => "Measured from battery discharge",
        PowerSourceTier.Modelled => "Estimated from processor activity",
        _ => "Not measured",
    };
}
