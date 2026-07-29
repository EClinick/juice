using Juice.Core.Power;
using Juice.Core.Presentation;
using Xunit;

namespace Juice.Core.Tests;

/// <summary>
/// Covers the rules that decide how the flyout is coloured.
/// </summary>
/// <remarks>
/// These live in Juice.Core rather than in the view precisely so they can be exercised
/// here. Driving the real window to check them would mean synthesising input on the
/// user's desktop, and the decisions themselves are arithmetic that needs no window.
/// </remarks>
public class PresentationRulesTests
{
    [Fact]
    public void BatteryClassifier_ReportsUnknownWithoutAReading()
    {
        Assert.Equal(BatteryLevel.Unknown, BatteryClassifier.Classify(null, isOnBattery: true));
        Assert.Equal(BatteryLevel.Unknown, BatteryClassifier.Classify(double.NaN, isOnBattery: true));
    }

    /// <summary>
    /// A machine at 5% on the charger is filling up, not running out. Colouring that as
    /// critical would be a false alarm, which is the whole reason the charge is not
    /// classified on its own.
    /// </summary>
    [Fact]
    public void BatteryClassifier_DoesNotWarnWhileCharging()
    {
        Assert.Equal(BatteryLevel.Normal, BatteryClassifier.Classify(5, isOnBattery: false));
        Assert.Equal(BatteryLevel.Normal, BatteryClassifier.Classify(15, isOnBattery: false));
    }

    [Theory]
    [InlineData(0, BatteryLevel.Critical)]
    [InlineData(9.9, BatteryLevel.Critical)]
    [InlineData(10, BatteryLevel.Low)]
    [InlineData(19.9, BatteryLevel.Low)]
    [InlineData(20, BatteryLevel.Normal)]
    [InlineData(100, BatteryLevel.Normal)]
    public void BatteryClassifier_BandsDischargingCharge(double percent, BatteryLevel expected)
    {
        Assert.Equal(expected, BatteryClassifier.Classify(percent, isOnBattery: true));
    }

    [Fact]
    public void RankingShare_IsTheRatioToTheHeaviest()
    {
        Assert.Equal(1.0, RankingShare.Of(16.5, 16.5), 9);
        Assert.Equal(0.5, RankingShare.Of(8.25, 16.5), 9);
        Assert.Equal(0.1, RankingShare.Of(1.65, 16.5), 9);
    }

    /// <summary>
    /// Guards the rule that a bar is never padded up to something visible. A row that
    /// drew almost nothing has to look like it drew almost nothing.
    /// </summary>
    [Fact]
    public void RankingShare_DoesNotFloorSmallValues()
    {
        Assert.Equal(0.0001, RankingShare.Of(0.001, 10.0), 9);
    }

    [Fact]
    public void RankingShare_ReturnsZeroWhenThereIsNothingToRankAgainst()
    {
        Assert.Equal(0.0, RankingShare.Of(5.0, 0.0));
        Assert.Equal(0.0, RankingShare.Of(5.0, -1.0));
        Assert.Equal(0.0, RankingShare.Of(0.0, 0.0));
        Assert.Equal(0.0, RankingShare.Of(double.NaN, 10.0));
        Assert.Equal(0.0, RankingShare.Of(5.0, double.NaN));
    }

    /// <summary>
    /// A negative watt figure is not a real draw, and a bar cannot run backwards, so it
    /// contributes nothing rather than inverting the row.
    /// </summary>
    [Fact]
    public void RankingShare_ClampsOutOfRangeValues()
    {
        Assert.Equal(0.0, RankingShare.Of(-4.0, 10.0));
        Assert.Equal(1.0, RankingShare.Of(20.0, 10.0));
    }

    [Fact]
    public void RankingShare_HeaviestIgnoresUnusableValues()
    {
        Assert.Equal(16.5, RankingShare.Heaviest([1.2, 16.5, double.NaN, 0.9]), 9);
        Assert.Equal(0.0, RankingShare.Heaviest([]));
        Assert.Equal(0.0, RankingShare.Heaviest([-3.0, -1.0]));
    }

    /// <summary>
    /// A bright accent over a dark panel lifts the background toward the light text on
    /// it, so it is applied more weakly. The same applies in reverse on a light panel.
    /// </summary>
    [Theory]
    [InlineData(0.9, false, true)]
    [InlineData(0.2, false, false)]
    [InlineData(0.2, true, true)]
    [InlineData(0.9, true, false)]
    public void SurfaceTint_DetectsAccentsThatFightTheSurface(
        double luminance, bool isSurfaceLight, bool expected)
    {
        Assert.Equal(expected, SurfaceTint.IsContrasting(luminance, isSurfaceLight));
    }

    [Fact]
    public void SurfaceTint_UsesTheWeakerAlphaWhenTheAccentFightsTheSurface()
    {
        Assert.Equal(SurfaceTint.ContrastingAlpha, SurfaceTint.AlphaFor(0.95, isSurfaceLight: false));
        Assert.Equal(SurfaceTint.NormalAlpha, SurfaceTint.AlphaFor(0.40, isSurfaceLight: false));
    }

    /// <summary>
    /// The tint sits under readable text, so no configuration may push it to a strength
    /// that takes the panel over.
    /// </summary>
    [Fact]
    public void SurfaceTint_StaysWeakEnoughToReadThrough()
    {
        Assert.True(SurfaceTint.ContrastingAlpha < SurfaceTint.NormalAlpha);

        foreach (var luminance in new[] { 0.0, 0.25, 0.5, 0.75, 1.0 })
        {
            foreach (var isLight in new[] { true, false })
            {
                var alpha = SurfaceTint.AlphaFor(luminance, isLight);
                Assert.InRange(alpha, 0.0, 0.2);
            }
        }
    }

    [Fact]
    public void SurfaceTint_TreatsAnUnreadableLuminanceAsSafe()
    {
        Assert.False(SurfaceTint.IsContrasting(double.NaN, isSurfaceLight: true));
        Assert.Equal(SurfaceTint.NormalAlpha, SurfaceTint.AlphaFor(double.NaN, isSurfaceLight: false));
    }
}
