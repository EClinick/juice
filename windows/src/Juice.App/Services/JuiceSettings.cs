using System.Globalization;
using Windows.Storage;

namespace Juice.App.Services;

/// <summary>
/// User settings, persisted in the package's local settings store.
/// </summary>
/// <remarks>
/// <para>
/// <see cref="ApplicationData"/> is used rather than a file of our own because the
/// package identity that Juice already needs for its startup task also gives it a
/// per-user settings container that Windows backs up and removes with the app.
/// </para>
/// <para>
/// The price is stored as an invariant string, not as a double. It is money the user
/// typed, and round-tripping 0.29 through binary floating point and back is exactly the
/// kind of quiet mutation of a displayed number this codebase does not do.
/// </para>
/// </remarks>
public sealed class JuiceSettings
{
    private const string RateOverrideKey = "ElectricityRateOverridePerKwh";
    private const string CurrencyKey = "ElectricityRateCurrency";

    private readonly ApplicationDataContainer? _container;
    private readonly Dictionary<string, string> _fallback = [];

    /// <summary>Loads settings, falling back to memory when there is no package identity.</summary>
    public JuiceSettings()
    {
        try
        {
            _container = ApplicationData.Current.LocalSettings;
        }
        catch (Exception ex) when (ex is InvalidOperationException or UnauthorizedAccessException)
        {
            // Running without package identity, for example under a plain debugger
            // attach. Settings still work for the session, they just do not survive it.
            _container = null;
        }
    }

    /// <summary>
    /// User-entered price per kilowatt-hour, or null to use the bundled regional average.
    /// </summary>
    public decimal? RateOverridePerKwh
    {
        get => Read(RateOverrideKey) is { } text
               && decimal.TryParse(text, NumberStyles.Number, CultureInfo.InvariantCulture, out var value)
               && value > 0
            ? value
            : null;
        set => Write(RateOverrideKey, value?.ToString(CultureInfo.InvariantCulture));
    }

    /// <summary>ISO 4217 currency code used alongside <see cref="RateOverridePerKwh"/>.</summary>
    public string Currency
    {
        get => Read(CurrencyKey) is { Length: > 0 } code ? code : "USD";
        set => Write(CurrencyKey, string.IsNullOrWhiteSpace(value) ? null : value.Trim().ToUpperInvariant());
    }

    private string? Read(string key)
    {
        if (_container is null) return _fallback.GetValueOrDefault(key);
        return _container.Values.TryGetValue(key, out var value) ? value as string : null;
    }

    private void Write(string key, string? value)
    {
        if (_container is null)
        {
            if (value is null) _fallback.Remove(key);
            else _fallback[key] = value;
            return;
        }

        if (value is null) _container.Values.Remove(key);
        else _container.Values[key] = value;
    }
}
