namespace Juice.Core.Cost;

/// <summary>Resolves an electricity rate for a region.</summary>
public interface IElectricityRateProvider
{
    /// <summary>
    /// Best rate for the given region code, falling back progressively: an exact
    /// subdivision match, then the containing country, then a documented fallback.
    /// Never returns null so the cost UI always has something to show.
    /// </summary>
    ElectricityRate ResolveFor(string? regionCode);
}

/// <summary>
/// Average residential electricity prices bundled with the app.
/// </summary>
/// <remarks>
/// <para>
/// These are averages, not tariffs. They exist so that cost figures are useful out of
/// the box, before the user has entered anything, and every value they produce is
/// marked <see cref="RateSource.BundledAverage"/> so the UI can say so.
/// </para>
/// <para>
/// US figures are average residential retail prices in US cents per kWh, of the order
/// published by the EIA. Non-US figures are national residential averages converted to
/// USD. They are rounded and will drift, which is exactly why a user override always
/// takes precedence and is offered prominently in settings.
/// </para>
/// </remarks>
public sealed class BundledRateTable : IElectricityRateProvider
{
    private static readonly ElectricityRate FallbackRate = new()
    {
        PricePerKwh = 0.17m,
        Currency = "USD",
        RegionCode = "??",
        RegionName = "Unknown region",
        Source = RateSource.Fallback,
    };

    // Region code -> (price per kWh USD, display name).
    private static readonly Dictionary<string, (decimal Price, string Name)> Rates =
        new(StringComparer.OrdinalIgnoreCase)
        {
            // United States, by state.
            ["US-AL"] = (0.152m, "Alabama"),
            ["US-AK"] = (0.247m, "Alaska"),
            ["US-AZ"] = (0.150m, "Arizona"),
            ["US-AR"] = (0.129m, "Arkansas"),
            ["US-CA"] = (0.317m, "California"),
            ["US-CO"] = (0.149m, "Colorado"),
            ["US-CT"] = (0.320m, "Connecticut"),
            ["US-DE"] = (0.172m, "Delaware"),
            ["US-DC"] = (0.174m, "District of Columbia"),
            ["US-FL"] = (0.152m, "Florida"),
            ["US-GA"] = (0.142m, "Georgia"),
            ["US-HI"] = (0.428m, "Hawaii"),
            ["US-ID"] = (0.113m, "Idaho"),
            ["US-IL"] = (0.163m, "Illinois"),
            ["US-IN"] = (0.145m, "Indiana"),
            ["US-IA"] = (0.132m, "Iowa"),
            ["US-KS"] = (0.140m, "Kansas"),
            ["US-KY"] = (0.128m, "Kentucky"),
            ["US-LA"] = (0.122m, "Louisiana"),
            ["US-ME"] = (0.245m, "Maine"),
            ["US-MD"] = (0.176m, "Maryland"),
            ["US-MA"] = (0.303m, "Massachusetts"),
            ["US-MI"] = (0.187m, "Michigan"),
            ["US-MN"] = (0.147m, "Minnesota"),
            ["US-MS"] = (0.135m, "Mississippi"),
            ["US-MO"] = (0.126m, "Missouri"),
            ["US-MT"] = (0.121m, "Montana"),
            ["US-NE"] = (0.114m, "Nebraska"),
            ["US-NV"] = (0.169m, "Nevada"),
            ["US-NH"] = (0.235m, "New Hampshire"),
            ["US-NJ"] = (0.196m, "New Jersey"),
            ["US-NM"] = (0.145m, "New Mexico"),
            ["US-NY"] = (0.239m, "New York"),
            ["US-NC"] = (0.135m, "North Carolina"),
            ["US-ND"] = (0.107m, "North Dakota"),
            ["US-OH"] = (0.155m, "Ohio"),
            ["US-OK"] = (0.122m, "Oklahoma"),
            ["US-OR"] = (0.135m, "Oregon"),
            ["US-PA"] = (0.180m, "Pennsylvania"),
            ["US-RI"] = (0.283m, "Rhode Island"),
            ["US-SC"] = (0.142m, "South Carolina"),
            ["US-SD"] = (0.122m, "South Dakota"),
            ["US-TN"] = (0.126m, "Tennessee"),
            ["US-TX"] = (0.150m, "Texas"),
            ["US-UT"] = (0.113m, "Utah"),
            ["US-VT"] = (0.216m, "Vermont"),
            ["US-VA"] = (0.143m, "Virginia"),
            ["US-WA"] = (0.114m, "Washington"),
            ["US-WV"] = (0.148m, "West Virginia"),
            ["US-WI"] = (0.163m, "Wisconsin"),
            ["US-WY"] = (0.112m, "Wyoming"),

            // National averages.
            ["US"] = (0.170m, "United States"),
            ["CA"] = (0.130m, "Canada"),
            ["GB"] = (0.310m, "United Kingdom"),
            ["IE"] = (0.330m, "Ireland"),
            ["DE"] = (0.400m, "Germany"),
            ["FR"] = (0.230m, "France"),
            ["ES"] = (0.240m, "Spain"),
            ["IT"] = (0.310m, "Italy"),
            ["NL"] = (0.320m, "Netherlands"),
            ["BE"] = (0.340m, "Belgium"),
            ["DK"] = (0.350m, "Denmark"),
            ["NO"] = (0.130m, "Norway"),
            ["SE"] = (0.200m, "Sweden"),
            ["FI"] = (0.180m, "Finland"),
            ["PL"] = (0.200m, "Poland"),
            ["PT"] = (0.240m, "Portugal"),
            ["AT"] = (0.290m, "Austria"),
            ["CH"] = (0.250m, "Switzerland"),
            ["AU"] = (0.230m, "Australia"),
            ["NZ"] = (0.190m, "New Zealand"),
            ["JP"] = (0.200m, "Japan"),
            ["KR"] = (0.110m, "South Korea"),
            ["CN"] = (0.080m, "China"),
            ["IN"] = (0.070m, "India"),
            ["BR"] = (0.150m, "Brazil"),
            ["MX"] = (0.090m, "Mexico"),
            ["ZA"] = (0.150m, "South Africa"),
            ["SG"] = (0.220m, "Singapore"),
            ["AE"] = (0.080m, "United Arab Emirates"),
        };

    /// <inheritdoc />
    public ElectricityRate ResolveFor(string? regionCode)
    {
        if (string.IsNullOrWhiteSpace(regionCode)) return FallbackRate;

        var code = regionCode.Trim();

        if (Rates.TryGetValue(code, out var exact))
        {
            return Build(code, exact);
        }

        // "US-WA" with no entry should still land on the US national average.
        var dash = code.IndexOf('-');
        if (dash > 0)
        {
            var country = code[..dash];
            if (Rates.TryGetValue(country, out var national))
            {
                return Build(country, national);
            }
        }

        return FallbackRate;
    }

    /// <summary>Every region the bundled table knows, for the settings picker.</summary>
    public IEnumerable<ElectricityRate> AllRegions()
        => Rates.OrderBy(kv => kv.Value.Name, StringComparer.CurrentCulture)
                .Select(kv => Build(kv.Key, kv.Value));

    private static ElectricityRate Build(string code, (decimal Price, string Name) entry) => new()
    {
        PricePerKwh = entry.Price,
        Currency = "USD",
        RegionCode = code,
        RegionName = entry.Name,
        Source = RateSource.BundledAverage,
    };
}

/// <summary>
/// Wraps another provider so a user-entered rate always wins.
/// </summary>
public sealed class OverridableRateProvider(IElectricityRateProvider inner) : IElectricityRateProvider
{
    /// <summary>User-entered price per kWh. When set, it takes precedence over any lookup.</summary>
    public decimal? OverridePricePerKwh { get; set; }

    /// <summary>Currency for the override.</summary>
    public string OverrideCurrency { get; set; } = "USD";

    /// <inheritdoc />
    public ElectricityRate ResolveFor(string? regionCode)
    {
        var resolved = inner.ResolveFor(regionCode);
        if (OverridePricePerKwh is not { } price) return resolved;

        return resolved with
        {
            PricePerKwh = price,
            Currency = OverrideCurrency,
            Source = RateSource.UserOverride,
        };
    }
}
