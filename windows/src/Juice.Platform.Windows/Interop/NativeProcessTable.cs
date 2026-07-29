using System.Runtime.InteropServices;
using System.Runtime.Versioning;

namespace Juice.Platform.Windows.Interop;

/// <summary>One process as reported by the kernel in a single system-wide snapshot.</summary>
public readonly record struct NativeProcessInfo(int ProcessId, string Name, TimeSpan ProcessorTime);

/// <summary>
/// Reads the whole process table in one call via <c>NtQuerySystemInformation</c>.
/// </summary>
/// <remarks>
/// <para>
/// <c>Process.GetProcesses()</c> opens a handle per process and allocates a managed
/// object per process, then requires a further query per process to read its CPU time.
/// On a busy desktop that is several hundred handles opened and closed on every sample.
/// </para>
/// <para>
/// <c>SystemProcessInformation</c> returns the entire table, including per-process kernel
/// and user time, in a single buffer with no handles at all. The buffer is pooled across
/// samples, so a steady-state sample allocates only the strings for process names.
/// </para>
/// <para>
/// This is an undocumented but extremely stable NT API, and it is what Task Manager
/// itself uses. <see cref="TryRead"/> fails closed so callers can fall back to the
/// managed path if a future Windows release changes the layout.
/// </para>
/// </remarks>
[SupportedOSPlatform("windows")]
public sealed partial class NativeProcessTable : IDisposable
{
    private const int SystemProcessInformation = 5;
    private const uint StatusInfoLengthMismatch = 0xC0000004;
    private const uint StatusSuccess = 0;

    // Field offsets within SYSTEM_PROCESS_INFORMATION on 64 bit Windows.
    private const int OffsetNextEntry = 0x00;
    private const int OffsetUserTime = 0x28;
    private const int OffsetKernelTime = 0x30;
    private const int OffsetImageNameLength = 0x38;
    private const int OffsetImageNameBuffer = 0x40;
    private const int OffsetUniqueProcessId = 0x50;

    private byte[] _buffer = new byte[512 * 1024];
    private bool _disposed;

    /// <summary>
    /// Reads every process, invoking <paramref name="onProcess"/> for each.
    /// </summary>
    /// <returns>False when the snapshot could not be taken.</returns>
    public bool TryRead(Action<NativeProcessInfo> onProcess)
    {
        if (_disposed || nint.Size != 8) return false;

        for (var attempt = 0; attempt < 6; attempt++)
        {
            uint status;
            uint needed;

            unsafe
            {
                fixed (byte* p = _buffer)
                {
                    status = NtQuerySystemInformation(
                        SystemProcessInformation, p, (uint)_buffer.Length, out needed);
                }
            }

            if (status == StatusSuccess)
            {
                Parse(onProcess);
                return true;
            }

            if (status != StatusInfoLengthMismatch) return false;

            // The table grows between the size query and the read, so add headroom
            // rather than sizing exactly and immediately failing again.
            _buffer = new byte[Math.Max(needed + (64 * 1024), (uint)_buffer.Length * 2)];
        }

        return false;
    }

    private void Parse(Action<NativeProcessInfo> onProcess)
    {
        unsafe
        {
            fixed (byte* basePtr = _buffer)
            {
                var offset = 0;

                while (true)
                {
                    if (offset < 0 || offset + OffsetUniqueProcessId + 8 > _buffer.Length) return;

                    var entry = basePtr + offset;

                    var pid = (int)*(nint*)(entry + OffsetUniqueProcessId);
                    var userTime = *(long*)(entry + OffsetUserTime);
                    var kernelTime = *(long*)(entry + OffsetKernelTime);

                    // Kernel and user time are in 100 nanosecond units, the same base as
                    // TimeSpan ticks, so they combine without conversion.
                    var processorTime = new TimeSpan(userTime + kernelTime);

                    var nameLength = *(ushort*)(entry + OffsetImageNameLength);
                    var namePtr = *(nint*)(entry + OffsetImageNameBuffer);

                    var name = namePtr != nint.Zero && nameLength > 0
                        ? new string((char*)namePtr, 0, nameLength / 2)
                        : pid == 0 ? "System Idle Process" : string.Empty;

                    // Process id 0 is the idle process: its "CPU time" is idle time and
                    // must never be attributed energy.
                    if (pid != 0 && name.Length > 0)
                    {
                        onProcess(new NativeProcessInfo(pid, StripExtension(name), processorTime));
                    }

                    var next = *(uint*)(entry + OffsetNextEntry);
                    if (next == 0) return;

                    offset += (int)next;
                }
            }
        }
    }

    private static string StripExtension(string imageName)
    {
        var dot = imageName.LastIndexOf('.');
        return dot > 0 && imageName.AsSpan(dot).Equals(".exe", StringComparison.OrdinalIgnoreCase)
            ? imageName[..dot]
            : imageName;
    }

    /// <inheritdoc />
    public void Dispose()
    {
        if (_disposed) return;
        _disposed = true;
        _buffer = [];
    }

    [LibraryImport("ntdll.dll")]
    private static unsafe partial uint NtQuerySystemInformation(
        int systemInformationClass, byte* systemInformation, uint length, out uint returnLength);
}
