using System.Runtime.Versioning;
using Microsoft.Win32;

namespace Juice.Platform.Windows;

/// <summary>How the taskbar is currently painted.</summary>
/// <param name="IsLightTheme">
/// True when the taskbar and other system surfaces are light.
/// </param>
/// <param name="AccentOnTaskbar">
/// True when the user has enabled "Show accent color on Start and taskbar", in which case
/// the taskbar is tinted with <paramref name="Accent"/> rather than being neutral.
/// </param>
/// <param name="Accent">The user's accent colour.</param>
public readonly record struct TaskbarAppearance(bool IsLightTheme, bool AccentOnTaskbar, AccentColor Accent);

/// <summary>An RGB colour.</summary>
public readonly record struct AccentColor(byte R, byte G, byte B)
{
    /// <summary>Default Windows blue, used when the accent cannot be read.</summary>
    public static AccentColor Default => new(0, 120, 215);

    /// <summary>
    /// Perceived brightness from 0 to 1, using the standard luma weighting.
    /// Useful for deciding whether text over this colour should be light or dark.
    /// </summary>
    public double Luminance => ((0.299 * R) + (0.587 * G) + (0.114 * B)) / 255.0;
}

/// <summary>
/// Reads how Windows is currently painting the taskbar, so Juice can sit on it as a
/// natural extension rather than as a foreign window parked next to it.
/// </summary>
/// <remarks>
/// <para>
/// The trap here is that Windows has two separate theme switches and they are frequently
/// set differently. <c>AppsUseLightTheme</c> drives application chrome, while
/// <c>SystemUsesLightTheme</c> drives the taskbar, Start and the notification area. A user
/// running light apps on a dark taskbar is a common configuration.
/// </para>
/// <para>
/// Anything that has to sit visually against the taskbar, which for Juice means both the
/// tray icon glyph and the flyout, must follow <c>SystemUsesLightTheme</c>. Following the
/// app theme instead produces a tray icon that is invisible against the taskbar it is
/// drawn on, which is the single most common way tray utilities get this wrong.
/// </para>
/// </remarks>
[SupportedOSPlatform("windows")]
public static class TaskbarAppearanceReader
{
    private const string PersonalizeKey = @"Software\Microsoft\Windows\CurrentVersion\Themes\Personalize";
    private const string DwmKey = @"Software\Microsoft\Windows\DWM";

    /// <summary>Reads the current appearance.</summary>
    public static TaskbarAppearance Read() => new(
        IsLightTheme: ReadDword(PersonalizeKey, "SystemUsesLightTheme") == 1,
        AccentOnTaskbar: ReadDword(DwmKey, "ColorPrevalence") == 1,
        Accent: ReadAccent());

    /// <summary>
    /// True when application chrome should be light. Exposed separately because it is a
    /// different switch from the one the taskbar follows.
    /// </summary>
    public static bool AppsUseLightTheme() => ReadDword(PersonalizeKey, "AppsUseLightTheme") == 1;

    private static AccentColor ReadAccent()
    {
        // DWM stores the accent as a DWORD in ABGR order, not the ARGB that most Windows
        // colour APIs use, so the red and blue channels have to be swapped back.
        if (ReadDword(DwmKey, "AccentColor") is not { } raw) return AccentColor.Default;

        var value = unchecked((uint)raw);
        return new AccentColor(
            R: (byte)(value & 0xFF),
            G: (byte)((value >> 8) & 0xFF),
            B: (byte)((value >> 16) & 0xFF));
    }

    private static int? ReadDword(string subKey, string name)
    {
        try
        {
            using var key = Registry.CurrentUser.OpenSubKey(subKey);
            return key?.GetValue(name) as int?;
        }
        catch (Exception ex) when (ex is System.Security.SecurityException or UnauthorizedAccessException or IOException)
        {
            return null;
        }
    }
}
