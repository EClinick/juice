using System.Text.Json;
using System.Text.Json.Serialization;

namespace Juice.Core.Contracts;

/// <summary>
/// The versioned JSON contract Juice emits in tools mode.
/// </summary>
/// <remarks>
/// <para>
/// The command line has two modes. The default is a human-readable terminal view. The
/// <c>--json</c> switch selects tools mode, intended for scripts and AI agents, where
/// every byte on stdout is machine-readable including failures.
/// </para>
/// <para>
/// The schema, not the command set, is the cross-platform contract. A consumer asking
/// what is drawing power should not care whether it is talking to macOS or Windows, so
/// the shape is designed to describe both without either platform having to lie.
/// </para>
/// <para>
/// Three rules make that possible, and they are the same honesty rules the UI follows.
/// A quantity that was not measured is <b>omitted</b>, never emitted as zero, because an
/// unknown reading and a zero reading are different facts. Every measurement carries its
/// provenance, so a consumer can distinguish a hardware measurement from an estimate.
/// Every derived cost carries whether the price behind it was a regional average or the
/// user's real tariff.
/// </para>
/// </remarks>
public static class JuiceSchema
{
    /// <summary>
    /// Current schema version.
    /// </summary>
    /// <remarks>
    /// Consumers should fail loudly on an unrecognised major version rather than guess.
    /// While this is 0.x the shape may still change; the version exists precisely so that
    /// tooling finds out by assertion rather than by silent misreading.
    /// </remarks>
    public const string Version = "0.1";

    /// <summary>Serializer options for tools mode.</summary>
    /// <remarks>
    /// Null properties are dropped rather than written, which is what implements the
    /// "omit what was not measured" rule. Indentation is on because these documents are
    /// read by humans while debugging at least as often as by machines.
    /// </remarks>
    public static readonly JsonSerializerOptions Options = new()
    {
        WriteIndented = true,
        PropertyNamingPolicy = JsonNamingPolicy.CamelCase,
        DefaultIgnoreCondition = JsonIgnoreCondition.WhenWritingNull,
        Converters = { new JsonStringEnumConverter(JsonNamingPolicy.CamelCase) },
    };
}

/// <summary>Platform that produced a document.</summary>
public enum JuicePlatform
{
    /// <summary>Windows.</summary>
    Windows,

    /// <summary>macOS.</summary>
    MacOS,
}

/// <summary>How much a reading can be trusted.</summary>
public enum MeasurementConfidence
{
    /// <summary>Read from hardware instrumentation.</summary>
    Measured,

    /// <summary>Derived from a calibrated model rather than measured.</summary>
    Estimated,

    /// <summary>Not available on this machine in its current state.</summary>
    Unavailable,
}

/// <summary>Battery charge direction.</summary>
public enum BatteryFlow
{
    /// <summary>Running on battery.</summary>
    Discharging,

    /// <summary>On external power and taking charge.</summary>
    Charging,

    /// <summary>On external power and holding charge.</summary>
    PluggedIn,

    /// <summary>Could not be determined.</summary>
    Unknown,
}

/// <summary>
/// Envelope shared by every document.
/// </summary>
/// <remarks>
/// A consumer should branch on <see cref="Ok"/> before reading anything else. Failures
/// are emitted in this same envelope rather than as plain text on stderr, so tools mode
/// never requires a caller to parse two different formats.
/// </remarks>
public abstract record JuiceDocument
{
    /// <summary>Schema version this document conforms to.</summary>
    [JsonPropertyOrder(-100)]
    public string SchemaVersion { get; init; } = JuiceSchema.Version;

    /// <summary>Platform that produced the document.</summary>
    [JsonPropertyOrder(-99)]
    public JuicePlatform Platform { get; init; } = JuicePlatform.Windows;

    /// <summary>Command that produced the document.</summary>
    [JsonPropertyOrder(-98)]
    public required string Command { get; init; }

    /// <summary>When it was produced.</summary>
    [JsonPropertyOrder(-97)]
    public DateTimeOffset GeneratedAt { get; init; } = DateTimeOffset.UtcNow;

    /// <summary>False when the command failed; <see cref="Error"/> then explains why.</summary>
    [JsonPropertyOrder(-96)]
    public bool Ok { get; init; } = true;

    /// <summary>Failure detail, omitted on success.</summary>
    [JsonPropertyOrder(-95)]
    public JuiceError? Error { get; init; }
}

/// <summary>A machine-readable failure.</summary>
/// <param name="Code">
/// Stable identifier suitable for branching, for example <c>noPowerSource</c>. Codes are
/// part of the contract and will not be renamed within a schema version.
/// </param>
/// <param name="Message">Human-readable explanation. Not stable, do not parse.</param>
public sealed record JuiceError(string Code, string Message);

/// <summary>Power drawn on the individual rails a platform meters.</summary>
/// <remarks>
/// Every member is nullable and omitted when the platform does not meter that rail.
/// Windows machines with an Energy Meter device report CPU, GPU, supply and sometimes
/// NPU; machines without one report none of them. The macOS counterpart would populate
/// <see cref="Cpu"/>, <see cref="Gpu"/> and <see cref="Npu"/> from its own per-component
/// accounting, with <see cref="Npu"/> carrying Neural Engine energy.
/// </remarks>
public sealed record RailsDto
{
    /// <summary>Aggregate CPU rail draw in watts.</summary>
    public double? Cpu { get; init; }

    /// <summary>GPU rail draw in watts.</summary>
    public double? Gpu { get; init; }

    /// <summary>Neural accelerator draw in watts. Neural Engine on macOS, NPU on Windows.</summary>
    public double? Npu { get; init; }

    /// <summary>External supply draw in watts, which includes charging and conversion loss.</summary>
    public double? Supply { get; init; }
}

/// <summary>Current system power draw.</summary>
public sealed record MeasurementDto
{
    /// <summary>Provenance of the reading.</summary>
    public required MeasurementConfidence Confidence { get; init; }

    /// <summary>
    /// Platform-specific name of the source, for example <c>hardwareRail</c> or
    /// <c>battery</c>. Useful for diagnostics; branch on
    /// <see cref="Confidence"/> for behaviour.
    /// </summary>
    public string? Source { get; init; }

    /// <summary>
    /// Total system draw in watts. Omitted when it could not be measured, which is the
    /// normal case for a machine on AC with no hardware energy meter.
    /// </summary>
    public double? SystemWatts { get; init; }

    /// <summary>Per-rail detail, omitted when nothing is metered.</summary>
    public RailsDto? Rails { get; init; }
}

/// <summary>Battery state.</summary>
public sealed record BatteryDto
{
    /// <summary>False on a machine with no battery, in which case nothing else is present.</summary>
    public required bool Present { get; init; }

    /// <summary>Charge percentage.</summary>
    public double? Percent { get; init; }

    /// <summary>Charge direction.</summary>
    public BatteryFlow Flow { get; init; } = BatteryFlow.Unknown;

    /// <summary>
    /// Watts flowing into the battery. Omitted when not meaningfully charging, so a full
    /// battery trickling a few milliwatts on AC does not report as charging.
    /// </summary>
    public double? ChargeWatts { get; init; }

    /// <summary>Energy remaining in watt-hours.</summary>
    public double? RemainingWattHours { get; init; }

    /// <summary>Energy at full charge in watt-hours, reflecting current health.</summary>
    public double? FullChargeWattHours { get; init; }
}

/// <summary>Price of electricity, and how confident Juice is in it.</summary>
public sealed record RateDto
{
    /// <summary>Price of one kilowatt-hour.</summary>
    public required decimal PricePerKwh { get; init; }

    /// <summary>ISO 4217 currency code.</summary>
    public required string Currency { get; init; }

    /// <summary>ISO 3166 region the price applies to.</summary>
    public string? RegionCode { get; init; }

    /// <summary>Display name of the region.</summary>
    public string? RegionName { get; init; }

    /// <summary>
    /// True when the price is a regional average rather than the user's tariff. Energy is
    /// measured, but the price attached to it is the uncertain term, so any cost derived
    /// from an estimated rate is itself an estimate.
    /// </summary>
    public required bool IsEstimate { get; init; }
}

/// <summary>A failure with no command-specific payload.</summary>
/// <remarks>
/// Emitted in tools mode when a command cannot produce its normal document, so that
/// stdout is machine-readable whether the command succeeded or not.
/// </remarks>
public sealed record ErrorDocument : JuiceDocument;

/// <summary>Response to <c>juice now</c>.</summary>
public sealed record NowDocument : JuiceDocument
{
    /// <summary>Current draw.</summary>
    public required MeasurementDto Measurement { get; init; }

    /// <summary>Battery state.</summary>
    public required BatteryDto Battery { get; init; }
}

/// <summary>Window a measurement covers.</summary>
public sealed record WindowDto
{
    /// <summary>Window start.</summary>
    public required DateTimeOffset Start { get; init; }

    /// <summary>Window end.</summary>
    public required DateTimeOffset End { get; init; }

    /// <summary>Window length in seconds.</summary>
    public double Seconds => (End - Start).TotalSeconds;
}

/// <summary>Energy attributed to one app over a window.</summary>
public sealed record AppEnergyDto
{
    /// <summary>Stable grouping key.</summary>
    public required string AppId { get; init; }

    /// <summary>Name for display.</summary>
    public required string DisplayName { get; init; }

    /// <summary>Average watts over the window.</summary>
    public required double Watts { get; init; }

    /// <summary>Energy attributed over the window.</summary>
    public required double WattHours { get; init; }

    /// <summary>Energy split by the rail it came from.</summary>
    public RailsDto? Components { get; init; }

    /// <summary>Contributing process ids.</summary>
    public IReadOnlyList<int>? ProcessIds { get; init; }

    /// <summary>
    /// Cost of running at this draw for a year. Omitted when no rate is available.
    /// </summary>
    public decimal? AnnualCost { get; init; }
}

/// <summary>Energy totals for a window.</summary>
public sealed record EnergyTotalsDto
{
    /// <summary>Total energy the system rail measured.</summary>
    public required double SystemWattHours { get; init; }

    /// <summary>Energy successfully attributed to apps.</summary>
    public required double AttributedWattHours { get; init; }

    /// <summary>
    /// Energy no app can be held responsible for, such as display, radios and conversion
    /// loss, plus anything Juice could not attribute.
    /// </summary>
    /// <remarks>
    /// This is a residual, so <see cref="AttributedWattHours"/> plus
    /// <see cref="PlatformWattHours"/> always equals <see cref="SystemWattHours"/>.
    /// Energy is never silently lost from the totals.
    /// </remarks>
    public required double PlatformWattHours { get; init; }
}

/// <summary>Response to <c>juice top</c>.</summary>
public sealed record TopDocument : JuiceDocument
{
    /// <summary>Window measured.</summary>
    public required WindowDto Window { get; init; }

    /// <summary>Energy totals, which always reconcile.</summary>
    public required EnergyTotalsDto Energy { get; init; }

    /// <summary>Price used for the cost figures, omitted when unavailable.</summary>
    public RateDto? Rate { get; init; }

    /// <summary>Apps ordered by attributed energy, descending.</summary>
    public required IReadOnlyList<AppEnergyDto> Apps { get; init; }
}

/// <summary>One power source and whether this machine has it.</summary>
public sealed record SourceDto
{
    /// <summary>Source identifier.</summary>
    public required string Name { get; init; }

    /// <summary>Confidence readings from this source would carry.</summary>
    public required MeasurementConfidence Confidence { get; init; }

    /// <summary>True when present and returning data.</summary>
    public required bool Available { get; init; }

    /// <summary>Human-readable detail.</summary>
    public string? Description { get; init; }
}

/// <summary>Response to <c>juice sources</c>.</summary>
public sealed record SourcesDocument : JuiceDocument
{
    /// <summary>Name of the source currently selected.</summary>
    public string? Selected { get; init; }

    /// <summary>All sources considered.</summary>
    public required IReadOnlyList<SourceDto> Sources { get; init; }

    /// <summary>Extra capabilities that affect attribution quality.</summary>
    public required IReadOnlyDictionary<string, bool> Capabilities { get; init; }
}

/// <summary>Response to <c>juice verify</c>.</summary>
/// <remarks>
/// Reports the agreement between two independent derivations of the same energy, which
/// is the executable form of the rule that displayed numbers must be verified against the
/// raw source rather than only against unit tests.
/// </remarks>
public sealed record VerifyDocument : JuiceDocument
{
    /// <summary>Length of the audit window in seconds.</summary>
    public required double Seconds { get; init; }

    /// <summary>Energy according to the hardware accumulator.</summary>
    public required double AccumulatorWattHours { get; init; }

    /// <summary>Energy obtained by integrating the instantaneous power counter.</summary>
    public required double IntegratedWattHours { get; init; }

    /// <summary>Signed disagreement between the two, as a percentage.</summary>
    public required double PercentDifference { get; init; }

    /// <summary>Tolerance the result was judged against.</summary>
    public required double TolerancePercent { get; init; }

    /// <summary>Number of samples taken.</summary>
    public required int SampleCount { get; init; }

    /// <summary>True when the two derivations agree within tolerance.</summary>
    public required bool Passed { get; init; }
}
