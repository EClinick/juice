namespace Juice.Core.Cost;

/// <summary>
/// A price for electrical energy, tagged with where it came from so the UI can be
/// honest about whether the user is seeing their real tariff or a regional average.
/// </summary>
public sealed record ElectricityRate
{
    /// <summary>Price of one kilowatt-hour in <see cref="Currency"/>.</summary>
    public required decimal PricePerKwh { get; init; }

    /// <summary>ISO 4217 currency code, for example <c>USD</c>.</summary>
    public required string Currency { get; init; }

    /// <summary>
    /// Region this rate applies to: an ISO 3166-2 subdivision such as <c>US-WA</c>,
    /// or an ISO 3166-1 alpha-2 country such as <c>DE</c>.
    /// </summary>
    public required string RegionCode { get; init; }

    /// <summary>Human-readable region name for display.</summary>
    public required string RegionName { get; init; }

    /// <summary>How this rate was obtained.</summary>
    public required RateSource Source { get; init; }

    /// <summary>True when the number is a regional average rather than the user's tariff.</summary>
    public bool IsEstimate => Source != RateSource.UserOverride;
}

/// <summary>Provenance of an <see cref="ElectricityRate"/>.</summary>
public enum RateSource
{
    /// <summary>Typed in by the user. Treated as ground truth.</summary>
    UserOverride,

    /// <summary>Regional average from the table bundled with the app.</summary>
    BundledAverage,

    /// <summary>Fallback used when the region could not be determined at all.</summary>
    Fallback,
}

/// <summary>Converts measured energy into money.</summary>
/// <remarks>
/// The arithmetic is deliberately trivial. The honesty lives in
/// <see cref="ElectricityRate.IsEstimate"/>: a cost derived from a regional average is
/// labelled as an estimate everywhere it is shown, because the rate, not the energy,
/// is the uncertain term. Juice measures energy from hardware counters, so the Wh
/// figure is sound even when the price attached to it is a regional mean.
/// </remarks>
public static class CostCalculator
{
    /// <summary>Cost of a quantity of energy at a given rate.</summary>
    public static decimal CostOf(double wattHours, ElectricityRate rate)
    {
        if (wattHours <= 0) return 0m;
        return (decimal)(wattHours / 1000.0) * rate.PricePerKwh;
    }

    /// <summary>
    /// Extrapolates an observed energy figure to a longer period, for answering
    /// "what would this cost me over a year if it kept this up".
    /// </summary>
    public static decimal ProjectedCost(
        double wattHours,
        TimeSpan observed,
        TimeSpan projectTo,
        ElectricityRate rate)
    {
        if (wattHours <= 0 || observed <= TimeSpan.Zero) return 0m;
        var scale = projectTo.TotalHours / observed.TotalHours;
        return CostOf(wattHours * scale, rate);
    }

    /// <summary>Average watts sustained over a period, projected to annual cost.</summary>
    public static decimal AnnualCostOfSustainedWatts(double watts, ElectricityRate rate)
        => CostOf(watts * 24 * 365.25, rate);
}
