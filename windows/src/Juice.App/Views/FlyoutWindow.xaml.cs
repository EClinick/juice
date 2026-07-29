using System.Runtime.Versioning;
using Juice.App.Interop;
using Juice.App.ViewModels;
using Juice.Core.Power;
using Juice.Core.Presentation;
using Juice.Platform.Windows;
using Microsoft.UI.Windowing;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Media;
using Windows.Graphics;
using Windows.UI;

namespace Juice.App.Views;

/// <summary>
/// The tray flyout: the live readout that appears above the notification area icon.
/// </summary>
/// <remarks>
/// <para>
/// This is a borderless always-on-top window rather than a XAML <c>Flyout</c>, because a
/// flyout needs a XAML element to hang off and the notification area icon is not one.
/// It behaves like a shell flyout instead: it is positioned against the icon's screen
/// rectangle, it dismisses on deactivation, and it is hidden rather than closed so that
/// hiding it never ends the process.
/// </para>
/// </remarks>
[SupportedOSPlatform("windows10.0.19041.0")]
public sealed partial class FlyoutWindow : Window
{
    /// <summary>Design size in device independent pixels, scaled to the monitor at show time.</summary>
    private const int WidthDips = 360;

    private const int HeightDips = 600;

    /// <summary>Gap between the flyout and the taskbar edge, matching shell flyouts.</summary>
    private const int GapDips = 12;

    /// <summary>
    /// Deactivations arriving within this window of a show are ignored while the flyout
    /// has never held focus. Opening from the tray overflow tears down the shell's own
    /// flyout a moment after the click, and the resulting deactivation would otherwise
    /// close Juice's flyout the instant it appeared.
    /// </summary>
    private static readonly TimeSpan ActivationSettle = TimeSpan.FromMilliseconds(750);

    private DateTimeOffset _shownAt = DateTimeOffset.MinValue;
    private bool _isOpen;
    private bool _hasHeldFocus;

    /// <summary>Creates the flyout, hidden.</summary>
    public FlyoutWindow(FlyoutViewModel viewModel)
    {
        ViewModel = viewModel;
        InitializeComponent();

        Title = "Juice";

        var presenter = OverlappedPresenter.Create();
        presenter.SetBorderAndTitleBar(false, false);
        presenter.IsResizable = false;
        presenter.IsMaximizable = false;
        presenter.IsMinimizable = false;
        presenter.IsAlwaysOnTop = true;
        AppWindow.SetPresenter(presenter);

        AppWindow.IsShownInSwitchers = false;
        AppWindow.Hide();

        ApplyRoundedCorners();

        // Closing the only window would end the process, and the flyout is opened and
        // dismissed dozens of times a day, so it is hidden instead and never closed.
        AppWindow.Closing += OnAppWindowClosing;
        Activated += OnActivated;

        // The severity and battery colours are resolved by function bindings, which run
        // once and keep whatever brush object the theme dictionary held at the time.
        // Re-running them is what makes the flyout follow a light or dark switch.
        if (Content is FrameworkElement root) root.ActualThemeChanged += OnActualThemeChanged;

        RefreshSystemAppearance();
    }

    private void OnActualThemeChanged(FrameworkElement sender, object args)
    {
        Bindings.Update();

        // The tint is mixed against the surface underneath it, and that surface just
        // changed colour.
        RefreshSystemAppearance();
    }

    /// <summary>
    /// Matches the flyout to the taskbar's current appearance.
    /// </summary>
    /// <remarks>
    /// <para>
    /// The flyout opens directly above the taskbar and reads as part of it. When the user
    /// has "Show accent color on Start and taskbar" on, a neutral acrylic panel stops
    /// looking like an extension of the shell and starts looking like a foreign window
    /// parked on top of it, so the same accent is layered over the backdrop.
    /// </para>
    /// <para>
    /// Called again whenever the shell reports an appearance change, because the accent
    /// colour, the accent-on-taskbar switch and the theme can all move underneath a
    /// running process.
    /// </para>
    /// </remarks>
    public void RefreshSystemAppearance()
    {
        var appearance = TaskbarAppearanceReader.Read();

        if (!appearance.AccentOnTaskbar)
        {
            // An untinted taskbar is neutral, and so is the acrylic already.
            RootGrid.Background = null;
            return;
        }

        var accent = appearance.Accent;

        // The accent is the user's colour, not one chosen to be legible, so how much of
        // it the surface can take depends on which way its brightness runs.
        var isSurfaceLight = Content is FrameworkElement { ActualTheme: ElementTheme.Light };
        var alpha = SurfaceTint.AlphaFor(accent.Luminance, isSurfaceLight);

        RootGrid.Background = new SolidColorBrush(
            Color.FromArgb((byte)Math.Round(alpha * byte.MaxValue), accent.R, accent.G, accent.B));
    }

    /// <summary>The view model bound by the XAML.</summary>
    public FlyoutViewModel ViewModel { get; }

    /// <summary>Raised when the user asked for the settings window.</summary>
    public event EventHandler? SettingsRequested;

    /// <summary>Raised whenever the flyout becomes visible or hidden.</summary>
    public event EventHandler<bool>? ShellVisibilityChanged;

    /// <summary>True while the flyout is on screen.</summary>
    public bool IsOpen => _isOpen;

    /// <summary>
    /// Lifts the close veto. Only the application shutdown path sets this; everything
    /// else hides the window, because closing the last window would end the process and
    /// take the tray icon with it.
    /// </summary>
    public bool AllowClose { get; set; }

    /// <summary>
    /// Caption describing how much of the charted window was actually recorded.
    /// </summary>
    /// <remarks>
    /// Shown beneath every chart, so a partially recorded window is never presented as a
    /// complete one. The wording comes from the core library rather than being composed
    /// here, so the caption cannot drift away from what the chart actually drew.
    /// </remarks>
    public static string HistoryCaption(EnergyChartSeries? series)
        => series?.CoverageCaption() ?? string.Empty;

    /// <summary>Caption describing breaks in the charge timeline.</summary>
    public static string ChargeCaption(ChargeTimeline? timeline)
        => timeline?.CoverageCaption() ?? string.Empty;

    /// <summary>Maps a flag to a visibility, for <c>x:Bind</c> without a converter.</summary>
    public static Visibility ToVisibility(bool value)
        => value ? Visibility.Visible : Visibility.Collapsed;

    /// <summary>Inverse of <see cref="ToVisibility"/>, for <c>x:Bind</c> without a converter.</summary>
    public static Visibility ToVisibilityInverse(bool value)
        => value ? Visibility.Collapsed : Visibility.Visible;

    /// <summary>Shows an element only when there is something for it to display.</summary>
    public static Visibility ToVisibilityIfPresent(object? value)
        => value is null ? Visibility.Collapsed : Visibility.Visible;

    /// <summary>
    /// Foreground for the hero readout, keyed to how hard the machine is drawing so the
    /// flyout and the tray icon agree at a glance.
    /// </summary>
    /// <remarks>
    /// Unknown deliberately stays the muted text colour. Any of the three signal colours
    /// would assert a classification that no measurement supports.
    /// </remarks>
    public static Brush? ReadoutBrush(DrainSeverity severity)
        => ThemeBrush(severity switch
        {
            DrainSeverity.Low => "SystemFillColorSuccessBrush",
            DrainSeverity.Normal => "AccentTextFillColorPrimaryBrush",
            DrainSeverity.High => "SystemFillColorCautionBrush",
            _ => "TextFillColorSecondaryBrush",
        });

    /// <summary>
    /// Foreground for the battery percentage, which turns into a warning only when the
    /// machine is actually running the battery down.
    /// </summary>
    public static Brush? BatteryBrush(BatteryLevel level)
        => ThemeBrush(level switch
        {
            BatteryLevel.Critical => "SystemFillColorCriticalBrush",
            BatteryLevel.Low => "SystemFillColorCautionBrush",
            _ => "TextFillColorPrimaryBrush",
        });

    /// <summary>Star width of the filled part of a ranking bar.</summary>
    public static GridLength BarLength(double fraction)
        => new(Math.Clamp(fraction, 0, 1), GridUnitType.Star);

    /// <summary>Star width of the empty remainder of a ranking bar.</summary>
    public static GridLength BarRemainderLength(double fraction)
        => new(1 - Math.Clamp(fraction, 0, 1), GridUnitType.Star);

    /// <summary>
    /// Resolves a named brush from the active theme dictionary.
    /// </summary>
    /// <remarks>
    /// The lookup happens per evaluation rather than once, and the bindings that call it
    /// are re-run on <see cref="FrameworkElement.ActualThemeChanged"/>, because the theme
    /// dictionaries hand back a different brush object per theme.
    /// </remarks>
    private static Brush? ThemeBrush(string key)
        => Application.Current.Resources.TryGetValue(key, out var value) ? value as Brush : null;

    /// <summary>
    /// Builds what a screen reader says for the hero readout.
    /// </summary>
    /// <remarks>
    /// The visible text is only the number, so an automation name of "System power draw"
    /// alone would announce the label and swallow the measurement. Both are joined here
    /// instead.
    /// </remarks>
    public static string ReadoutAnnouncement(string watts, string source)
        => $"System power draw {watts}, {source}";

    /// <summary>
    /// Builds what a screen reader says for one energy row, so the list does not announce
    /// the view model's type name.
    /// </summary>
    public static string RowAnnouncement(string name, string watts, string cost)
        => $"{name}, {watts}, {cost}";

    /// <summary>
    /// Shows the flyout above <paramref name="anchor"/>, the tray icon's screen
    /// rectangle in physical pixels, or in the corner of the work area when the shell
    /// will not say where the icon is.
    /// </summary>
    internal void ShowAt(NativeMethods.RECT? anchor)
    {
        var hwnd = WinRT.Interop.WindowNative.GetWindowHandle(this);
        var scale = NativeMethods.GetDpiForWindow(hwnd) / 96.0;
        if (scale <= 0) scale = 1.0;

        var width = (int)Math.Round(WidthDips * scale);
        var height = (int)Math.Round(HeightDips * scale);
        var gap = (int)Math.Round(GapDips * scale);

        var display = anchor is { } rect
            ? DisplayArea.GetFromRect(
                new RectInt32(rect.Left, rect.Top, Math.Max(rect.Width, 1), Math.Max(rect.Height, 1)),
                DisplayAreaFallback.Nearest)
            : DisplayArea.Primary;

        var work = display.WorkArea;

        int x, y;
        if (anchor is { } icon)
        {
            // Right edge aligned with the icon, sitting just above it. That is where the
            // shell puts its own tray flyouts, so it lands where the user expects.
            x = icon.Right - width;
            y = icon.Top - height - gap;
        }
        else
        {
            x = work.X + work.Width - width - gap;
            y = work.Y + work.Height - height - gap;
        }

        x = Math.Clamp(x, work.X + gap, Math.Max(work.X + gap, work.X + work.Width - width - gap));
        y = Math.Clamp(y, work.Y + gap, Math.Max(work.Y + gap, work.Y + work.Height - height - gap));

        AppWindow.MoveAndResize(new RectInt32(x, y, width, height));

        _shownAt = DateTimeOffset.UtcNow;
        _isOpen = true;
        _hasHeldFocus = false;

        AppWindow.Show(true);
        Activate();
        NativeMethods.SetForegroundWindow(hwnd);

        ShellVisibilityChanged?.Invoke(this, true);
    }

    /// <summary>Hides the flyout without closing it.</summary>
    public void HideFlyout()
    {
        if (!_isOpen) return;

        _isOpen = false;
        AppWindow.Hide();
        ShellVisibilityChanged?.Invoke(this, false);
    }

    /// <summary>Shows the flyout if hidden, hides it if shown.</summary>
    internal void Toggle(NativeMethods.RECT? anchor)
    {
        if (_isOpen) HideFlyout();
        else ShowAt(anchor);
    }

    private void OnActivated(object sender, WindowActivatedEventArgs args)
    {
        if (args.WindowActivationState != WindowActivationState.Deactivated)
        {
            _hasHeldFocus = true;
            return;
        }

        if (!_isOpen) return;

        // Once the flyout has actually held focus, any loss of it is the user clicking
        // away and the flyout should go. Before that it is the shell finishing with its
        // own tray flyout, which is not a dismissal.
        if (!_hasHeldFocus && DateTimeOffset.UtcNow - _shownAt < ActivationSettle) return;

        HideFlyout();
    }

    private void OnAppWindowClosing(AppWindow sender, AppWindowClosingEventArgs args)
    {
        if (AllowClose) return;

        args.Cancel = true;
        HideFlyout();
    }

    private void OnOpenSettingsClick(object sender, RoutedEventArgs e)
    {
        HideFlyout();
        SettingsRequested?.Invoke(this, EventArgs.Empty);
    }

    private void ApplyRoundedCorners()
    {
        var hwnd = WinRT.Interop.WindowNative.GetWindowHandle(this);
        var preference = NativeMethods.DWMWCP_ROUND;

        NativeMethods.DwmSetWindowAttribute(
            hwnd,
            NativeMethods.DWMWA_WINDOW_CORNER_PREFERENCE,
            ref preference,
            sizeof(int));
    }
}
