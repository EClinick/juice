using System.Runtime.Versioning;
using Juice.Core.Storage;

namespace Juice.App.Services;

/// <summary>
/// Opens the local history database in the right place for how the app is running.
/// </summary>
/// <remarks>
/// <para>
/// This is the Windows counterpart of the macOS version's
/// <c>~/Library/Application Support/Juice</c>. Packaged, the store lives in the app's own
/// local folder, which Windows redirects per package and removes on uninstall. Running
/// unpackaged, for example from the debugger or from the CLI, it falls back to
/// <c>%LOCALAPPDATA%\Juice</c>.
/// </para>
/// <para>
/// A failure to open the store is not fatal. Juice still measures, it simply has no
/// history, and the charts say so rather than the app refusing to start.
/// </para>
/// </remarks>
[SupportedOSPlatform("windows10.0.19041.0")]
public static class HistoryStoreFactory
{
    private const string FileName = "juice-history.db";

    /// <summary>Opens the store, or returns null when it cannot be opened.</summary>
    public static JuiceStore? TryOpen()
    {
        try
        {
            return JuiceStore.Open(ResolvePath());
        }
        catch (Exception ex) when (ex is Microsoft.Data.Sqlite.SqliteException
                                    or IOException
                                    or UnauthorizedAccessException)
        {
            return null;
        }
    }

    /// <summary>Where the database file lives.</summary>
    public static string ResolvePath()
    {
        var folder = TryPackagedFolder() ?? UnpackagedFolder();
        Directory.CreateDirectory(folder);
        return Path.Combine(folder, FileName);
    }

    private static string? TryPackagedFolder()
    {
        try
        {
            return Windows.Storage.ApplicationData.Current.LocalFolder.Path;
        }
        catch (Exception ex) when (ex is InvalidOperationException or UnauthorizedAccessException)
        {
            // Thrown when there is no package identity, which is the normal unpackaged case.
            return null;
        }
    }

    private static string UnpackagedFolder()
        => Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
            "Juice");
}
