using System.Runtime.InteropServices;
using System.Runtime.Versioning;

namespace Juice.Platform.Windows.Interop;

/// <summary>
/// Minimal PDH bindings for reading a whole wildcard counter set in one call.
/// </summary>
/// <remarks>
/// <para>
/// The managed <c>PerformanceCounter</c> class binds one counter instance per object.
/// For <c>\GPU Engine(*)\Utilization Percentage</c> that means allocating and disposing
/// several hundred objects on every sample, which is far too expensive for something
/// that runs forever in the background.
/// </para>
/// <para>
/// PDH natively supports wildcard paths: one query, one counter handle, and a single
/// call that returns every instance as a flat array. The query handle is kept open
/// across samples, which also satisfies the requirement that rate counters be collected
/// at least twice before they yield a value.
/// </para>
/// </remarks>
[SupportedOSPlatform("windows")]
internal sealed partial class PdhWildcardCounter : IDisposable
{
    private const uint PdhFmtDouble = 0x00000200;
    private const uint PdhFmtNoCap100 = 0x00008000;
    private const uint PdhMoreData = 0x800007D2;
    private const uint PdhCstatusValidData = 0x00000000;
    private const uint PdhCstatusNewData = 0x00000001;

    private readonly nint _query;
    private readonly nint _counter;
    private byte[] _buffer = [];
    private bool _hasBaseline;
    private bool _disposed;

    private PdhWildcardCounter(nint query, nint counter)
    {
        _query = query;
        _counter = counter;
    }

    /// <summary>Opens a wildcard query, or returns null when the path does not exist.</summary>
    public static PdhWildcardCounter? TryOpen(string counterPath)
    {
        if (PdhOpenQuery(null, nint.Zero, out var query) != 0) return null;

        if (PdhAddEnglishCounter(query, counterPath, nint.Zero, out var counter) != 0)
        {
            PdhCloseQuery(query);
            return null;
        }

        var instance = new PdhWildcardCounter(query, counter);

        // Prime the query. Rate counters need a prior collection to difference against.
        PdhCollectQueryData(query);

        return instance;
    }

    /// <summary>
    /// Collects the counter set and invokes <paramref name="onItem"/> per instance.
    /// </summary>
    /// <remarks>
    /// The callback form avoids materialising a dictionary or list inside the interop
    /// layer, so callers that only need to accumulate totals allocate nothing per sample
    /// beyond the reusable buffer.
    /// </remarks>
    public bool Collect(Action<string, double> onItem)
    {
        if (_disposed) return false;
        if (PdhCollectQueryData(_query) != 0) return false;

        if (!_hasBaseline)
        {
            // The first collection only establishes a baseline for the rate counters;
            // values are not meaningful until the next one.
            _hasBaseline = true;
            return false;
        }

        uint size;
        uint count;
        uint status;

        // Grow the buffer until PDH stops asking for more. Instance counts move around as
        // processes come and go, so the buffer is retained between samples and only ever
        // grows to the high-water mark.
        for (var attempt = 0; attempt < 5; attempt++)
        {
            unsafe
            {
                if (_buffer.Length == 0)
                {
                    size = 0;
                    status = PdhGetFormattedCounterArray(
                        _counter, PdhFmtDouble | PdhFmtNoCap100, ref size, out count, null);
                }
                else
                {
                    fixed (byte* p = _buffer)
                    {
                        size = (uint)_buffer.Length;
                        status = PdhGetFormattedCounterArray(
                            _counter, PdhFmtDouble | PdhFmtNoCap100, ref size, out count, p);
                    }
                }
            }

            if (status == 0)
            {
                ReadItems(count, onItem);
                return true;
            }

            if (status != PdhMoreData) return false;

            _buffer = new byte[Math.Max(size + 1024, (uint)_buffer.Length * 2)];
        }

        return false;
    }

    private void ReadItems(uint count, Action<string, double> onItem)
    {
        // PDH_FMT_COUNTERVALUE_ITEM_W on x64:
        //   0x00 LPWSTR szName
        //   0x08 DWORD  CStatus
        //   0x10 double doubleValue (8 byte aligned, so 4 bytes of padding precede it)
        var pointerSize = nint.Size;
        var itemSize = pointerSize == 8 ? 24 : 16;
        var statusOffset = pointerSize;
        var valueOffset = pointerSize == 8 ? 16 : 8;

        if ((long)count * itemSize > _buffer.Length) return;

        unsafe
        {
            fixed (byte* basePtr = _buffer)
            {
                for (uint i = 0; i < count; i++)
                {
                    var item = basePtr + (i * itemSize);

                    var cstatus = *(uint*)(item + statusOffset);
                    if (cstatus != PdhCstatusValidData && cstatus != PdhCstatusNewData) continue;

                    var namePtr = *(nint*)item;
                    if (namePtr == nint.Zero) continue;

                    var value = *(double*)(item + valueOffset);
                    if (value <= 0) continue;

                    var name = Marshal.PtrToStringUni(namePtr);
                    if (name is null) continue;

                    onItem(name, value);
                }
            }
        }
    }

    /// <inheritdoc />
    public void Dispose()
    {
        if (_disposed) return;
        _disposed = true;
        PdhCloseQuery(_query);
        _buffer = [];
    }

    [LibraryImport("pdh.dll", EntryPoint = "PdhOpenQueryW", StringMarshalling = StringMarshalling.Utf16)]
    private static partial uint PdhOpenQuery(string? dataSource, nint userData, out nint query);

    [LibraryImport("pdh.dll", EntryPoint = "PdhAddEnglishCounterW", StringMarshalling = StringMarshalling.Utf16)]
    private static partial uint PdhAddEnglishCounter(nint query, string path, nint userData, out nint counter);

    [LibraryImport("pdh.dll")]
    private static partial uint PdhCollectQueryData(nint query);

    [LibraryImport("pdh.dll", EntryPoint = "PdhGetFormattedCounterArrayW")]
    private static unsafe partial uint PdhGetFormattedCounterArray(
        nint counter, uint format, ref uint bufferSize, out uint itemCount, byte* buffer);

    [LibraryImport("pdh.dll")]
    private static partial uint PdhCloseQuery(nint query);
}
