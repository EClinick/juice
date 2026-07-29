using System.Runtime.Versioning;
using Juice.App.Monitoring;
using Juice.App.Services;
using Juice.App.Tray;
using Juice.App.ViewModels;
using Juice.App.Views;
using Juice.Core.Power;
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

        _monitor = new PowerMonitor(_ui);
        _monitor.SnapshotReady += OnSnapshotReady;

        _activity.StateChanged += (_, state) => _monitor.State = state;

        _flyout = new FlyoutWindow(_flyoutViewModel);
        _flyout.SettingsRequested += (_, _) => ShowSettings();
        _flyout.ShellVisibilityChanged += OnWindowVisibilityChanged;

        CreateTrayIcon();

        _monitor.Start();
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

        if (isVisible && ReferenceEquals(sender, _flyout) && _latest is { } snapshot)
        {
            _flyoutViewModel.Update(snapshot, _rates.Current);
        }
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

        Exit();
    }
}
