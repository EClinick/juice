using Juice.Core.Presentation;
using Microsoft.UI;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Shapes;
using XamlPath = Microsoft.UI.Xaml.Shapes.Path;
using Windows.Foundation;
using Windows.UI;

namespace Juice.App.Controls;

/// <summary>
/// Draws a <see cref="ChargeTimeline"/> as a filled area chart.
/// </summary>
/// <remarks>
/// <para>
/// The visual target is the Windows Settings battery levels chart, because that is the
/// idiom a Windows user already recognises for battery history: a gradient-filled area
/// under a line, with horizontal reference lines and shaded periods behind it.
/// </para>
/// <para>
/// One thing is deliberately different. Settings draws a single unbroken line across the
/// whole period, including stretches it holds no data for. Juice draws each continuous
/// run as its own figure, so a period the machine was asleep appears as a break rather
/// than as a gentle slope between the charge it had when it shut and the charge it had
/// when it woke. That slope would be an assertion about a discharge curve nobody
/// observed, which the repository's charting rules forbid.
/// </para>
/// <para>
/// Built from <see cref="Path"/> geometry rather than a charting library, for the same
/// reasons as the bar chart: no dependency, theme resources work, and the shapes are
/// ordinary XAML elements that accessibility and tooltips already understand.
/// </para>
/// <para>
/// The brushes arrive as dependency properties rather than being looked up by name here,
/// for the reason given at length on <see cref="EnergyHistoryChart"/>: a code lookup
/// resolves against the process theme, and this chart lives in a window that follows the
/// taskbar theme instead.
/// </para>
/// </remarks>
public sealed class ChargeTimelineChart : UserControl
{
    /// <summary>Identifies the <see cref="Timeline"/> dependency property.</summary>
    public static readonly DependencyProperty TimelineProperty = DependencyProperty.Register(
        nameof(Timeline),
        typeof(ChargeTimeline),
        typeof(ChargeTimelineChart),
        new PropertyMetadata(null, OnVisualPropertyChanged));

    /// <summary>Identifies the <see cref="LineBrush"/> dependency property.</summary>
    public static readonly DependencyProperty LineBrushProperty = DependencyProperty.Register(
        nameof(LineBrush),
        typeof(Brush),
        typeof(ChargeTimelineChart),
        new PropertyMetadata(null, OnVisualPropertyChanged));

    /// <summary>Identifies the <see cref="GridLineBrush"/> dependency property.</summary>
    public static readonly DependencyProperty GridLineBrushProperty = DependencyProperty.Register(
        nameof(GridLineBrush),
        typeof(Brush),
        typeof(ChargeTimelineChart),
        new PropertyMetadata(null, OnVisualPropertyChanged));

    /// <summary>Identifies the <see cref="ChargingBandBrush"/> dependency property.</summary>
    public static readonly DependencyProperty ChargingBandBrushProperty = DependencyProperty.Register(
        nameof(ChargingBandBrush),
        typeof(Brush),
        typeof(ChargeTimelineChart),
        new PropertyMetadata(null, OnVisualPropertyChanged));

    /// <summary>Identifies the <see cref="ChargingBandOpacity"/> dependency property.</summary>
    public static readonly DependencyProperty ChargingBandOpacityProperty = DependencyProperty.Register(
        nameof(ChargingBandOpacity),
        typeof(double),
        typeof(ChargeTimelineChart),
        new PropertyMetadata(1.0, OnVisualPropertyChanged));

    private readonly Grid _root = new();

    /// <summary>Creates the control.</summary>
    public ChargeTimelineChart()
    {
        MinHeight = 96;
        Content = _root;
        SizeChanged += (_, _) => Render();
    }

    /// <summary>The timeline to draw. Null renders nothing.</summary>
    public ChargeTimeline? Timeline
    {
        get => (ChargeTimeline?)GetValue(TimelineProperty);
        set => SetValue(TimelineProperty, value);
    }

    /// <summary>
    /// Stroke for the level line. Also the source colour for the area gradient under it
    /// and for the bands marking time spent on external power.
    /// </summary>
    public Brush? LineBrush
    {
        get => (Brush?)GetValue(LineBrushProperty);
        set => SetValue(LineBrushProperty, value);
    }

    /// <summary>Stroke for the reference lines at 50 and 100 percent.</summary>
    public Brush? GridLineBrush
    {
        get => (Brush?)GetValue(GridLineBrushProperty);
        set => SetValue(GridLineBrushProperty, value);
    }

    /// <summary>Fill for the bands marking time spent on external power.</summary>
    public Brush? ChargingBandBrush
    {
        get => (Brush?)GetValue(ChargingBandBrushProperty);
        set => SetValue(ChargingBandBrushProperty, value);
    }

    /// <summary>
    /// How strongly the charging bands are drawn, from 0 for not at all to 1 for solid.
    /// </summary>
    /// <remarks>
    /// <para>
    /// A property rather than a constant because high contrast has to be able to turn it
    /// off. The band is a full-height wash behind the line, which works when it can be
    /// laid on at a tenth of its strength, but high contrast overrides opacity, so the
    /// same wash comes out as a solid block sitting over the measurement it was meant to
    /// sit behind.
    /// </para>
    /// <para>
    /// Dropping it there loses nothing a reader needs. A charging run is already visible
    /// as a rising line, the coverage caption below the chart says what was recorded, and
    /// the automation name carries the same. High contrast is a legibility mode, and this
    /// band is the one thing on the chart that is atmosphere rather than measurement.
    /// </para>
    /// </remarks>
    public double ChargingBandOpacity
    {
        get => (double)GetValue(ChargingBandOpacityProperty);
        set => SetValue(ChargingBandOpacityProperty, value);
    }

    private static void OnVisualPropertyChanged(DependencyObject d, DependencyPropertyChangedEventArgs e)
        => ((ChargeTimelineChart)d).Render();

    private void Render()
    {
        _root.Children.Clear();

        if (Timeline is not { IsEmpty: false } timeline) return;

        var width = ActualWidth;
        var height = ActualHeight > 0 ? ActualHeight : MinHeight;
        if (width <= 0) return;

        AutomationProperties.SetName(this, $"Battery level history. {timeline.CoverageCaption()}");

        DrawChargingBands(timeline, width, height);
        DrawGridLines(width, height);

        foreach (var segment in timeline.Segments)
        {
            DrawSegment(segment, width, height);
        }
    }

    /// <summary>
    /// Shades the periods spent on external power, behind everything else.
    /// </summary>
    /// <remarks>
    /// The macOS version highlights on-AC periods in its charge timeline, and the Settings
    /// chart uses similar vertical banding, so this reads correctly on both counts.
    /// </remarks>
    private void DrawChargingBands(ChargeTimeline timeline, double width, double height)
    {
        if (ChargingBandOpacity <= 0) return;

        foreach (var band in timeline.ChargingBands)
        {
            var left = band.StartX * width;
            var bandWidth = Math.Max(1.0, (band.EndX - band.StartX) * width);

            _root.Children.Add(new Rectangle
            {
                Width = bandWidth,
                Height = height,
                HorizontalAlignment = HorizontalAlignment.Left,
                VerticalAlignment = VerticalAlignment.Stretch,
                Margin = new Thickness(left, 0, 0, 0),
                Fill = ChargingBandBrush,
                Opacity = ChargingBandOpacity,
            });
        }
    }

    /// <summary>Reference lines at 50% and 100%, matching the Settings chart.</summary>
    /// <remarks>
    /// No opacity is applied. The brush is already the subtle divider colour in light and
    /// dark, and thinning it further with opacity would have taken the high contrast
    /// mapping below the contrast floor that mode exists to guarantee.
    /// </remarks>
    private void DrawGridLines(double width, double height)
    {
        foreach (var fraction in new[] { 1.0, 0.5 })
        {
            var y = height - (fraction * height);

            _root.Children.Add(new Line
            {
                X1 = 0,
                X2 = width,
                Y1 = y,
                Y2 = y,
                StrokeThickness = 1,
                Stroke = GridLineBrush,
            });
        }
    }

    private void DrawSegment(TimelineSegment segment, double width, double height)
    {
        var points = segment.Points;
        if (points.Count < 2) return;

        var line = new PathFigure { StartPoint = At(points[0], width, height), IsClosed = false, IsFilled = false };
        var area = new PathFigure
        {
            StartPoint = new Point(points[0].X * width, height),
            IsClosed = true,
            IsFilled = true,
        };

        area.Segments.Add(new LineSegment { Point = At(points[0], width, height) });

        for (var i = 1; i < points.Count; i++)
        {
            var p = At(points[i], width, height);
            line.Segments.Add(new LineSegment { Point = p });
            area.Segments.Add(new LineSegment { Point = p });
        }

        area.Segments.Add(new LineSegment { Point = new Point(points[^1].X * width, height) });

        _root.Children.Add(new XamlPath
        {
            Data = new PathGeometry { Figures = [area] },
            Fill = AreaGradient(),
        });

        _root.Children.Add(new XamlPath
        {
            Data = new PathGeometry { Figures = [line] },
            Stroke = LineBrush,
            StrokeThickness = 1.5,
            StrokeLineJoin = PenLineJoin.Round,
        });
    }

    private static Point At(TimelinePoint point, double width, double height)
        => new(point.X * width, height - (point.Y * height));

    /// <summary>
    /// Vertical gradient under the line, fading out toward the axis.
    /// </summary>
    /// <remarks>
    /// The accent colour is read from the current theme dictionary rather than hardcoded,
    /// so the fill follows the user's accent the way the Settings chart does.
    /// </remarks>
    private Brush AreaGradient()
    {
        var accent = LineBrush is SolidColorBrush solid
            ? solid.Color
            : Colors.SteelBlue;

        return new LinearGradientBrush
        {
            StartPoint = new Point(0, 0),
            EndPoint = new Point(0, 1),
            GradientStops =
            [
                new GradientStop { Color = Color.FromArgb(140, accent.R, accent.G, accent.B), Offset = 0 },
                new GradientStop { Color = Color.FromArgb(20, accent.R, accent.G, accent.B), Offset = 1 },
            ],
        };
    }
}
