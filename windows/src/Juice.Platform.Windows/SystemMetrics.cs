using System.Runtime.InteropServices;
using System.Runtime.Versioning;

namespace Juice.Platform.Windows;

/// <summary>System metrics Juice needs for sizing rendered artwork.</summary>
[SupportedOSPlatform("windows")]
public static partial class SystemMetrics
{
    private const int SmCxSmIcon = 49;

    /// <summary>
    /// Notification area icon edge in physical pixels for the current DPI.
    /// </summary>
    /// <remarks>
    /// 16 at 100 percent scaling, 20 at 125, 24 at 150 and 32 at 200. The result is
    /// range-checked because a bogus value here would be rasterised into an unreadable or
    /// enormous bitmap rather than failing loudly.
    /// </remarks>
    public static int SmallIconSize()
    {
        var size = GetSystemMetrics(SmCxSmIcon);
        return size is >= 8 and <= 256 ? size : 16;
    }

    [LibraryImport("user32.dll")]
    private static partial int GetSystemMetrics(int index);
}
