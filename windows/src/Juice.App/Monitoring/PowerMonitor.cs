using System.Runtime.Versioning;
using Juice.App.Interop;
using Juice.Core.Attribution;
using Juice.Core.Power;
using Juice.Platform.Windows;
using Microsoft.UI.Dispatching;

namespace Juice.App.Monitoring;

/// <summary>
/// Runs the sampling loop and publishes snapshots to the UI thread.
/// </summary>
/// <remarks>
/// <para>
/// The loop is a single one-shot timer that re-arms itself with whatever cadence
/// <see cref="SamplingPolicy"/> currently returns, rather than a fixed fast timer that
/// discards most of its ticks. That distinction is the whole point: a one second timer
/// left running in the tray wakes the processor 86,400 times a day for a number nobody
/// is looking at, and Juice would then appear in its own list of top energy users.
/// </para>
/// <para>
/// Everything expensive happens on the thread pool. Only the finished
/// <see cref="PowerSnapshot"/> crosses to the UI thread, so neither the counter reads nor
/// the process table walk can make the flyout stutter.
/// </para>
/// </remarks>
[SupportedOSPlatform("windows10.0.19041.0")]
public sealed class PowerMonitor : IDisposable
{
    /// <summary>
    /// The hardware counters are <c>AverageCount64</c>, so the first read has no
    /// interval behind it and returns zero. Priming pays that cost once, at startup,
    /// instead of showing a fabricated zero watt reading.
    /// </summary>
    private static readonly TimeSpan PrimeSettle = TimeSpan.FromMilliseconds(400);

    /// <summary>
    /// Shortest interval Juice will attribute energy over. Below this the CPU time
    /// deltas are dominated by scheduling noise and the app list reorders itself faster
    /// than it can be read.
    /// </summary>
    private static readonly TimeSpan MinimumAttributionWindow = TimeSpan.FromSeconds(5);

    private readonly DispatcherQueue _ui;
    private readonly EnergyAttributor _attributor = new();
    private readonly Lock _gate = new();
    private readonly Timer _timer;

    private CompositePowerSource? _source;
    private ProcessSampler? _processes;

    private ActivityState _state = ActivityState.TrayOnly;
    private bool _onAc = true;
    private bool _running;
    private bool _disposed;

    private PowerSample? _anchorSample;
    private List<ProcessSample>? _anchorProcesses;
    private DateTimeOffset _nextProcessSample = DateTimeOffset.MinValue;
    private AttributionResult? _lastAttribution;
    private double? _idleBaseline;

    /// <summary>Creates a monitor that publishes onto the given dispatcher.</summary>
    public PowerMonitor(DispatcherQueue ui)
    {
        _ui = ui;
        _timer = new Timer(_ => Tick(), null, Timeout.InfiniteTimeSpan, Timeout.InfiniteTimeSpan);
    }

    /// <summary>Raised on the UI thread each time a reading completes.</summary>
    public event EventHandler<PowerSnapshot>? SnapshotReady;

    /// <summary>The power source stack, or null until the first tick has built it.</summary>
    public CompositePowerSource? Source => _source;

    /// <summary>The process sampler, or null until the first tick has built it.</summary>
    public ProcessSampler? Processes => _processes;

    /// <summary>
    /// What the user can currently see. Setting it re-arms the timer immediately so a
    /// flyout that just opened does not wait out the tray cadence before updating.
    /// </summary>
    public ActivityState State
    {
        get { lock (_gate) return _state; }
        set
        {
            lock (_gate)
            {
                if (_state == value) return;
                _state = value;
                if (!_running) return;
            }

            Arm(TimeSpan.Zero);
        }
    }

    /// <summary>Starts sampling.</summary>
    public void Start()
    {
        lock (_gate)
        {
            if (_running || _disposed) return;
            _running = true;
        }

        Arm(TimeSpan.Zero);
    }

    private void Arm(TimeSpan delay)
    {
        lock (_gate)
        {
            if (!_running || _disposed) return;
            _timer.Change(delay, Timeout.InfiniteTimeSpan);
        }
    }

    private void Tick()
    {
        SamplingCadence cadence;

        try
        {
            EnsureInitialized();

            var sample = _source?.Read();
            var now = sample?.Timestamp ?? DateTimeOffset.UtcNow;

            if (sample is not null) _onAc = sample.OnAc;

            cadence = SamplingPolicy.For(State, _onAc);

            UpdateIdleBaseline(sample?.SystemWatts);
            MaybeAttribute(sample, now, cadence);

            var severity = DrainClassifier.Classify(sample?.SystemWatts, _idleBaseline);
            var remaining = SystemPower.RemainingRuntime();

            var snapshot = new PowerSnapshot
            {
                Sample = sample,
                Severity = severity,
                TrayLabel = PowerFormatter.TrayLabel(sample?.SystemWatts),
                Tooltip = PowerFormatter.Tooltip(sample, remaining),
                Remaining = remaining,
                Attribution = _lastAttribution,
                IdleBaselineWatts = _idleBaseline,
            };

            _ui.TryEnqueue(() => SnapshotReady?.Invoke(this, snapshot));
        }
        catch (Exception ex) when (ex is not OutOfMemoryException)
        {
            // A transient counter failure must not take the tray icon down with it. The
            // next tick re-reads from scratch, and the icon keeps showing its last value
            // rather than a fabricated one.
            cadence = SamplingPolicy.For(State, _onAc);
        }

        if (SamplingPolicy.IsIdle(cadence))
        {
            // Modern standby. Any wake here is charged straight to the user's battery,
            // so the loop stops until an activity state change re-arms it.
            return;
        }

        Arm(cadence.Power);
    }

    private void EnsureInitialized()
    {
        if (_source is not null) return;

        var source = CompositePowerSource.CreateDefault();
        source.Prime(PrimeSettle);

        _processes = new ProcessSampler();
        _source = source;
    }

    /// <summary>
    /// Tracks the machine's own idle draw so the tray tint means something on hardware
    /// where 15 W is heavy and hardware where it is nothing.
    /// </summary>
    /// <remarks>
    /// The baseline drops instantly to any lower reading and rises only very slowly.
    /// A machine that has genuinely got quieter should be believed at once, whereas a
    /// machine that is busy should not be allowed to normalise its own busy state into
    /// the baseline within a single work session.
    /// </remarks>
    private void UpdateIdleBaseline(double? watts)
    {
        if (watts is not { } w || w <= 0 || double.IsNaN(w)) return;

        if (_idleBaseline is not { } baseline || w < baseline)
        {
            _idleBaseline = w;
            return;
        }

        _idleBaseline = baseline + ((w - baseline) * 0.0005);
    }

    private void MaybeAttribute(PowerSample? sample, DateTimeOffset now, SamplingCadence cadence)
    {
        if (sample is null || _processes is null) return;
        if (cadence.Process is not { } processInterval) return;
        if (now < _nextProcessSample) return;

        _nextProcessSample = now + processInterval;

        var current = _processes.Sample();

        if (_anchorSample is { } anchorSample
            && _anchorProcesses is { } anchorProcesses
            && now - anchorSample.Timestamp >= MinimumAttributionWindow)
        {
            _lastAttribution = _attributor.Attribute(anchorSample, sample, anchorProcesses, current);

            // The sampler reuses its buffer, so the anchor has to be a copy: the next
            // Sample() call would otherwise rewrite the very list being compared against.
            _anchorProcesses = [.. current];
            _anchorSample = sample;
            return;
        }

        if (_anchorSample is null)
        {
            _anchorProcesses = [.. current];
            _anchorSample = sample;
        }
    }

    /// <inheritdoc />
    public void Dispose()
    {
        lock (_gate)
        {
            if (_disposed) return;
            _disposed = true;
            _running = false;
        }

        _timer.Dispose();
        _source?.Dispose();
        _processes?.Dispose();
    }
}
