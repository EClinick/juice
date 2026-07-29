using System.Collections.Concurrent;
using System.Drawing;
using System.Drawing.Imaging;
using System.Runtime.InteropServices;
using System.Runtime.Versioning;

namespace Juice.Platform.Windows;

/// <summary>
/// Resolves the real icon for a running process.
/// </summary>
/// <remarks>
/// <para>
/// The macOS app shows genuine app icons, and CONTRIBUTING.md requires it: rows use real
/// icons rather than emoji or generic glyphs. On macOS that is
/// <c>NSWorkspace.icon(forFile:)</c>, a single call that resolves the icon for a bundle.
/// </para>
/// <para>
/// Windows has no equivalent, so this reconstructs it in three steps. The executable path
/// is resolved from the process id, the icon is extracted from that executable's
/// resources at a requested size, and the result is encoded as PNG so the UI layer can
/// consume it without this assembly taking a dependency on any XAML type.
/// </para>
/// <para>
/// Extraction is comparatively expensive and the answer never changes for a given
/// executable, so results are cached by path for the lifetime of the process, including
/// negative results. Without that, a list of twenty apps refreshing every few seconds
/// would re-extract twenty icons forever.
/// </para>
/// </remarks>
[SupportedOSPlatform("windows")]
public sealed partial class AppIconResolver : IDisposable
{
    private const uint ProcessQueryLimitedInformation = 0x1000;

    private readonly ConcurrentDictionary<string, byte[]?> _cache = new(StringComparer.OrdinalIgnoreCase);
    private readonly ConcurrentDictionary<int, string?> _paths = new();
    private bool _disposed;

    /// <summary>Size in pixels that icons are extracted at.</summary>
    public int IconSize { get; init; } = 32;

    /// <summary>
    /// Full path of the executable backing a process, or null when it cannot be read.
    /// </summary>
    /// <remarks>
    /// Uses <c>QueryFullProcessImageName</c> with
    /// <c>PROCESS_QUERY_LIMITED_INFORMATION</c>, which succeeds for most processes
    /// without elevation. <c>Process.MainModule</c> would be the obvious managed route but
    /// it requires far broader access and throws for protected and cross-bitness
    /// processes, which are common.
    /// </remarks>
    public string? ResolveExecutablePath(int processId)
        => _paths.GetOrAdd(processId, static pid =>
        {
            var handle = OpenProcess(ProcessQueryLimitedInformation, false, pid);
            if (handle == nint.Zero) return null;

            try
            {
                var capacity = 260;
                var buffer = new char[capacity];
                var size = capacity;

                return QueryFullProcessImageName(handle, 0, buffer, ref size)
                    ? new string(buffer, 0, size)
                    : null;
            }
            finally
            {
                CloseHandle(handle);
            }
        });

    /// <summary>
    /// The icon for a process, encoded as PNG, or null when none could be extracted.
    /// </summary>
    public byte[]? GetIconPng(int processId)
    {
        var path = ResolveExecutablePath(processId);
        return path is null ? null : GetIconPngForPath(path);
    }

    /// <summary>The icon for an executable path, encoded as PNG.</summary>
    public byte[]? GetIconPngForPath(string executablePath)
        => _cache.GetOrAdd(executablePath, path => Extract(path, IconSize));

    private static byte[]? Extract(string path, int size)
    {
        if (!File.Exists(path)) return null;

        var handles = new nint[1];
        var ids = new uint[1];

        // PrivateExtractIcons is used rather than ExtractIconEx because it takes an
        // explicit size, so the icon comes back already matched to what the list renders
        // instead of being scaled up from a 16 pixel variant.
        var extracted = PrivateExtractIcons(path, 0, size, size, handles, ids, 1, 0);
        if (extracted == 0 || handles[0] == nint.Zero) return null;

        try
        {
            using var icon = Icon.FromHandle(handles[0]);
            using var bitmap = icon.ToBitmap();
            using var stream = new MemoryStream();

            bitmap.Save(stream, ImageFormat.Png);
            return stream.ToArray();
        }
        catch (Exception ex) when (ex is ArgumentException or ExternalException or IOException)
        {
            return null;
        }
        finally
        {
            // The handle is owned by the caller of PrivateExtractIcons, and Icon.FromHandle
            // does not take ownership, so it has to be released explicitly. Missing this
            // leaks a GDI handle per icon, which matters in a process that runs for weeks.
            DestroyIcon(handles[0]);
        }
    }

    /// <summary>
    /// Forgets cached process id to path mappings.
    /// </summary>
    /// <remarks>
    /// Process ids are recycled by Windows, so the path cache would eventually hand back
    /// the wrong executable for a reused id. The icon cache is keyed by path and stays
    /// valid, so only the id mapping is cleared.
    /// </remarks>
    public void InvalidateProcessPaths() => _paths.Clear();

    /// <inheritdoc />
    public void Dispose()
    {
        if (_disposed) return;
        _disposed = true;
        _cache.Clear();
        _paths.Clear();
    }

    [LibraryImport("kernel32.dll", SetLastError = true)]
    private static partial nint OpenProcess(uint desiredAccess, [MarshalAs(UnmanagedType.Bool)] bool inheritHandle, int processId);

    [LibraryImport("kernel32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static partial bool CloseHandle(nint handle);

    [LibraryImport("kernel32.dll", EntryPoint = "QueryFullProcessImageNameW", SetLastError = true, StringMarshalling = StringMarshalling.Utf16)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static partial bool QueryFullProcessImageName(nint process, uint flags, [Out] char[] exeName, ref int size);

    [LibraryImport("user32.dll", EntryPoint = "PrivateExtractIconsW", SetLastError = true, StringMarshalling = StringMarshalling.Utf16)]
    private static partial uint PrivateExtractIcons(
        string fileName, int iconIndex, int cx, int cy, nint[] icons, uint[] iconIds, uint iconCount, uint flags);

    [LibraryImport("user32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static partial bool DestroyIcon(nint icon);
}
