using System.Runtime.InteropServices;

namespace Juice.App.Interop;

/// <summary>
/// The Win32 surface Juice needs for the notification area and for system state
/// notifications.
/// </summary>
/// <remarks>
/// <para>
/// None of this has a Windows App SDK equivalent. The notification area is reachable
/// only through <c>Shell_NotifyIcon</c>, and display, session and suspend transitions
/// only arrive as window messages, so Juice owns a small amount of interop rather than
/// taking a tray library dependency. Keeping it first-party also keeps the working set
/// of a process that lives in the tray for weeks down to what Juice actually calls.
/// </para>
/// </remarks>
internal static class NativeMethods
{
    // Window messages Juice listens for.
    internal const uint WM_DESTROY = 0x0002;
    internal const uint WM_SETTINGCHANGE = 0x001A;
    internal const uint WM_DISPLAYCHANGE = 0x007E;
    internal const uint WM_POWERBROADCAST = 0x0218;
    internal const uint WM_WTSSESSION_CHANGE = 0x02B1;
    internal const uint WM_NULL = 0x0000;
    internal const uint WM_APP = 0x8000;

    /// <summary>Private callback message the shell posts for tray icon input.</summary>
    internal const uint WM_JUICE_TRAY = WM_APP + 1;

    // Mouse messages arriving through the tray callback.
    internal const uint WM_LBUTTONUP = 0x0202;
    internal const uint WM_RBUTTONUP = 0x0205;
    internal const uint WM_CONTEXTMENU = 0x007B;
    internal const uint NIN_SELECT = WM_APP + 0;
    internal const uint NIN_KEYSELECT = WM_APP + 1;

    // Window styles. The tray window is a real top-level window rather than a
    // message-only one because HWND_MESSAGE windows are excluded from broadcasts, and
    // the taskbar restart notification and the theme change notification are both
    // broadcasts. WS_EX_TOOLWINDOW keeps it out of the task switcher, and it is never
    // shown, so it costs the same as a message-only window in practice.
    internal const uint WS_POPUP = 0x80000000;
    internal const uint WS_EX_TOOLWINDOW = 0x00000080;
    internal const uint WS_EX_NOACTIVATE = 0x08000000;

    internal const int SM_CXSMICON = 49;

    // Shell_NotifyIcon.
    internal const uint NIM_ADD = 0x00000000;
    internal const uint NIM_MODIFY = 0x00000001;
    internal const uint NIM_DELETE = 0x00000002;
    internal const uint NIM_SETVERSION = 0x00000004;

    internal const uint NIF_MESSAGE = 0x00000001;
    internal const uint NIF_ICON = 0x00000002;
    internal const uint NIF_TIP = 0x00000004;
    internal const uint NIF_SHOWTIP = 0x00000080;

    /// <summary>
    /// Version 4 callback packing. It puts the click coordinates in wParam in screen
    /// space, which is what <c>TrackPopupMenuEx</c> wants, and it lets the shell draw
    /// the standard tooltip instead of the legacy one.
    /// </summary>
    internal const uint NOTIFYICON_VERSION_4 = 4;

    // Popup menus.
    internal const uint MF_STRING = 0x00000000;
    internal const uint MF_SEPARATOR = 0x00000800;
    internal const uint TPM_RIGHTBUTTON = 0x0002;
    internal const uint TPM_RETURNCMD = 0x0100;
    internal const uint TPM_NONOTIFY = 0x0080;

    // Power broadcasts.
    internal const int PBT_APMSUSPEND = 0x0004;
    internal const int PBT_APMRESUMESUSPEND = 0x0007;
    internal const int PBT_APMRESUMEAUTOMATIC = 0x0012;
    internal const int PBT_POWERSETTINGCHANGE = 0x8013;
    internal const uint DEVICE_NOTIFY_WINDOW_HANDLE = 0x00000000;

    /// <summary>
    /// Console display state. Data is 0 off, 1 on, 2 dimmed. This is the signal that
    /// nobody can see the tray number, which is what lets Juice back off to a five
    /// minute cadence.
    /// </summary>
    internal static readonly Guid GuidConsoleDisplayState =
        new("6FE69556-704A-47A0-8F24-C28D936FDA47");

    // Session change.
    internal const int NOTIFY_FOR_THIS_SESSION = 0;
    internal const int WTS_SESSION_LOCK = 0x7;
    internal const int WTS_SESSION_UNLOCK = 0x8;

    // Battery status flags from GetSystemPowerStatus.
    internal const byte AC_LINE_ONLINE = 1;
    internal const uint BATTERY_LIFE_UNKNOWN = 0xFFFFFFFF;

    // Rounded corners for the borderless flyout.
    internal const int DWMWA_WINDOW_CORNER_PREFERENCE = 33;
    internal const int DWMWCP_ROUND = 2;

    /// <summary>Border colour attribute, used to remove the system border entirely.</summary>
    internal const int DWMWA_BORDER_COLOR = 34;

    /// <summary>Sentinel meaning "draw no border", as opposed to a transparent one.</summary>
    internal const int DWMWA_COLOR_NONE = unchecked((int)0xFFFFFFFE);

    [UnmanagedFunctionPointer(CallingConvention.Winapi)]
    internal delegate nint WindowProc(nint hWnd, uint msg, nint wParam, nint lParam);

    [StructLayout(LayoutKind.Sequential)]
    internal struct WNDCLASSEXW
    {
        public uint cbSize;
        public uint style;
        public nint lpfnWndProc;
        public int cbClsExtra;
        public int cbWndExtra;
        public nint hInstance;
        public nint hIcon;
        public nint hCursor;
        public nint hbrBackground;
        public nint lpszMenuName;
        public nint lpszClassName;
        public nint hIconSm;
    }

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    internal struct NOTIFYICONDATAW
    {
        public uint cbSize;
        public nint hWnd;
        public uint uID;
        public uint uFlags;
        public uint uCallbackMessage;
        public nint hIcon;

        /// <summary>Tooltip text. The shell truncates at 127 characters plus the null.</summary>
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 128)]
        public string szTip;

        public uint dwState;
        public uint dwStateMask;

        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 256)]
        public string szInfo;

        /// <summary>Union of uTimeout and uVersion; Juice only ever uses the version.</summary>
        public uint uVersion;

        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 64)]
        public string szInfoTitle;

        public uint dwInfoFlags;
        public Guid guidItem;
        public nint hBalloonIcon;
    }

    [StructLayout(LayoutKind.Sequential)]
    internal struct NOTIFYICONIDENTIFIER
    {
        public uint cbSize;
        public nint hWnd;
        public uint uID;
        public Guid guidItem;
    }

    [StructLayout(LayoutKind.Sequential)]
    internal struct RECT
    {
        public int Left;
        public int Top;
        public int Right;
        public int Bottom;

        public readonly int Width => Right - Left;
        public readonly int Height => Bottom - Top;
    }

    [StructLayout(LayoutKind.Sequential)]
    internal struct POWERBROADCAST_SETTING
    {
        public Guid PowerSetting;
        public uint DataLength;
        public byte Data;
    }

    [StructLayout(LayoutKind.Sequential)]
    internal struct SYSTEM_POWER_STATUS
    {
        public byte ACLineStatus;
        public byte BatteryFlag;
        public byte BatteryLifePercent;
        public byte SystemStatusFlag;
        public uint BatteryLifeTime;
        public uint BatteryFullLifeTime;
    }

    [DllImport("user32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    internal static extern ushort RegisterClassExW(ref WNDCLASSEXW wndClass);

    [DllImport("user32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    internal static extern nint CreateWindowExW(
        uint exStyle,
        nint className,
        nint windowName,
        uint style,
        int x,
        int y,
        int width,
        int height,
        nint parent,
        nint menu,
        nint instance,
        nint param);

    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    internal static extern nint DefWindowProcW(nint hWnd, uint msg, nint wParam, nint lParam);

    [DllImport("user32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    internal static extern bool DestroyWindow(nint hWnd);

    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    internal static extern uint RegisterWindowMessageW(string message);

    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    internal static extern nint GetModuleHandleW(string? moduleName);

    [DllImport("shell32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    internal static extern bool Shell_NotifyIconW(uint message, ref NOTIFYICONDATAW data);

    [DllImport("shell32.dll")]
    internal static extern int Shell_NotifyIconGetRect(
        ref NOTIFYICONIDENTIFIER identifier,
        out RECT iconLocation);

    [DllImport("user32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    internal static extern bool DestroyIcon(nint hIcon);

    [DllImport("user32.dll")]
    internal static extern int GetSystemMetrics(int index);

    [DllImport("user32.dll")]
    internal static extern uint GetDpiForWindow(nint hWnd);

    [DllImport("user32.dll", SetLastError = true)]
    internal static extern nint CreatePopupMenu();

    [DllImport("user32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    internal static extern bool AppendMenuW(nint menu, uint flags, nuint itemId, string? item);

    [DllImport("user32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    internal static extern bool DestroyMenu(nint menu);

    [DllImport("user32.dll", SetLastError = true)]
    internal static extern int TrackPopupMenuEx(
        nint menu,
        uint flags,
        int x,
        int y,
        nint hWnd,
        nint parameters);

    [DllImport("user32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    internal static extern bool SetForegroundWindow(nint hWnd);

    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    internal static extern nint PostMessageW(nint hWnd, uint msg, nint wParam, nint lParam);

    [DllImport("user32.dll", SetLastError = true)]
    internal static extern nint RegisterPowerSettingNotification(
        nint recipient,
        ref Guid powerSettingGuid,
        uint flags);

    [DllImport("user32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    internal static extern bool UnregisterPowerSettingNotification(nint handle);

    [DllImport("wtsapi32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    internal static extern bool WTSRegisterSessionNotification(nint hWnd, uint flags);

    [DllImport("wtsapi32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    internal static extern bool WTSUnRegisterSessionNotification(nint hWnd);

    [DllImport("kernel32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    internal static extern bool GetSystemPowerStatus(out SYSTEM_POWER_STATUS status);

    [DllImport("dwmapi.dll")]
    internal static extern int DwmSetWindowAttribute(
        nint hWnd,
        int attribute,
        ref int value,
        int size);

    /// <summary>Low 16 bits of a message parameter, as a signed coordinate.</summary>
    internal static int LowWord(nint value) => unchecked((short)(long)value);

    /// <summary>High 16 bits of a message parameter, as a signed coordinate.</summary>
    internal static int HighWord(nint value) => unchecked((short)((long)value >> 16));
}
