using System.Globalization;
using System.Runtime.Versioning;
using CommunityToolkit.Mvvm.ComponentModel;
using Juice.Core.Monitoring;
using Juice.Platform.Windows;
using Juice.App.Services;

namespace Juice.App.ViewModels;

/// <summary>
/// Backs the settings window: electricity rate, startup behaviour and diagnostics.
/// </summary>
/// <remarks>
/// The rate override is the only setting that changes a displayed number, so it is
/// deliberately explicit. The regional average is shown read-only next to it, and turning
/// the override off restores the average rather than leaving the last typed value in
/// place looking like a measurement.
/// </remarks>
[SupportedOSPlatform("windows10.0.19041.0")]
public sealed partial class SettingsViewModel : ObservableObject
{
    private readonly RateService _rates;
    private readonly PowerMonitor _monitor;
    private bool _isLoading;

    /// <summary>Creates the view model over the app's live services.</summary>
    public SettingsViewModel(RateService rates, PowerMonitor monitor)
    {
        _rates = rates;
        _monitor = monitor;

        _isLoading = true;
        try
        {
            UseCustomRate = rates.OverridePricePerKwh is not null;
            CustomRatePerKwh = (double)(rates.OverridePricePerKwh ?? rates.Current.PricePerKwh);
            Currency = rates.OverrideCurrency;
            RegionText = string.Empty;
            ResolvedRateText = string.Empty;
            StartupNote = string.Empty;
            SourceTierText = string.Empty;
            SourceDescriptionText = string.Empty;
            GpuCountersText = string.Empty;
            ProcessTableText = string.Empty;
        }
        finally
        {
            _isLoading = false;
        }

        RefreshRateSummary();
        RefreshDiagnostics();
    }

    /// <summary>True when the user is supplying their own price per kWh.</summary>
    [ObservableProperty]
    public partial bool UseCustomRate { get; set; }

    /// <summary>The price per kWh the user entered.</summary>
    [ObservableProperty]
    public partial double CustomRatePerKwh { get; set; }

    /// <summary>ISO 4217 currency code the entered price is in.</summary>
    [ObservableProperty]
    public partial string Currency { get; set; }

    /// <summary>Region the bundled rate table resolved, shown read-only.</summary>
    [ObservableProperty]
    public partial string RegionText { get; set; }

    /// <summary>The rate actually in use, and where it came from.</summary>
    [ObservableProperty]
    public partial string ResolvedRateText { get; set; }

    /// <summary>Whether Juice is registered to start with Windows.</summary>
    [ObservableProperty]
    public partial bool StartWithWindows { get; set; }

    /// <summary>Explains why startup could not be enabled, when that happens.</summary>
    [ObservableProperty]
    public partial string StartupNote { get; set; }

    /// <summary>Which power source tier is supplying readings.</summary>
    [ObservableProperty]
    public partial string SourceTierText { get; set; }

    /// <summary>The composite source's own description of what it is reading.</summary>
    [ObservableProperty]
    public partial string SourceDescriptionText { get; set; }

    /// <summary>Whether per-process GPU counters are available on this machine.</summary>
    [ObservableProperty]
    public partial string GpuCountersText { get; set; }

    /// <summary>Whether the fast native process table is in use.</summary>
    [ObservableProperty]
    public partial string ProcessTableText { get; set; }

    /// <summary>Reads the current startup task state, which requires an async call.</summary>
    public async Task LoadStartupStateAsync()
    {
        _isLoading = true;
        try
        {
            StartWithWindows = await StartupTaskService.IsEnabledAsync();
            StartupNote = await StartupTaskService.IsBlockedByUserAsync()
                ? "Startup is switched off for Juice in Task Manager, so this cannot be turned on here."
                : string.Empty;
        }
        finally
        {
            _isLoading = false;
        }
    }

    /// <summary>Re-reads the diagnostics, which change once the first tick has run.</summary>
    public void RefreshDiagnostics()
    {
        RegionText = _rates.RegionCode ?? "Not determined";

        SourceTierText = _monitor.Source is { } source
            ? DiagnosticsReport.TierName(source.Tier)
            : "not initialised yet";

        SourceDescriptionText = _monitor.Source?.Description ?? "Waiting for the first reading.";

        GpuCountersText = _monitor.Processes as ProcessSampler is { } processes
            ? processes.GpuCountersAvailable ? "Available" : "Not available on this machine"
            : "Waiting for the first reading";

        ProcessTableText = _monitor.Processes as ProcessSampler is { } sampler
            ? sampler.UsingNativeProcessTable ? "Native bulk read" : "Managed enumeration fallback"
            : "Waiting for the first reading";
    }

    partial void OnUseCustomRateChanged(bool value)
    {
        if (_isLoading) return;

        _rates.OverridePricePerKwh = value ? ToRate(CustomRatePerKwh) : null;
        RefreshRateSummary();
    }

    partial void OnCustomRatePerKwhChanged(double value)
    {
        if (_isLoading || !UseCustomRate) return;

        _rates.OverridePricePerKwh = ToRate(value);
        RefreshRateSummary();
    }

    partial void OnCurrencyChanged(string value)
    {
        if (_isLoading) return;

        _rates.OverrideCurrency = value;
        RefreshRateSummary();
    }

    partial void OnStartWithWindowsChanged(bool value)
    {
        if (_isLoading) return;
        _ = ApplyStartupAsync(value);
    }

    private async Task ApplyStartupAsync(bool requested)
    {
        var achieved = await StartupTaskService.SetEnabledAsync(requested);
        if (achieved == requested) return;

        // Windows refused, almost always because the user disabled Juice in Task
        // Manager. Snap the toggle back rather than leaving it showing a state that is
        // not real.
        _isLoading = true;
        try
        {
            StartWithWindows = achieved;
            StartupNote = "Windows is blocking Juice from starting automatically. Enable it in Task Manager's Startup apps tab.";
        }
        finally
        {
            _isLoading = false;
        }
    }

    private void RefreshRateSummary()
    {
        var rate = _rates.Current;
        var price = MoneyFormatter.Format(rate.PricePerKwh, rate.Currency);

        ResolvedRateText = rate.IsEstimate
            ? $"{price} per kWh, the {rate.RegionName} average. Costs derived from it are estimates."
            : $"{price} per kWh, entered by you.";
    }

    /// <summary>
    /// Converts the entered figure to the decimal the rate table uses, or null when it
    /// is not a usable price.
    /// </summary>
    private static decimal? ToRate(double value)
        => double.IsFinite(value) && value > 0
            ? decimal.Round((decimal)value, 4, MidpointRounding.AwayFromZero)
            : null;

    /// <summary>Formats a rate for the read-only summary line.</summary>
    public static string FormatRate(decimal price, string currency)
        => MoneyFormatter.Format(price, currency)
           + " per kWh ("
           + price.ToString("0.####", CultureInfo.InvariantCulture)
           + ")";
}
