using System.Drawing;
using System.Drawing.Drawing2D;
using System.Drawing.Text;
using System.Runtime.Versioning;
using Juice.Core.Power;

namespace Juice.App.Tray;

/// <summary>
/// Draws the live wattage into the notification area icon bitmap.
/// </summary>
/// <remarks>
/// <para>
/// A Windows tray icon is a square bitmap with no text label API of any kind, so the
/// only way to put a number in the notification area is to rasterise it. That makes the
/// icon a rendering surface of 16 to 32 pixels a side, which is why
/// <see cref="PowerFormatter.TrayLabel"/> caps the string at three characters and why
/// the font here is sized by measurement rather than by a table.
/// </para>
/// <para>
/// Every render allocates a GDI icon handle that the shell then owns a copy of, and this
/// process runs for weeks. The renderer therefore returns a handle the caller is
/// required to destroy, and <see cref="TrayIcon"/> destroys the previous one on every
/// update.
/// </para>
/// </remarks>
[SupportedOSPlatform("windows10.0.19041.0")]
internal static class TrayIconRenderer
{
    /// <summary>
    /// Preferred faces in descending order. The variable Segoe faces are narrower at
    /// small sizes than the static one, which buys roughly a pixel per glyph, and a
    /// pixel is a lot when the whole canvas is sixteen of them.
    /// </summary>
    private static readonly string[] FontCandidates =
    [
        "Segoe UI Variable Text",
        "Segoe UI Semibold",
        "Segoe UI",
        "Tahoma",
    ];

    private static readonly string ResolvedFamily = ResolveFamily();

    /// <summary>
    /// Ink colour for a drain severity on a given taskbar theme.
    /// </summary>
    /// <remarks>
    /// The two palettes are not inversions of each other. On a dark taskbar the warning
    /// tone has to be light enough to read, and on a light taskbar the same hue has to be
    /// dark enough, so amber moves from a bright tint to a deep one rather than flipping.
    /// Low draw is deliberately low contrast: an idle machine should not attract the eye.
    /// </remarks>
    public static Color InkFor(DrainSeverity severity, bool taskbarIsLight) => severity switch
    {
        DrainSeverity.Low => taskbarIsLight
            ? Color.FromArgb(255, 0x5D, 0x5D, 0x5D)
            : Color.FromArgb(255, 0x9A, 0x9A, 0x9A),

        DrainSeverity.Normal => taskbarIsLight
            ? Color.FromArgb(255, 0x1A, 0x1A, 0x1A)
            : Color.FromArgb(255, 0xFF, 0xFF, 0xFF),

        DrainSeverity.High => taskbarIsLight
            ? Color.FromArgb(255, 0x8A, 0x3E, 0x00)
            : Color.FromArgb(255, 0xFF, 0xC8, 0x3D),

        // Unknown draw shows the placeholder glyph, which should read as absent
        // information rather than as a measurement.
        _ => taskbarIsLight
            ? Color.FromArgb(255, 0x77, 0x77, 0x77)
            : Color.FromArgb(255, 0x88, 0x88, 0x88),
    };

    /// <summary>
    /// The icon edge in physical pixels for the current DPI: 16 at 100 percent, 20 at
    /// 125, 24 at 150, 32 at 200.
    /// </summary>
    public static int IconSize()
    {
        var size = Interop.NativeMethods.GetSystemMetrics(Interop.NativeMethods.SM_CXSMICON);
        return size is >= 8 and <= 256 ? size : 16;
    }

    /// <summary>
    /// Rasterises <paramref name="label"/> and returns a new HICON.
    /// </summary>
    /// <remarks>
    /// The caller owns the returned handle and must pass it to <c>DestroyIcon</c>.
    /// </remarks>
    /// <param name="label">At most three characters, from <see cref="PowerFormatter.TrayLabel"/>.</param>
    /// <param name="ink">Glyph colour, chosen for the current taskbar theme.</param>
    /// <param name="size">Icon edge in pixels.</param>
    public static nint CreateIcon(string label, Color ink, int size)
    {
        using var bitmap = new Bitmap(size, size, System.Drawing.Imaging.PixelFormat.Format32bppArgb);
        using var graphics = Graphics.FromImage(bitmap);

        graphics.Clear(Color.Transparent);
        graphics.SmoothingMode = SmoothingMode.AntiAlias;
        graphics.InterpolationMode = InterpolationMode.HighQualityBicubic;

        // ClearType cannot be composited onto a transparent surface: it needs to know
        // the pixels behind the glyph, and the taskbar supplies those after the fact.
        graphics.TextRenderingHint = TextRenderingHint.AntiAliasGridFit;

        using var format = new StringFormat(StringFormat.GenericTypographic)
        {
            FormatFlags = StringFormatFlags.NoWrap | StringFormatFlags.NoClip,
            Trimming = StringTrimming.None,
        };

        var (font, measured) = FitFont(graphics, label, size, format);

        try
        {
            using var brush = new SolidBrush(ink);

            // Centre on the measured extent rather than in a layout rectangle, because
            // GDI+ line height leaves visibly uneven padding above and below a string of
            // digits at these sizes.
            var x = (size - measured.Width) / 2f;
            var y = (size - measured.Height) / 2f;

            graphics.DrawString(label, font, brush, x, y, format);
        }
        finally
        {
            font.Dispose();
        }

        return bitmap.GetHicon();
    }

    /// <summary>
    /// Finds the largest font size at which <paramref name="label"/> still fits the icon.
    /// </summary>
    /// <remarks>
    /// Shrinking to fit rather than picking a size per string length matters because
    /// "7.2" and "99+" are the same character count but not the same width, and a
    /// clipped digit is a wrong reading rather than an ugly one.
    /// </remarks>
    private static (Font Font, SizeF Measured) FitFont(
        Graphics graphics,
        string label,
        int size,
        StringFormat format)
    {
        // One pixel of breathing room on each side keeps antialiased edges off the icon
        // boundary, where the shell would clip them.
        var available = size - 1f;
        var bounds = new SizeF(size * 4f, size * 4f);

        var em = size * 1.05f;
        const float minimumEm = 6f;

        while (true)
        {
            var font = new Font(ResolvedFamily, em, FontStyle.Bold, GraphicsUnit.Pixel);
            var measured = graphics.MeasureString(label, font, bounds, format);

            if (em <= minimumEm || (measured.Width <= available && measured.Height <= size))
            {
                return (font, measured);
            }

            font.Dispose();
            em -= 0.5f;
        }
    }

    private static string ResolveFamily()
    {
        foreach (var candidate in FontCandidates)
        {
            try
            {
                using var family = new FontFamily(candidate);
                return candidate;
            }
            catch (ArgumentException)
            {
                // Face is not installed on this machine; try the next one.
            }
        }

        return FontFamily.GenericSansSerif.Name;
    }
}
