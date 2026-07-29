using System.Globalization;
using System.Runtime.Versioning;
using System.Text;
using Juice.Core.Monitoring;
using Juice.Platform.Windows;
using Juice.Core.Power;

namespace Juice.App.Services;

/// <summary>
/// Builds the plain text report behind "Copy diagnostics".
/// </summary>
/// <remarks>
/// Juice's numbers differ enormously between machines depending on whether an Energy
/// Meter is present, so the first question about any reported number is which tier
/// produced it. This report answers that in a form a user can paste into an issue,
/// without collecting anything about them beyond the hardware capability set.
/// </remarks>
[SupportedOSPlatform("windows10.0.19041.0")]
public static class DiagnosticsReport
{
    /// <summary>Renders the report for the current machine and monitor state.</summary>
    public static string Build(PowerMonitor monitor, RateService rates, PowerSnapshot? latest)
    {
        var report = new StringBuilder();

        report.AppendLine("Juice diagnostics");
        report.AppendLine(CultureInfo.InvariantCulture, $"Version: {AppVersion()}");
        report.AppendLine(CultureInfo.InvariantCulture, $"Windows: {Environment.OSVersion.Version}");
        report.AppendLine(CultureInfo.InvariantCulture,
            $"Architecture: {System.Runtime.InteropServices.RuntimeInformation.ProcessArchitecture}");
        report.AppendLine();

        report.AppendLine("Power source");
        if (monitor.Source is { } source)
        {
            report.AppendLine(CultureInfo.InvariantCulture, $"  Active tier: {TierName(source.Tier)}");
            report.AppendLine(CultureInfo.InvariantCulture, $"  Description: {source.Description}");

            foreach (var candidate in (source as CompositePowerSource)?.Sources ?? [])
            {
                var availability = candidate.IsAvailable ? "available" : "unavailable";
                report.AppendLine(CultureInfo.InvariantCulture,
                    $"  - {TierName(candidate.Tier)}: {availability} - {candidate.Description}");
            }
        }
        else
        {
            report.AppendLine("  Not initialised yet.");
        }

        report.AppendLine();
        report.AppendLine("Process sampling");
        if (monitor.Processes is { } processes)
        {
            report.AppendLine(CultureInfo.InvariantCulture,
                $"  Per-process GPU counters: {((processes as ProcessSampler)?.GpuCountersAvailable == true ? "available" : "unavailable")}");
            report.AppendLine(CultureInfo.InvariantCulture,
                $"  Native process table: {((processes as ProcessSampler)?.UsingNativeProcessTable == true ? "in use" : "fallen back to managed enumeration")}");
        }
        else
        {
            report.AppendLine("  Not initialised yet.");
        }

        report.AppendLine();
        report.AppendLine("Latest reading");
        if (latest?.Sample is { } sample)
        {
            report.AppendLine(CultureInfo.InvariantCulture, $"  Timestamp: {sample.Timestamp:O}");
            report.AppendLine(CultureInfo.InvariantCulture, $"  System: {PowerFormatter.Watts(sample.SystemWatts)}");
            report.AppendLine(CultureInfo.InvariantCulture, $"  On AC: {sample.OnAc}");
            report.AppendLine(CultureInfo.InvariantCulture,
                $"  Battery: {(sample.BatteryPercent is { } p ? p.ToString("0", CultureInfo.InvariantCulture) + "%" : "none")}");

            foreach (var rail in sample.Rails)
            {
                report.AppendLine(CultureInfo.InvariantCulture,
                    $"  Rail {rail.Rail} ({rail.InstanceName}): {rail.Watts:0.000} W");
            }
        }
        else
        {
            report.AppendLine("  No reading yet.");
        }

        report.AppendLine();
        report.AppendLine("Electricity rate");
        var rate = rates.Current;
        report.AppendLine(CultureInfo.InvariantCulture, $"  Region: {rate.RegionName} ({rate.RegionCode})");
        report.AppendLine(CultureInfo.InvariantCulture,
            $"  Price: {rate.PricePerKwh.ToString("0.000", CultureInfo.InvariantCulture)} {rate.Currency} per kWh");
        report.AppendLine(CultureInfo.InvariantCulture, $"  Source: {rate.Source} (estimate: {rate.IsEstimate})");

        return report.ToString();
    }

    /// <summary>Human-readable tier name, matching the wording used in the flyout.</summary>
    public static string TierName(PowerSourceTier tier) => tier switch
    {
        PowerSourceTier.HardwareRail => "hardware meter",
        PowerSourceTier.Battery => "battery discharge",
        PowerSourceTier.Modelled => "estimated",
        _ => "not measured",
    };

    private static string AppVersion()
    {
        try
        {
            var version = Windows.ApplicationModel.Package.Current.Id.Version;
            return $"{version.Major}.{version.Minor}.{version.Build}.{version.Revision}";
        }
        catch (Exception ex) when (ex is InvalidOperationException or ArgumentException)
        {
            return typeof(DiagnosticsReport).Assembly.GetName().Version?.ToString() ?? "unknown";
        }
    }
}
