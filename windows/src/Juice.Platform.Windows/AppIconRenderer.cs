using System.Drawing;
using System.Drawing.Drawing2D;
using System.Runtime.Versioning;

namespace Juice.Platform.Windows;

/// <summary>
/// Draws the application mark, at any size, for the package's visual assets.
/// </summary>
/// <remarks>
/// <para>
/// The shipped assets were the Windows App SDK template placeholders, the grey crossed
/// box, which is what Windows was showing in the Start menu, the taskbar, Alt+Tab and
/// search. This draws the real mark instead, from the same brand lime and the same battery
/// silhouette <see cref="TrayIconRenderer"/> uses, so the notification area icon and the
/// application icon are recognisably the same thing.
/// </para>
/// <para>
/// Generated rather than hand authored because MSIX wants the mark at around thirty sizes,
/// across scale factors and target sizes and their unplated variants, and a set of thirty
/// hand exported files goes stale the first time the mark changes. Regenerate with
/// <c>juice appicons</c>.
/// </para>
/// <para>
/// Two variants exist because Windows composites them differently. The tile form fills its
/// canvas with the brand colour and is used where Windows draws the icon on a plate of its
/// own choosing. The unplated form draws the mark on transparency, for the taskbar and for
/// Start's small icons, where a filled square would read as a coloured block rather than an
/// icon.
/// </para>
/// </remarks>
[SupportedOSPlatform("windows")]
public static class AppIconRenderer
{
    /// <summary>Brand lime, the same value the notification area mark uses on a dark taskbar.</summary>
    private static readonly Color BrandLime = Color.FromArgb(255, 0xAE, 0xE8, 0x3A);

    /// <summary>The deep field the tile form sits on, dark enough for the lime to carry.</summary>
    private static readonly Color TileField = Color.FromArgb(255, 0x1B, 0x24, 0x0B);

    /// <summary>Renders the mark at one size.</summary>
    /// <param name="size">Edge length in pixels.</param>
    /// <param name="plated">
    /// True for the filled tile form, false to draw the mark on transparency.
    /// </param>
    public static Bitmap Render(int size, bool plated)
    {
        var bitmap = new Bitmap(size, size, System.Drawing.Imaging.PixelFormat.Format32bppArgb);

        using var graphics = Graphics.FromImage(bitmap);
        graphics.SmoothingMode = SmoothingMode.AntiAlias;
        graphics.InterpolationMode = InterpolationMode.HighQualityBicubic;
        graphics.PixelOffsetMode = PixelOffsetMode.HighQuality;
        graphics.Clear(Color.Transparent);

        if (plated)
        {
            // Windows rounds tile corners itself on some surfaces and not others, so the
            // plate is drawn square and left for the shell to mask.
            using var field = new SolidBrush(TileField);
            graphics.FillRectangle(field, 0, 0, size, size);
        }

        DrawBattery(graphics, size, BrandLime, plated);
        return bitmap;
    }

    /// <summary>
    /// Draws a battery silhouette, sized as a fraction of the canvas.
    /// </summary>
    /// <remarks>
    /// The proportions follow the notification area mark: a rounded body with a terminal
    /// nub on the right, and a bolt cut out of the body. Stroke weight scales with the
    /// canvas so the outline stays visible at sixteen pixels without becoming heavy at two
    /// hundred and fifty six.
    /// </remarks>
    private static void DrawBattery(Graphics graphics, int size, Color brand, bool plated)
    {
        // The mark occupies less of a plated tile than of a bare icon, because a tile has
        // its own edges to breathe against and an unplated icon has none. A battery is a
        // wide shape, so in a square canvas it will always leave headroom above and below;
        // the unplated inset is tight to stop that headroom making the mark look shrunken
        // at the sixteen and twenty four pixel sizes the taskbar and Start list use.
        var inset = plated ? size * 0.22f : size * 0.05f;
        var width = size - (inset * 2);
        var height = width * 0.66f;
        var top = (size - height) / 2f;

        var nub = width * 0.07f;
        var bodyWidth = width - nub;
        var body = new RectangleF(inset, top, bodyWidth, height);

        var stroke = MathF.Max(1.5f, size * 0.055f);
        var radius = MathF.Max(1f, size * 0.09f);

        using var pen = new Pen(brand, stroke) { Alignment = PenAlignment.Center };
        using var path = Rounded(body, radius);
        graphics.DrawPath(pen, path);

        // Terminal, drawn as a filled cap rather than a stroked rectangle so it stays solid
        // at small sizes where a stroke would close up into a smudge.
        using var fill = new SolidBrush(brand);
        var nubHeight = height * 0.36f;
        graphics.FillRectangle(
            fill,
            inset + bodyWidth + (stroke / 2f),
            top + ((height - nubHeight) / 2f),
            nub,
            nubHeight);

        DrawBolt(graphics, body, brand);
    }

    /// <summary>Draws the charge bolt inside the battery body.</summary>
    private static void DrawBolt(Graphics graphics, RectangleF body, Color brand)
    {
        var centreX = body.X + (body.Width / 2f);
        var centreY = body.Y + (body.Height / 2f);
        var half = body.Height * 0.30f;
        var wide = body.Height * 0.20f;

        var bolt = new[]
        {
            new PointF(centreX + (wide * 0.55f), centreY - half),
            new PointF(centreX - (wide * 0.85f), centreY + (half * 0.12f)),
            new PointF(centreX - (wide * 0.05f), centreY + (half * 0.12f)),
            new PointF(centreX - (wide * 0.55f), centreY + half),
            new PointF(centreX + (wide * 0.85f), centreY - (half * 0.12f)),
            new PointF(centreX + (wide * 0.05f), centreY - (half * 0.12f)),
        };

        using var fill = new SolidBrush(brand);
        graphics.FillPolygon(fill, bolt);
    }

    private static GraphicsPath Rounded(RectangleF rect, float radius)
    {
        var path = new GraphicsPath();
        var diameter = radius * 2;

        path.AddArc(rect.X, rect.Y, diameter, diameter, 180, 90);
        path.AddArc(rect.Right - diameter, rect.Y, diameter, diameter, 270, 90);
        path.AddArc(rect.Right - diameter, rect.Bottom - diameter, diameter, diameter, 0, 90);
        path.AddArc(rect.X, rect.Bottom - diameter, diameter, diameter, 90, 90);
        path.CloseFigure();

        return path;
    }
}
