using Juice.Core.Attribution;
using Juice.Core.Power;
using Juice.Core.Storage;

namespace Juice.Core.Monitoring;

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

    /// <summary>
    /// How often a battery observation is persisted for the charge timeline.
    /// </summary>
    private static readonly TimeSpan BatterySampleInterval = TimeSpan.FromMinutes(1);

    /// <summary>How often expired battery samples are swept.</summary>
    private static readonly TimeSpan PruneInterval = TimeSpan.FromHours(6);

    private readonly Func<IPowerSource> _sourceFactory;
    private readonly Func<IProcessSampler> _processFactory;
    private readonly IBatteryRuntimeReader? _runtime;
    private readonly Action<Action> _post;
    private readonly EnergyAttributor _attributor;
    private readonly Lock _gate = new();
    private readonly Timer _timer;
    private readonly JuiceStore? _store;

    private IPowerSource? _source;
    private IProcessSampler? _processes;

    private ActivityState _state = ActivityState.TrayOnly;
    private bool _onAc = true;
    private bool _running;
    private bool _disposed;

    private PowerSample? _anchorSample;
    private List<ProcessSample>? _anchorProcesses;
    private DateTimeOffset _nextProcessSample = DateTimeOffset.MinValue;
    private DateTimeOffset _nextBatterySample = DateTimeOffset.MinValue;
    private DateTimeOffset _nextPrune = DateTimeOffset.MinValue;
    private AttributionResult? _lastAttribution;
    private double? _idleBaseline;

    /// <summary>Creates a monitor over the given platform pieces.</summary>
    /// <param name="sourceFactory">
    /// Builds the power source, called once on the first tick rather than in the
    /// constructor so that a host can be created before any hardware is touched.
    /// </param>
    /// <param name="processFactory">Builds the process table sampler.</param>
    /// <param name="runtime">
    /// Optional supplier of the platform's own remaining-runtime estimate.
    /// </param>
    /// <param name="store">
    /// Optional history store. When supplied, every attributed interval and a periodic
    /// battery sample are persisted, which is what allows the charts to show anything
    /// beyond the current process lifetime.
    /// </param>
    /// <param name="post">
    /// Marshals the snapshot event onto whichever thread the host wants it on. A user
    /// interface passes its dispatcher. A host whose own loop is the sampling thread, such
    /// as the tray agent or a headless collector, passes nothing and the event is raised
    /// inline.
    /// </param>
    /// <param name="displayNameSelector">
    /// Turns a process into the name shown to a person. Optional, and without it the
    /// ranking shows raw process names, which are accurate and hard to read.
    /// </param>
    public PowerMonitor(
        Func<IPowerSource> sourceFactory,
        Func<IProcessSampler> processFactory,
        IBatteryRuntimeReader? runtime = null,
        JuiceStore? store = null,
        Action<Action>? post = null,
        Func<ProcessSample, string>? displayNameSelector = null)
    {
        _sourceFactory = sourceFactory;
        _processFactory = processFactory;
        _runtime = runtime;
        _store = store;
        _post = post ?? (action => action());
        _attributor = new EnergyAttributor(displayNameSelector: displayNameSelector);
        _timer = new Timer(_ => Tick(), null, Timeout.InfiniteTimeSpan, Timeout.InfiniteTimeSpan);
    }

    /// <summary>Raised each time a reading completes, on whichever thread <c>post</c> chose.</summary>
    public event EventHandler<PowerSnapshot>? SnapshotReady;

    /// <summary>The power source stack, or null until the first tick has built it.</summary>
    public IPowerSource? Source => _source;

    /// <summary>The process sampler, or null until the first tick has built it.</summary>
    public IProcessSampler? Processes => _processes;

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

                // Re-arming the timer alone is not enough. The process sample is gated
                // separately by _nextProcessSample, which was set using the previous, much
                // slower cadence, so a flyout opened while the tray cadence was in force
                // would keep returning early until that deadline passed. On AC that is a
                // thirty second wait before the app list shows anything, which reads as
                // the app being broken rather than as it being frugal.
                //
                // Clearing the deadline lets the next tick sample immediately. It is safe
                // because attribution still requires the anchor to be at least
                // MinimumAttributionWindow old, so this cannot manufacture a reading from
                // too short an interval.
                _nextProcessSample = DateTimeOffset.MinValue;

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
            MaybeRecordBattery(sample, now);
            MaybePrune(now);

            var severity = DrainClassifier.Classify(sample?.SystemWatts, _idleBaseline);
            var remaining = _runtime?.RemainingRuntime();

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

            _post(() => SnapshotReady?.Invoke(this, snapshot));
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

        var source = _sourceFactory();
        source.Prime(PrimeSettle);

        _processes = _processFactory();
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
            var result = _attributor.Attribute(anchorSample, sample, anchorProcesses, current);
            _lastAttribution = result;

            // RecordInterval rejects anything longer than the continuity window, so a
            // machine returning from sleep cannot dump hours of accumulated energy into
            // the hour it woke up in. The rejection is silent and correct: that energy is
            // real but unattributable to any particular hour.
            TryRecord(() => _store?.RecordInterval(result));

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

    /// <summary>
    /// Persists a battery observation for the charge timeline.
    /// </summary>
    /// <remarks>
    /// Deliberately much less frequent than the power cadence. The timeline is drawn over
    /// hours or days, so a sample a minute is already finer than anything the chart can
    /// show, and writing one per tick would grow the database for no visible benefit.
    /// </remarks>
    private void MaybeRecordBattery(PowerSample? sample, DateTimeOffset now)
    {
        if (sample?.BatteryPercent is null || _store is null) return;
        if (now < _nextBatterySample) return;

        _nextBatterySample = now + BatterySampleInterval;
        TryRecord(() => _store.RecordBatterySample(sample));
    }

    /// <summary>
    /// Drops battery samples past their retention window.
    /// </summary>
    /// <remarks>
    /// Hourly energy is never pruned. It is small, and it is the only copy of history
    /// that outlives what the operating system itself keeps.
    /// </remarks>
    private void MaybePrune(DateTimeOffset now)
    {
        if (_store is null || now < _nextPrune) return;

        _nextPrune = now + PruneInterval;
        TryRecord(() => _store.Prune(now));
    }

    /// <summary>
    /// Runs a store write, swallowing storage failures.
    /// </summary>
    /// <remarks>
    /// A locked or corrupt database must not take down live measurement. Losing history
    /// is bad; losing the tray readout because history could not be written is worse, and
    /// the live path does not depend on the store at all.
    /// </remarks>
    private static void TryRecord(Action write)
    {
        try
        {
            write();
        }
        catch (Exception ex) when (ex is Microsoft.Data.Sqlite.SqliteException or IOException or InvalidOperationException)
        {
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

        // The interfaces do not require disposability, because not every implementation
        // holds an operating system handle. The Windows ones do, so ask.
        (_source as IDisposable)?.Dispose();
        (_processes as IDisposable)?.Dispose();
    }
}
