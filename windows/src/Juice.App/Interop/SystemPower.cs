using System.Runtime.Versioning;

namespace Juice.App.Interop;

/// <summary>
/// Battery runtime as the operating system reports it.
/// </summary>
/// <remarks>
/// Juice does not compute remaining time itself. Dividing remaining charge by present
/// draw produces a number that swings wildly with every burst of activity, and inventing
/// a smoother one would be fabricating a value. Windows already maintains an estimate
/// from its own history of the battery, so Juice shows that and shows nothing when
/// Windows says it does not know.
/// </remarks>
[SupportedOSPlatform("windows10.0.19041.0")]
internal static class SystemPower
{
    /// <summary>
    /// Estimated time left on battery, or null when on AC or when Windows has not
    /// settled on an estimate yet.
    /// </summary>
    public static TimeSpan? RemainingRuntime()
    {
        if (!NativeMethods.GetSystemPowerStatus(out var status)) return null;
        if (status.ACLineStatus == NativeMethods.AC_LINE_ONLINE) return null;
        if (status.BatteryLifeTime == NativeMethods.BATTERY_LIFE_UNKNOWN) return null;

        return TimeSpan.FromSeconds(status.BatteryLifeTime);
    }
}
