using Juice.Core.Attribution;

namespace Juice.Core.Monitoring;

/// <summary>
/// Supplies the process table the attributor divides rail energy across.
/// </summary>
/// <remarks>
/// Declared in Core rather than in a platform assembly so that the sampling loop can live
/// beside the attribution it feeds. Implementations are expected to reuse their buffer
/// between calls, so a caller that needs to keep a result must copy it.
/// </remarks>
public interface IProcessSampler
{
    /// <summary>Reads the current process table.</summary>
    IReadOnlyList<ProcessSample> Sample();
}

/// <summary>
/// Supplies the operating system's own estimate of remaining battery runtime.
/// </summary>
/// <remarks>
/// Juice never computes this itself. Dividing remaining charge by present draw produces a
/// figure that lurches with every burst of activity, and smoothing it would be inventing a
/// number rather than measuring one.
/// </remarks>
public interface IBatteryRuntimeReader
{
    /// <summary>Time left on battery, or null on AC or when the platform will not say.</summary>
    TimeSpan? RemainingRuntime();
}
