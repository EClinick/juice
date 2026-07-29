using Juice.Core.Power;
using Juice.Core.Presentation;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Shapes;

namespace Juice.App.Controls;

/// <summary>
/// Draws an <see cref="EnergyChartSeries"/> as hour columns.
/// </summary>
/// <remarks>
/// <para>
/// The honesty rules live in <see cref="EnergyChartBuilder"/> rather than here, so this
/// control only has to render faithfully what it is handed. Two things it must not do are
/// worth stating, because both are natural things for a chart renderer to do.
/// </para>
/// <para>
/// It must not skip gap columns. Every hour in the window gets a slot of equal width, so
/// the horizontal axis stays linear in time and a missing hour occupies exactly the space
/// it would have occupied had it been recorded. Skipping them would compress the axis and
/// silently place measurements hours apart next to each other.
/// </para>
/// <para>
/// It must not draw a gap as a zero-height bar. A bar sitting on the axis reads as "this
/// hour was idle", which is a claim Juice cannot support for an hour it never observed.
/// Gaps get a distinct low marker instead, so absence is visible as absence.
/// </para>
/// <para>
/// Composition is plain XAML elements rather than a charting library or custom drawing.
/// That keeps the dependency footprint of a tray app that runs for weeks unchanged, lets
/// every brush be a theme resource so Light, Dark and HighContrast stay correct, and gives
/// per-column tooltips and automation names without extra work. The tradeoff is one
/// element per column, which is why callers must aggregate longer ranges into days rather
/// than asking for thousands of hours.
/// </para>
/// </remarks>
public sealed class EnergyHistoryChart : UserControl
{
    /// <summary>Identifies the <see cref="Series"/> dependency property.</summary>
    public static readonly DependencyProperty SeriesProperty = DependencyProperty.Register(
        nameof(Series),
        typeof(EnergyChartSeries),
        typeof(EnergyHistoryChart),
        new PropertyMetadata(null, (d, _) => ((EnergyHistoryChart)d).Render()));

    private readonly Grid _columns = new() { ColumnSpacing = 1 };

    /// <summary>Creates the control.</summary>
    public EnergyHistoryChart()
    {
        MinHeight = 56;
        Content = _columns;

        // Bar heights are in pixels, so the plot has to be rebuilt when the control is
        // resized. Re-rendering is cheap because the series is already computed.
        SizeChanged += (_, _) => Render();
        ActualThemeChanged += (_, _) => Render();
    }

    /// <summary>The series to draw. Null renders nothing.</summary>
    public EnergyChartSeries? Series
    {
        get => (EnergyChartSeries?)GetValue(SeriesProperty);
        set => SetValue(SeriesProperty, value);
    }

    private void Render()
    {
        _columns.Children.Clear();
        _columns.ColumnDefinitions.Clear();

        if (Series is not { Bars.Count: > 0 } series) return;

        var height = ActualHeight > 0 ? ActualHeight : MinHeight;

        AutomationProperties.SetName(
            this,
            $"Energy history, {series.Bars.Count} hours, {series.CoverageCaption()}");

        for (var i = 0; i < series.Bars.Count; i++)
        {
            var bar = series.Bars[i];

            _columns.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });

            var slot = bar.IsGap ? BuildGap(height) : BuildBar(bar, height);
            slot.SetValue(Grid.ColumnProperty, i);

            var description = Describe(bar);
            ToolTipService.SetToolTip(slot, description);
            AutomationProperties.SetName(slot, description.Replace('\n', ' '));

            _columns.Children.Add(slot);
        }
    }

    private FrameworkElement BuildBar(ChartBar bar, double height)
    {
        // A measured hour always gets at least a hairline, so a genuine zero still reads
        // as "recorded, and it was nothing" rather than vanishing into the axis and
        // becoming indistinguishable from an hour that was never observed.
        var barHeight = Math.Max(1.0, bar.HeightFraction * height);

        return new Border
        {
            Height = barHeight,
            VerticalAlignment = VerticalAlignment.Bottom,
            CornerRadius = new CornerRadius(2, 2, 0, 0),
            Background = Brush(bar.IsPartial ? "AccentFillColorTertiaryBrush" : "AccentFillColorDefaultBrush"),
        };
    }

    private FrameworkElement BuildGap(double height)
    {
        return new Rectangle
        {
            Height = Math.Max(2.0, height * 0.05),
            VerticalAlignment = VerticalAlignment.Bottom,
            RadiusX = 1,
            RadiusY = 1,
            Fill = Brush("TextFillColorDisabledBrush"),
        };
    }

    private Brush Brush(string themeResourceKey)
        => (Brush)Application.Current.Resources[themeResourceKey];

    private static string Describe(ChartBar bar)
    {
        var hour = bar.HourStart.ToString("ddd HH:mm");

        if (bar.IsGap && bar.WattHours is null) return $"{hour}\nNot recorded";

        var energy = PowerFormatter.Energy(bar.WattHours ?? 0);

        if (bar.IsGap) return $"{hour}\nPartly recorded, {energy} measured";

        var watts = bar.Watts is { } w ? $"\n{w:0.0} W average" : string.Empty;
        return $"{hour}\n{energy}{watts}";
    }
}
