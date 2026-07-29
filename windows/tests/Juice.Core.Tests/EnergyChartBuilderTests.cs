using Juice.Core.Presentation;
using Juice.Core.Storage;
using Xunit;

namespace Juice.Core.Tests;

public class EnergyChartBuilderTests
{
    private static readonly DateTimeOffset Noon =
        new DateTimeOffset(2026, 3, 1, 12, 0, 0, TimeSpan.Zero).ToLocalTime();

    private static HourBucket Bucket(DateTimeOffset hour, double wh, double coveredSeconds = 3600)
        => new()
        {
            HourStart = hour,
            SystemWattHours = wh,
            PlatformWattHours = 0,
            CoveredSeconds = coveredSeconds,
        };

    /// <summary>
    /// The rule that stops a sparse chart looking complete. A 24 hour window with 3 hours
    /// of data must still be 24 columns wide.
    /// </summary>
    [Fact]
    public void AxisIsPinnedToTheRequestedWindow_NotToTheData()
    {
        var from = Noon;
        var to = Noon.AddHours(24);

        var series = EnergyChartBuilder.Build(
            [Bucket(from, 10), Bucket(from.AddHours(1), 12), Bucket(from.AddHours(2), 11)],
            from,
            to);

        Assert.Equal(24, series.Bars.Count);
        Assert.Equal(from, series.Start);
        Assert.Equal(to, series.End);
        Assert.Equal(21, series.GapCount);
    }

    [Fact]
    public void MissingHours_BecomeExplicitGapColumns()
    {
        var series = EnergyChartBuilder.Build(
            [Bucket(Noon, 10), Bucket(Noon.AddHours(2), 10)],
            Noon,
            Noon.AddHours(3));

        Assert.False(series.Bars[0].IsGap);
        Assert.True(series.Bars[1].IsGap);
        Assert.False(series.Bars[2].IsGap);

        // A gap carries no value at all, so a renderer cannot accidentally plot one.
        Assert.Null(series.Bars[1].WattHours);
        Assert.Equal(0, series.Bars[1].HeightFraction);
    }

    /// <summary>
    /// The distinction a chart must never lose: an hour that was measured and was quiet
    /// looks nothing like an hour that was never measured.
    /// </summary>
    [Fact]
    public void MeasuredZero_IsNotAGap()
    {
        var series = EnergyChartBuilder.Build(
            [Bucket(Noon, 0), Bucket(Noon.AddHours(1), 10)],
            Noon,
            Noon.AddHours(2));

        Assert.False(series.Bars[0].IsGap);
        Assert.Equal(0.0, series.Bars[0].WattHours);
        Assert.Equal(0, series.Bars[0].HeightFraction);
    }

    [Fact]
    public void BarelyCoveredHour_IsDrawnAsAGapButKeepsItsMeasuredEnergy()
    {
        // Two minutes of a sixty minute hour.
        var series = EnergyChartBuilder.Build(
            [Bucket(Noon, 0.5, coveredSeconds: 120)],
            Noon,
            Noon.AddHours(1));

        var bar = Assert.Single(series.Bars);

        Assert.True(bar.IsGap);
        Assert.True(bar.IsPartial);
        Assert.Equal(0, bar.HeightFraction);

        // The measurement is preserved and is not scaled up to a whole hour.
        Assert.Equal(0.5, bar.WattHours);
        Assert.Equal(0.5, series.TotalWattHours, 9);
    }

    [Fact]
    public void PartiallyCoveredHours_DoNotSetTheAxisMaximum()
    {
        var series = EnergyChartBuilder.Build(
            [
                Bucket(Noon, 20),
                Bucket(Noon.AddHours(1), 3, coveredSeconds: 600),
            ],
            Noon,
            Noon.AddHours(2));

        Assert.Equal(20, series.MaxWattHours);
        Assert.Equal(1.0, series.Bars[0].HeightFraction, 9);
    }

    [Fact]
    public void HeightFractionsAreRelativeToTheTallestPlottableHour()
    {
        var series = EnergyChartBuilder.Build(
            [Bucket(Noon, 5), Bucket(Noon.AddHours(1), 20), Bucket(Noon.AddHours(2), 10)],
            Noon,
            Noon.AddHours(3));

        Assert.Equal(0.25, series.Bars[0].HeightFraction, 9);
        Assert.Equal(1.00, series.Bars[1].HeightFraction, 9);
        Assert.Equal(0.50, series.Bars[2].HeightFraction, 9);
    }

    [Fact]
    public void CoverageAndCaptionDescribeWhatIsMissing()
    {
        var series = EnergyChartBuilder.Build(
            [Bucket(Noon, 10), Bucket(Noon.AddHours(1), 10)],
            Noon,
            Noon.AddHours(4));

        Assert.Equal(0.5, series.Coverage, 9);
        Assert.True(series.HasGaps);
        Assert.Contains("2 hours not recorded", series.CoverageCaption());
    }

    [Fact]
    public void FullyRecordedWindow_SaysSo()
    {
        var series = EnergyChartBuilder.Build(
            [Bucket(Noon, 10), Bucket(Noon.AddHours(1), 10)],
            Noon,
            Noon.AddHours(2));

        Assert.False(series.HasGaps);
        Assert.Equal(1.0, series.Coverage, 9);
        Assert.Contains("Complete recording", series.CoverageCaption());
    }

    [Fact]
    public void EmptyWindow_IsEmptyRatherThanThrowing()
    {
        var series = EnergyChartBuilder.Build([], Noon, Noon.AddHours(6));

        Assert.Equal(6, series.Bars.Count);
        Assert.True(series.IsEmpty);
        Assert.All(series.Bars, b => Assert.True(b.IsGap));
        Assert.Contains("No data recorded", series.CoverageCaption());
    }

    [Fact]
    public void InvertedWindow_ProducesNothingRatherThanNegativeColumns()
    {
        var series = EnergyChartBuilder.Build([], Noon, Noon.AddHours(-3));

        Assert.Empty(series.Bars);
        Assert.True(series.IsEmpty);
    }

    [Fact]
    public void TotalCountsOnlyRecordedHours()
    {
        var series = EnergyChartBuilder.Build(
            [Bucket(Noon, 10), Bucket(Noon.AddHours(3), 5)],
            Noon,
            Noon.AddHours(6));

        Assert.Equal(15, series.TotalWattHours, 9);
    }
}
