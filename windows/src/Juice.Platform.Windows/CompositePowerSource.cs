using System.Runtime.Versioning;
using Juice.Core.Power;

namespace Juice.Platform.Windows;

/// <summary>
/// Picks the best available power source and reports which one it used.
/// </summary>
/// <remarks>
/// <para>
/// Selection is per reading, not once at startup, because the best source can change
/// while the app runs. A laptop with an Energy Meter always uses it. A laptop without
/// one has real measurement on battery and none on AC, and Juice says so rather than
/// showing a fabricated number.
/// </para>
/// <para>
/// Sources are never blended. A displayed wattage comes from exactly one tier and
/// carries that tier with it, so the UI can label a modelled figure as modelled.
/// </para>
/// </remarks>
[SupportedOSPlatform("windows")]
public sealed class CompositePowerSource : IPowerSource, IDisposable
{
    private readonly IReadOnlyList<IPowerSource> _sources;
    private bool _disposed;

    /// <summary>Creates a composite over the given sources, best first.</summary>
    public CompositePowerSource(IEnumerable<IPowerSource> sources)
    {
        _sources = sources.OrderByDescending(s => s.Tier).ToList();
    }

    /// <summary>Builds the standard Windows source stack for this machine.</summary>
    public static CompositePowerSource CreateDefault()
    {
        var battery = new WmiBatteryStateReader();
        return new CompositePowerSource(
        [
            new EnergyMeterPowerSource(battery),
            new BatteryPowerSource(battery),
        ]);
    }

    /// <inheritdoc />
    public PowerSourceTier Tier => _sources.FirstOrDefault(s => s.IsAvailable)?.Tier ?? PowerSourceTier.None;

    /// <inheritdoc />
    public string Description =>
        _sources.FirstOrDefault(s => s.IsAvailable)?.Description ?? "No power source available";

    /// <inheritdoc />
    public bool IsAvailable => _sources.Any(s => s.IsAvailable);

    /// <summary>Every source considered, for the diagnostics screen.</summary>
    public IReadOnlyList<IPowerSource> Sources => _sources;

    /// <summary>
    /// Primes any source that needs a baseline before it can measure.
    /// One-shot callers must do this; continuous pollers need not.
    /// </summary>
    public void Prime(TimeSpan settle)
    {
        foreach (var source in _sources)
        {
            if (source is EnergyMeterPowerSource meter) meter.Prime(settle);
        }
    }

    /// <inheritdoc />
    public PowerSample? Read()
    {
        PowerSample? best = null;

        foreach (var source in _sources)
        {
            if (!source.IsAvailable) continue;
            if (source.Read() is not { } sample) continue;

            // A sample with no wattage still carries battery and AC state, so keep it as
            // a fallback while continuing to look for one that can actually measure.
            if (sample.SystemWatts is > 0) return sample;
            best ??= sample;
        }

        return best;
    }

    /// <inheritdoc />
    public void Dispose()
    {
        if (_disposed) return;
        _disposed = true;
        foreach (var source in _sources)
        {
            if (source is IDisposable d) d.Dispose();
        }
    }
}
