using System.Diagnostics;
using System.Runtime.Versioning;
using Juice.Core.Power;

namespace Juice.Platform.Windows;

/// <summary>
/// Reads hardware rail metering from the Windows <c>Energy Meter</c> PDH counter set.
/// </summary>
/// <remarks>
/// <para>
/// This is Juice's best power source on Windows, and the reason the Windows version can
/// do something the macOS original cannot: report true compute draw <i>while plugged in</i>.
/// The ACPI battery only reports a discharge rate when discharging, so a laptop sitting
/// on AC reports nothing. An Energy Meter Interface device meters the physical rails
/// regardless of power state.
/// </para>
/// <para>
/// The counter set is present on machines with an EMI device, which includes Surface
/// hardware (Power Meter MAX34417) and a growing number of modern laptops. It is absent
/// on most desktops, so <see cref="IsAvailable"/> must always be checked and callers
/// should fall back to <see cref="BatteryPowerSource"/>.
/// </para>
/// <para>
/// Units are undocumented and were established empirically. See <see cref="EnergyUnits"/>
/// for the calibration: <c>Power</c> is milliwatts and <c>Energy</c> is picowatt-hours.
/// </para>
/// </remarks>
[SupportedOSPlatform("windows")]
public sealed class EnergyMeterPowerSource : IPowerSource, IDisposable
{
    /// <summary>Name of the PDH counter category.</summary>
    public const string CategoryName = "Energy Meter";

    /// <summary>
    /// Shortest interval over which power will be derived from the energy accumulator.
    /// </summary>
    /// <remarks>
    /// The EMI driver refreshes roughly once a second. Deriving watts across an interval
    /// much shorter than that divides a possibly-zero energy delta by a tiny elapsed
    /// time, which produces noise rather than a measurement.
    /// </remarks>
    private static readonly TimeSpan MinimumDerivationInterval = TimeSpan.FromMilliseconds(250);

    private readonly List<RailCounters> _rails = [];
    private readonly IBatteryStateReader? _batteryState;
    private bool _disposed;

    /// <summary>Creates the source, discovering rails once at construction.</summary>
    /// <param name="batteryState">
    /// Optional reader used only to label samples with AC and charge state. The Energy
    /// Meter itself says nothing about the battery.
    /// </param>
    public EnergyMeterPowerSource(IBatteryStateReader? batteryState = null)
    {
        _batteryState = batteryState;
        TryDiscoverRails();
    }

    /// <inheritdoc />
    public PowerSourceTier Tier => PowerSourceTier.HardwareRail;

    /// <inheritdoc />
    public string Description => IsAvailable
        ? $"Hardware energy meter ({_rails.Count} rails: {string.Join(", ", _rails.Select(r => r.Instance))})"
        : "Hardware energy meter (not present on this machine)";

    /// <inheritdoc />
    public bool IsAvailable => _rails.Count > 0;

    /// <summary>
    /// Establishes the baseline that the power counters require, then waits for a
    /// measurable interval to elapse.
    /// </summary>
    /// <remarks>
    /// <para>
    /// The <c>Power</c> counters are of type <c>AverageCount64</c>: each read reports the
    /// average since the previous read, so the very first read of a fresh handle has no
    /// baseline and necessarily returns 0. A long-running GUI never notices, because it
    /// polls continuously and only the first sample is discarded. A one-shot command like
    /// <c>juice now</c> would otherwise report 0 W on a machine drawing 30 W.
    /// </para>
    /// <para>
    /// This is deliberately explicit rather than a hidden sleep inside <see cref="Read"/>,
    /// so that callers who poll continuously never pay for it.
    /// </para>
    /// <para>
    /// The <c>Energy</c> accumulators are raw counters and need no priming, which is
    /// another reason Juice prefers them for anything that must be accurate.
    /// </para>
    /// </remarks>
    /// <param name="settle">How long to wait after establishing the baseline.</param>
    public void Prime(TimeSpan settle)
    {
        foreach (var rail in _rails) rail.TryRead(out _);

        // Long enough that the EMI driver, which refreshes about once a second, is
        // guaranteed to have advanced the accumulators before the first real read.
        if (settle > TimeSpan.Zero) Thread.Sleep(settle);
    }

    /// <summary>True when a rail metering whole-system draw was found.</summary>
    public bool HasSystemRail => _rails.Any(r => r.Rail == PowerRail.System);

    /// <inheritdoc />
    public PowerSample? Read()
    {
        if (!IsAvailable) return null;

        var readings = new List<RailReading>(_rails.Count);
        foreach (var rail in _rails)
        {
            if (rail.TryRead(out var reading)) readings.Add(reading);
        }

        if (readings.Count == 0) return null;

        var battery = _batteryState?.Read();

        var sample = new PowerSample
        {
            Timestamp = DateTimeOffset.UtcNow,
            Tier = PowerSourceTier.HardwareRail,
            Rails = readings,
            OnAc = battery?.OnAc ?? true,
            BatteryPercent = battery?.Percent,
            ChargeWatts = battery?.ChargeWatts,
        };

        return sample with { SystemWatts = ResolveSystemWatts(sample) };
    }

    /// <summary>
    /// Total system draw. Prefers the dedicated system rail; falls back to the supply
    /// rail, then to the sum of the compute rails. The compute sum is a floor, not a
    /// total, because it excludes display and radios, but it beats reporting nothing.
    /// </summary>
    private static double? ResolveSystemWatts(PowerSample sample)
    {
        if (sample.WattsFor(PowerRail.System) is { } sys and > 0) return sys;
        if (sample.WattsFor(PowerRail.Supply) is { } supply and > 0) return supply;

        double compute = 0;
        var any = false;
        foreach (var rail in new[] { PowerRail.Cpu, PowerRail.Gpu, PowerRail.Npu })
        {
            if (sample.WattsFor(rail) is not { } w) continue;
            compute += w;
            any = true;
        }
        return any ? compute : null;
    }

    private void TryDiscoverRails()
    {
        try
        {
            if (!PerformanceCounterCategory.Exists(CategoryName)) return;

            var category = new PerformanceCounterCategory(CategoryName);
            foreach (var instance in category.GetInstanceNames())
            {
                var rail = ClassifyRail(instance);
                if (rail is null) continue;

                try
                {
                    _rails.Add(new RailCounters(instance, rail.Value));
                }
                catch (Exception ex) when (ex is InvalidOperationException or UnauthorizedAccessException)
                {
                    // An instance can disappear between enumeration and binding; skip it.
                }
            }
        }
        catch (Exception ex) when (ex is InvalidOperationException or UnauthorizedAccessException or PlatformNotSupportedException)
        {
            _rails.Clear();
        }
    }

    /// <summary>
    /// Maps a raw EMI instance name onto a normalised rail, or null when the instance
    /// must be ignored.
    /// </summary>
    /// <remarks>
    /// Two classes of instance must never be treated as a rail total. <c>_total</c> is a
    /// PDH aggregate that sums unrelated rails and reads as garbage. Names like
    /// <c>sys_1a</c>, <c>sys_1b</c> and <c>sys_rop_left</c> are <i>sub-rails</i> of
    /// <c>sys</c>; counting them alongside <c>sys</c> would double count the machine's
    /// entire draw. They are mapped to <see cref="PowerRail.Other"/> so they remain
    /// visible for diagnostics without contributing to any total.
    /// </remarks>
    internal static PowerRail? ClassifyRail(string instance)
    {
        var name = instance.Trim().ToLowerInvariant();

        if (name is "_total" or "") return null;

        if (name is "sys" or "system" or "platform") return PowerRail.System;
        if (name.StartsWith("cpu", StringComparison.Ordinal)) return PowerRail.Cpu;
        if (name is "gpu" || name.StartsWith("gpu_", StringComparison.Ordinal)) return PowerRail.Gpu;
        if (name is "npu" or "ane" or "vpu" || name.StartsWith("npu", StringComparison.Ordinal)) return PowerRail.Npu;
        if (name is "psu_usb" or "usbc_total" or "ac" or "adapter" or "charger") return PowerRail.Supply;

        return PowerRail.Other;
    }

    /// <inheritdoc />
    public void Dispose()
    {
        if (_disposed) return;
        _disposed = true;
        foreach (var rail in _rails) rail.Dispose();
        _rails.Clear();
    }

    private sealed class RailCounters : IDisposable
    {
        private readonly PerformanceCounter _power;
        private readonly PerformanceCounter? _energy;

        private double _lastEnergyWattHours = double.NaN;
        private long _lastTimestamp;

        public RailCounters(string instance, PowerRail rail)
        {
            Instance = instance;
            Rail = rail;
            _power = new PerformanceCounter(CategoryName, "Power", instance, readOnly: true);

            try
            {
                _energy = new PerformanceCounter(CategoryName, "Energy", instance, readOnly: true);
            }
            catch (InvalidOperationException)
            {
                // Energy accumulator is optional; power alone still works.
                _energy = null;
            }

            // Establish the averaging counter's baseline immediately so that a caller
            // polling on a timer gets a real value on its second read rather than
            // silently reporting zero watts.
            try
            {
                _power.NextValue();
            }
            catch (Exception ex) when (ex is InvalidOperationException or UnauthorizedAccessException)
            {
            }
        }

        public string Instance { get; }

        public PowerRail Rail { get; }

        public bool TryRead(out RailReading reading)
        {
            reading = default;
            try
            {
                double? cumulativeWh = null;
                var derivedWatts = double.NaN;
                var now = Stopwatch.GetTimestamp();

                if (_energy is not null)
                {
                    var picowattHours = _energy.NextValue();
                    if (picowattHours > 0)
                    {
                        var wattHours = EnergyUnits.PicowattHoursToWattHours(picowattHours);
                        cumulativeWh = wattHours;

                        // Prefer deriving power from the accumulator. The Power counter is
                        // an AverageCount64 over the interval between reads, and the EMI
                        // driver only refreshes about once a second, so a short interval
                        // can land entirely between refreshes and average to exactly zero.
                        // The accumulator has no such failure mode: it is monotonic, so
                        // any elapsed energy shows up in the delta whenever it is read.
                        if (!double.IsNaN(_lastEnergyWattHours))
                        {
                            var elapsed = Stopwatch.GetElapsedTime(_lastTimestamp, now);
                            var delta = wattHours - _lastEnergyWattHours;

                            if (delta >= 0 && elapsed >= MinimumDerivationInterval)
                            {
                                derivedWatts = EnergyUnits.AverageWatts(delta, elapsed);
                            }
                        }

                        _lastEnergyWattHours = wattHours;
                        _lastTimestamp = now;
                    }
                }

                var counterWatts = EnergyUnits.MilliwattsToWatts(_power.NextValue());

                var watts = double.IsNaN(derivedWatts) ? counterWatts : derivedWatts;

                reading = new RailReading(Rail, Instance, watts, cumulativeWh, counterWatts);
                return true;
            }
            catch (Exception ex) when (ex is InvalidOperationException or UnauthorizedAccessException)
            {
                return false;
            }
        }

        public void Dispose()
        {
            _power.Dispose();
            _energy?.Dispose();
        }
    }
}
