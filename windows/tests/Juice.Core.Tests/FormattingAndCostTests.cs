using Juice.Core.Cost;
using Juice.Core.Power;
using Xunit;

namespace Juice.Core.Tests;

public class PowerFormatterTests
{
    [Theory]
    [InlineData(null, "-")]
    [InlineData(double.NaN, "-")]
    [InlineData(-1.0, "-")]
    public void UnknownPower_NeverRendersAsZero(double? watts, string expected)
        => Assert.Equal(expected, PowerFormatter.TrayLabel(watts));

    [Theory]
    [InlineData(0.0, "0.0")]
    [InlineData(7.24, "7.2")]
    [InlineData(9.9, "9.9")]
    [InlineData(9.96, "10")]
    [InlineData(15.2, "15")]
    [InlineData(99.4, "99")]
    [InlineData(120.0, "99+")]
    public void TrayLabel_StaysWithinThreeGlyphs(double watts, string expected)
    {
        var label = PowerFormatter.TrayLabel(watts);
        Assert.Equal(expected, label);
        Assert.True(label.Length <= 3, $"'{label}' will not fit in a 16 pixel tray icon");
    }

    [Theory]
    [InlineData(0.0005, "0 Wh")]
    [InlineData(0.25, "250 mWh")]
    [InlineData(12.5, "12.5 Wh")]
    [InlineData(2500.0, "2.50 kWh")]
    public void Energy_ScalesToMagnitude(double wattHours, string expected)
        => Assert.Equal(expected, PowerFormatter.Energy(wattHours));

    [Fact]
    public void Tooltip_DoesNotClaimChargingForATrickle()
    {
        var sample = new PowerSample
        {
            Timestamp = DateTimeOffset.UtcNow,
            Tier = PowerSourceTier.HardwareRail,
            SystemWatts = 25,
            OnAc = true,
            BatteryPercent = 100,
            ChargeWatts = 0.024,
        };

        Assert.Contains("plugged in", PowerFormatter.Tooltip(sample, null));
        Assert.DoesNotContain("charging", PowerFormatter.Tooltip(sample, null));
    }

    [Fact]
    public void Tooltip_ReportsRealCharging()
    {
        var sample = new PowerSample
        {
            Timestamp = DateTimeOffset.UtcNow,
            Tier = PowerSourceTier.HardwareRail,
            SystemWatts = 25,
            OnAc = true,
            BatteryPercent = 60,
            ChargeWatts = 18.5,
        };

        Assert.Contains("charging 18.5 W", PowerFormatter.Tooltip(sample, null));
    }

    [Fact]
    public void FormatDuration_UsesHoursOnlyWhenPresent()
    {
        Assert.Equal("3h 12m", PowerFormatter.FormatDuration(TimeSpan.FromMinutes(192)));
        Assert.Equal("45m", PowerFormatter.FormatDuration(TimeSpan.FromMinutes(45)));
    }
}

public class SamplingPolicyTests
{
    [Fact]
    public void Foreground_SamplesFastest()
    {
        var foreground = SamplingPolicy.For(ActivityState.Foreground, onAc: true);
        var tray = SamplingPolicy.For(ActivityState.TrayOnly, onAc: true);

        Assert.True(foreground.Power < tray.Power);
    }

    [Fact]
    public void OnBattery_BacksOffFurtherThanOnAc()
    {
        var ac = SamplingPolicy.For(ActivityState.TrayOnly, onAc: true);
        var battery = SamplingPolicy.For(ActivityState.TrayOnly, onAc: false);

        Assert.True(battery.Power > ac.Power);
    }

    [Fact]
    public void DisplayOff_StopsTouchingTheProcessTable()
    {
        var cadence = SamplingPolicy.For(ActivityState.DisplayOff, onAc: false);

        Assert.Null(cadence.Process);
        Assert.True(cadence.Power >= TimeSpan.FromMinutes(1));
    }

    [Fact]
    public void Suspended_IsCompletelyIdle()
        => Assert.True(SamplingPolicy.IsIdle(SamplingPolicy.For(ActivityState.Suspended, onAc: false)));

    [Theory]
    [InlineData(60, true)]
    [InlineData(300, true)]
    [InlineData(301, false)]
    [InlineData(0, false)]
    public void ContinuityWindow_MatchesTheFiveMinuteRule(int seconds, bool expected)
        => Assert.Equal(expected, SamplingPolicy.IsContinuous(TimeSpan.FromSeconds(seconds)));
}

public class CostTests
{
    private static readonly BundledRateTable Table = new();

    [Fact]
    public void CostOf_ConvertsWattHoursToMoney()
    {
        var rate = Table.ResolveFor("US-WA");
        // 1 kWh at the Washington average.
        Assert.Equal(0.114m, CostCalculator.CostOf(1000, rate));
    }

    [Fact]
    public void UnknownSubdivision_FallsBackToTheCountry()
    {
        var rate = Table.ResolveFor("US-ZZ");

        Assert.Equal("US", rate.RegionCode);
        Assert.Equal(RateSource.BundledAverage, rate.Source);
    }

    [Fact]
    public void UnknownRegion_StillReturnsAUsableRate()
    {
        var rate = Table.ResolveFor(null);

        Assert.Equal(RateSource.Fallback, rate.Source);
        Assert.True(rate.PricePerKwh > 0);
    }

    [Fact]
    public void BundledRates_AreAlwaysLabelledAsEstimates()
        => Assert.True(Table.ResolveFor("US-CA").IsEstimate);

    [Fact]
    public void UserOverride_WinsAndIsNotAnEstimate()
    {
        var provider = new OverridableRateProvider(Table) { OverridePricePerKwh = 0.42m };
        var rate = provider.ResolveFor("US-WA");

        Assert.Equal(0.42m, rate.PricePerKwh);
        Assert.Equal(RateSource.UserOverride, rate.Source);
        Assert.False(rate.IsEstimate);
    }

    [Fact]
    public void AnnualCost_OfSustainedWatts()
    {
        var rate = new ElectricityRate
        {
            PricePerKwh = 0.10m,
            Currency = "USD",
            RegionCode = "US",
            RegionName = "United States",
            Source = RateSource.UserOverride,
        };

        // 10 W for a year is 87.66 kWh, which at 0.10 is 8.766.
        var annual = CostCalculator.AnnualCostOfSustainedWatts(10, rate);
        Assert.Equal(8.766m, annual, 3);
    }

    [Fact]
    public void ZeroEnergy_CostsNothing()
        => Assert.Equal(0m, CostCalculator.CostOf(0, Table.ResolveFor("US")));
}
