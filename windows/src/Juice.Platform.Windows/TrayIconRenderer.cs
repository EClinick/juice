using System.Drawing;
using System.Drawing.Drawing2D;
using System.Drawing.Text;
using System.Runtime.Versioning;
using Juice.Core.Power;

namespace Juice.Platform.Windows;

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
public static partial class TrayIconRenderer
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
        var size = SystemMetrics.SmallIconSize();
        return size is >= 8 and <= 256 ? size : 16;
    }

    /// <summary>Brand lime from the application mark, for a dark taskbar.</summary>
    private static readonly Color BrandOnDark = Color.FromArgb(255, 0xAE, 0xE8, 0x3A);

    /// <summary>
    /// A deeper lime for a light taskbar.
    /// </summary>
    /// <remarks>
    /// The brand lime is chosen to glow on the dark app icon and has far too little
    /// contrast against a light taskbar, so the light variant is darkened rather than
    /// reused. It is the same hue, so the mark still reads as the same brand.
    /// </remarks>
    private static readonly Color BrandOnLight = Color.FromArgb(255, 0x3F, 0x6B, 0x0A);

    /// <summary>Brand colour for the current taskbar theme.</summary>
    public static Color BrandFor(bool taskbarIsLight) => taskbarIsLight ? BrandOnLight : BrandOnDark;

    /// <summary>
    /// Rasterises a reading and returns a new HICON.
    /// </summary>
    /// <remarks>
    /// The caller owns the returned handle and must pass it to <c>DestroyIcon</c>.
    /// </remarks>
    /// <param name="label">The reading, already fitted to the style's character budget.</param>
    /// <param name="ink">Glyph colour for the current severity and taskbar theme.</param>
    /// <param name="size">Icon edge in pixels.</param>
    /// <param name="style">Presentation style.</param>
    /// <param name="taskbarIsLight">True when the taskbar is light.</param>
    public static nint CreateIcon(
        string label,
        Color ink,
        int size,
        TrayIconStyle style = TrayIconStyle.Number,
        bool taskbarIsLight = false)
    {
        using var bitmap = new Bitmap(size, size, System.Drawing.Imaging.PixelFormat.Format32bppArgb);
        using var graphics = Graphics.FromImage(bitmap);

        graphics.Clear(Color.Transparent);
        graphics.SmoothingMode = SmoothingMode.AntiAlias;
        graphics.InterpolationMode = InterpolationMode.HighQualityBicubic;

        // ClearType cannot be composited onto a transparent surface: it needs to know
        // the pixels behind the glyph, and the taskbar supplies those after the fact.
        graphics.TextRenderingHint = TextRenderingHint.AntiAliasGridFit;

        var resolved = TrayIconLayout.Resolve(style, size);
        var textArea = new RectangleF(0, 0, size, size);
        var textInk = ink;

        switch (resolved)
        {
            case TrayIconStyle.Badge:
                textInk = DrawBadge(graphics, size, ink);
                textArea = Inset(size, size * 0.14f);
                break;

            case TrayIconStyle.Battery:
                textArea = DrawBatteryOutline(graphics, size, BrandFor(taskbarIsLight));
                break;
        }

        DrawLabel(graphics, label, textInk, textArea);
        return bitmap.GetHicon();
    }

    /// <summary>
    /// Fills the icon with the severity colour and returns the ink the label should use
    /// on top of it.
    /// </summary>
    /// <remarks>
    /// The field is what makes this style identifiable at a glance: a coloured tile in the
    /// notification area is not something a headphone battery indicator produces. The
    /// label colour is chosen from the field's luminance rather than from the taskbar
    /// theme, because the label sits on the field and not on the taskbar.
    /// </remarks>
    private static Color DrawBadge(Graphics graphics, int size, Color severityColor)
    {
        var radius = MathF.Max(2f, size * 0.22f);
        var rect = Inset(size, MathF.Max(0.5f, size * 0.03f));

        using (var path = RoundedRect(rect, radius))
        using (var brush = new SolidBrush(severityColor))
        {
            graphics.FillPath(brush, path);
        }

        var luminance = ((0.299 * severityColor.R) + (0.587 * severityColor.G) + (0.114 * severityColor.B)) / 255.0;
        return luminance > 0.55 ? Color.FromArgb(255, 0x10, 0x10, 0x10) : Color.White;
    }

    /// <summary>
    /// Draws the battery capsule from the application mark and returns the area inside it
    /// that the label may occupy.
    /// </summary>
    /// <remarks>
    /// This is the same silhouette as the app icon, a horizontal cell with a terminal nub
    /// on the right, so the notification area icon and the entry in the app list read as
    /// the same product. Shape carries the identity here rather than colour, which keeps
    /// it working when the severity tint changes.
    /// </remarks>
    private static RectangleF DrawBatteryOutline(Graphics graphics, int size, Color brand)
    {
        var stroke = MathF.Max(1f, size / 16f);
        var bodyHeight = size * 0.62f;
        var nubWidth = MathF.Max(1.5f, size * 0.07f);

        var body = new RectangleF(
            stroke / 2f,
            (size - bodyHeight) / 2f,
            size - nubWidth - stroke,
            bodyHeight);

        var radius = MathF.Max(1.5f, size * 0.12f);

        using (var pen = new Pen(brand, stroke) { Alignment = PenAlignment.Center })
        using (var path = RoundedRect(body, radius))
        {
            graphics.DrawPath(pen, path);
        }

        // The terminal, drawn filled because at these sizes an outlined nub collapses
        // into a smudge.
        var nubHeight = bodyHeight * 0.4f;
        using (var brush = new SolidBrush(brand))
        {
            graphics.FillRectangle(
                brush,
                body.Right + (stroke / 2f),
                (size - nubHeight) / 2f,
                nubWidth,
                nubHeight);
        }

        var pad = stroke + MathF.Max(0.5f, size * 0.04f);
        return RectangleF.Inflate(body, -pad, -pad);
    }

    private static RectangleF Inset(int size, float amount)
        => new(amount, amount, size - (amount * 2), size - (amount * 2));

    private static GraphicsPath RoundedRect(RectangleF rect, float radius)
    {
        var path = new GraphicsPath();
        var d = radius * 2;

        path.AddArc(rect.X, rect.Y, d, d, 180, 90);
        path.AddArc(rect.Right - d, rect.Y, d, d, 270, 90);
        path.AddArc(rect.Right - d, rect.Bottom - d, d, d, 0, 90);
        path.AddArc(rect.X, rect.Bottom - d, d, d, 90, 90);
        path.CloseFigure();

        return path;
    }

    private static void DrawLabel(Graphics graphics, string label, Color ink, RectangleF area)
    {
        using var format = new StringFormat(StringFormat.GenericTypographic)
        {
            FormatFlags = StringFormatFlags.NoWrap | StringFormatFlags.NoClip,
            Trimming = StringTrimming.None,
        };

        var (font, measured) = FitFont(graphics, label, area, format);

        try
        {
            using var brush = new SolidBrush(ink);

            // Centre on the measured extent rather than in a layout rectangle, because
            // GDI+ line height leaves visibly uneven padding above and below digits at
            // these sizes.
            var x = area.X + ((area.Width - measured.Width) / 2f);
            var y = area.Y + ((area.Height - measured.Height) / 2f);

            graphics.DrawString(label, font, brush, x, y, format);
        }
        finally
        {
            font.Dispose();
        }
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
        RectangleF area,
        StringFormat format)
    {
        // A little breathing room keeps antialiased edges off the boundary, where the
        // shell would clip them.
        var availableWidth = area.Width - 1f;
        var availableHeight = area.Height;
        var bounds = new SizeF(area.Width * 4f, area.Height * 4f);

        var em = availableHeight * 1.15f;
        const float minimumEm = 5f;

        while (true)
        {
            var font = new Font(ResolvedFamily, em, FontStyle.Bold, GraphicsUnit.Pixel);
            var measured = graphics.MeasureString(label, font, bounds, format);

            if (em <= minimumEm || (measured.Width <= availableWidth && measured.Height <= availableHeight))
            {
                return (font, measured);
            }

            font.Dispose();
            em -= 0.5f;
        }
    }

    /// <summary>
    /// Renders every style at every notification area size onto one sheet, for design
    /// review.
    /// </summary>
    /// <remarks>
    /// The tray icon is the app's most visible surface and the hardest to inspect, since
    /// it is a few dozen pixels sitting on someone else's taskbar. This produces the same
    /// bitmaps the shell would receive, at all four DPI sizes and on both taskbar themes,
    /// so the design can be judged from a file rather than by squinting at a live
    /// taskbar or by driving the UI.
    /// </remarks>
    /// <param name="path">Destination PNG path.</param>
    /// <param name="watts">Reading to render.</param>
    public static void SavePreviewSheet(string path, double watts = 34.8)
    {
        int[] sizes = [16, 20, 24, 32];
        TrayIconStyle[] styles = [TrayIconStyle.Badge, TrayIconStyle.Battery, TrayIconStyle.Number];
        DrainSeverity[] severities = [DrainSeverity.Low, DrainSeverity.Normal, DrainSeverity.High];

        const int cell = 56;
        const int labelColumn = 150;
        var width = labelColumn + (sizes.Length * severities.Length * cell);
        var height = (styles.Length * 2 * cell) + 40;

        using var sheet = new Bitmap(width, height, System.Drawing.Imaging.PixelFormat.Format32bppArgb);
        using var g = Graphics.FromImage(sheet);
        using var caption = new Font("Segoe UI", 10f, FontStyle.Regular, GraphicsUnit.Pixel);
        using var heading = new Font("Segoe UI", 11f, FontStyle.Bold, GraphicsUnit.Pixel);

        g.Clear(Color.FromArgb(255, 32, 32, 32));
        g.SmoothingMode = SmoothingMode.AntiAlias;

        var row = 30;

        foreach (var style in styles)
        {
            foreach (var light in new[] { false, true })
            {
                // Paint the row in the taskbar colour it is meant to sit on, otherwise
                // contrast cannot be judged at all.
                var backdrop = light ? Color.FromArgb(255, 243, 243, 243) : Color.FromArgb(255, 32, 32, 32);
                using (var bg = new SolidBrush(backdrop))
                {
                    g.FillRectangle(bg, 0, row, width, cell);
                }

                using (var text = new SolidBrush(light ? Color.Black : Color.White))
                {
                    g.DrawString($"{style} / {(light ? "light" : "dark")}", caption, text, 6, row + (cell / 2) - 6);
                }

                var x = labelColumn;

                foreach (var severity in severities)
                {
                    foreach (var size in sizes)
                    {
                        var budget = TrayIconLayout.CharacterBudget(TrayIconLayout.Resolve(style, size), size);
                        var label = PowerFormatter.TrayLabel(watts, budget);
                        var ink = InkFor(severity, light);

                        var handle = CreateIcon(label, ink, size, style, light);
                        try
                        {
                            using var icon = Icon.FromHandle(handle);
                            using var bmp = icon.ToBitmap();
                            g.DrawImageUnscaled(bmp, x + ((cell - size) / 2), row + ((cell - size) / 2));
                        }
                        finally
                        {
                            DestroyIcon(handle);
                        }

                        x += cell;
                    }
                }

                row += cell;
            }
        }

        using (var text = new SolidBrush(Color.White))
        {
            g.DrawString(
                $"{watts:0.0} W   |   columns: Low 16/20/24/32, Normal 16/20/24/32, High 16/20/24/32",
                heading, text, 6, 8);
        }

        sheet.Save(path, System.Drawing.Imaging.ImageFormat.Png);
    }

    [System.Runtime.InteropServices.LibraryImport("user32.dll")]
    [return: System.Runtime.InteropServices.MarshalAs(System.Runtime.InteropServices.UnmanagedType.Bool)]
    private static partial bool DestroyIcon(nint icon);

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
