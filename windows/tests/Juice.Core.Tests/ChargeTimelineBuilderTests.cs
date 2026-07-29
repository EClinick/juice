using Juice.Core.Presentation;
using Juice.Core.Storage;
using Xunit;

namespace Juice.Core.Tests;

public class ChargeTimelineBuilderTests
{
    private static readonly DateTimeOffset Start =
        new DateTimeOffset(2026, 3, 1, 0, 0, 0, TimeSpan.Zero).ToLocalTime();

    private static BatteryPoint Point(int minutes, double percent, bool onAc = false)
        => new()
        {
            Timestamp = Start.AddMinutes(minutes),
            Percent = percent,
            OnAc = onAc,
            Watts = 10,
        };

    [Fact]
    public void NormalisesToUnitSpaceAcrossTheRequestedWindow()
    {
        var timeline = ChargeTimelineBuilder.Build(
            [Point(0, 100), Point(5, 80), Point(10, 60)],
            Start,
            Start.AddMinutes(10));

        var points = Assert.Single(timeline.Segments).Points;

        Assert.Equal(0.0, points[0].X, 6);
        Assert.Equal(0.5, points[1].X, 6);
        Assert.Equal(1.0, points[2].X, 6);

        Assert.Equal(1.0, points[0].Y, 6);
        Assert.Equal(0.8, points[1].Y, 6);
    }

    /// <summary>
    /// The rule that separates this from the Windows Settings battery chart, which draws
    /// one continuous line across periods it has no data for.
    /// </summary>
    [Fact]
    public void RecordingGap_BreaksTheLineInsteadOfInterpolating()
    {
        var timeline = ChargeTimelineBuilder.Build(
            [
                Point(0, 100), Point(1, 99),
                // Machine asleep for four hours.
                Point(240, 60), Point(241, 59),
            ],
            Start,
            Start.AddHours(5));

        Assert.Equal(2, timeline.Segments.Count);
        Assert.Equal(1, timeline.GapCount);
        Assert.Contains("1 break", timeline.CoverageCaption());
    }

    [Fact]
    public void ClosePointsStayInOneSegment()
    {
        var timeline = ChargeTimelineBuilder.Build(
            [Point(0, 100), Point(1, 99), Point(2, 98), Point(3, 97)],
            Start,
            Start.AddHours(1));

        Assert.Single(timeline.Segments);
        Assert.Equal(0, timeline.GapCount);
        Assert.Contains("Continuous recording", timeline.CoverageCaption());
    }

    [Fact]
    public void ChargingPeriodsBecomeBands()
    {
        var timeline = ChargeTimelineBuilder.Build(
            [
                Point(0, 50),
                Point(5, 55, onAc: true),
                Point(10, 70, onAc: true),
                Point(15, 70),
            ],
            Start,
            Start.AddMinutes(20));

        var band = Assert.Single(timeline.ChargingBands);

        Assert.Equal(0.25, band.StartX, 6);
        Assert.Equal(0.75, band.EndX, 6);
    }

    /// <summary>
    /// A band cannot be claimed across a period Juice was not watching, because the
    /// machine may well have been unplugged while it was asleep.
    /// </summary>
    [Fact]
    public void ChargingBandIsClosedByARecordingGap()
    {
        var timeline = ChargeTimelineBuilder.Build(
            [
                Point(0, 50, onAc: true),
                Point(10, 60, onAc: true),
                Point(300, 40, onAc: true),
                Point(310, 45, onAc: true),
            ],
            Start,
            Start.AddHours(6));

        Assert.Equal(2, timeline.ChargingBands.Count);
        Assert.Equal(1, timeline.GapCount);
    }

    [Fact]
    public void TrailingChargingBandIsClosedAtTheLastSample()
    {
        var timeline = ChargeTimelineBuilder.Build(
            [Point(0, 50), Point(5, 60, onAc: true), Point(10, 70, onAc: true)],
            Start,
            Start.AddMinutes(20));

        var band = Assert.Single(timeline.ChargingBands);
        Assert.Equal(0.25, band.StartX, 6);
        Assert.Equal(0.5, band.EndX, 6);
    }

    [Fact]
    public void SamplesOutsideTheWindowAreIgnored()
    {
        var timeline = ChargeTimelineBuilder.Build(
            [Point(-60, 100), Point(10, 90), Point(20, 85), Point(600, 10)],
            Start,
            Start.AddHours(1));

        Assert.Equal(2, timeline.PointCount);
    }

    [Fact]
    public void SinglePointRunsAreDropped()
    {
        // One isolated sample cannot be drawn as a line.
        var timeline = ChargeTimelineBuilder.Build([Point(0, 100)], Start, Start.AddHours(1));

        Assert.True(timeline.IsEmpty);
        Assert.Contains("No battery history", timeline.CoverageCaption());
    }

    [Fact]
    public void UnorderedInputIsSorted()
    {
        var timeline = ChargeTimelineBuilder.Build(
            [Point(10, 80), Point(0, 100), Point(5, 90)],
            Start,
            Start.AddMinutes(10));

        var points = Assert.Single(timeline.Segments).Points;

        Assert.True(points[0].X < points[1].X);
        Assert.True(points[1].X < points[2].X);
    }

    [Fact]
    public void InvertedWindowProducesNothing()
    {
        var timeline = ChargeTimelineBuilder.Build(
            [Point(0, 100), Point(10, 90)],
            Start,
            Start.AddHours(-1));

        Assert.True(timeline.IsEmpty);
        Assert.Empty(timeline.ChargingBands);
    }

    [Fact]
    public void PercentagesAreClampedToTheAxis()
    {
        var timeline = ChargeTimelineBuilder.Build(
            [Point(0, 140), Point(10, -5)],
            Start,
            Start.AddHours(1));

        var points = Assert.Single(timeline.Segments).Points;

        Assert.Equal(1.0, points[0].Y, 6);
        Assert.Equal(0.0, points[1].Y, 6);
    }
}
