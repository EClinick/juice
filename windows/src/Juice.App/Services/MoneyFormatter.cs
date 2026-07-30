using System.Globalization;

namespace Juice.App.Services;

/// <summary>
/// Formats a cost in the currency the rate is quoted in.
/// </summary>
/// <remarks>
/// The rate table quotes ISO 4217 codes, not locales, so the machine's own culture is
/// the wrong formatter: a French user reading a US average rate should still see dollars.
/// Only the symbol is localised here; when the code is not in the table Juice prints the
/// code itself rather than guessing a symbol and implying the wrong currency.
/// </remarks>
public static class MoneyFormatter
{
    private static readonly Dictionary<string, string> Symbols = new(StringComparer.OrdinalIgnoreCase)
    {
        ["USD"] = "$",
        ["CAD"] = "$",
        ["AUD"] = "$",
        ["NZD"] = "$",
        ["EUR"] = "\u20ac",
        ["GBP"] = "\u00a3",
        ["JPY"] = "\u00a5",
        ["CNY"] = "\u00a5",
        ["INR"] = "\u20b9",
        ["KRW"] = "\u20a9",
        ["BRL"] = "R$",
        ["MXN"] = "$",
        ["ZAR"] = "R",
        ["PLN"] = "z\u0142",
        ["SEK"] = "kr",
        ["NOK"] = "kr",
        ["DKK"] = "kr",
    };

    /// <summary>Formats an amount, choosing a sensible number of decimal places.</summary>
    /// <remarks>
    /// <para>
    /// Sub-cent amounts round to zero at two places, and "$0.00 a year" reads as "nothing"
    /// when the honest answer is "less than a cent", so those get a third decimal.
    /// </para>
    /// <para>
    /// A third decimal only moves the problem, it does not solve it. A period covering a
    /// few minutes produces costs below a tenth of a cent, and those printed as "$0.000",
    /// which reads as a broken formatter rather than as a very small number. Anything that
    /// is genuinely non-zero but rounds away at the chosen precision is therefore printed
    /// as a bound, "&lt;$0.001", which is the one statement that is both true and legible.
    /// An amount that is exactly zero keeps "$0.00", because no energy really did cost
    /// nothing and hedging that would be its own small lie.
    /// </para>
    /// </remarks>
    public static string Format(decimal amount, string currency)
    {
        var digits = Math.Abs(amount) is > 0 and < 0.01m ? 3 : 2;

        var rounded = Math.Round(amount, digits, MidpointRounding.AwayFromZero);
        var vanished = amount != 0 && rounded == 0;

        // The bound is the smallest magnitude the chosen precision can express, so it
        // tracks the digit count rather than being spelled out twice.
        var smallest = (decimal)Math.Pow(10, -digits);
        var number = (vanished ? smallest : rounded).ToString("N" + digits, CultureInfo.InvariantCulture);
        var prefix = vanished ? (amount < 0 ? ">-" : "<") : string.Empty;

        return Symbols.TryGetValue(currency, out var symbol)
            ? prefix + symbol + number
            : $"{prefix}{number} {currency}";
    }
}
