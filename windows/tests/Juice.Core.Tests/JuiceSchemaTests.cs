using System.Text.Json;
using Juice.Core.Contracts;
using Xunit;

namespace Juice.Core.Tests;

public class JuiceSchemaTests
{
    private static string Serialize<T>(T document) where T : JuiceDocument
        => JsonSerializer.Serialize(document, typeof(T), JuiceSchema.Options);

    private static NowDocument Now(MeasurementDto measurement, BatteryDto battery)
        => new() { Command = "now", Measurement = measurement, Battery = battery };

    /// <summary>
    /// The central honesty rule of the contract. An unmeasured quantity and a zero
    /// quantity are different facts, so unmeasured rails must vanish from the document
    /// rather than appear as 0.
    /// </summary>
    [Fact]
    public void UnmeasuredValues_AreOmittedRatherThanZeroed()
    {
        var json = Serialize(Now(
            new MeasurementDto
            {
                Confidence = MeasurementConfidence.Measured,
                SystemWatts = 34.6,
                Rails = new RailsDto { Cpu = 17.5, Gpu = 0.04, Supply = 34.6 },
            },
            new BatteryDto { Present = true, Percent = 80, Flow = BatteryFlow.PluggedIn }));

        Assert.Contains("\"cpu\"", json);
        // This machine meters no NPU rail, so the key must not appear at all.
        Assert.DoesNotContain("\"npu\"", json);
        // A full battery on AC is not charging, so no charge figure is claimed.
        Assert.DoesNotContain("chargeWatts", json);
    }

    [Fact]
    public void UnavailableDraw_OmitsSystemWattsEntirely()
    {
        var json = Serialize(Now(
            new MeasurementDto { Confidence = MeasurementConfidence.Unavailable },
            new BatteryDto { Present = true, Percent = 80, Flow = BatteryFlow.PluggedIn }));

        Assert.DoesNotContain("systemWatts", json);
        Assert.Contains("\"unavailable\"", json);
    }

    [Fact]
    public void EnvelopeFields_ComeFirst()
    {
        var json = Serialize(Now(
            new MeasurementDto { Confidence = MeasurementConfidence.Measured, SystemWatts = 10 },
            new BatteryDto { Present = false }));

        // A consumer, or a human reading a truncated log line, should see what contract
        // it is looking at before the payload.
        Assert.True(
            json.IndexOf("schemaVersion", StringComparison.Ordinal)
            < json.IndexOf("measurement", StringComparison.Ordinal));
    }

    [Fact]
    public void EnumsSerializeAsCamelCaseStrings_NotIntegers()
    {
        var json = Serialize(Now(
            new MeasurementDto { Confidence = MeasurementConfidence.Measured, SystemWatts = 1 },
            new BatteryDto { Present = true, Flow = BatteryFlow.Discharging }));

        Assert.Contains("\"measured\"", json);
        Assert.Contains("\"discharging\"", json);
        Assert.Contains("\"windows\"", json);
    }

    [Fact]
    public void FailuresUseTheSameEnvelope()
    {
        var json = Serialize(new ErrorDocument
        {
            Command = "now",
            Ok = false,
            Error = new JuiceError("noPowerSource", "No power source is available."),
        });

        Assert.Contains("\"ok\": false", json);
        Assert.Contains("noPowerSource", json);
        Assert.Contains("schemaVersion", json);
    }

    [Fact]
    public void SuccessfulDocuments_OmitTheErrorProperty()
    {
        var json = Serialize(Now(
            new MeasurementDto { Confidence = MeasurementConfidence.Measured, SystemWatts = 1 },
            new BatteryDto { Present = false }));

        Assert.DoesNotContain("\"error\"", json);
        Assert.Contains("\"ok\": true", json);
    }

    [Fact]
    public void WindowSeconds_IsDerivedFromTheBounds()
    {
        var start = DateTimeOffset.UtcNow;
        var window = new WindowDto { Start = start, End = start.AddSeconds(12) };

        Assert.Equal(12.0, window.Seconds, 6);
    }

    [Fact]
    public void SchemaVersionIsStamped()
        => Assert.Equal(JuiceSchema.Version, Now(
            new MeasurementDto { Confidence = MeasurementConfidence.Unavailable },
            new BatteryDto { Present = false }).SchemaVersion);

    /// <summary>
    /// Documents the reconciliation guarantee the totals block promises.
    /// </summary>
    [Fact]
    public void EnergyTotals_Reconcile()
    {
        var totals = new EnergyTotalsDto
        {
            SystemWattHours = 0.0861,
            AttributedWattHours = 0.0722,
            PlatformWattHours = 0.0139,
        };

        Assert.Equal(
            totals.SystemWattHours,
            totals.AttributedWattHours + totals.PlatformWattHours,
            9);
    }
}
