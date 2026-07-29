using System.Runtime.Versioning;
using Juice.App.Interop;
using Juice.App.ViewModels;
using Microsoft.UI.Windowing;
using Microsoft.UI.Xaml;
using Windows.ApplicationModel.DataTransfer;
using Windows.Graphics;

namespace Juice.App.Views;

/// <summary>
/// Settings and diagnostics.
/// </summary>
/// <remarks>
/// Like the flyout, this window is hidden rather than closed. Juice has no main window,
/// so closing the last one would end the process and take the tray icon with it.
/// </remarks>
[SupportedOSPlatform("windows10.0.19041.0")]
public sealed partial class SettingsWindow : Window
{
    private const int WidthDips = 640;
    private const int HeightDips = 720;

    private readonly Func<string> _diagnosticsFactory;

    /// <summary>Creates the settings window, hidden.</summary>
    /// <param name="viewModel">Backing view model.</param>
    /// <param name="diagnosticsFactory">
    /// Produces the diagnostics report on demand, so the window never holds the monitor
    /// or the sampler itself.
    /// </param>
    public SettingsWindow(SettingsViewModel viewModel, Func<string> diagnosticsFactory)
    {
        ViewModel = viewModel;
        _diagnosticsFactory = diagnosticsFactory;

        InitializeComponent();

        Title = "Juice settings";
        AppWindow.SetIcon("Assets/AppIcon.ico");

        ResizeToContent();

        AppWindow.Closing += OnAppWindowClosing;
    }

    /// <summary>The view model bound by the XAML.</summary>
    public SettingsViewModel ViewModel { get; }

    /// <summary>
    /// Lifts the close veto. Only the application shutdown path sets this.
    /// </summary>
    public bool AllowClose { get; set; }

    /// <summary>Raised whenever the window becomes visible or hidden.</summary>
    public event EventHandler<bool>? ShellVisibilityChanged;

    /// <summary>True when a string has content, for <c>x:Bind</c> without a converter.</summary>
    public static bool HasText(string? value) => !string.IsNullOrWhiteSpace(value);

    /// <summary>Brings the window up, refreshing the values that change while it is closed.</summary>
    public async void ShowSettings()
    {
        ViewModel.RefreshDiagnostics();
        CopyConfirmationText.Text = string.Empty;

        AppWindow.Show(true);
        Activate();

        ShellVisibilityChanged?.Invoke(this, true);

        await ViewModel.LoadStartupStateAsync();
    }

    /// <summary>Hides the window without closing it.</summary>
    public void HideSettings()
    {
        AppWindow.Hide();
        ShellVisibilityChanged?.Invoke(this, false);
    }

    private void ResizeToContent()
    {
        var hwnd = WinRT.Interop.WindowNative.GetWindowHandle(this);
        var scale = NativeMethods.GetDpiForWindow(hwnd) / 96.0;
        if (scale <= 0) scale = 1.0;

        AppWindow.Resize(new SizeInt32(
            (int)Math.Round(WidthDips * scale),
            (int)Math.Round(HeightDips * scale)));

        AppWindow.Hide();
    }

    private void OnAppWindowClosing(AppWindow sender, AppWindowClosingEventArgs args)
    {
        if (AllowClose) return;

        args.Cancel = true;
        HideSettings();
    }

    private void OnRefreshDiagnosticsClick(object sender, RoutedEventArgs e)
    {
        ViewModel.RefreshDiagnostics();
        CopyConfirmationText.Text = string.Empty;
    }

    private void OnCopyDiagnosticsClick(object sender, RoutedEventArgs e)
    {
        var package = new DataPackage { RequestedOperation = DataPackageOperation.Copy };
        package.SetText(_diagnosticsFactory());

        Clipboard.SetContent(package);
        CopyConfirmationText.Text = "Diagnostics copied to the clipboard.";
    }
}
