using System.Runtime.InteropServices;
using System.Runtime.Versioning;
using Juice.Core.Monitoring;
using Juice.Core.Power;

namespace Juice.Platform.Windows;

/// <summary>
/// Reads AC state and charge percentage through <c>GetSystemPowerStatus</c>.
/// </summary>
/// <remarks>
/// <para>
/// This exists because <see cref="WmiBatteryStateReader"/> cannot run under Native AOT.
/// WMI activates its COM types by reflection, so the trimmer removes constructors it
/// cannot see being used, and the first query fails with "No parameterless constructor
/// defined for type 'System.Management.WbemDefPath'". The failure is at runtime rather
/// than at build time, which is why the tray agent showed an icon with no number on it
/// instead of failing to start.
/// </para>
/// <para>
/// It reports less than the WMI reader: no rates, no capacities, and a percentage rather
/// than a computed ratio of milliwatt-hours. That is enough for the hardware rail path,
/// which needs the battery only to say whether the machine is on mains and roughly how
/// full it is. Watts there come from the energy meter, not from the battery.
/// </para>
/// <para>
/// It is deliberately not a replacement for the WMI reader everywhere. The battery power
/// source derives watts from the discharge rate, and that field has no equivalent here,
/// so a complete removal of the WMI dependency means talking to the battery device
/// directly with <c>IOCTL_BATTERY_QUERY_STATUS</c>. Until then this covers the common
/// case, which is every machine that has an energy meter.
/// </para>
/// </remarks>
[SupportedOSPlatform("windows")]
public sealed partial class SystemPowerStatusReader : IBatteryStateReader, IBatteryRuntimeReader
{
    private const byte AcOffline = 0;
    private const byte Unknown = 255;

    /// <summary>Windows reports this when it has no runtime estimate yet.</summary>
    private const uint BatteryLifeUnknown = 0xFFFFFFFF;

    /// <summary>Indicates the machine reports no battery at all.</summary>
    private const byte NoSystemBattery = 128;

    /// <summary>
    /// Time left on battery as Windows estimates it, or null on AC or when it will not say.
    /// </summary>
    /// <remarks>
    /// Windows maintains this from its own history of the battery. Juice reports that
    /// figure or reports nothing, rather than dividing remaining charge by present draw,
    /// which produces a number that lurches with every burst of activity.
    /// </remarks>
    public TimeSpan? RemainingRuntime()
    {
        if (!GetSystemPowerStatus(out var status)) return null;
        if (status.ACLineStatus != AcOffline) return null;
        if (status.BatteryLifeTime == BatteryLifeUnknown) return null;

        return TimeSpan.FromSeconds(status.BatteryLifeTime);
    }

    /// <inheritdoc />
    public BatteryState? Read()
    {
        if (!GetSystemPowerStatus(out var status)) return null;

        // A desktop still answers this call, and says it has no battery. Reporting a
        // fabricated 100 percent there would be worse than reporting nothing.
        if ((status.BatteryFlag & NoSystemBattery) != 0)
        {
            return new BatteryState { OnAc = status.ACLineStatus != AcOffline };
        }

        double? percent = status.BatteryLifePercent == Unknown
            ? null
            : Math.Clamp((double)status.BatteryLifePercent, 0d, 100d);

        return new BatteryState
        {
            // Unknown is treated as mains. A machine that cannot say is far more often
            // plugged in than running flat, and the alternative is telling someone their
            // battery is draining when it is not.
            OnAc = status.ACLineStatus != AcOffline,
            Percent = percent,
        };
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct SYSTEM_POWER_STATUS
    {
        public byte ACLineStatus;
        public byte BatteryFlag;
        public byte BatteryLifePercent;
        public byte SystemStatusFlag;
        public uint BatteryLifeTime;
        public uint BatteryFullLifeTime;
    }

    [LibraryImport("kernel32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static partial bool GetSystemPowerStatus(out SYSTEM_POWER_STATUS status);
}
