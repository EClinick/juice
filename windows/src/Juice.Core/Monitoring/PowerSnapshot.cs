using Juice.Core.Attribution;
using Juice.Core.Power;

namespace Juice.Core.Monitoring;

/// <summary>
/// Everything one pass of the sampling loop produced, already formatted where formatting
/// is cheap and left raw where the view needs the number.
/// </summary>
/// <remarks>
/// The snapshot is immutable and is the only thing that crosses from the sampling thread
/// to the UI thread. Passing the live <see cref="IProcessSampler"/>
/// buffers instead would hand the UI a list that the next sample is about to overwrite.
/// </remarks>
public sealed record PowerSnapshot
{
    /// <summary>The reading, or null when no source could produce one.</summary>
    public PowerSample? Sample { get; init; }

    /// <summary>Drain classification for the tray tint.</summary>
    public DrainSeverity Severity { get; init; } = DrainSeverity.Unknown;

    /// <summary>The at-most-three character string for the tray icon.</summary>
    public required string TrayLabel { get; init; }

    /// <summary>Tooltip text for the tray icon.</summary>
    public required string Tooltip { get; init; }

    /// <summary>Remaining battery runtime as Windows estimates it, or null.</summary>
    public TimeSpan? Remaining { get; init; }

    /// <summary>
    /// Most recent attribution, or null when no window has closed yet. Kept across
    /// snapshots so the app list does not blank out between process samples.
    /// </summary>
    public AttributionResult? Attribution { get; init; }

    /// <summary>Lowest draw observed this session, used as the classifier baseline.</summary>
    public double? IdleBaselineWatts { get; init; }
}
