using System.Diagnostics;
using System.Globalization;
using System.Runtime.Versioning;
using Juice.Core.Attribution;
using Juice.Core.Monitoring;
using Juice.Core.Power;
using Juice.Platform.Windows.Interop;

namespace Juice.Platform.Windows;

/// <summary>
/// Samples per-process CPU time and GPU utilisation, the two signals Juice uses to
/// divide measured rail energy between apps.
/// </summary>
/// <remarks>
/// <para>
/// This is the most expensive thing Juice does, so both halves use bulk APIs. The
/// process table comes from a single <c>NtQuerySystemInformation</c> call, and GPU
/// utilisation from a single PDH wildcard query, rather than one object per process and
/// one per GPU engine instance. On a desktop with several hundred processes and over
/// five hundred GPU engine instances, the naive approach costs more energy than most of
/// the apps it is trying to measure.
/// </para>
/// <para>
/// Both fast paths degrade to managed equivalents if the native calls fail, so the app
/// keeps working on a Windows build that changes either surface.
/// </para>
/// </remarks>
[SupportedOSPlatform("windows")]
public sealed class ProcessSampler : IDisposable, IProcessSampler
{
    private const string GpuCounterPath = @"\GPU Engine(*)\Utilization Percentage";

    private readonly NativeProcessTable _processTable = new();
    private readonly PdhWildcardCounter? _gpuCounter;

    // Reused between samples so a steady-state sample allocates almost nothing.
    private readonly Dictionary<int, double> _gpuByPid = [];
    private readonly List<ProcessSample> _samples = [];

    private bool _nativeProcessTableWorks = true;
    private bool _disposed;

    /// <summary>Creates a sampler, opening the GPU query once for the process lifetime.</summary>
    public ProcessSampler()
    {
        _gpuCounter = PdhWildcardCounter.TryOpen(GpuCounterPath);
    }

    /// <summary>True when per-process GPU utilisation can be read on this machine.</summary>
    public bool GpuCountersAvailable => _gpuCounter is not null;

    /// <summary>True while the bulk process table read is working.</summary>
    public bool UsingNativeProcessTable => _nativeProcessTableWorks;

    /// <summary>
    /// Takes one sample of every visible process.
    /// </summary>
    /// <remarks>
    /// The returned list is reused between calls, so callers must finish with it before
    /// calling <see cref="Sample"/> again. This keeps a sampler that runs for weeks from
    /// producing steady garbage collector pressure.
    /// </remarks>
    public IReadOnlyList<ProcessSample> Sample()
    {
        _gpuByPid.Clear();
        _samples.Clear();

        CollectGpu();

        if (_nativeProcessTableWorks)
        {
            var ok = _processTable.TryRead(info => _samples.Add(new ProcessSample
            {
                ProcessId = info.ProcessId,
                ProcessName = info.Name,
                TotalProcessorTime = info.ProcessorTime,
                GpuUtilization = _gpuByPid.GetValueOrDefault(info.ProcessId),
            }));

            if (ok) return _samples;

            _nativeProcessTableWorks = false;
            _samples.Clear();
        }

        CollectManaged();
        return _samples;
    }

    private void CollectGpu()
    {
        _gpuCounter?.Collect((name, value) =>
        {
            if (ParsePid(name) is not { } pid) return;
            _gpuByPid[pid] = _gpuByPid.GetValueOrDefault(pid) + value;
        });
    }

    private void CollectManaged()
    {
        foreach (var process in Process.GetProcesses())
        {
            try
            {
                _samples.Add(new ProcessSample
                {
                    ProcessId = process.Id,
                    ProcessName = process.ProcessName,
                    TotalProcessorTime = process.TotalProcessorTime,
                    GpuUtilization = _gpuByPid.GetValueOrDefault(process.Id),
                });
            }
            catch (Exception ex) when (ex is InvalidOperationException
                                        or System.ComponentModel.Win32Exception
                                        or NotSupportedException)
            {
                // Protected or exited processes cannot be read. Their energy is real but
                // unattributable, so it stays in the platform bucket rather than being
                // spread across innocent apps.
            }
            finally
            {
                process.Dispose();
            }
        }
    }

    /// <summary>
    /// Extracts the process id from a <c>GPU Engine</c> instance name of the form
    /// <c>pid_1234_luid_0x00000000_0x0000C4C1_phys_0_eng_0_engtype_3D</c>.
    /// Returns null when the name does not carry one.
    /// </summary>
    internal static int? ParsePid(string instanceName)
    {
        const string prefix = "pid_";
        if (!instanceName.StartsWith(prefix, StringComparison.Ordinal)) return null;

        var rest = instanceName.AsSpan(prefix.Length);
        var end = rest.IndexOf('_');
        var digits = end < 0 ? rest : rest[..end];

        return int.TryParse(digits, NumberStyles.None, CultureInfo.InvariantCulture, out var pid)
            ? pid
            : null;
    }

    /// <inheritdoc />
    public void Dispose()
    {
        if (_disposed) return;
        _disposed = true;
        _processTable.Dispose();
        _gpuCounter?.Dispose();
    }
}
