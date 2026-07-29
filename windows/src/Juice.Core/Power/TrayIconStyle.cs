namespace Juice.Core.Power;

/// <summary>
/// How the notification area icon presents the live reading.
/// </summary>
/// <remarks>
/// <para>
/// A bare number in the notification area is ambiguous. Headphone and battery utilities
/// render exactly the same thing, so a user glancing at the taskbar cannot tell a wattage
/// from a charge percentage. Every style except <see cref="Number"/> exists to carry some
/// mark that identifies the reading as power.
/// </para>
/// <para>
/// This is a preference rather than a single choice because the right answer depends on
/// the taskbar it sits on and on how many other icons are competing with it.
/// </para>
/// </remarks>
public enum TrayIconStyle
{
    /// <summary>
    /// Wattage over a filled field tinted by drain severity. The most visible option, and
    /// the easiest to pick out of a crowded notification area, at the cost of being the
    /// loudest.
    /// </summary>
    Badge,

    /// <summary>
    /// Wattage inside a battery outline, matching the application's own mark. Identifies
    /// the reading as power through shape rather than through colour, so it stays legible
    /// on any taskbar.
    /// </summary>
    Battery,

    /// <summary>
    /// Wattage alone, tinted by drain severity. The quietest option, and the one that can
    /// be mistaken for a percentage.
    /// </summary>
    Number,
}

/// <summary>Layout facts a tray renderer needs, derived from style and icon size.</summary>
public static class TrayIconLayout
{
    /// <summary>
    /// How many characters of the reading will fit for a style at a given icon size.
    /// </summary>
    /// <remarks>
    /// Notification area icons are 16 pixels at 100 percent scaling and 32 at 200. Styles
    /// that draw a surround spend pixels on it, so they have less room for digits, and at
    /// the smallest sizes they have to drop the decimal to stay readable.
    /// </remarks>
    public static int CharacterBudget(TrayIconStyle style, int iconSize) => style switch
    {
        // The outline and its inner padding cost roughly a third of the width.
        TrayIconStyle.Battery => iconSize >= 24 ? 2 : 1,

        // The fill costs nothing horizontally, only a small inset.
        TrayIconStyle.Badge => iconSize >= 20 ? 3 : 2,

        _ => 3,
    };

    /// <summary>
    /// True when a style can be drawn legibly at this size.
    /// </summary>
    /// <remarks>
    /// The battery outline needs enough pixels for a stroke, an inner gap and a glyph.
    /// Below that it degrades into a smudge, and a smudge that cannot be read is worse
    /// than a plain number, so the caller should fall back rather than draw it.
    /// </remarks>
    public static bool IsLegible(TrayIconStyle style, int iconSize) => style switch
    {
        TrayIconStyle.Battery => iconSize >= 20,
        _ => true,
    };

    /// <summary>
    /// The style actually used, after falling back from one that cannot be drawn legibly.
    /// </summary>
    public static TrayIconStyle Resolve(TrayIconStyle preferred, int iconSize)
        => IsLegible(preferred, iconSize) ? preferred : TrayIconStyle.Badge;
}
