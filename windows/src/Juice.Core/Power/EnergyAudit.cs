namespace Juice.Core.Power;

/// <summary>Result of auditing measured energy against independently derived energy.</summary>
public sealed record EnergyAuditResult
{
    /// <summary>Length of the audit window.</summary>
    public required double Seconds { get; init; }

    /// <summary>Energy taken from the hardware accumulator delta.</summary>
    public required double AccumulatorWattHours { get; init; }

    /// <summary>Energy obtained by integrating the instantaneous power counter.</summary>
    public required double IntegratedWattHours { get; init; }

    /// <summary>Number of power samples taken.</summary>
    public required int SampleCount { get; init; }

    /// <summary>Tolerance the audit was judged against, as a percentage.</summary>
    public required double TolerancePercent { get; init; }

    /// <summary>Signed disagreement between the two derivations, as a percentage.</summary>
    public double PercentDifference => AccumulatorWattHours <= 0
        ? 0
        : (IntegratedWattHours - AccumulatorWattHours) / AccumulatorWattHours * 100.0;

    /// <summary>True when the two derivations agree within tolerance.</summary>
    public bool Passed => AccumulatorWattHours > 0
                          && Math.Abs(PercentDifference) <= TolerancePercent;
}

/// <summary>
/// Cross-checks the two independent ways of deriving energy from a rail source.
/// </summary>
/// <remarks>
/// <para>
/// The repository rule is that displayed numbers must be verified against the raw
/// source rather than only against unit tests. On Windows there are two genuinely
/// independent derivations available at runtime: the hardware energy accumulator, and
/// the integral of the instantaneous power counter. They come from different counters
/// and different arithmetic, so if they agree the watt-hour figures Juice displays are
/// sound.
/// </para>
/// <para>
/// This is also what established the picowatt-hour unit in <see cref="EnergyUnits"/> in
/// the first place, so the audit doubles as a regression test for that constant: if a
/// future Windows release changed the scaling, this would immediately start failing.
/// </para>
/// <para>
/// The default tolerance is deliberately loose. Integration of a sampled signal cannot
/// exactly reproduce an accumulator when the load is changing, so a few percent of
/// disagreement is expected and only a gross mismatch indicates a real problem.
/// </para>
/// </remarks>
public static class EnergyAudit
{
    /// <summary>Default tolerance, as a percentage.</summary>
    public const double DefaultTolerancePercent = 10.0;

    /// <summary>
    /// Runs an audit over the given window, sampling roughly once per second.
    /// </summary>
    /// <param name="source">Source to audit. Must expose a system rail accumulator.</param>
    /// <param name="window">How long to sample for.</param>
    /// <param name="rail">Rail to audit.</param>
    /// <param name="tolerancePercent">Allowed disagreement.</param>
    /// <param name="sleep">Delay function, injectable so tests need not really wait.</param>
    /// <param name="clock">Clock, injectable for tests.</param>
    public static EnergyAuditResult Run(
        IPowerSource source,
        TimeSpan window,
        PowerRail rail = PowerRail.System,
        double tolerancePercent = DefaultTolerancePercent,
        Action<TimeSpan>? sleep = null,
        Func<DateTimeOffset>? clock = null)
    {
        sleep ??= Thread.Sleep;
        clock ??= () => DateTimeOffset.UtcNow;

        var first = source.Read();
        var startAccumulator = first?.CumulativeWattHoursFor(rail);
        var startTime = clock();

        var previousTime = startTime;
        var previousWatts = first?.WattsFor(rail) ?? 0;

        var integrated = 0.0;
        var samples = 1;
        double? endAccumulator = startAccumulator;
        var endTime = startTime;

        while (clock() - startTime < window)
        {
            sleep(TimeSpan.FromSeconds(1));

            if (source.Read() is not { } sample) continue;

            var now = clock();
            var watts = sample.WattsFor(rail) ?? previousWatts;

            // Trapezoid rule: the mean of the endpoints over the elapsed time.
            integrated += (watts + previousWatts) / 2.0 * (now - previousTime).TotalHours;

            previousWatts = watts;
            previousTime = now;
            endAccumulator = sample.CumulativeWattHoursFor(rail) ?? endAccumulator;
            endTime = now;
            samples++;
        }

        var accumulated = startAccumulator is { } a && endAccumulator is { } b && b >= a
            ? b - a
            : 0.0;

        return new EnergyAuditResult
        {
            Seconds = (endTime - startTime).TotalSeconds,
            AccumulatorWattHours = accumulated,
            IntegratedWattHours = integrated,
            SampleCount = samples,
            TolerancePercent = tolerancePercent,
        };
    }
}
