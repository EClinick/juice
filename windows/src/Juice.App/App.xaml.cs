using System.Runtime.Versioning;
using Juice.Core.Monitoring;
using Juice.App.Services;
using Juice.App.Tray;
using Juice.App.ViewModels;
using Juice.App.Views;
using Juice.Core.Insights;
using Juice.Core.Power;
using Juice.Core.Presentation;
using Juice.Core.Storage;
using Juice.Platform.Windows;
using Microsoft.UI.Dispatching;
using Microsoft.UI.Xaml;
using Windows.ApplicationModel.DataTransfer;

namespace Juice.App;

/// <summary>
/// Application entry point and owner of everything with a lifetime.
/// </summary>
/// <remarks>
/// <para>
/// Juice has no main window. Its primary surface is the notification area icon, and the
/// flyout and settings windows are created hidden and shown on demand, so the process
/// outlives every window it owns. That is why both windows cancel their own close and
/// hide instead, and why quitting goes through <see cref="Shutdown"/> rather than through
/// a window closing.
/// </para>
/// </remarks>
[SupportedOSPlatform("windows10.0.19041.0")]
public partial class App : Application
{
    private readonly ActivityStateTracker _activity = new();

    private DispatcherQueue _ui = null!;
    private AppIconService _icons = null!;
    private FlyoutViewModel _flyoutViewModel = null!;
    private JuiceSettings _settings = null!;
    private RateService _rates = null!;
    private PowerMonitor _monitor = null!;

    /// <summary>
    /// Local history database. Null when it could not be opened, in which case Juice
    /// still measures but has no history to chart.
    /// </summary>
    private JuiceStore? _store;

    /// <summary>Pending idle trim, replaced each time a window closes.</summary>
    private Timer? _idleTrim;

    /// <summary>How long after the last window closes to collect and trim.</summary>
    private static readonly TimeSpan IdleTrimDelay = TimeSpan.FromSeconds(5);
    private TrayIcon _tray = null!;
    private FlyoutWindow _flyout = null!;
    private SettingsWindow? _settingsWindow;
    private PowerSnapshot? _latest;
    private bool _isExiting;

    /// <summary>Initialises the singleton application object.</summary>
    public App() => InitializeComponent();

    /// <summary>Invoked when the application is launched.</summary>
    /// <param name="args">Details about the launch request and process.</param>
    protected override void OnLaunched(LaunchActivatedEventArgs args)
    {
        _ui = DispatcherQueue.GetForCurrentThread();

        _settings = new JuiceSettings();
        _rates = new RateService(_settings);

        _icons = new AppIconService(_ui);
        _flyoutViewModel = new FlyoutViewModel(_icons);

        _store = HistoryStoreFactory.TryOpen();
        _monitor = new PowerMonitor(
            CompositePowerSource.CreateDefault,
            () => new ProcessSampler(),
            new SystemPowerStatusReader(),
            _store,
            action => _ui.TryEnqueue(() => action()));
        _monitor.SnapshotReady += OnSnapshotReady;

        _activity.StateChanged += (_, state) =>
        {
            _monitor.State = state;

            // Anything other than Foreground means nothing is on screen, so whatever the
            // last visible window needed can go back to the operating system. This is the
            // hook that matters in practice: a tray app spends almost all of its life
            // arriving here and never opening a window at all.
            if (state != ActivityState.Foreground) ScheduleIdleTrim();
        };

        _flyout = new FlyoutWindow(_flyoutViewModel);
        _flyout.SettingsRequested += (_, _) => ShowSettings();
        _flyout.ShellVisibilityChanged += OnWindowVisibilityChanged;

        CreateTrayIcon();

        _monitor.Start();

        // First trim after startup settles. Launch touches a great deal that is never
        // needed again: XAML parsing, resource dictionaries, JIT for paths that run once.
        ScheduleIdleTrim();
    }

    private void CreateTrayIcon()
    {
        _tray = new TrayIcon();

        _tray.Selected += (_, _) => ToggleFlyout();
        _tray.CommandInvoked += (_, command) => Invoke(command);
        _tray.AppearanceChanged += (_, _) => RedrawTrayIcon();
        _tray.DisplayStateChanged += (_, isDisplayOn) => _activity.IsDisplayOff = !isDisplayOn;
        _tray.SessionLockChanged += (_, isLocked) => _activity.IsSessionLocked = isLocked;
        _tray.SuspendStateChanged += (_, isSuspended) => _activity.IsSuspended = isSuspended;

        // Place the icon before the first reading exists. The placeholder glyph says
        // "not measured yet", which is true, where a zero would not be.
        _tray.Update(null, DrainSeverity.Unknown, "Juice");
    }

    private void OnSnapshotReady(object? sender, PowerSnapshot snapshot)
    {
        _latest = snapshot;

        _tray.Update(snapshot.Sample?.SystemWatts, snapshot.Severity, snapshot.Tooltip);

        // The flyout is the only consumer of the expensive half of a snapshot, so it is
        // only rebuilt when somebody can see it.
        if (_flyout.IsOpen) _flyoutViewModel.Update(snapshot, _rates.Current);
    }

    private void RedrawTrayIcon()
    {
        // The same shell notification that changes the tray ink also changes what the
        // flyout has to sit against.
        _flyout.RefreshSystemAppearance();

        if (_latest is { } snapshot)
        {
            _tray.Update(snapshot.Sample?.SystemWatts, snapshot.Severity, snapshot.Tooltip);
            return;
        }

        _tray.Update(null, DrainSeverity.Unknown, "Juice");
    }

    private void ToggleFlyout()
    {
        if (_flyout.IsOpen)
        {
            _flyout.HideFlyout();
            return;
        }

        // Fill the flyout from the last reading before it appears, so it never flashes
        // empty on the way in.
        if (_latest is { } snapshot) _flyoutViewModel.Update(snapshot, _rates.Current);

        _flyout.ShowAt(_tray.TryGetIconRect());
    }

    private void ShowSettings()
    {
        _settingsWindow ??= CreateSettingsWindow();
        _settingsWindow.ShowSettings();
    }

    private SettingsWindow CreateSettingsWindow()
    {
        var window = new SettingsWindow(
            new SettingsViewModel(_rates, _monitor),
            BuildDiagnostics);

        window.ShellVisibilityChanged += OnWindowVisibilityChanged;
        return window;
    }

    private void OnWindowVisibilityChanged(object? sender, bool isVisible)
    {
        // Sampling runs at its fastest only while a window is on screen. Either window
        // being visible counts, so the flag is recomputed from both rather than set.
        _activity.IsWindowVisible = _flyout.IsOpen || _settingsWindow is { Visible: true };

        // Nothing on screen means the XAML tree, decoded icons and layout scratch that a
        // visible window needed are all dead weight until the next open. Give the runtime
        // a moment to settle, then collect and hand the pages back.
        if (!_activity.IsWindowVisible) ScheduleIdleTrim();

        if (isVisible && ReferenceEquals(sender, _flyout) && _latest is { } snapshot)
        {
            _flyoutViewModel.Update(snapshot, _rates.Current);
        }

        if (isVisible && ReferenceEquals(sender, _flyout))
        {
            RefreshHistory();
        }
    }

    /// <summary>
    /// Rebuilds the history chart from the store.
    /// </summary>
    /// <remarks>
    /// <para>
    /// Only refreshed when the flyout opens, not on every sampling tick. The chart is
    /// hour-resolution, so it cannot visibly change more than once an hour, and querying
    /// it on a five second cadence would be pure waste in a process that is trying not to
    /// show up in its own energy rankings.
    /// </para>
    /// <para>
    /// The window is the last 24 hours and is passed to the builder explicitly, which is
    /// what pins the axis. A machine that has only been recording for twenty minutes
    /// still shows a 24 hour axis with the rest drawn as gaps, rather than a full-looking
    /// chart of twenty minutes.
    /// </para>
    /// </remarks>
    private void RefreshHistory()
    {
        if (_store is null)
        {
            _flyoutViewModel.UpdateHistory(null);
            _flyoutViewModel.UpdateCharge(null);
            _flyoutViewModel.UpdateInsights(BuildInsights());
            return;
        }

        try
        {
            var to = DateTimeOffset.Now;
            var from = to.AddHours(-24);
            var buckets = _store.SystemEnergyBetween(from, to);
            _flyoutViewModel.UpdateHistory(EnergyChartBuilder.Build(buckets, from, to));
            _flyoutViewModel.UpdateCharge(
                ChargeTimelineBuilder.Build(_store.BatteryBetween(from, to), from, to));
            _flyoutViewModel.UpdateInsights(BuildInsights());
        }
        catch (Exception ex) when (ex is Microsoft.Data.Sqlite.SqliteException or IOException or InvalidOperationException)
        {
            // History is a nicety; a failure to read it must not stop the flyout opening.
            _flyoutViewModel.UpdateHistory(null);
            _flyoutViewModel.UpdateCharge(null);
            _flyoutViewModel.UpdateInsights([]);
        }
    }

    /// <summary>
    /// Generates the observations shown above the app ranking.
    /// </summary>
    /// <remarks>
    /// Reads a fortnight rather than the day the charts show, because the engine judges an
    /// app against its own earlier behaviour and a single day gives it nothing to compare
    /// against. Live draw and the session's idle baseline are passed in so that the drain
    /// observation works even on a machine with no history at all.
    /// </remarks>
    private IReadOnlyList<Insight> BuildInsights()
    {
        try
        {
            return InsightsReport.Build(
                _store,
                DateTimeOffset.Now,
                _latest?.Sample?.SystemWatts,
                _latest?.IdleBaselineWatts);
        }
        catch (Exception ex) when (ex is Microsoft.Data.Sqlite.SqliteException or IOException or InvalidOperationException)
        {
            return [];
        }
    }

    /// <summary>
    /// Collects and trims the working set a short while after the last window closes.
    /// </summary>
    /// <remarks>
    /// Delayed rather than immediate because closing a window is followed by teardown that
    /// itself allocates, and trimming into that only forces the pages straight back in.
    /// Debounced because opening and closing the flyout repeatedly should cost one trim,
    /// not one per close.
    /// </remarks>
    private void ScheduleIdleTrim()
    {
        _idleTrim?.Dispose();
        _idleTrim = new Timer(
            _ =>
            {
                if (_activity.IsWindowVisible) return;
                ProcessMemory.TrimAfterIdle();
            },
            null,
            IdleTrimDelay,
            Timeout.InfiniteTimeSpan);
    }

    private void Invoke(TrayCommand command)
    {
        switch (command)
        {
            case TrayCommand.Open:
                if (!_flyout.IsOpen) ToggleFlyout();
                break;

            case TrayCommand.Settings:
                ShowSettings();
                break;

            case TrayCommand.CopyDiagnostics:
                CopyDiagnostics();
                break;

            case TrayCommand.Exit:
                Shutdown();
                break;
        }
    }

    private void CopyDiagnostics()
    {
        var package = new DataPackage { RequestedOperation = DataPackageOperation.Copy };
        package.SetText(BuildDiagnostics());
        Clipboard.SetContent(package);
    }

    private string BuildDiagnostics() => DiagnosticsReport.Build(_monitor, _rates, _latest);

    private void Shutdown()
    {
        if (_isExiting) return;
        _isExiting = true;

        // The windows veto their own close so that hiding them never ends the process.
        // Quitting is the one case where that veto has to be lifted.
        _flyout.AllowClose = true;
        if (_settingsWindow is { } settings) settings.AllowClose = true;

        _tray.Dispose();
        _monitor.Dispose();
        _icons.Dispose();
        _store?.Dispose();
        _idleTrim?.Dispose();

        Exit();
    }
}
