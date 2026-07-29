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
    public static string Format(decimal amount, string currency)
    {
        // Sub-cent amounts round to zero at two places, and "$0.00 a year" reads as
        // "nothing" when the honest answer is "less than a cent".
        var digits = Math.Abs(amount) is > 0 and < 0.01m ? 3 : 2;
        var number = amount.ToString("N" + digits, CultureInfo.InvariantCulture);

        return Symbols.TryGetValue(currency, out var symbol)
            ? symbol + number
            : $"{number} {currency}";
    }
}
