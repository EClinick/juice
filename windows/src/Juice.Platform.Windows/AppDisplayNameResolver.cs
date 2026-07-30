using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Runtime.Versioning;

namespace Juice.Platform.Windows;

/// <summary>
/// Turns a process name into the name a person would recognise.
/// </summary>
/// <remarks>
/// <para>
/// A ranking of <c>msedge</c>, <c>dwm</c> and <c>svchost</c> is accurate and close to
/// useless: it asks the reader to know what those are before it can tell them anything.
/// Windows already carries the answer in every executable's version resource, which is the
/// same string Task Manager shows in its Details view, so this reads that rather than
/// inventing a mapping table that would need maintaining forever.
/// </para>
/// <para>
/// The result is cached by process name and never expires. Resolving costs a handle open
/// and a version resource read, and the answer cannot change while a build is installed, so
/// paying it once per distinct name per session is the whole cost. That matters because
/// attribution runs every thirty seconds and walks every process on the machine.
/// </para>
/// <para>
/// Anything unresolvable falls back to the process name. A row labelled <c>svchost</c> is
/// worse than one labelled "Host Process for Windows Services", but both are true, and
/// guessing a friendlier name would not be.
/// </para>
/// </remarks>
[SupportedOSPlatform("windows")]
public sealed partial class AppDisplayNameResolver
{
    private const int MaximumPath = 32768;
    private const uint QueryLimitedInformation = 0x1000;

    private readonly Dictionary<string, string> _byProcessName = new(StringComparer.OrdinalIgnoreCase);
    private readonly Lock _gate = new();

    /// <summary>
    /// The descriptive name for a process, or its process name when none can be read.
    /// </summary>
    public string Resolve(int processId, string processName)
    {
        lock (_gate)
        {
            if (_byProcessName.TryGetValue(processName, out var cached)) return cached;
        }

        var resolved = Describe(processId) ?? SystemName(processName) ?? processName;

        lock (_gate)
        {
            _byProcessName[processName] = resolved;
        }

        return resolved;
    }

    /// <summary>
    /// Names for the Windows processes whose own version resource cannot be read.
    /// </summary>
    /// <remarks>
    /// <para>
    /// These run as SYSTEM or in another session, so <c>OpenProcess</c> fails with access
    /// denied even for <c>PROCESS_QUERY_LIMITED_INFORMATION</c>, and their executable path
    /// is therefore unreachable without elevation. Juice deliberately runs unelevated, so
    /// the version resource is simply not available for exactly the processes a reader is
    /// least likely to recognise.
    /// </para>
    /// <para>
    /// Every string here is the name Windows itself uses in Task Manager for that process.
    /// This is a lookup table for facts that cannot be read at runtime, not a friendlier
    /// label invented for the occasion, and nothing is guessed: a process not in this table
    /// keeps its process name rather than acquiring a plausible one.
    /// </para>
    /// <para>
    /// <c>svchost</c> is the awkward case. Task Manager expands it per hosted service, which
    /// needs a service enumeration Juice does not do, so it gets the generic name. That is
    /// honest but not very useful, and it is the reason a service level breakdown would be
    /// worth having eventually.
    /// </para>
    /// </remarks>
    private static string? SystemName(string processName) => processName.ToLowerInvariant() switch
    {
        "system" => "System",
        "registry" => "Registry",
        "memcompression" => "Memory compression",
        "dwm" => "Desktop Window Manager",
        "csrss" => "Client Server Runtime Process",
        "smss" => "Session Manager Subsystem",
        "wininit" => "Windows Start-Up Application",
        "winlogon" => "Windows Logon Application",
        "lsass" => "Local Security Authority Process",
        "services" => "Services and Controller app",
        "svchost" => "Host Process for Windows Services",
        "fontdrvhost" => "Usermode Font Driver Host",
        "audiodg" => "Windows Audio Device Graph Isolation",
        "wmiprvse" => "WMI Provider Host",
        "msmpeng" => "Antimalware Service Executable",
        "nissrv" => "Microsoft Network Realtime Inspection Service",
        "securityhealthservice" => "Windows Security Health Service",
        "searchindexer" => "Microsoft Windows Search Indexer",
        "spoolsv" => "Spooler SubSystem App",
        "taskhostw" => "Host Process for Windows Tasks",
        "sihost" => "Shell Infrastructure Host",
        "ctfmon" => "CTF Loader",
        "conhost" => "Console Window Host",
        "runtimebroker" => "Runtime Broker",
        "dllhost" => "COM Surrogate",
        "wudfhost" => "Windows Driver Foundation User-mode Driver Framework Host",
        _ => null,
    };

    private static string? Describe(int processId)
    {
        var path = ResolvePath(processId);
        if (path is null) return null;

        try
        {
            var info = FileVersionInfo.GetVersionInfo(path);

            // FileDescription is what Task Manager shows and is almost always the friendly
            // name. ProductName is the fallback because some executables leave the
            // description blank but still identify their product.
            return Clean(info.FileDescription) ?? Clean(info.ProductName);
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException)
        {
            return null;
        }
    }

    /// <summary>
    /// Rejects version strings that carry no more information than the file name.
    /// </summary>
    /// <remarks>
    /// Plenty of executables set the description to the file name, or to a path, or leave
    /// whitespace. Substituting any of those would add nothing and can look like a bug when
    /// a row suddenly shows a full path.
    /// </remarks>
    private static string? Clean(string? value)
    {
        var trimmed = value?.Trim();

        if (string.IsNullOrEmpty(trimmed)) return null;
        if (trimmed.Contains('\\') || trimmed.Contains('/')) return null;
        if (trimmed.EndsWith(".exe", StringComparison.OrdinalIgnoreCase)) return null;

        return trimmed;
    }

    private static string? ResolvePath(int processId)
    {
        var handle = OpenProcess(QueryLimitedInformation, false, processId);
        if (handle == nint.Zero) return null;

        try
        {
            var buffer = new char[MaximumPath];
            var size = buffer.Length;

            return QueryFullProcessImageName(handle, 0, buffer, ref size)
                ? new string(buffer, 0, size)
                : null;
        }
        finally
        {
            CloseHandle(handle);
        }
    }

    [LibraryImport("kernel32.dll", SetLastError = true)]
    private static partial nint OpenProcess(uint access, [MarshalAs(UnmanagedType.Bool)] bool inherit, int processId);

    [LibraryImport("kernel32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static partial bool CloseHandle(nint handle);

    [LibraryImport("kernel32.dll", EntryPoint = "QueryFullProcessImageNameW", SetLastError = true, StringMarshalling = StringMarshalling.Utf16)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static partial bool QueryFullProcessImageName(nint process, uint flags, [Out] char[] exeName, ref int size);
}
