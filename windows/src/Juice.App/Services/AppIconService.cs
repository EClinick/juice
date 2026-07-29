using System.Runtime.InteropServices;
using System.Runtime.InteropServices.WindowsRuntime;
using System.Runtime.Versioning;
using Juice.Platform.Windows;
using Microsoft.UI.Dispatching;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Media.Imaging;
using Windows.Storage.Streams;

namespace Juice.App.Services;

/// <summary>
/// Supplies real app icons for the energy list, decoded and cached for the UI thread.
/// </summary>
/// <remarks>
/// <para>
/// <see cref="AppIconResolver"/> deliberately stops at PNG bytes so the platform assembly
/// stays free of XAML types. This is the other half of that split: it turns those bytes
/// into a <see cref="ImageSource"/> and keeps one instance per app, so a list refreshing
/// every couple of seconds re-uses the same decoded bitmap instead of allocating a new
/// one per row per tick.
/// </para>
/// <para>
/// Every field here is touched only from the UI thread, which is what lets them be plain
/// dictionaries. The expensive part, reading the executable and extracting the icon, is
/// the only thing that runs on the thread pool.
/// </para>
/// </remarks>
[SupportedOSPlatform("windows10.0.19041.0")]
public sealed class AppIconService : IDisposable
{
    /// <summary>
    /// Extraction size. The list draws icons at 16 device independent pixels, so 32
    /// keeps them sharp on a 200% display without holding a full size icon per app.
    /// </summary>
    private const int IconPixelSize = 32;

    /// <summary>
    /// How long a process id to executable mapping is trusted before it is thrown away.
    /// </summary>
    /// <remarks>
    /// Windows recycles process ids, so a cached mapping eventually names the wrong
    /// executable and the list would show one app wearing another app's icon. Five
    /// minutes is short enough that a recycled id cannot linger through a session and
    /// long enough that the cache still does its job across many refreshes.
    /// </remarks>
    private static readonly TimeSpan ProcessPathLifetime = TimeSpan.FromMinutes(5);

    private readonly AppIconResolver _resolver = new() { IconSize = IconPixelSize };
    private readonly Dictionary<string, ImageSource?> _byApp = new(StringComparer.Ordinal);
    private readonly HashSet<string> _pending = new(StringComparer.Ordinal);
    private readonly DispatcherQueue _ui;

    private DateTimeOffset _pathsResolvedAt = DateTimeOffset.UtcNow;
    private bool _disposed;

    /// <summary>Creates a service that decodes onto the given dispatcher.</summary>
    public AppIconService(DispatcherQueue ui) => _ui = ui;

    /// <summary>
    /// Supplies the icon for an app, from cache when it has one and asynchronously when
    /// it does not.
    /// </summary>
    /// <param name="appId">Stable identity of the app, used as the cache key.</param>
    /// <param name="processIds">
    /// Process ids belonging to the app, tried in order until one yields an icon. An app
    /// with several processes often has one that cannot be opened, so the first id is
    /// not necessarily the one that resolves.
    /// </param>
    /// <param name="apply">
    /// Receives the icon, or null when none could be extracted. Called synchronously on
    /// a cache hit, so a refresh does not blank the row before filling it in again.
    /// </param>
    public void Request(string appId, IReadOnlyList<int> processIds, Action<ImageSource?> apply)
    {
        ArgumentNullException.ThrowIfNull(apply);

        if (_disposed || processIds.Count == 0)
        {
            apply(null);
            return;
        }

        ExpireProcessPaths();

        if (_byApp.TryGetValue(appId, out var cached))
        {
            apply(cached);
            return;
        }

        // A second request for an app already in flight is dropped rather than queued.
        // The row objects are re-used across refreshes, so the call already running will
        // land on the same row.
        if (!_pending.Add(appId)) return;

        // Copied so the background read cannot observe the attributor mutating its own
        // collections underneath it.
        var pids = processIds.ToArray();

        _ = Task.Run(() =>
        {
            byte[]? png = null;

            foreach (var pid in pids)
            {
                png = _resolver.GetIconPng(pid);
                if (png is not null) break;
            }

            // A failed enqueue means the dispatcher is shutting down, in which case the
            // pending entry no longer matters.
            _ui.TryEnqueue(() => _ = CompleteAsync(appId, png, apply));
        });
    }

    private async Task CompleteAsync(string appId, byte[]? png, Action<ImageSource?> apply)
    {
        var image = png is null ? null : await DecodeAsync(png);

        _pending.Remove(appId);

        // Failures are cached as well. An executable that will not give up an icon will
        // not start doing so, and re-attempting every refresh would keep a thread pool
        // work item running for the life of the process.
        _byApp[appId] = image;

        apply(image);
    }

    private static async Task<ImageSource?> DecodeAsync(byte[] png)
    {
        try
        {
            using var stream = new InMemoryRandomAccessStream();
            await stream.WriteAsync(png.AsBuffer());
            stream.Seek(0);

            var bitmap = new BitmapImage
            {
                DecodePixelWidth = IconPixelSize,
                DecodePixelHeight = IconPixelSize,
            };

            await bitmap.SetSourceAsync(stream);
            return bitmap;
        }
        catch (Exception ex) when (ex is COMException or ArgumentException)
        {
            // A malformed icon resource is the app's problem, not something to show the
            // user an error over. The row simply goes without an icon.
            return null;
        }
    }

    private void ExpireProcessPaths()
    {
        if (DateTimeOffset.UtcNow - _pathsResolvedAt < ProcessPathLifetime) return;

        _pathsResolvedAt = DateTimeOffset.UtcNow;
        _resolver.InvalidateProcessPaths();

        // The decoded icons are keyed by app rather than by path, so they have to go too:
        // otherwise a recycled process id would keep being served the icon it resolved
        // to before the mapping was dropped.
        _byApp.Clear();
    }

    /// <inheritdoc />
    public void Dispose()
    {
        if (_disposed) return;
        _disposed = true;

        _resolver.Dispose();
        _byApp.Clear();
        _pending.Clear();
    }
}
