using System.Diagnostics;
using System.Runtime.Versioning;
using Juice.Core.Battery;

namespace Juice.Platform.Windows;

/// <summary>
/// Runs <c>powercfg /batteryreport</c> and parses the result.
/// </summary>
/// <remarks>
/// <para>
/// Unlike the SRUM database, this needs no elevation, which makes it the one rich source
/// of history available to Juice without a privileged helper. It reaches back over the
/// machine's whole life, so it fills in the period before Juice was ever installed.
/// </para>
/// <para>
/// Generating the report costs a process launch and a second or two of disk work, so it
/// is not something to call on a sampling cadence. Battery health changes on the order of
/// weeks; once a day is generous.
/// </para>
/// </remarks>
[SupportedOSPlatform("windows")]
public static class BatteryReportReader
{
    /// <summary>How long to wait for powercfg before giving up.</summary>
    private static readonly TimeSpan Timeout = TimeSpan.FromSeconds(30);

    /// <summary>
    /// Generates and parses a battery report, or returns null when it cannot be produced.
    /// </summary>
    /// <remarks>
    /// Returns null rather than an empty result on failure, so callers can distinguish
    /// "this machine has no battery history" from "we could not ask".
    /// </remarks>
    public static BatteryHealth? Read()
    {
        var path = Path.Combine(Path.GetTempPath(), $"juice-battery-{Guid.NewGuid():N}.xml");

        try
        {
            if (!RunPowerCfg(path)) return null;
            if (!File.Exists(path)) return null;

            return BatteryReportParser.Parse(File.ReadAllText(path));
        }
        catch (Exception ex) when (ex is IOException
                                    or UnauthorizedAccessException
                                    or System.ComponentModel.Win32Exception)
        {
            return null;
        }
        finally
        {
            try
            {
                if (File.Exists(path)) File.Delete(path);
            }
            catch (IOException)
            {
            }
        }
    }

    private static bool RunPowerCfg(string outputPath)
    {
        var info = new ProcessStartInfo
        {
            FileName = "powercfg.exe",
            UseShellExecute = false,
            CreateNoWindow = true,
            RedirectStandardOutput = true,
            RedirectStandardError = true,
        };

        info.ArgumentList.Add("/batteryreport");
        info.ArgumentList.Add("/xml");
        info.ArgumentList.Add("/output");
        info.ArgumentList.Add(outputPath);

        using var process = Process.Start(info);
        if (process is null) return false;

        if (!process.WaitForExit(Timeout))
        {
            try
            {
                process.Kill(entireProcessTree: true);
            }
            catch (InvalidOperationException)
            {
            }

            return false;
        }

        return process.ExitCode == 0;
    }
}
