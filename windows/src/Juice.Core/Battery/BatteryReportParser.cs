using System.Globalization;
using System.Xml.Linq;

namespace Juice.Core.Battery;

/// <summary>
/// Parses the XML produced by <c>powercfg /batteryreport /xml</c>.
/// </summary>
/// <remarks>
/// <para>
/// This is the one place Windows gives away more than macOS. The report needs no
/// elevation, and it carries weekly capacity and cycle-count history going back as far as
/// the machine's life, which is history Juice could never reconstruct itself because it
/// predates the app being installed.
/// </para>
/// <para>
/// Parsing is deliberately tolerant. The schema is not versioned in any useful way, so a
/// missing or renamed attribute drops that entry rather than failing the whole report.
/// Capacities are in milliwatt-hours and are converted to watt-hours here so that nothing
/// downstream has to remember which unit it is holding.
/// </para>
/// </remarks>
public static class BatteryReportParser
{
    private static readonly XNamespace Ns = "http://schemas.microsoft.com/battery/2012";

    /// <summary>Parses a battery report document.</summary>
    /// <param name="xml">Contents of the report produced with the <c>/xml</c> switch.</param>
    public static BatteryHealth Parse(string xml)
    {
        try
        {
            return Parse(XDocument.Parse(xml));
        }
        catch (System.Xml.XmlException)
        {
            return new BatteryHealth();
        }
    }

    /// <summary>Parses an already-loaded battery report document.</summary>
    public static BatteryHealth Parse(XDocument document)
    {
        var entries = document
            .Descendants(Ns + "HistoryEntry")
            .Select(ParseEntry)
            .Where(e => e is not null)
            .Select(e => e!)
            .OrderBy(e => e.Start)
            .ToList();

        return new BatteryHealth { History = entries };
    }

    private static BatteryHealthPoint? ParseEntry(XElement element)
    {
        // A row without a usable full charge capacity says nothing about health, and a
        // zero would render as a totally dead battery, so it is dropped instead.
        if (ReadDouble(element, "FullChargeCapacity") is not { } full || full <= 0) return null;

        var design = ReadDouble(element, "DesignCapacity") ?? 0;

        return new BatteryHealthPoint
        {
            Start = ReadDate(element, "LocalStartDate") ?? ReadDate(element, "StartDate") ?? default,
            End = ReadDate(element, "LocalEndDate") ?? ReadDate(element, "EndDate") ?? default,
            DesignWattHours = design / 1000.0,
            FullChargeWattHours = full / 1000.0,
            CycleCount = ReadInt(element, "CycleCount"),
        };
    }

    private static double? ReadDouble(XElement element, string name)
        => double.TryParse(
            element.Attribute(name)?.Value,
            NumberStyles.Float,
            CultureInfo.InvariantCulture,
            out var value)
            ? value
            : null;

    private static int? ReadInt(XElement element, string name)
        => int.TryParse(
            element.Attribute(name)?.Value,
            NumberStyles.Integer,
            CultureInfo.InvariantCulture,
            out var value)
            ? value
            : null;

    private static DateTimeOffset? ReadDate(XElement element, string name)
        => DateTimeOffset.TryParse(
            element.Attribute(name)?.Value,
            CultureInfo.InvariantCulture,
            DateTimeStyles.AssumeLocal,
            out var value)
            ? value
            : null;
}
