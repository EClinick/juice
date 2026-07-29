using System.Drawing;
using System.Runtime.InteropServices;
using System.Runtime.Versioning;
using Juice.App.Interop;
using Juice.Core.Power;
using Juice.Platform.Windows;

namespace Juice.App.Tray;

/// <summary>
/// The notification area icon, and the hidden window that carries every system
/// notification Juice reacts to.
/// </summary>
/// <remarks>
/// <para>
/// The window and the icon are one type because they are one lifetime: the icon is
/// identified to the shell by this window's handle, so the handle cannot outlive or
/// predecease it.
/// </para>
/// <para>
/// It is an ordinary top-level window rather than an <c>HWND_MESSAGE</c> one. Message
/// only windows are deliberately excluded from broadcasts, and two of the notifications
/// Juice depends on are broadcasts: the <c>TaskbarCreated</c> message that says the icon
/// must be re-added after an Explorer restart, and the <c>WM_SETTINGCHANGE</c> that says
/// the taskbar switched between light and dark. The window is never shown and carries
/// <c>WS_EX_TOOLWINDOW</c>, so it costs the same as a message-only window while still
/// receiving what Juice needs.
/// </para>
/// </remarks>
[SupportedOSPlatform("windows10.0.19041.0")]
internal sealed class TrayIcon : IDisposable
{
    private const string WindowClassName = "JuiceTrayWindow";
    private const uint IconId = 1;

    /// <summary>The shell truncates the tooltip at 127 characters plus the terminator.</summary>
    private const int MaxTooltipLength = 127;

    // Held as a field so the delegate is not collected while the shell still holds a
    // function pointer to it.
    private readonly NativeMethods.WindowProc _windowProc;

    private readonly uint _taskbarCreatedMessage;
    private readonly nint _classNamePointer;
    private readonly ushort _classAtom;

    private nint _hwnd;
    private nint _iconHandle;
    private nint _displayNotification;
    private bool _sessionNotificationsRegistered;
    private bool _iconAdded;
    private bool _disposed;

    // The shell is asked to redraw only when one of these actually changed. A tray icon
    // that rebuilds its bitmap every second for a number that did not move is exactly
    // the kind of background cost Juice exists to expose.
    private string _renderedLabel = string.Empty;
    private Color _renderedInk;
    private int _renderedSize;
    private string _tooltip = string.Empty;

    /// <summary>Creates the window and places the icon in the notification area.</summary>
    public TrayIcon()
    {
        _windowProc = WindowProcedure;
        _taskbarCreatedMessage = NativeMethods.RegisterWindowMessageW("TaskbarCreated");
        _classNamePointer = Marshal.StringToHGlobalUni(WindowClassName);

        var wndClass = new NativeMethods.WNDCLASSEXW
        {
            cbSize = (uint)Marshal.SizeOf<NativeMethods.WNDCLASSEXW>(),
            lpfnWndProc = Marshal.GetFunctionPointerForDelegate(_windowProc),
            hInstance = NativeMethods.GetModuleHandleW(null),
            lpszClassName = _classNamePointer,
        };

        _classAtom = NativeMethods.RegisterClassExW(ref wndClass);
        if (_classAtom == 0)
        {
            throw new InvalidOperationException(
                $"Could not register the tray window class (Win32 error {Marshal.GetLastWin32Error()}).");
        }

        _hwnd = NativeMethods.CreateWindowExW(
            NativeMethods.WS_EX_TOOLWINDOW | NativeMethods.WS_EX_NOACTIVATE,
            _classNamePointer,
            nint.Zero,
            NativeMethods.WS_POPUP,
            0, 0, 0, 0,
            nint.Zero,
            nint.Zero,
            wndClass.hInstance,
            nint.Zero);

        if (_hwnd == nint.Zero)
        {
            throw new InvalidOperationException(
                $"Could not create the tray window (Win32 error {Marshal.GetLastWin32Error()}).");
        }

        RegisterSystemNotifications();
    }

    /// <summary>Raised when the user left clicks or keyboard-selects the icon.</summary>
    public event EventHandler? Selected;

    /// <summary>Raised with the chosen context menu command.</summary>
    public event EventHandler<TrayCommand>? CommandInvoked;

    /// <summary>Raised when the taskbar theme or DPI changed and the icon must be redrawn.</summary>
    public event EventHandler? AppearanceChanged;

    /// <summary>Raised with true when the display is on, false when it is off or dimmed.</summary>
    public event EventHandler<bool>? DisplayStateChanged;

    /// <summary>Raised with true when the session locked, false when it unlocked.</summary>
    public event EventHandler<bool>? SessionLockChanged;

    /// <summary>Raised with true when the machine is suspending, false when it resumed.</summary>
    public event EventHandler<bool>? SuspendStateChanged;

    /// <summary>Handle of the hidden window, for callers that need to anchor to it.</summary>
    public nint Handle => _hwnd;

    /// <summary>
    /// Updates the icon and its tooltip.
    /// </summary>
    /// <remarks>
    /// The bitmap is only rebuilt when the rendered string, the ink colour or the DPI
    /// changed, and the shell is only notified when something the user can see changed.
    /// </remarks>
    /// <param name="watts">Live draw, or null when it cannot be measured.</param>
    /// <param name="severity">Drain classification, which decides the ink colour.</param>
    /// <param name="tooltip">Full tooltip text; truncated to the shell's limit.</param>
    public void Update(double? watts, DrainSeverity severity, string tooltip)
    {
        if (_disposed || _hwnd == nint.Zero) return;

        var label = PowerFormatter.TrayLabel(watts);

        // The taskbar switch, not the app one. An app running dark on a light taskbar
        // still needs dark ink, and following the app theme here is the classic way a
        // tray icon ends up invisible on the surface it is drawn on.
        var ink = TrayIconRenderer.InkFor(severity, TaskbarAppearanceReader.Read().IsLightTheme);
        var size = TrayIconRenderer.IconSize();
        var trimmed = Truncate(tooltip);

        var iconChanged = label != _renderedLabel || ink != _renderedInk || size != _renderedSize;
        var tooltipChanged = trimmed != _tooltip;

        if (!iconChanged && !tooltipChanged && _iconAdded) return;

        if (iconChanged)
        {
            var next = TrayIconRenderer.CreateIcon(label, ink, size);
            if (next == nint.Zero) return;

            var previous = _iconHandle;
            _iconHandle = next;
            _renderedLabel = label;
            _renderedInk = ink;
            _renderedSize = size;

            // The shell copies the icon on NIM_ADD/NIM_MODIFY, so the old handle can go
            // once the new one is published. Leaking it instead would burn a GDI handle
            // per update, and this process updates for weeks.
            if (previous != nint.Zero) NativeMethods.DestroyIcon(previous);
        }

        _tooltip = trimmed;
        Publish(_iconAdded ? NativeMethods.NIM_MODIFY : NativeMethods.NIM_ADD);
    }

    /// <summary>Forces a redraw, for example after the taskbar theme changed.</summary>
    public void Refresh()
    {
        _renderedLabel = string.Empty;
        _renderedSize = 0;
    }

    /// <summary>
    /// Screen rectangle of the icon in physical pixels, or null when the shell will not
    /// say - typically because the icon is inside the overflow chevron.
    /// </summary>
    public NativeMethods.RECT? TryGetIconRect()
    {
        if (_hwnd == nint.Zero || !_iconAdded) return null;

        var identifier = new NativeMethods.NOTIFYICONIDENTIFIER
        {
            cbSize = (uint)Marshal.SizeOf<NativeMethods.NOTIFYICONIDENTIFIER>(),
            hWnd = _hwnd,
            uID = IconId,
        };

        return NativeMethods.Shell_NotifyIconGetRect(ref identifier, out var rect) == 0
            ? rect
            : null;
    }

    private void Publish(uint message)
    {
        var data = new NativeMethods.NOTIFYICONDATAW
        {
            cbSize = (uint)Marshal.SizeOf<NativeMethods.NOTIFYICONDATAW>(),
            hWnd = _hwnd,
            uID = IconId,
            uFlags = NativeMethods.NIF_MESSAGE | NativeMethods.NIF_ICON
                     | NativeMethods.NIF_TIP | NativeMethods.NIF_SHOWTIP,
            uCallbackMessage = NativeMethods.WM_JUICE_TRAY,
            hIcon = _iconHandle,
            szTip = _tooltip,
            szInfo = string.Empty,
            szInfoTitle = string.Empty,
        };

        if (!NativeMethods.Shell_NotifyIconW(message, ref data)) return;

        if (message != NativeMethods.NIM_ADD) return;

        _iconAdded = true;

        // Version 4 gives screen coordinates in wParam and lets the shell own the
        // tooltip, which is the only way to get placement right on a secondary monitor.
        data.uVersion = NativeMethods.NOTIFYICON_VERSION_4;
        NativeMethods.Shell_NotifyIconW(NativeMethods.NIM_SETVERSION, ref data);
    }

    private void RegisterSystemNotifications()
    {
        var displayState = NativeMethods.GuidConsoleDisplayState;
        _displayNotification = NativeMethods.RegisterPowerSettingNotification(
            _hwnd, ref displayState, NativeMethods.DEVICE_NOTIFY_WINDOW_HANDLE);

        _sessionNotificationsRegistered = NativeMethods.WTSRegisterSessionNotification(
            _hwnd, NativeMethods.NOTIFY_FOR_THIS_SESSION);
    }

    private nint WindowProcedure(nint hWnd, uint msg, nint wParam, nint lParam)
    {
        if (msg == NativeMethods.WM_JUICE_TRAY)
        {
            HandleTrayCallback(wParam, lParam);
            return nint.Zero;
        }

        if (msg == _taskbarCreatedMessage && _taskbarCreatedMessage != 0)
        {
            // Explorer restarted and forgot every icon. Re-adding is the only recovery.
            _iconAdded = false;
            Refresh();
            AppearanceChanged?.Invoke(this, EventArgs.Empty);
            return nint.Zero;
        }

        switch (msg)
        {
            case NativeMethods.WM_SETTINGCHANGE:
                // The shell announces a light/dark switch through the ImmersiveColorSet
                // area. Anything else here is not ours.
                if (lParam != nint.Zero
                    && Marshal.PtrToStringUni(lParam) is "ImmersiveColorSet")
                {
                    Refresh();
                    AppearanceChanged?.Invoke(this, EventArgs.Empty);
                }
                break;

            case NativeMethods.WM_DISPLAYCHANGE:
                // Resolution or scaling moved, so SM_CXSMICON may have moved with it.
                Refresh();
                AppearanceChanged?.Invoke(this, EventArgs.Empty);
                break;

            case NativeMethods.WM_POWERBROADCAST:
                HandlePowerBroadcast(wParam, lParam);
                break;

            case NativeMethods.WM_WTSSESSION_CHANGE:
                var session = (int)wParam;
                if (session == NativeMethods.WTS_SESSION_LOCK) SessionLockChanged?.Invoke(this, true);
                else if (session == NativeMethods.WTS_SESSION_UNLOCK) SessionLockChanged?.Invoke(this, false);
                break;

            case NativeMethods.WM_DESTROY:
                RemoveIcon();
                break;
        }

        return NativeMethods.DefWindowProcW(hWnd, msg, wParam, lParam);
    }

    private void HandlePowerBroadcast(nint wParam, nint lParam)
    {
        switch ((int)wParam)
        {
            case NativeMethods.PBT_APMSUSPEND:
                SuspendStateChanged?.Invoke(this, true);
                break;

            case NativeMethods.PBT_APMRESUMESUSPEND:
            case NativeMethods.PBT_APMRESUMEAUTOMATIC:
                SuspendStateChanged?.Invoke(this, false);
                break;

            case NativeMethods.PBT_POWERSETTINGCHANGE:
                if (lParam == nint.Zero) break;

                var setting = Marshal.PtrToStructure<NativeMethods.POWERBROADCAST_SETTING>(lParam);
                if (setting.PowerSetting != NativeMethods.GuidConsoleDisplayState) break;

                // 0 is off and 2 is dimmed. Both mean the tray number has no reader.
                DisplayStateChanged?.Invoke(this, setting.Data == 1);
                break;
        }
    }

    private void HandleTrayCallback(nint wParam, nint lParam)
    {
        var notification = (uint)NativeMethods.LowWord(lParam);
        var x = NativeMethods.LowWord(wParam);
        var y = NativeMethods.HighWord(wParam);

        switch (notification)
        {
            case NativeMethods.NIN_SELECT:
            case NativeMethods.NIN_KEYSELECT:
            case NativeMethods.WM_LBUTTONUP:
                Selected?.Invoke(this, EventArgs.Empty);
                break;

            case NativeMethods.WM_CONTEXTMENU:
            case NativeMethods.WM_RBUTTONUP:
                ShowContextMenu(x, y);
                break;
        }
    }

    private void ShowContextMenu(int x, int y)
    {
        var menu = NativeMethods.CreatePopupMenu();
        if (menu == nint.Zero) return;

        try
        {
            NativeMethods.AppendMenuW(menu, NativeMethods.MF_STRING, (nuint)TrayCommand.Open, "Open Juice");
            NativeMethods.AppendMenuW(menu, NativeMethods.MF_STRING, (nuint)TrayCommand.Settings, "Settings");
            NativeMethods.AppendMenuW(menu, NativeMethods.MF_STRING, (nuint)TrayCommand.CopyDiagnostics, "Copy diagnostics");
            NativeMethods.AppendMenuW(menu, NativeMethods.MF_SEPARATOR, 0, null);
            NativeMethods.AppendMenuW(menu, NativeMethods.MF_STRING, (nuint)TrayCommand.Exit, "Exit");

            // Both calls are required by the shell: the menu will not dismiss on an
            // outside click without the foreground activation, and the window will not
            // return to a sane state without the null message afterwards.
            NativeMethods.SetForegroundWindow(_hwnd);

            var chosen = NativeMethods.TrackPopupMenuEx(
                menu,
                NativeMethods.TPM_RIGHTBUTTON | NativeMethods.TPM_RETURNCMD | NativeMethods.TPM_NONOTIFY,
                x, y, _hwnd, nint.Zero);

            NativeMethods.PostMessageW(_hwnd, NativeMethods.WM_NULL, nint.Zero, nint.Zero);

            if (chosen != 0) CommandInvoked?.Invoke(this, (TrayCommand)chosen);
        }
        finally
        {
            NativeMethods.DestroyMenu(menu);
        }
    }

    private void RemoveIcon()
    {
        if (!_iconAdded) return;
        _iconAdded = false;

        var data = new NativeMethods.NOTIFYICONDATAW
        {
            cbSize = (uint)Marshal.SizeOf<NativeMethods.NOTIFYICONDATAW>(),
            hWnd = _hwnd,
            uID = IconId,
            szTip = string.Empty,
            szInfo = string.Empty,
            szInfoTitle = string.Empty,
        };

        NativeMethods.Shell_NotifyIconW(NativeMethods.NIM_DELETE, ref data);
    }

    private static string Truncate(string text)
        => text.Length <= MaxTooltipLength ? text : text[..MaxTooltipLength];

    /// <inheritdoc />
    public void Dispose()
    {
        if (_disposed) return;
        _disposed = true;

        RemoveIcon();

        if (_displayNotification != nint.Zero)
        {
            NativeMethods.UnregisterPowerSettingNotification(_displayNotification);
            _displayNotification = nint.Zero;
        }

        if (_sessionNotificationsRegistered && _hwnd != nint.Zero)
        {
            NativeMethods.WTSUnRegisterSessionNotification(_hwnd);
            _sessionNotificationsRegistered = false;
        }

        if (_hwnd != nint.Zero)
        {
            NativeMethods.DestroyWindow(_hwnd);
            _hwnd = nint.Zero;
        }

        if (_iconHandle != nint.Zero)
        {
            NativeMethods.DestroyIcon(_iconHandle);
            _iconHandle = nint.Zero;
        }

        if (_classNamePointer != nint.Zero) Marshal.FreeHGlobal(_classNamePointer);
    }
}
