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

    /// <summary>
    /// Height used only before the content has ever been laid out.
    /// </summary>
    /// <remarks>
    /// The window is sized from its content, so this is a seed rather than a design size.
    /// It is deliberately close to a typical populated flyout: the bottom edge is
    /// anchored, so any correction moves the top edge only, and seeding near the real
    /// answer keeps that correction too small to perceive.
    ///
    /// Measured against a first open with the app list reserved and no charts yet, which
    /// is the layout every fresh launch shows, so the seed is right for the one open that
    /// has no previous measurement to reuse.
    /// </remarks>
    private const int SeedHeightDips = 500;

    /// <summary>Gap between the flyout and the taskbar edge, matching shell flyouts.</summary>
    private const int GapDips = 12;

    /// <summary>Distinguishes this window's subclass from any other on the same window.</summary>
    private const uint SubclassId = 1;

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

    /// <summary>
    /// Content height in DIPs as of the last layout pass, or zero before the first one.
    /// </summary>
    private double _contentHeightDips;

    /// <summary>
    /// Held for the lifetime of the window so the callback is not collected while the
    /// subclass is still installed, which would tear the process down on the next message.
    /// </summary>
    private readonly NativeMethods.SubclassProc _subclassProc = OnSubclassMessage;

    /// <summary>Creates the flyout, hidden.</summary>
    public FlyoutWindow(FlyoutViewModel viewModel)
    {
        ViewModel = viewModel;
        InitializeComponent();

        Title = "Juice";

        var presenter = OverlappedPresenter.Create();

        // Asking for no border and no title bar is not enough on its own: the presenter
        // leaves WS_DLGFRAME and WS_EX_WINDOWEDGE set, and reasserts them if they are
        // cleared. The resulting frame is removed by the subclass installed below.
        presenter.SetBorderAndTitleBar(false, false);
        presenter.IsResizable = false;
        presenter.IsMaximizable = false;
        presenter.IsMinimizable = false;
        presenter.IsAlwaysOnTop = true;
        AppWindow.SetPresenter(presenter);

        AppWindow.IsShownInSwitchers = false;
        AppWindow.Hide();

        NativeMethods.SetWindowSubclass(
            WinRT.Interop.WindowNative.GetWindowHandle(this),
            _subclassProc,
            SubclassId,
            0);

        ApplyRoundedCorners();
        ApplyTaskbarTheme();

        // Closing the only window would end the process, and the flyout is opened and
        // dismissed dozens of times a day, so it is hidden instead and never closed.
        AppWindow.Closing += OnAppWindowClosing;
        Activated += OnActivated;

        // The severity and battery colours are resolved by function bindings, which run
        // once and keep whatever brush object the theme dictionary held at the time.
        // Re-running them is what makes the flyout follow a light or dark switch.
        if (Content is FrameworkElement root) root.ActualThemeChanged += OnActualThemeChanged;

        // Subscribed permanently, not per show. RootGrid is top aligned with auto rows, so
        // its arranged size is the content size, and it changes whenever the data does.
        RootGrid.SizeChanged += OnContentSizeChanged;

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
    /// <remarks>
    /// A reserved row announces that it is waiting rather than announcing three empty
    /// strings, which would otherwise read out as a run of commas.
    /// </remarks>
    public static string RowAnnouncement(bool isPlaceholder, string name, string watts, string cost)
        => isPlaceholder ? "Waiting for the first measurement" : $"{name}, {watts}, {cost}";

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
        var gap = (int)Math.Round(GapDips * scale);

        var display = anchor is { } rect
            ? DisplayArea.GetFromRect(
                new RectInt32(rect.Left, rect.Top, Math.Max(rect.Width, 1), Math.Max(rect.Height, 1)),
                DisplayAreaFallback.Nearest)
            : DisplayArea.Primary;

        var work = display.WorkArea;

        var height = OuterHeightFor(ClampToWorkArea(OpeningHeightDips(), work, scale), scale);

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

        // Applied after showing, not before. The presenter reasserts its own window styles
        // as part of Show, so a strip performed earlier is silently undone and the frame
        // comes back every time the flyout is reopened.
        ApplyRoundedCorners();

        // Parked on the root so no control looks preselected. Done after activation,
        // because activating the window restores focus to whatever last held it.
        RootGrid.Focus(FocusState.Programmatic);

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

    /// <summary>
    /// Themes the flyout content to match the taskbar rather than the app.
    /// </summary>
    /// <remarks>
    /// <para>
    /// Windows has two independent theme switches: <c>AppsUseLightTheme</c> drives
    /// application chrome, while <c>SystemUsesLightTheme</c> drives the taskbar. They can
    /// be set differently, and light apps on a dark taskbar is a supported configuration.
    /// </para>
    /// <para>
    /// A flyout anchored to the taskbar reads as part of the shell, so it follows the
    /// taskbar switch. Following the app switch instead would produce a light panel
    /// hanging off a dark taskbar, which is the same class of mistake as a tray icon that
    /// is invisible against the bar it sits on.
    /// </para>
    /// <para>
    /// Only the content theme is set here. The backdrop derives its colours from that, so
    /// nothing in this file needs to know what acrylic looks like in either theme. An
    /// earlier attempt to tune the acrylic by hand, setting tint and luminosity opacity on
    /// a DesktopAcrylicController without also supplying a per-theme tint colour, rendered
    /// a light panel on a fully dark system. Theme the content and let the material follow.
    /// </para>
    /// </remarks>
    private void ApplyTaskbarTheme()
    {
        if (Content is not FrameworkElement root) return;

        root.RequestedTheme = TaskbarAppearanceReader.Read().IsLightTheme
            ? ElementTheme.Light
            : ElementTheme.Dark;
    }

    /// <summary>
    /// Outer window height in physical pixels for a given content height in DIPs.
    /// </summary>
    /// <remarks>
    /// Content occupies the client area, but the window is moved and resized by its outer
    /// rectangle. The subclass claims the whole window rect as client area, so the two are
    /// currently the same, but the difference is measured rather than assumed so that this
    /// stays correct if the window ever regains a frame.
    /// </remarks>
    private int OuterHeightFor(double contentHeightDips, double scale)
    {
        var chrome = Math.Max(0, AppWindow.Size.Height - AppWindow.ClientSize.Height);
        return (int)Math.Round(contentHeightDips * scale) + chrome;
    }

    /// <summary>
    /// Content height to open at, in DIPs.
    /// </summary>
    /// <remarks>
    /// Whatever this returns is provisional. The window is corrected against the real
    /// arranged height by <see cref="OnContentSizeChanged"/> as soon as one exists, so the
    /// only job here is to open close enough that the correction is not perceptible.
    /// </remarks>
    private double OpeningHeightDips()
        => _contentHeightDips > 1 ? _contentHeightDips : SeedHeightDips;

    /// <summary>
    /// Caps a content height at what the monitor's work area can actually show.
    /// </summary>
    /// <remarks>
    /// Content taller than the screen would otherwise produce a window taller than the
    /// screen, whose top rows would sit off the display. The cap is what the ScrollViewer
    /// around the content exists for: past this height the list scrolls rather than
    /// running off the top edge, so nothing is hidden without a way to reach it.
    /// </remarks>
    /// <param name="contentHeightDips">Measured content height, in DIPs.</param>
    /// <param name="work">Work area of the monitor the flyout is on, in physical pixels.</param>
    /// <param name="scale">Monitor scale factor, physical pixels per DIP.</param>
    private static double ClampToWorkArea(double contentHeightDips, RectInt32 work, double scale)
    {
        // Two gaps: one below the window for the tray, one above it so the flyout never
        // butts against the top of the work area.
        var availableDips = (work.Height / scale) - (GapDips * 2);

        // A work area this small is not a real configuration, and clamping to it would
        // produce a window with no height at all.
        return availableDips > 0 ? Math.Min(contentHeightDips, availableDips) : contentHeightDips;
    }

    /// <summary>
    /// Keeps the window exactly as tall as its content.
    /// </summary>
    /// <remarks>
    /// <para>
    /// The root grid is top aligned and every row is auto sized, so its arranged height is
    /// the height of the content and not the height of the window containing it. That is
    /// what stops this feeding the window's own size back into itself.
    /// </para>
    /// <para>
    /// This stays subscribed for the lifetime of the window rather than for one layout
    /// pass after a show. Content genuinely changes height while the flyout is open, as
    /// charts appear, as the app ranking fills in and as rows come and go, and each of
    /// those has to move the window too.
    /// </para>
    /// <para>
    /// The bottom edge is held and the top edge moves. The flyout is anchored to the tray
    /// icon, so growing downward would push it under the taskbar and shrinking upward
    /// would detach it from the icon it belongs to.
    /// </para>
    /// </remarks>
    private void OnContentSizeChanged(object sender, SizeChangedEventArgs e)
    {
        var height = e.NewSize.Height;
        if (double.IsNaN(height) || double.IsInfinity(height) || height <= 1) return;

        _contentHeightDips = height;

        // There is nothing to reposition while hidden, but the measurement is still worth
        // keeping, because it is what the next open sizes itself from.
        if (!_isOpen) return;

        var hwnd = WinRT.Interop.WindowNative.GetWindowHandle(this);
        var scale = NativeMethods.GetDpiForWindow(hwnd) / 96.0;
        if (scale <= 0) scale = 1.0;

        var target = OuterHeightFor(
            ClampToWorkArea(
                height,
                DisplayArea.GetFromWindowId(AppWindow.Id, DisplayAreaFallback.Nearest).WorkArea,
                scale),
            scale);
        var current = AppWindow.Size.Height;
        // Sub-pixel disagreement is rounding, not a layout change. Acting on it would
        // resize the window on every single layout pass.
        if (Math.Abs(target - current) <= 2) return;

        var bottom = AppWindow.Position.Y + current;

        AppWindow.MoveAndResize(new RectInt32(
            AppWindow.Position.X,
            bottom - target,
            AppWindow.Size.Width,
            target));
    }

    /// <summary>
    /// Removes the window frame and rounds the corners.
    /// </summary>
    /// <remarks>
    /// <para>
    /// The light edge this removes was never the DWM border, which is why setting
    /// <c>DWMWA_BORDER_COLOR</c> to <c>DWMWA_COLOR_NONE</c> returned S_OK and changed
    /// nothing. Sampling the pixels at the window rect showed E3E3E3, FFFFFF and F0F0F0
    /// down the left and top and A0A0A0, 696969 down the right. Those are
    /// <c>COLOR_3DLIGHT</c>, <c>COLOR_3DHILIGHT</c>, <c>COLOR_3DFACE</c>,
    /// <c>COLOR_3DSHADOW</c> and <c>COLOR_3DDKSHADOW</c>: a classic raised 3D edge painted
    /// into the non-client area by <c>DefWindowProc</c>, before DWM composites anything
    /// and therefore beyond the reach of every DWM attribute. Measuring confirmed it, with
    /// the client rect inset three pixels from the window rect on every side.
    /// </para>
    /// <para>
    /// It cannot be removed by clearing <c>WS_DLGFRAME</c> and <c>WS_EX_WINDOWEDGE</c>,
    /// because <c>OverlappedPresenter</c> reasserts its own styles and the write is
    /// silently discarded; the styles read back unchanged even when set from another
    /// process. The non-client area is removed instead, in the subclass, so there is
    /// nothing left for the system to paint.
    /// </para>
    /// <para>
    /// The DWM calls stay. Rounding is what gives the flyout its shape once the frame is
    /// gone, and the border colour suppresses the separate one pixel Windows 11 border,
    /// which is a real DWM border and does honour the attribute.
    /// </para>
    /// </remarks>
    private void ApplyRoundedCorners()
    {
        var hwnd = WinRT.Interop.WindowNative.GetWindowHandle(this);

        var preference = NativeMethods.DWMWCP_ROUND;
        NativeMethods.DwmSetWindowAttribute(
            hwnd,
            NativeMethods.DWMWA_WINDOW_CORNER_PREFERENCE,
            ref preference,
            sizeof(int));

        var noBorder = NativeMethods.DWMWA_COLOR_NONE;
        NativeMethods.DwmSetWindowAttribute(
            hwnd,
            NativeMethods.DWMWA_BORDER_COLOR,
            ref noBorder,
            sizeof(int));
    }

    /// <summary>
    /// Claims the entire window rect as client area, leaving no frame to paint.
    /// </summary>
    /// <remarks>
    /// Answering <c>WM_NCCALCSIZE</c> with zero and the proposed rectangle untouched tells
    /// the window its client area is the whole window, which is the only reliable way to
    /// be rid of the system frame here given that the presenter overrides window styles.
    /// Every other message is passed on, so nothing else about the window changes.
    /// </remarks>
    private static nint OnSubclassMessage(
        nint hwnd,
        uint msg,
        nint wParam,
        nint lParam,
        nuint id,
        nint refData)
    {
        // wParam is FALSE for the simple form of the message, where lParam is a bare RECT
        // that also needs no adjustment, so both forms are answered the same way.
        if (msg == NativeMethods.WM_NCCALCSIZE) return 0;

        return NativeMethods.DefSubclassProc(hwnd, msg, wParam, lParam);
    }
}
