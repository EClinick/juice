namespace Juice.App.Tray;

/// <summary>Commands offered by the tray icon's context menu.</summary>
internal enum TrayCommand
{
    /// <summary>Nothing was chosen.</summary>
    None = 0,

    /// <summary>Show the live readout.</summary>
    Open = 1,

    /// <summary>Show settings.</summary>
    Settings = 2,

    /// <summary>Put the diagnostics report on the clipboard.</summary>
    CopyDiagnostics = 3,

    /// <summary>Quit.</summary>
    Exit = 4,
}
