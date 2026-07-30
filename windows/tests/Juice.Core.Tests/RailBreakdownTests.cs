using Juice.Core.Power;
using Juice.Core.Presentation;
using Xunit;

namespace Juice.Core.Tests;

/// <summary>
/// Covers the rail breakdown, which is the measurement this port has and the macOS
/// version does not: the processor, graphics and neural engine rails metered separately
/// rather than apportioned out of one system figure.
/// </summary>
/// <remarks>
/// A stacked bar looks like a whole whatever it is actually drawn from, so most of what
/// is asserted here is about what the breakdown refuses to do: invent a rail the hardware
/// did not report, fold the supply rail in with the consumers, or rescale the parts to
/// make them fit the whole.
/// </remarks>
public class RailBreakdownTests
{
    private static PowerSample Sample(double? system, params RailReading[] rails) => new()
    {
        Timestamp = DateTimeOffset.UnixEpoch,
        Tier = PowerSourceTier.HardwareRail,
        SystemWatts = system,
        Rails = rails,
    };

    private static RailReading Rail(PowerRail rail, double watts)
        => new(rail, rail.ToString().ToLowerInvariant(), watts, null);

    [Fact]
    public void Build_ReportsNothingWithoutASample()
    {
        Assert.True(RailBreakdownBuilder.Build(null).IsEmpty);
    }

    [Fact]
    public void Build_ReportsNothingWhenNoComponentRailWasMetered()
    {
        var sample = Sample(12.0);

        Assert.True(RailBreakdownBuilder.Build(sample).IsEmpty);
    }

    /// <summary>
    /// A machine with no discrete graphics rail shows the rails it has. A zero watt GPU
    /// segment would be a claim that the hardware reported one.
    /// </summary>
    [Fact]
    public void Build_OmitsRailsTheHardwareDoesNotMeter()
    {
        var breakdown = RailBreakdownBuilder.Build(Sample(10.0, Rail(PowerRail.Cpu, 4.0)));

        Assert.Equal(2, breakdown.Segments.Count);
        Assert.Equal(PowerRail.Cpu, breakdown.Segments[0].Rail);
        Assert.True(breakdown.Segments[1].IsRemainder);
    }

    [Fact]
    public void Build_StatesWhatTheRailsDidNotAccountFor()
    {
        var breakdown = RailBreakdownBuilder.Build(Sample(
            10.0,
            Rail(PowerRail.Cpu, 4.0),
            Rail(PowerRail.Gpu, 2.0),
            Rail(PowerRail.Npu, 1.0)));

        Assert.True(breakdown.CoversWholeSystem);
        Assert.Equal(10.0, breakdown.TotalWatts, 9);

        var remainder = Assert.Single(breakdown.Segments, segment => segment.IsRemainder);
        Assert.Equal(3.0, remainder.Watts, 9);
        Assert.Equal(0.3, remainder.Fraction, 9);
    }

    /// <summary>
    /// The fractions are the widths of a stacked bar, so a bar that claims to be the whole
    /// machine has to actually add up to it.
    /// </summary>
    [Fact]
    public void Build_FractionsFillTheBarWhenItCoversTheWholeSystem()
    {
        var breakdown = RailBreakdownBuilder.Build(Sample(
            20.0,
            Rail(PowerRail.Cpu, 5.0),
            Rail(PowerRail.Gpu, 5.0)));

        Assert.Equal(1.0, breakdown.Segments.Sum(segment => segment.Fraction), 9);
    }

    /// <summary>
    /// Rails and the system rail describe slightly different instants, so a transient can
    /// leave the parts exceeding the whole. Scaling them down to fit would misstate every
    /// rail, so the breakdown reports the parts and says it is partial.
    /// </summary>
    [Fact]
    public void Build_DoesNotRescaleRailsToFitASmallerSystemReading()
    {
        var breakdown = RailBreakdownBuilder.Build(Sample(
            6.0,
            Rail(PowerRail.Cpu, 5.0),
            Rail(PowerRail.Gpu, 3.0)));

        Assert.False(breakdown.CoversWholeSystem);
        Assert.Equal(8.0, breakdown.TotalWatts, 9);
        Assert.Equal(5.0, breakdown.Segments[0].Watts, 9);
        Assert.DoesNotContain(breakdown.Segments, segment => segment.IsRemainder);
    }

    [Fact]
    public void Build_IsPartialWhenThereIsNoSystemReadingToCompareAgainst()
    {
        var breakdown = RailBreakdownBuilder.Build(Sample(null, Rail(PowerRail.Cpu, 4.0)));

        Assert.False(breakdown.CoversWholeSystem);
        Assert.Equal(4.0, breakdown.TotalWatts, 9);
        Assert.Contains("do not account for the whole machine", breakdown.Caption());
    }

    /// <summary>
    /// The supply rail is what the charger delivers, which while charging is larger than
    /// what the machine consumes. Adding it to a bar of consumers would double count.
    /// </summary>
    [Fact]
    public void Build_KeepsTheSupplyRailOutOfTheConsumptionSplit()
    {
        var breakdown = RailBreakdownBuilder.Build(Sample(
            10.0,
            Rail(PowerRail.Cpu, 4.0),
            Rail(PowerRail.Supply, 45.0)));

        Assert.Equal(45.0, breakdown.SupplyWatts);
        Assert.DoesNotContain(breakdown.Segments, segment => segment.Rail == PowerRail.Supply);
        Assert.Equal(10.0, breakdown.TotalWatts, 9);
    }

    /// <summary>
    /// A remainder below the precision the flyout prints would render as a 0.0 W segment,
    /// which reads as a measurement of nothing rather than as nothing left over.
    /// </summary>
    [Fact]
    public void Build_DropsARemainderTooSmallToPrint()
    {
        var breakdown = RailBreakdownBuilder.Build(Sample(
            10.02,
            Rail(PowerRail.Cpu, 6.0),
            Rail(PowerRail.Gpu, 4.0)));

        Assert.True(breakdown.CoversWholeSystem);
        Assert.DoesNotContain(breakdown.Segments, segment => segment.IsRemainder);
    }

    [Fact]
    public void Build_IgnoresUnusableReadings()
    {
        var breakdown = RailBreakdownBuilder.Build(Sample(
            10.0,
            Rail(PowerRail.Cpu, 4.0),
            Rail(PowerRail.Gpu, double.NaN),
            Rail(PowerRail.Npu, -1.0)));

        Assert.Equal(PowerRail.Cpu, Assert.Single(breakdown.Segments, s => !s.IsRemainder).Rail);
    }

    /// <summary>
    /// The remainder is the same quantity the app ranking calls out separately, so the two
    /// take one name. Two names for one measurement on one panel would read as two.
    /// </summary>
    [Fact]
    public void Build_NamesTheRemainderAsTheRankingDoes()
    {
        var breakdown = RailBreakdownBuilder.Build(Sample(10.0, Rail(PowerRail.Cpu, 4.0)));

        Assert.Equal(
            EnergyRankingBuilder.PlatformDisplayName,
            breakdown.Segments.Single(segment => segment.IsRemainder).Label);
    }
}

/// <summary>
/// Covers what the flyout admits to about where its numbers came from.
/// </summary>
public class MeasurementNoticeTests
{
    /// <summary>
    /// Metered hardware is the case the app is built for. Announcing that everything is
    /// normal would train the user to ignore the one place a real caveat appears.
    /// </summary>
    [Fact]
    public void For_SaysNothingWhenTheHardwareIsMeteringProperly()
    {
        Assert.False(MeasurementNotice.For(PowerSourceTier.HardwareRail, onAc: true).IsPresent);
        Assert.False(MeasurementNotice.For(PowerSourceTier.HardwareRail, onAc: false).IsPresent);
    }

    /// <summary>
    /// The battery tier is a real measurement on battery and no measurement at all on AC,
    /// where a full battery reports zero for both rates. Only the second is worth saying.
    /// </summary>
    [Fact]
    public void For_ExplainsTheBatteryTierOnlyWhereItGoesBlind()
    {
        Assert.False(MeasurementNotice.For(PowerSourceTier.Battery, onAc: false).IsPresent);

        var onAc = MeasurementNotice.For(PowerSourceTier.Battery, onAc: true);
        Assert.Equal(MeasurementNoticeSeverity.Informational, onAc.Severity);
        Assert.Contains("plugged in", onAc.Title);
    }

    [Fact]
    public void For_CallsAModelledReadingAnEstimate()
    {
        var notice = MeasurementNotice.For(PowerSourceTier.Modelled, onAc: true);

        Assert.Equal(MeasurementNoticeSeverity.Informational, notice.Severity);
        Assert.Contains("Estimated", notice.Title);
    }

    [Fact]
    public void For_WarnsWhenNothingIsMeasuring()
    {
        var notice = MeasurementNotice.For(PowerSourceTier.None, onAc: false);

        Assert.Equal(MeasurementNoticeSeverity.Warning, notice.Severity);
        Assert.Contains("unknown", notice.Message);
    }

    /// <summary>
    /// Every notice is shown to a user, so none of them may be a blank card.
    /// </summary>
    [Theory]
    [InlineData(PowerSourceTier.None)]
    [InlineData(PowerSourceTier.Modelled)]
    [InlineData(PowerSourceTier.Battery)]
    [InlineData(PowerSourceTier.HardwareRail)]
    public void For_AlwaysCarriesWordsWhenItIsPresent(PowerSourceTier tier)
    {
        foreach (var onAc in new[] { true, false })
        {
            var notice = MeasurementNotice.For(tier, onAc);
            if (!notice.IsPresent) continue;

            Assert.False(string.IsNullOrWhiteSpace(notice.Title));
            Assert.False(string.IsNullOrWhiteSpace(notice.Message));
        }
    }

    /// <summary>
    /// The line under the reading states what was measured. Measuring a machine while it
    /// is plugged in is what this port can do and the macOS version cannot, so the
    /// wording claims a measurement only where there is one.
    /// </summary>
    [Fact]
    public void SourceLabel_ClaimsAMeasurementOnlyWhereThereIsOne()
    {
        Assert.Contains("Measured", MeasurementSource.Label(PowerSourceTier.HardwareRail, onAc: true));
        Assert.Contains("Measured", MeasurementSource.Label(PowerSourceTier.Battery, onAc: false));
        Assert.DoesNotContain("Measured", MeasurementSource.Label(PowerSourceTier.Battery, onAc: true));
        Assert.DoesNotContain("Measured", MeasurementSource.Label(PowerSourceTier.Modelled, onAc: false));
        Assert.DoesNotContain("Measured", MeasurementSource.Label(PowerSourceTier.None, onAc: false));
    }
}
