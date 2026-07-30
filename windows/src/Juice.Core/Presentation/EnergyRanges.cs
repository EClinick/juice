namespace Juice.Core.Presentation;

/// <summary>Which period the flyout's ranking and totals describe.</summary>
/// <remarks>
/// The four match the macOS switcher, because the question a user is asking does not
/// change between platforms: what is happening now, what has today cost me, is this week
/// unusual, and what does this machine do in general.
/// </remarks>
public enum EnergyRange
{
    /// <summary>The live attribution window, refreshed as it is measured.</summary>
    Session,

    /// <summary>Local midnight to now.</summary>
    Today,

    /// <summary>The rolling last seven days.</summary>
    Week,

    /// <summary>Everything still in the store.</summary>
    All,
}

/// <summary>A period resolved to the bounds a query should actually use.</summary>
/// <remarks>
/// Members are <c>init</c> with defaults rather than <c>required</c> for the reason
/// recorded in <see cref="EnergyChartSeries"/>: the WinUI XAML type-info generator emits
/// a parameterless construction for every type reachable from an <c>x:Bind</c> path, and
/// <c>required</c> members reject that at compile time.
/// </remarks>
public sealed record EnergyRangeWindow
{
    /// <summary>The range this window resolves.</summary>
    public EnergyRange Range { get; init; }

    /// <summary>Start of the period. Equal to <see cref="To"/> for a live range.</summary>
    public DateTimeOffset From { get; init; }

    /// <summary>End of the period, which is always the instant it was resolved.</summary>
    public DateTimeOffset To { get; init; }

    /// <summary>
    /// True when the period is the live attribution window rather than a stored one.
    /// </summary>
    /// <remarks>
    /// A live range is served by the sampling loop and has no bounds worth querying, so
    /// callers branch on this rather than on the enum, which keeps the query path unaware
    /// of how many stored ranges there happen to be.
    /// </remarks>
    public bool IsLive { get; init; }

    /// <summary>
    /// False when the store holds nothing inside this period, so there is nothing to ask
    /// it for.
    /// </summary>
    public bool HasRecords { get; init; }

    /// <summary>How long the period is, or zero for a live range.</summary>
    public TimeSpan Duration => To > From ? To - From : TimeSpan.Zero;

    /// <summary>
    /// How the period is described to the user, in the words the caption uses.
    /// </summary>
    /// <remarks>
    /// "All recorded" rather than "all time", because the store keeps ninety days and
    /// discards what falls out of it. Claiming to show all time would be a claim about
    /// data Juice has already deleted.
    /// </remarks>
    public string Description => Range switch
    {
        EnergyRange.Session => "this session",
        EnergyRange.Today => "since midnight",
        EnergyRange.Week => "the last 7 days",
        _ => "all recorded history",
    };
}

/// <summary>
/// Turns a chosen range into the bounds a query runs over.
/// </summary>
/// <remarks>
/// This is arithmetic about calendars and about what the store happens to hold, so it
/// lives here rather than in the view where it would need a window to exercise. The two
/// awkward cases are both handled once: a day boundary has to be the user's local
/// midnight rather than a fixed twenty four hours back, and "all" has no meaningful start
/// until something has been recorded.
/// </remarks>
public static class EnergyRanges
{
    /// <summary>How far back the week range reaches.</summary>
    /// <remarks>
    /// Rolling rather than calendar aligned, matching how Windows Settings presents
    /// battery usage. A calendar week would show a nearly empty chart every Monday
    /// morning, which says more about the calendar than about the machine.
    /// </remarks>
    public static readonly TimeSpan WeekLength = TimeSpan.FromDays(7);

    /// <summary>Resolves a range against the clock and against what has been recorded.</summary>
    /// <param name="range">The range the user selected.</param>
    /// <param name="now">The instant to resolve against.</param>
    /// <param name="earliestRecorded">
    /// Start of the oldest hour the store still holds, or null when it holds nothing.
    /// Only <see cref="EnergyRange.All"/> depends on it, but every range reports whether
    /// there is anything inside it so a caller can say "not recorded" rather than "zero".
    /// </param>
    public static EnergyRangeWindow Resolve(
        EnergyRange range,
        DateTimeOffset now,
        DateTimeOffset? earliestRecorded)
    {
        if (range == EnergyRange.Session)
        {
            return new EnergyRangeWindow
            {
                Range = range,
                From = now,
                To = now,
                IsLive = true,
                HasRecords = true,
            };
        }

        var from = range switch
        {
            EnergyRange.Today => LocalMidnight(now),
            EnergyRange.Week => now - WeekLength,
            _ => earliestRecorded ?? now,
        };

        // A stored range can start before anything was recorded, which is the normal case
        // for the first week after installation. The bounds stay as asked, because
        // narrowing the window to the data is exactly the axis pinning failure that
        // CONTRIBUTING.md forbids in charts, and the same reasoning applies to a total.
        return new EnergyRangeWindow
        {
            Range = range,
            From = from,
            To = now,
            IsLive = false,

            // The oldest hour in the store is the only thing that can be known without a
            // second query, so this says no more than it can support: there is something
            // recorded before the end of the window. Whether any of it falls inside the
            // window is answered by the query itself.
            HasRecords = earliestRecorded is { } earliest && earliest < now,
        };
    }

    /// <summary>
    /// The most recent local midnight, taking the offset in force at that midnight.
    /// </summary>
    /// <remarks>
    /// Subtracting the current offset would be wrong on the two days a year a time zone
    /// changes it, which would put the boundary an hour into yesterday or an hour into
    /// today and quietly move a day's total.
    /// </remarks>
    private static DateTimeOffset LocalMidnight(DateTimeOffset now)
    {
        var midnight = now.ToLocalTime().Date;
        var offset = TimeZoneInfo.Local.GetUtcOffset(DateTime.SpecifyKind(midnight, DateTimeKind.Unspecified));

        return new DateTimeOffset(midnight, offset);
    }
}
