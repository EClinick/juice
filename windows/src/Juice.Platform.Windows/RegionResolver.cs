using System.Globalization;
using System.Runtime.Versioning;

namespace Juice.Platform.Windows;

/// <summary>
/// Determines which region's electricity price applies.
/// </summary>
/// <remarks>
/// <para>
/// Juice resolves the region without asking for the location capability by default. The
/// Windows user region gives a country immediately, with no permission prompt, no
/// network call, and nothing to leak. For a background utility that is the proportionate
/// choice, and it is enough to pick a national average price.
/// </para>
/// <para>
/// Precise geolocation only improves the answer in countries where prices vary sharply
/// by subdivision, which in practice means the United States. Callers can supply a
/// subdivision from the Windows geolocation API when the user has explicitly opted in;
/// see <see cref="WithSubdivision"/>. Nothing here ever contacts the network.
/// </para>
/// </remarks>
[SupportedOSPlatform("windows")]
public static class RegionResolver
{
    /// <summary>
    /// The user's region as an ISO 3166-1 alpha-2 country code, or null when it cannot
    /// be determined.
    /// </summary>
    public static string? CurrentRegionCode()
    {
        try
        {
            var region = RegionInfo.CurrentRegion;
            var name = region.TwoLetterISORegionName;
            return string.IsNullOrWhiteSpace(name) ? null : name.ToUpperInvariant();
        }
        catch (Exception ex) when (ex is ArgumentException or InvalidOperationException)
        {
            return null;
        }
    }

    /// <summary>
    /// Combines the current country with a subdivision code to form an ISO 3166-2 style
    /// region such as <c>US-WA</c>, which the bundled rate table can match exactly.
    /// </summary>
    /// <param name="subdivision">
    /// Subdivision code without the country prefix, for example <c>WA</c>. When null or
    /// empty the country code alone is returned.
    /// </param>
    public static string? WithSubdivision(string? subdivision)
    {
        var country = CurrentRegionCode();
        if (country is null) return null;
        if (string.IsNullOrWhiteSpace(subdivision)) return country;

        var code = subdivision.Trim().ToUpperInvariant();

        // Accept a value that already carries the country prefix.
        return code.StartsWith(country + "-", StringComparison.Ordinal) ? code : $"{country}-{code}";
    }
}
