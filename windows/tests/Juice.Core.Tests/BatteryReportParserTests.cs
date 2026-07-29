using Juice.Core.Battery;
using Xunit;

namespace Juice.Core.Tests;

public class BatteryReportParserTests
{
    /// <summary>
    /// Two entries taken verbatim from a real <c>powercfg /batteryreport /xml</c> run,
    /// so the parser is tested against the shape Windows actually emits rather than one
    /// invented to match the parser.
    /// </summary>
    private const string RealReport = """
        <?xml version="1.0" encoding="utf-8"?>
        <BatteryReport xmlns="http://schemas.microsoft.com/battery/2012">
          <History>
            <HistoryEntry StartDate="2025-01-06T00:58:57Z" LocalStartDate="2025-01-05T16:58:57"
                          EndDate="2025-01-13T01:55:08Z" LocalEndDate="2025-01-12T17:55:08"
                          DesignCapacity="52330" FullChargeCapacity="53117" CycleCount="21"
                          ActiveDcEnergy="9332" CsDcEnergy="2698" BatteryChanged="0" />
            <HistoryEntry StartDate="2025-01-13T01:55:08Z" LocalStartDate="2025-01-12T17:55:08"
                          EndDate="2025-01-20T01:15:49Z" LocalEndDate="2025-01-19T17:15:49"
                          DesignCapacity="52330" FullChargeCapacity="44080" CycleCount="161"
                          ActiveDcEnergy="1870" CsDcEnergy="2320" BatteryChanged="0" />
          </History>
        </BatteryReport>
        """;

    [Fact]
    public void ParsesRealReportAndConvertsToWattHours()
    {
        var health = BatteryReportParser.Parse(RealReport);

        Assert.Equal(2, health.History.Count);

        // Milliwatt-hours in the report become watt-hours here.
        Assert.Equal(52.330, health.History[0].DesignWattHours, 6);
        Assert.Equal(53.117, health.History[0].FullChargeWattHours, 6);
        Assert.Equal(21, health.History[0].CycleCount);
    }

    [Fact]
    public void OrdersOldestFirstAndExposesCurrent()
    {
        var health = BatteryReportParser.Parse(RealReport);

        Assert.True(health.Oldest!.Start < health.Current!.Start);
        Assert.Equal(161, health.Current.CycleCount);
    }

    /// <summary>
    /// A new battery routinely exceeds its nominal design capacity, so a health fraction
    /// above 1 is correct data and must not be clamped or treated as an error.
    /// </summary>
    [Fact]
    public void HealthAboveDesignCapacityIsNotClamped()
    {
        var health = BatteryReportParser.Parse(RealReport);

        Assert.True(health.History[0].HealthFraction > 1.0);
    }

    [Fact]
    public void CapacityLossIsMeasuredBetweenOldestAndNewest()
    {
        var health = BatteryReportParser.Parse(RealReport);

        // 53117/52330 down to 44080/52330 is roughly 17 points of capacity.
        Assert.NotNull(health.CapacityLostPercent);
        Assert.InRange(health.CapacityLostPercent!.Value, 16, 18);
    }

    [Fact]
    public void EntriesWithoutUsableCapacityAreDropped()
    {
        const string xml = """
            <BatteryReport xmlns="http://schemas.microsoft.com/battery/2012">
              <History>
                <HistoryEntry StartDate="2025-01-06T00:58:57Z" DesignCapacity="52330" FullChargeCapacity="0" />
                <HistoryEntry StartDate="2025-01-13T01:55:08Z" DesignCapacity="52330" />
                <HistoryEntry StartDate="2025-01-20T01:55:08Z" DesignCapacity="52330" FullChargeCapacity="50000" />
              </History>
            </BatteryReport>
            """;

        var health = BatteryReportParser.Parse(xml);

        Assert.Single(health.History);
        Assert.Equal(50.0, health.History[0].FullChargeWattHours, 6);
    }

    [Fact]
    public void MalformedXmlYieldsEmptyHistoryRatherThanThrowing()
    {
        var health = BatteryReportParser.Parse("<BatteryReport><History>");

        Assert.Empty(health.History);
        Assert.Null(health.Current);
        Assert.Contains("No battery health history", health.Summary());
    }

    [Fact]
    public void ReportWithNoBatteryYieldsEmptyHistory()
    {
        var health = BatteryReportParser.Parse(
            """<BatteryReport xmlns="http://schemas.microsoft.com/battery/2012" />""");

        Assert.Empty(health.History);
        Assert.Null(health.CapacityLostPercent);
    }

    [Fact]
    public void SummaryDescribesCondition()
    {
        var health = BatteryReportParser.Parse(RealReport);

        var summary = health.Summary();

        Assert.Contains("84%", summary);
        Assert.Contains("161 charge cycles", summary);
    }

    [Fact]
    public void SingleEntryCannotReportCapacityLoss()
    {
        const string xml = """
            <BatteryReport xmlns="http://schemas.microsoft.com/battery/2012">
              <History>
                <HistoryEntry StartDate="2025-01-06T00:58:57Z" DesignCapacity="52330" FullChargeCapacity="50000" />
              </History>
            </BatteryReport>
            """;

        Assert.Null(BatteryReportParser.Parse(xml).CapacityLostPercent);
    }
}
