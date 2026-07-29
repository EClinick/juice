using System.Runtime.Versioning;

namespace Juice.Platform.Windows;

/// <summary>
/// Holds a battery reading for a short while so that a fast sampling loop does not issue
/// a WMI query per read.
/// </summary>
/// <remarks>
/// <para>
/// <see cref="WmiBatteryStateReader"/> builds a <c>ManagementObjectSearcher</c>, runs a
/// query against <c>root\wmi</c> and then runs a second one for the full charge capacity,
/// every single time it is asked. That is a cross process call into the WMI service, and
/// it is orders of magnitude more expensive than the performance counter read it sits
/// next to: the hardware rails come from PDH, which is a memory read behind a handle.
/// </para>
/// <para>
/// The values it returns do not deserve that price. Charge percentage moves over minutes,
/// and AC state changes when someone touches a cable. Sampling them every five seconds
/// alongside the rails means roughly seventeen thousand WMI queries a day for a number
/// that changes a few dozen times. An application whose subject is background waste
/// cannot credibly ship that.
/// </para>
/// <para>
/// Discharge rate is the one field that is genuinely rate-like, and it matters only when
/// the battery is the power source of last resort rather than a hardware rail. That path
/// keeps an uncached reader, so accuracy is unaffected where it is load bearing.
/// </para>
/// </remarks>
[SupportedOSPlatform("windows")]
public sealed class CachedBatteryStateReader : IBatteryStateReader
{
    /// <summary>
    /// How long a reading is reused. Long enough to make the query rare, short enough
    /// that plugging in a charger is reflected within one tray refresh cycle.
    /// </summary>
    public static readonly TimeSpan DefaultLifetime = TimeSpan.FromSeconds(30);

    private readonly IBatteryStateReader _inner;
    private readonly TimeSpan _lifetime;
    private readonly Lock _gate = new();

    private BatteryState? _cached;
    private DateTime _readAtUtc = DateTime.MinValue;

    /// <summary>Wraps a reader, reusing its result for <paramref name="lifetime"/>.</summary>
    public CachedBatteryStateReader(IBatteryStateReader inner, TimeSpan? lifetime = null)
    {
        _inner = inner;
        _lifetime = lifetime ?? DefaultLifetime;
    }

    /// <inheritdoc />
    public BatteryState? Read()
    {
        lock (_gate)
        {
            var age = DateTime.UtcNow - _readAtUtc;
            if (age < _lifetime) return _cached;

            _cached = _inner.Read();
            _readAtUtc = DateTime.UtcNow;
            return _cached;
        }
    }

    /// <summary>Discards the cached reading, so the next call queries again.</summary>
    /// <remarks>
    /// Worth calling when Windows says the power source changed, since that is precisely
    /// the moment the cached answer is guaranteed to be wrong.
    /// </remarks>
    public void Invalidate()
    {
        lock (_gate) _readAtUtc = DateTime.MinValue;
    }
}
