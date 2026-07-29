namespace Juice.Core.Power;

/// <summary>
/// Where a power reading came from, in descending order of trust. Juice always labels
/// readings with their tier rather than blending measured and modelled numbers.
/// </summary>
public enum PowerSourceTier
{
    /// <summary>
    /// No usable source. Live watts are unavailable and must be shown as unknown,
    /// never as zero.
    /// </summary>
    None = 0,

    /// <summary>
    /// Modelled from a linear fit calibrated against measured battery discharge.
    /// Always surfaced to the user as an estimate.
    /// </summary>
    Modelled = 1,

    /// <summary>
    /// Battery discharge/charge rate from the ACPI battery (<c>root\wmi BatteryStatus</c>).
    /// Real measurement, but only while running on battery: a full battery on AC reports
    /// zero for both rates, which is precisely the blind spot Juice fills with Tier A.
    /// </summary>
    Battery = 2,

    /// <summary>
    /// Hardware rail metering from the <c>Energy Meter</c> PDH counter set, backed by an
    /// ACPI Energy Meter Interface device. Reports true system draw on AC and on battery,
    /// with CPU and GPU rails metered separately.
    /// </summary>
    HardwareRail = 3,
}

/// <summary>Identifies a metered hardware rail, normalised across vendors.</summary>
public enum PowerRail
{
    /// <summary>Whole-system draw (the <c>sys</c> rail).</summary>
    System,

    /// <summary>Aggregate of all CPU cluster rails (<c>cpu_cluster_0..n</c>).</summary>
    Cpu,

    /// <summary>Integrated/discrete GPU rail (<c>gpu</c>).</summary>
    Gpu,

    /// <summary>
    /// Neural processing unit rail, where the platform meters one. This is the Windows
    /// counterpart of the Neural Engine energy the macOS version reports.
    /// </summary>
    Npu,

    /// <summary>Power delivered by the external supply (<c>psu_usb</c>, <c>usbc_total</c>).</summary>
    Supply,

    /// <summary>A metered rail Juice does not map to a known role.</summary>
    Other,
}

/// <summary>
/// One rail's reading at a point in time. <paramref name="CumulativeWattHours"/> is the
/// running accumulator when the source provides one; it is monotonic and survives
/// polling gaps, so it is preferred over integrating <paramref name="Watts"/>.
/// </summary>
public readonly record struct RailReading(
    PowerRail Rail,
    string InstanceName,
    double Watts,
    double? CumulativeWattHours);

/// <summary>
/// A single system-wide power observation, with whatever rail detail the source offered.
/// </summary>
public sealed record PowerSample
{
    /// <summary>When the sample was taken (UTC).</summary>
    public required DateTimeOffset Timestamp { get; init; }

    /// <summary>Which kind of source produced it.</summary>
    public required PowerSourceTier Tier { get; init; }

    /// <summary>
    /// Total system draw in watts, or null when unknown. Null is meaningful: it means
    /// "we could not measure", and must not be rendered as 0 W.
    /// </summary>
    public double? SystemWatts { get; init; }

    /// <summary>Per-rail detail, empty when the source is not rail-aware.</summary>
    public IReadOnlyList<RailReading> Rails { get; init; } = [];

    /// <summary>True when running on external power.</summary>
    public bool OnAc { get; init; }

    /// <summary>Battery charge percentage, or null on a machine with no battery.</summary>
    public double? BatteryPercent { get; init; }

    /// <summary>
    /// Rate of energy going into the battery in watts while charging. This is not part of
    /// <see cref="SystemWatts"/> consumption by apps; it is tracked so the UI can explain
    /// the difference between wall draw and compute draw.
    /// </summary>
    public double? ChargeWatts { get; init; }

    /// <summary>Watts on a given rail, or null when that rail was not metered.</summary>
    public double? WattsFor(PowerRail rail)
    {
        double sum = 0;
        var found = false;
        foreach (var r in Rails)
        {
            if (r.Rail != rail) continue;
            sum += r.Watts;
            found = true;
        }
        return found ? sum : null;
    }

    /// <summary>Cumulative watt-hours on a rail, or null when no accumulator was offered.</summary>
    public double? CumulativeWattHoursFor(PowerRail rail)
    {
        double sum = 0;
        var found = false;
        foreach (var r in Rails)
        {
            if (r.Rail != rail || r.CumulativeWattHours is not { } wh) continue;
            sum += wh;
            found = true;
        }
        return found ? sum : null;
    }
}

/// <summary>A source of live system power readings.</summary>
public interface IPowerSource
{
    /// <summary>Tier this source reports at.</summary>
    PowerSourceTier Tier { get; }

    /// <summary>Human-readable description for the settings screen.</summary>
    string Description { get; }

    /// <summary>True when the source is present and returning data on this machine.</summary>
    bool IsAvailable { get; }

    /// <summary>Takes a reading, or returns null when the source cannot currently measure.</summary>
    PowerSample? Read();
}
