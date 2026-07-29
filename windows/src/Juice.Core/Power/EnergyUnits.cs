namespace Juice.Core.Power;

/// <summary>
/// Conversions between the raw units Windows power/energy sources report and the
/// watt-hour domain Juice presents.
/// </summary>
/// <remarks>
/// <para>
/// The Windows <c>Energy Meter</c> PDH counter set exposes hardware rail metering on
/// machines with an ACPI Energy Meter Interface (EMI) device. Its units are not
/// documented by Microsoft, so they were established empirically on a Surface laptop
/// (Power Meter MAX34417) by trapezoid-integrating the <c>Power</c> counter over a
/// ~117 second window and dividing the <c>Energy</c> counter delta by the integral:
/// </para>
/// <code>
/// sys      dEnergy=601,884,116,171  integrated=2,164,959.8 mJ  =&gt; 278,011.677 units/mJ
/// psu_usb  dEnergy=601,892,590,651  integrated=2,164,997.6 mJ  =&gt; 278,010.747 units/mJ
/// </code>
/// <para>
/// Two independent rails agreed to four significant figures. 1 J is
/// 1/3600 Wh = 2.77778e8 pWh, and the measured constant was 2.78011e8 units/J - a
/// 0.08% match, inside the error of the sampling loop. The <c>Energy</c> counter is
/// therefore in <b>picowatt-hours</b>, and <c>Power</c> is in <b>milliwatts</b>
/// (independently corroborated: <c>psu_usb</c> read 15.2-17.3 W from a USB-C charger).
/// </para>
/// <para>
/// The <c>Time</c> counter advances in milliseconds (delta 21,123 over 21.03 s wall).
/// Its absolute value is not a wall-clock epoch and differs in base between rails, so
/// only deltas are meaningful. Juice prefers its own monotonic clock for interval
/// length and uses the energy accumulator - not integrated power samples - whenever it
/// is available, because an accumulator cannot lose energy to polling gaps.
/// </para>
/// </remarks>
public static class EnergyUnits
{
    /// <summary>Picowatt-hours in one watt-hour.</summary>
    public const double PicowattHoursPerWattHour = 1e12;

    /// <summary>Milliwatts in one watt.</summary>
    public const double MilliwattsPerWatt = 1000.0;

    /// <summary>Joules in one watt-hour.</summary>
    public const double JoulesPerWattHour = 3600.0;

    /// <summary>Converts a raw <c>Energy Meter</c> counter value in picowatt-hours to watt-hours.</summary>
    public static double PicowattHoursToWattHours(double picowattHours)
        => picowattHours / PicowattHoursPerWattHour;

    /// <summary>Converts watt-hours to picowatt-hours.</summary>
    public static double WattHoursToPicowattHours(double wattHours)
        => wattHours * PicowattHoursPerWattHour;

    /// <summary>Converts milliwatts (WMI battery rates, EMI power counters) to watts.</summary>
    public static double MilliwattsToWatts(double milliwatts)
        => milliwatts / MilliwattsPerWatt;

    /// <summary>Converts watts to milliwatts.</summary>
    public static double WattsToMilliwatts(double watts)
        => watts * MilliwattsPerWatt;

    /// <summary>Converts joules to watt-hours.</summary>
    public static double JoulesToWattHours(double joules)
        => joules / JoulesPerWattHour;

    /// <summary>
    /// Integrates a constant power level held for a duration into watt-hours.
    /// Used only when no energy accumulator is available.
    /// </summary>
    public static double WattHoursFrom(double watts, TimeSpan duration)
        => watts * duration.TotalHours;

    /// <summary>
    /// Average watts implied by an energy delta over a duration.
    /// Returns 0 for non-positive durations rather than dividing by zero.
    /// </summary>
    public static double AverageWatts(double wattHours, TimeSpan duration)
        => duration.TotalHours <= 0 ? 0.0 : wattHours / duration.TotalHours;
}
