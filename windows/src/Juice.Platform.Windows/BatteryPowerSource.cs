using System.Management;
using System.Runtime.Versioning;
using Juice.Core.Power;

namespace Juice.Platform.Windows;

/// <summary>Battery state independent of any power measurement.</summary>
public readonly record struct BatteryState
{
    /// <summary>True when running on external power.</summary>
    public required bool OnAc { get; init; }

    /// <summary>Charge percentage, or null when it cannot be computed.</summary>
    public double? Percent { get; init; }

    /// <summary>Positive watts flowing out of the battery, or null when not discharging.</summary>
    public double? DischargeWatts { get; init; }

    /// <summary>Positive watts flowing into the battery, or null when not charging.</summary>
    public double? ChargeWatts { get; init; }

    /// <summary>Remaining energy in watt-hours.</summary>
    public double? RemainingWattHours { get; init; }

    /// <summary>Energy at full charge in watt-hours, reflecting current health.</summary>
    public double? FullChargeWattHours { get; init; }
}

/// <summary>Reads instantaneous battery state.</summary>
public interface IBatteryStateReader
{
    /// <summary>Current state, or null on a machine with no battery.</summary>
    BatteryState? Read();
}

/// <summary>
/// Reads the ACPI battery through <c>root\wmi</c>.
/// </summary>
/// <remarks>
/// <c>BatteryStatus</c> reports <c>ChargeRate</c> and <c>DischargeRate</c> in milliwatts
/// and <c>RemainingCapacity</c> in milliwatt-hours. No elevation is required. The one
/// blind spot is the reason this is only Juice's second-choice power source: a full
/// battery sitting on AC reports zero for both rates, so on AC this source cannot say
/// what the machine is drawing.
/// </remarks>
[SupportedOSPlatform("windows")]
public sealed class WmiBatteryStateReader : IBatteryStateReader
{
    private const string Scope = @"root\wmi";

    /// <inheritdoc />
    public BatteryState? Read()
    {
        try
        {
            using var searcher = new ManagementObjectSearcher(Scope, "SELECT * FROM BatteryStatus");
            using var results = searcher.Get();

            foreach (var o in results)
            {
                using var status = (ManagementObject)o;

                var onAc = GetBool(status, "PowerOnline");
                var chargeMw = GetUInt(status, "ChargeRate");
                var dischargeMw = GetUInt(status, "DischargeRate");
                var remainingMwh = GetUInt(status, "RemainingCapacity");
                var fullMwh = ReadFullChargeCapacityMwh();

                double? percent = remainingMwh is { } r && fullMwh is { } f && f > 0
                    ? Math.Clamp(r / (double)f * 100.0, 0, 100)
                    : null;

                return new BatteryState
                {
                    OnAc = onAc ?? true,
                    Percent = percent,
                    DischargeWatts = dischargeMw is { } d and > 0 ? EnergyUnits.MilliwattsToWatts(d) : null,
                    ChargeWatts = chargeMw is { } c and > 0 ? EnergyUnits.MilliwattsToWatts(c) : null,
                    RemainingWattHours = remainingMwh is { } rw ? rw / 1000.0 : null,
                    FullChargeWattHours = fullMwh is { } fw ? fw / 1000.0 : null,
                };
            }
        }
        catch (ManagementException)
        {
            // No battery, or the class is unavailable on this platform.
        }
        catch (UnauthorizedAccessException)
        {
        }

        return null;
    }

    private static uint? ReadFullChargeCapacityMwh()
    {
        try
        {
            using var searcher = new ManagementObjectSearcher(
                Scope, "SELECT FullChargedCapacity FROM BatteryFullChargedCapacity");
            using var results = searcher.Get();

            foreach (var o in results)
            {
                using var item = (ManagementObject)o;
                if (GetUInt(item, "FullChargedCapacity") is { } value and > 0) return value;
            }
        }
        catch (ManagementException)
        {
        }

        return null;
    }

    private static uint? GetUInt(ManagementBaseObject o, string property)
    {
        try
        {
            return o[property] is null ? null : Convert.ToUInt32(o[property]);
        }
        catch (Exception ex) when (ex is ManagementException or InvalidCastException or FormatException or OverflowException)
        {
            return null;
        }
    }

    private static bool? GetBool(ManagementBaseObject o, string property)
    {
        try
        {
            return o[property] is null ? null : Convert.ToBoolean(o[property]);
        }
        catch (Exception ex) when (ex is ManagementException or InvalidCastException or FormatException)
        {
            return null;
        }
    }
}

/// <summary>
/// Power source derived from battery discharge. Real measurement, but only while the
/// machine is actually running on the battery.
/// </summary>
[SupportedOSPlatform("windows")]
public sealed class BatteryPowerSource(IBatteryStateReader reader) : IPowerSource
{
    /// <inheritdoc />
    public PowerSourceTier Tier => PowerSourceTier.Battery;

    /// <inheritdoc />
    public string Description => "Battery discharge rate (ACPI)";

    /// <inheritdoc />
    public bool IsAvailable => reader.Read() is not null;

    /// <inheritdoc />
    public PowerSample? Read()
    {
        if (reader.Read() is not { } state) return null;

        return new PowerSample
        {
            Timestamp = DateTimeOffset.UtcNow,
            Tier = PowerSourceTier.Battery,
            // Null rather than 0 while on AC: we genuinely do not know the draw here,
            // and claiming 0 W would be a lie the rest of the app would propagate.
            SystemWatts = state.DischargeWatts,
            OnAc = state.OnAc,
            BatteryPercent = state.Percent,
            ChargeWatts = state.ChargeWatts,
        };
    }
}
