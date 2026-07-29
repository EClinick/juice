using System.Runtime.InteropServices;
using System.Runtime.Versioning;

namespace Juice.Platform.Windows;

/// <summary>
/// Releases resident memory when the application has nothing on screen.
/// </summary>
/// <remarks>
/// <para>
/// Juice sits in the notification area for weeks at a time and is visible for seconds of
/// that. Holding a full working set the whole while is exactly the sort of background cost
/// the application exists to complain about, so when the last window closes it collects,
/// compacts, and asks the kernel to trim its resident pages.
/// </para>
/// <para>
/// Trimming does not free memory in the sense of returning it to the heap. It empties the
/// working set, so pages that are genuinely still needed fault back in on demand and
/// pages that were only needed while a window was open do not. That trade is right here
/// and wrong in most applications: the cost is a slower next open, and the next open is
/// seconds of human reaction time away.
/// </para>
/// <para>
/// It is deliberately not called on a timer or after every sample. Trimming repeatedly
/// while the process is still working causes the same pages to fault back in immediately,
/// which burns more energy than it saves.
/// </para>
/// </remarks>
[SupportedOSPlatform("windows")]
public static partial class ProcessMemory
{
    /// <summary>
    /// Compacts the managed heap and empties the process working set.
    /// </summary>
    /// <remarks>
    /// The collection happens first so that the pages backing unreachable objects are
    /// actually reclaimable before the trim, otherwise the trim evicts memory the runtime
    /// is about to reuse.
    /// </remarks>
    public static void TrimAfterIdle()
    {
        // Compacting matters more than usual here. The large object heap fragments badly
        // with the buffers this app reuses, and a trim only helps if the survivors have
        // been packed together first.
        System.Runtime.GCSettings.LargeObjectHeapCompactionMode =
            System.Runtime.GCLargeObjectHeapCompactionMode.CompactOnce;

        GC.Collect(GC.MaxGeneration, GCCollectionMode.Aggressive, blocking: true, compacting: true);
        GC.WaitForPendingFinalizers();
        GC.Collect(GC.MaxGeneration, GCCollectionMode.Forced, blocking: true, compacting: true);

        Trim();
    }

    /// <summary>
    /// Empties the working set without touching the managed heap.
    /// </summary>
    /// <remarks>
    /// Passing -1 for both sizes is the documented way to ask the kernel to trim as much
    /// as it can. Failure is ignored: this is an optimisation, and a process that cannot
    /// trim is merely using more memory than it might.
    /// </remarks>
    public static void Trim()
    {
        try
        {
            SetProcessWorkingSetSize(GetCurrentProcess(), -1, -1);
        }
        catch (EntryPointNotFoundException)
        {
        }
    }

    [LibraryImport("kernel32.dll")]
    private static partial nint GetCurrentProcess();

    [LibraryImport("kernel32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static partial bool SetProcessWorkingSetSize(nint process, nint minimumWorkingSetSize, nint maximumWorkingSetSize);
}
