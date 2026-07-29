namespace Juice.Core.Presentation;

/// <summary>
/// Turns a measured value into its share of the largest value it is ranked against, for
/// the proportional bars behind a ranked list.
/// </summary>
/// <remarks>
/// The share is never floored to a visible minimum. A row that drew almost nothing has to
/// look like it drew almost nothing, and padding its bar up to something noticeable would
/// be asserting a magnitude the measurement does not support.
/// </remarks>
public static class RankingShare
{
    /// <summary>
    /// <paramref name="value"/> as a fraction of <paramref name="heaviest"/>, from 0 to 1.
    /// </summary>
    /// <remarks>
    /// Zero when there is nothing to compare against. That covers an empty list and a
    /// list where everything measured zero, which are both cases where no row outranks
    /// any other and so no row has earned a bar.
    /// </remarks>
    public static double Of(double value, double heaviest)
    {
        if (double.IsNaN(value) || double.IsNaN(heaviest)) return 0;
        if (heaviest <= 0 || value <= 0) return 0;

        return Math.Clamp(value / heaviest, 0, 1);
    }

    /// <summary>Largest value in a set, or zero when there is no positive value in it.</summary>
    public static double Heaviest(IEnumerable<double> values)
    {
        ArgumentNullException.ThrowIfNull(values);

        var heaviest = 0.0;

        foreach (var value in values)
        {
            if (double.IsNaN(value)) continue;
            heaviest = Math.Max(heaviest, value);
        }

        return heaviest;
    }
}
