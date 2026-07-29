using Juice.Core.Power;
using Xunit;

namespace Juice.Core.Tests;

public class EnergyUnitsTests
{
    [Fact]
    public void PicowattHoursToWattHours_UsesTheCalibratedScale()
    {
        Assert.Equal(1.0, EnergyUnits.PicowattHoursToWattHours(1e12), 12);
        Assert.Equal(0.5, EnergyUnits.PicowattHoursToWattHours(5e11), 12);
    }

    /// <summary>
    /// Guards the constant that the whole Windows energy pipeline rests on.
    /// </summary>
    /// <remarks>
    /// The Energy Meter unit was established empirically by integrating the power
    /// counter against the energy accumulator, which produced 278,011 units per
    /// millijoule on two independent rails. That is 2.78011e8 units per joule, and one
    /// joule is 2.77778e8 picowatt-hours. If this assertion ever fails, the unit
    /// assumption in EnergyUnits is wrong and every displayed watt-hour is wrong with it.
    /// </remarks>
    [Fact]
    public void MeasuredCalibrationConstant_MatchesPicowattHours()
    {
        const double measuredUnitsPerMillijoule = 278_011.0;
        var measuredUnitsPerJoule = measuredUnitsPerMillijoule * 1000.0;

        var picowattHoursPerJoule =
            EnergyUnits.PicowattHoursPerWattHour / EnergyUnits.JoulesPerWattHour;

        var errorPercent =
            Math.Abs(measuredUnitsPerJoule - picowattHoursPerJoule) / picowattHoursPerJoule * 100.0;

        Assert.True(errorPercent < 0.5, $"Calibration drifted by {errorPercent:0.000}%");
    }

    [Fact]
    public void MilliwattsToWatts_Converts()
    {
        Assert.Equal(15.22, EnergyUnits.MilliwattsToWatts(15_220), 6);
    }

    [Fact]
    public void WattHoursFrom_IntegratesConstantPower()
    {
        Assert.Equal(10.0, EnergyUnits.WattHoursFrom(20.0, TimeSpan.FromMinutes(30)), 9);
    }

    [Fact]
    public void AverageWatts_ReturnsZeroForEmptyInterval()
    {
        Assert.Equal(0.0, EnergyUnits.AverageWatts(5.0, TimeSpan.Zero));
        Assert.Equal(0.0, EnergyUnits.AverageWatts(5.0, TimeSpan.FromSeconds(-1)));
    }
}
