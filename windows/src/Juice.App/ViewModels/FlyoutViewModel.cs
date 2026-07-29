using System.Collections.ObjectModel;
using System.Globalization;
using System.Runtime.Versioning;
using CommunityToolkit.Mvvm.ComponentModel;
using Juice.App.Monitoring;
using Juice.App.Services;
using Juice.Core.Attribution;
using Juice.Core.Cost;
using Juice.Core.Power;
using Juice.Core.Presentation;

namespace Juice.App.ViewModels;

/// <summary>
/// Backs the tray flyout: the live readout, the rail breakdown and the top energy users.
/// </summary>
/// <remarks>
/// Every string here is produced by <see cref="PowerFormatter"/> or by
/// <see cref="MoneyFormatter"/> from a measured value. Where there is no measurement the
/// view model says so; it never substitutes a zero, and it never carries a rail or an app
/// row forward from an earlier reading to fill a gap.
/// </remarks>
[SupportedOSPlatform("windows10.0.19041.0")]
public sealed partial class FlyoutViewModel : ObservableObject
{
    /// <summary>
    /// Rows shown before the platform row. Five is what fits the flyout without
    /// scrolling, and beyond that the numbers are small enough that the ranking is noise.
    /// </summary>
    private const int MaxAppRows = 5;

    /// <summary>
    /// Rows the list reserves before any measurement exists: the app rows plus the
    /// platform row, which is what the populated list settles at.
    /// </summary>
    private const int ReservedRowCount = MaxAppRows + 1;

    /// <summary>
    /// Identity used for the platform row. It is not an app, so it takes a key that no
    /// executable can produce rather than sharing the app id space.
    /// </summary>
    private const string PlatformRowId = "\u0000platform";

    /// <summary>Creates the view model in its pre-measurement state.</summary>
    /// <param name="icons">
    /// Supplies real app icons for the energy rows. Optional so the view model can be
    /// constructed without a dispatcher, in which case rows go without icons.
    /// </param>
    public FlyoutViewModel(AppIconService? icons = null)
    {
        _icons = icons;

        // Partial properties cannot carry initialisers. The opening text says there is no
        // reading yet rather than showing a zero that would look like a measurement.
        WattsText = "Unknown";
        SourceText = "waiting for a reading";
        BatteryText = string.Empty;
        PowerStateText = string.Empty;
        EnergyWindowText = "Collecting the first sampling window.";
        RateFooterText = string.Empty;

        // Reserved from the outset rather than on the first snapshot, because the flyout
        // can be opened before any snapshot has been delivered and that is exactly the
        // case the user sees resize.
        ReservePlaceholderRows();
    }

    private readonly AppIconService? _icons;

    /// <summary>System wattage, or "Unknown" when nothing has measured it.</summary>
    [ObservableProperty]
    public partial string WattsText { get; set; }

    /// <summary>Human readable name of the tier the reading came from.</summary>
    [ObservableProperty]
    public partial string SourceText { get; set; }

    /// <summary>Battery charge as a percentage, when there is a battery.</summary>
    [ObservableProperty]
    public partial string BatteryText { get; set; }

    /// <summary>True when the machine reported a battery percentage.</summary>
    [ObservableProperty]
    public partial bool HasBattery { get; set; }

    /// <summary>Charging, plugged in, or the remaining runtime on battery.</summary>
    [ObservableProperty]
    public partial string PowerStateText { get; set; }

    /// <summary>True when at least one rail was metered.</summary>
    [ObservableProperty]
    public partial bool HasRails { get; set; }

    /// <summary>True once an attribution window has produced rows.</summary>
    [ObservableProperty]
    public partial bool HasEnergyRows { get; set; }

    /// <summary>Describes the window the energy rows were measured over.</summary>
    [ObservableProperty]
    public partial string EnergyWindowText { get; set; }

    /// <summary>Electricity rate line, including whether it is an estimate.</summary>
    [ObservableProperty]
    public partial string RateFooterText { get; set; }

    /// <summary>
    /// How hard the machine is drawing, as <see cref="DrainClassifier"/> sees it. The
    /// hero readout is coloured from this, matching the tray icon's tint.
    /// </summary>
    [ObservableProperty]
    public partial DrainSeverity Severity { get; set; }

    /// <summary>Battery charge as a number, or null when there is no battery.</summary>
    /// <remarks>
    /// <see cref="BatteryText"/> is what is displayed; this is the classification, kept
    /// separately so the view can colour a low battery without parsing its own label.
    /// </remarks>
    [ObservableProperty]
    public partial BatteryLevel BatteryLevel { get; set; }

    /// <summary>Metered rails present in the latest reading.</summary>
    public ObservableCollection<RailRowViewModel> Rails { get; } = [];

    /// <summary>Top energy users, with the platform row last.</summary>
    public ObservableCollection<EnergyRowViewModel> EnergyRows { get; } = [];

    /// <summary>
    /// Recent energy history, or null when nothing has been recorded yet.
    /// </summary>
    /// <remarks>
    /// Built by <see cref="EnergyChartBuilder"/>, so the axis is pinned to the requested
    /// window and unrecorded hours arrive as explicit gap columns rather than being
    /// omitted. The view only renders it.
    /// </remarks>
    [ObservableProperty]
    public partial EnergyChartSeries? History { get; set; }

    /// <summary>True when there is a history series worth drawing.</summary>
    [ObservableProperty]
    public partial bool HasHistory { get; set; }

    /// <summary>
    /// Battery charge over the same window, or null when there is nothing to draw.
    /// </summary>
    /// <remarks>
    /// Split into continuous runs by <see cref="ChargeTimelineBuilder"/>, so a period the
    /// machine was asleep breaks the line rather than being drawn through.
    /// </remarks>
    [ObservableProperty]
    public partial ChargeTimeline? Charge { get; set; }

    /// <summary>True when there is a charge timeline worth drawing.</summary>
    [ObservableProperty]
    public partial bool HasCharge { get; set; }

    /// <summary>
    /// Applies a freshly built charge timeline.
    /// </summary>
    /// <remarks>
    /// A timeline with only a handful of points is hidden rather than drawn. It would
    /// occupy as much height as a full day of history while showing a stub of line in one
    /// corner, which looks like a rendering fault and pushes the app ranking below the
    /// fold for no information gained.
    /// </remarks>
    public void UpdateCharge(ChargeTimeline? timeline)
    {
        Charge = timeline;
        HasCharge = timeline is { IsEmpty: false, PointCount: >= MinimumTimelinePoints };
    }

    /// <summary>
    /// Points required before the charge timeline is worth the vertical space it costs.
    /// </summary>
    /// <remarks>
    /// Battery samples are written about once a minute, so this is roughly a quarter of an
    /// hour of continuous recording.
    /// </remarks>
    private const int MinimumTimelinePoints = 15;

    /// <summary>
    /// Applies a freshly built history series.
    /// </summary>
    /// <remarks>
    /// An all-gap series hides the chart and leaves only its caption. A plot area of pure
    /// gap markers carries no more information than the sentence under it, and on a
    /// freshly installed machine it would push the app ranking, which is the reason most
    /// people open the flyout, below the fold for the first day.
    /// </remarks>
    public void UpdateHistory(EnergyChartSeries? series)
    {
        History = series;
        HasHistory = series is { IsEmpty: false };
    }

    /// <summary>Applies a completed sampling pass.</summary>
    public void Update(PowerSnapshot snapshot, ElectricityRate rate)
    {
        var sample = snapshot.Sample;

        Severity = snapshot.Severity;
        WattsText = PowerFormatter.Watts(sample?.SystemWatts);
        SourceText = sample is null
            ? "waiting for a reading"
            : DiagnosticsReport.TierName(sample.Tier);

        UpdateBattery(sample, snapshot.Remaining);
        UpdateRails(sample);
        UpdateEnergyRows(snapshot.Attribution, rate);
        UpdateFooter(rate);
    }

    private void UpdateBattery(PowerSample? sample, TimeSpan? remaining)
    {
        HasBattery = sample?.BatteryPercent is not null;
        BatteryLevel = BatteryClassifier.Classify(sample?.BatteryPercent, sample is { OnAc: false });

        BatteryText = sample?.BatteryPercent is { } percent
            ? percent.ToString("0", CultureInfo.CurrentCulture) + "%"
            : string.Empty;

        if (sample is null)
        {
            PowerStateText = string.Empty;
            return;
        }

        if (sample.OnAc)
        {
            PowerStateText = sample.ChargeWatts is { } charge
                             && charge >= PowerFormatter.ChargingThresholdWatts
                ? $"charging at {charge:0.0} W"
                : "plugged in";
            return;
        }

        PowerStateText = remaining is { } left && left > TimeSpan.Zero
            ? $"on battery, {PowerFormatter.FormatDuration(left)} left"
            : "on battery";
    }

    private void UpdateRails(PowerSample? sample)
    {
        // Only rails the hardware actually metered are listed. A machine with no GPU
        // rail should show three entries, not a fourth reading zero watts.
        var present = new List<(PowerRail Rail, string Name, string Value)>();

        foreach (var (rail, label) in RailLabels)
        {
            if (sample?.WattsFor(rail) is not { } watts) continue;
            present.Add((rail, label, PowerFormatter.Watts(watts)));
        }

        SyncRows(Rails, present.Count, () => new RailRowViewModel(), (row, index) =>
        {
            row.Rail = present[index].Rail;
            row.Name = present[index].Name;
            row.WattsText = present[index].Value;
        });

        HasRails = present.Count > 0;
    }

    private void UpdateEnergyRows(AttributionResult? attribution, ElectricityRate rate)
    {
        if (attribution is null || attribution.End <= attribution.Start)
        {
            ReservePlaceholderRows();
            HasEnergyRows = false;
            EnergyWindowText = "Collecting the first sampling window.";
            return;
        }

        var window = attribution.End - attribution.Start;
        var hours = window.TotalHours;

        var rows = new List<(string AppId, string Name, double Watts, bool IsPlatform, IReadOnlyList<int> Pids)>();

        foreach (var app in attribution.Apps.Take(MaxAppRows))
        {
            if (app.TotalWattHours <= 0) continue;
            rows.Add((app.AppId, app.DisplayName, app.Watts, false, app.ProcessIds));
        }

        if (attribution.PlatformWattHours > 0 && hours > 0)
        {
            rows.Add((PlatformRowId, "System and display", attribution.PlatformWattHours / hours, true, []));
        }

        // Bars are scaled against the heaviest app, not against the heaviest row. The
        // platform row is usually the largest single consumer, and including it would
        // squeeze every app into the same short stub and destroy the ranking the list
        // exists to show. The platform row is scaled against that same app maximum and
        // clamps at full width when it exceeds it, which is honest enough because it is
        // drawn in grey and set apart from the apps, and because its watts figure is
        // printed next to it either way.
        var heaviestAppWatts = RankingShare.Heaviest(
            rows.Where(r => !r.IsPlatform).Select(r => r.Watts));

        SyncRows(EnergyRows, rows.Count, () => new EnergyRowViewModel(), (row, index) =>
        {
            var (appId, name, watts, isPlatform, pids) = rows[index];
            row.AppId = appId;
            row.DisplayName = name;
            row.WattsText = PowerFormatter.Watts(watts);
            row.CostText = MoneyFormatter.Format(
                CostCalculator.AnnualCostOfSustainedWatts(watts, rate), rate.Currency) + " a year";
            row.IsPlatform = isPlatform;
            row.IsPlaceholder = false;
            row.BarFraction = RankingShare.Of(watts, heaviestAppWatts);

            UpdateIcon(row, appId, isPlatform, pids);
        });

        HasEnergyRows = rows.Count > 0;
        EnergyWindowText = rows.Count > 0
            ? $"Measured over the last {PowerFormatter.FormatDuration(window)}, {PowerFormatter.Energy(attribution.SystemWattHours)} total."
            : "No app drew measurable energy in the last window.";
    }

    /// <summary>
    /// Fills the list with blank rows that occupy the height the populated list will
    /// occupy, so the first real measurement does not resize the window under the user.
    /// </summary>
    private void ReservePlaceholderRows()
    {
        SyncRows(EnergyRows, ReservedRowCount, () => new EnergyRowViewModel(), (row, index) =>
        {
            row.AppId = string.Empty;
            row.DisplayName = string.Empty;
            row.WattsText = string.Empty;
            row.CostText = string.Empty;
            row.Icon = null;
            row.IsPlatform = false;
            row.IsPlaceholder = true;
            row.BarFraction = 0;
        });
    }

    /// <summary>
    /// Asks for the row's real icon, per CONTRIBUTING.md: app rows carry the app's own
    /// icon, and generic glyphs are reserved for system indicators.
    /// </summary>
    private void UpdateIcon(EnergyRowViewModel row, string appId, bool isPlatform, IReadOnlyList<int> pids)
    {
        if (_icons is null) return;

        if (isPlatform)
        {
            // The platform row is the display, radios and regulator loss. There is no
            // app behind it, so it keeps the system glyph the view draws for it.
            row.Icon = null;
            return;
        }

        // The row is captured rather than its index, because rows are re-used and the
        // index will have been handed to a different app by the time a slow lookup
        // returns. The identity check is what makes that safe.
        _icons.Request(appId, pids, icon =>
        {
            if (string.Equals(row.AppId, appId, StringComparison.Ordinal)) row.Icon = icon;
        });
    }

    private void UpdateFooter(ElectricityRate rate)    {
        var price = MoneyFormatter.Format(rate.PricePerKwh, rate.Currency);
        var provenance = rate.IsEstimate
            ? $"{rate.RegionName} average, an estimate"
            : "your rate";

        RateFooterText = $"{price} per kWh - {provenance}";
    }

    /// <summary>
    /// Grows or shrinks <paramref name="rows"/> to <paramref name="count"/> and rewrites
    /// each item in place, so the list view keeps its containers between updates.
    /// </summary>
    private static void SyncRows<T>(
        ObservableCollection<T> rows,
        int count,
        Func<T> create,
        Action<T, int> apply)
    {
        while (rows.Count > count) rows.RemoveAt(rows.Count - 1);
        while (rows.Count < count) rows.Add(create());

        for (var i = 0; i < count; i++) apply(rows[i], i);
    }

    private static readonly (PowerRail Rail, string Label)[] RailLabels =
    [
        (PowerRail.Cpu, "CPU"),
        (PowerRail.Gpu, "GPU"),
        (PowerRail.Npu, "NPU"),
        (PowerRail.Supply, "Supply"),
    ];
}
