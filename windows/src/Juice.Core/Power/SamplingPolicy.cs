namespace Juice.Core.Power;

/// <summary>What the user can currently see, which decides how hard Juice may work.</summary>
public enum ActivityState
{
    /// <summary>A Juice window or flyout is open and the user is watching live numbers.</summary>
    Foreground,

    /// <summary>Only the tray icon is visible. Its number is the sole live consumer.</summary>
    TrayOnly,

    /// <summary>Display is off or the session is locked. Nothing is being read.</summary>
    DisplayOff,

    /// <summary>Machine is entering or in modern standby. Juice must stop entirely.</summary>
    Suspended,
}

/// <summary>How often to sample, split by cost.</summary>
/// <param name="Power">
/// Interval between power readings. Cheap: a handful of counter reads.
/// </param>
/// <param name="Process">
/// Interval between per-process samples, or null to skip them. Expensive: enumerating
/// every process and every GPU engine instance.
/// </param>
public readonly record struct SamplingCadence(TimeSpan Power, TimeSpan? Process);

/// <summary>
/// Decides sampling cadence so that Juice never shows up in its own top energy users.
/// </summary>
/// <remarks>
/// <para>
/// The governing insight is that the hardware energy counters are cumulative. Energy
/// accrues in the counter whether or not Juice is looking, so a longer interval costs
/// resolution but never accuracy: totals over a day are identical at a 1 second and a
/// 60 second cadence. That makes it safe to be lazy by default and fast only when the
/// user is actually watching a live number.
/// </para>
/// <para>
/// Per-process sampling has no such accumulator. CPU time is cumulative per process, but
/// GPU utilisation is instantaneous, and a process that starts and exits between two
/// samples is invisible. Attribution therefore degrades with longer intervals even
/// though system totals do not, which is why process sampling has its own cadence and is
/// dropped entirely when nobody can see the result.
/// </para>
/// </remarks>
public static class SamplingPolicy
{
    /// <summary>Cadence for a given activity state and power source.</summary>
    /// <param name="state">What the user can see.</param>
    /// <param name="onAc">
    /// True when on external power. On battery Juice deliberately backs off further,
    /// because a battery monitor that measurably shortens battery life is self-defeating.
    /// </param>
    public static SamplingCadence For(ActivityState state, bool onAc) => state switch
    {
        // Someone is reading live watts, so resolution matters more than cost.
        ActivityState.Foreground => new(
            TimeSpan.FromSeconds(1),
            TimeSpan.FromSeconds(onAc ? 2 : 3)),

        // Only the tray number updates, and it is rounded to whole watts anyway, so
        // there is nothing to gain from sub-5-second reads.
        ActivityState.TrayOnly => new(
            TimeSpan.FromSeconds(onAc ? 5 : 10),
            TimeSpan.FromSeconds(onAc ? 30 : 60)),

        // Nothing is visible. Keep the history honest with occasional accumulator reads
        // and stop touching the process table completely.
        ActivityState.DisplayOff => new(TimeSpan.FromMinutes(5), null),

        // Modern standby. Any wake here is charged directly against the user's battery.
        ActivityState.Suspended => new(Timeout, null),

        _ => new(TimeSpan.FromSeconds(10), TimeSpan.FromSeconds(60)),
    };

    /// <summary>Sentinel meaning "do not sample at all".</summary>
    public static readonly TimeSpan Timeout = System.Threading.Timeout.InfiniteTimeSpan;

    /// <summary>True when the cadence means Juice should be completely idle.</summary>
    public static bool IsIdle(SamplingCadence cadence) => cadence.Power == Timeout;

    /// <summary>
    /// Longest interval whose energy Juice will still record as continuous.
    /// </summary>
    /// <remarks>
    /// Matches the macOS version's five minute rule. A gap longer than this is reported
    /// as missing monitoring coverage rather than being integrated across, so a laptop
    /// that slept for six hours never produces a fabricated six hour energy figure.
    /// </remarks>
    public static readonly TimeSpan MaxContinuousGap = TimeSpan.FromMinutes(5);

    /// <summary>
    /// True when the interval between two samples is short enough to treat as continuous
    /// recording.
    /// </summary>
    public static bool IsContinuous(TimeSpan gap) => gap > TimeSpan.Zero && gap <= MaxContinuousGap;
}
