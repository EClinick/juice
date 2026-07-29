using System.Runtime.Versioning;
using Juice.Core.Cost;
using Juice.Platform.Windows;

namespace Juice.App.Services;

/// <summary>
/// Resolves the electricity price Juice converts measured energy into money with.
/// </summary>
/// <remarks>
/// The rate is the uncertain term in every cost Juice shows: the energy comes from
/// hardware counters, the price comes from a regional average unless the user typed
/// their own. <see cref="Current"/> therefore always carries
/// <see cref="ElectricityRate.IsEstimate"/> with it so the UI can say which it is
/// showing, and the override is stored rather than folded into the table.
/// </remarks>
[SupportedOSPlatform("windows10.0.19041.0")]
public sealed class RateService
{
    private readonly OverridableRateProvider _provider = new(new BundledRateTable());
    private readonly JuiceSettings _settings;

    /// <summary>Loads the persisted override, if any, and resolves the region once.</summary>
    public RateService(JuiceSettings settings)
    {
        _settings = settings;
        RegionCode = RegionResolver.CurrentRegionCode();

        _provider.OverrideCurrency = settings.Currency;
        _provider.OverridePricePerKwh = settings.RateOverridePerKwh;
    }

    /// <summary>The user's region as Windows reports it, or null when unknown.</summary>
    public string? RegionCode { get; }

    /// <summary>The rate in force right now.</summary>
    public ElectricityRate Current => _provider.ResolveFor(RegionCode);

    /// <summary>User-entered price per kilowatt-hour, or null to use the regional average.</summary>
    public decimal? OverridePricePerKwh
    {
        get => _provider.OverridePricePerKwh;
        set
        {
            _provider.OverridePricePerKwh = value;
            _settings.RateOverridePerKwh = value;
        }
    }

    /// <summary>Currency for the override.</summary>
    public string OverrideCurrency
    {
        get => _provider.OverrideCurrency;
        set
        {
            _provider.OverrideCurrency = value;
            _settings.Currency = value;
        }
    }
}
