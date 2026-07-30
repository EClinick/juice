using System.Collections.ObjectModel;
using System.Globalization;
using System.Runtime.Versioning;
using CommunityToolkit.Mvvm.ComponentModel;
using Juice.Core.Monitoring;
using Juice.App.Services;
using Juice.Core.Attribution;
using Juice.Core.Cost;
using Juice.Core.Insights;
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
    /// Rows the list reserves before any measurement exists: the app rows plus the
    /// platform row, which is what the populated list settles at.
    /// </summary>
    private const int ReservedRowCount = MaxAppRows + 1;

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
        SourceText = "Waiting for a reading";
        HasSourceLine = true;
        BatteryText = string.Empty;
        PowerStateText = string.Empty;
        EnergyWindowText = "Collecting the first sampling window.";
        EnergyCoverageText = string.Empty;
        RateFooterText = string.Empty;
        RailTotalText = string.Empty;
        RailCaptionText = string.Empty;
        SupplyText = string.Empty;
        NoticeTitle = string.Empty;
        NoticeMessage = string.Empty;
        OverflowHeaderText = string.Empty;
        OverflowValueText = string.Empty;

        // Reserved from the outset rather than on the first snapshot, because the flyout
        // can be opened before any snapshot has been delivered and that is exactly the
        // case the user sees resize.
        ReservePlaceholderRows();
    }

    private readonly AppIconService? _icons;

    /// <summary>
    /// How many app rows the ranking shows, before the platform row.
    /// </summary>
    /// <remarks>
    /// The cap itself and the reasoning behind it live with the builder that applies it.
    /// </remarks>
    private const int MaxAppRows = EnergyRankingBuilder.DefaultAppLimit;

    /// <summary>
    /// The period the ranking and its totals describe.
    /// </summary>
    /// <remarks>
    /// Only the ranking follows this. The hero readout, the battery state and the rail
    /// breakdown are instantaneous measurements and stay live whatever is selected,
    /// because there is no such thing as last week's wattage right now. The charts keep
    /// their own stated window for the reason recorded on them.
    /// </remarks>
    [ObservableProperty]
    public partial EnergyRange SelectedRange { get; set; }

    /// <summary>True while the live session is selected.</summary>
    /// <remarks>
    /// Drives whether an incoming snapshot is allowed to rewrite the ranking. A stored
    /// period must not be overwritten by the sampling loop every few seconds.
    /// </remarks>
    public bool IsLiveRange => SelectedRange == EnergyRange.Session;

    /// <summary>Raised when the user picked a different period.</summary>
    /// <remarks>
    /// The view model has no store and no clock of its own, deliberately: it is the
    /// application that owns the database handle and decides what a query costs. So the
    /// selection is announced and the answer arrives back through
    /// <see cref="ApplyRanking"/>.
    /// </remarks>
    public event EventHandler<EnergyRange>? RangeChanged;

    partial void OnSelectedRangeChanged(EnergyRange value)
    {
        OnPropertyChanged(nameof(IsLiveRange));
        RangeChanged?.Invoke(this, value);
    }

    /// <summary>System wattage, or "Unknown" when nothing has measured it.</summary>
    [ObservableProperty]
    public partial string WattsText { get; set; }

    /// <summary>Human readable name of the tier the reading came from.</summary>
    [ObservableProperty]
    public partial string SourceText { get; set; }

    /// <summary>True while the source line is what explains the reading.</summary>
    /// <remarks>
    /// False whenever a notice is shown, because the notice explains the same thing at
    /// greater length and directly underneath.
    /// </remarks>
    [ObservableProperty]
    public partial bool HasSourceLine { get; set; }

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

    /// <summary>
    /// What the stacked breakdown bar adds up to, formatted.
    /// </summary>
    /// <remarks>
    /// Stated next to the bar because a stacked bar looks like a whole whatever it is
    /// drawn from, and on a machine where the rails do not account for the system reading
    /// this total is the rails alone.
    /// </remarks>
    [ObservableProperty]
    public partial string RailTotalText { get; set; }

    /// <summary>A sentence saying what the breakdown covers.</summary>
    [ObservableProperty]
    public partial string RailCaptionText { get; set; }

    /// <summary>Processor rails as a fraction of the breakdown total, from 0 to 1.</summary>
    /// <remarks>
    /// The four fractions below are the widths of the stacked bar's columns. They are
    /// separate properties rather than a collection because a stacked bar needs star
    /// sizing, and an items panel has no way to give one item four tenths of the width.
    /// The set of rails is fixed and small, so four columns in markup costs less than a
    /// custom panel would.
    /// </remarks>
    [ObservableProperty]
    public partial double CpuFraction { get; set; }

    /// <summary>Graphics rail as a fraction of the breakdown total.</summary>
    [ObservableProperty]
    public partial double GpuFraction { get; set; }

    /// <summary>Neural engine rail as a fraction of the breakdown total.</summary>
    [ObservableProperty]
    public partial double NpuFraction { get; set; }

    /// <summary>Whatever the rails did not account for, as a fraction of the total.</summary>
    [ObservableProperty]
    public partial double RemainderFraction { get; set; }

    /// <summary>
    /// What the external supply is delivering, or nothing when it is not metered.
    /// </summary>
    /// <remarks>
    /// Kept out of the breakdown bar deliberately. It is what comes in from the charger,
    /// which while charging is larger than what the machine consumes, because the
    /// difference is going into the battery. Putting it in a bar of consumers would count
    /// every watt in it twice.
    /// </remarks>
    [ObservableProperty]
    public partial string SupplyText { get; set; }

    /// <summary>True when the supply rail is metered.</summary>
    [ObservableProperty]
    public partial bool HasSupply { get; set; }

    /// <summary>Headline of the status message about the measurement, when there is one.</summary>
    [ObservableProperty]
    public partial string NoticeTitle { get; set; }

    /// <summary>The explanation behind <see cref="NoticeTitle"/>.</summary>
    [ObservableProperty]
    public partial string NoticeMessage { get; set; }

    /// <summary>How much attention the status message deserves.</summary>
    [ObservableProperty]
    public partial MeasurementNoticeSeverity NoticeSeverity { get; set; }

    /// <summary>True when the flyout owes the user a status message about its numbers.</summary>
    /// <remarks>
    /// Only ever true when something is genuinely limiting the measurement. Metered
    /// hardware is the case the app is built for, and a bar that says everything is
    /// normal teaches the user to ignore the one place a real caveat appears.
    /// </remarks>
    [ObservableProperty]
    public partial bool HasNotice { get; set; }

    /// <summary>True once an attribution window has produced rows.</summary>
    [ObservableProperty]
    public partial bool HasEnergyRows { get; set; }

    /// <summary>Describes the window the energy rows were measured over.</summary>
    [ObservableProperty]
    public partial string EnergyWindowText { get; set; }

    /// <summary>
    /// States how much of the selected period was actually recorded, or nothing when all
    /// of it was.
    /// </summary>
    /// <remarks>
    /// Kept apart from <see cref="EnergyWindowText"/> so it can be hidden rather than
    /// producing a trailing blank sentence, and so it can be drawn in the same muted
    /// style the chart captions use for the same admission.
    /// </remarks>
    [ObservableProperty]
    public partial string EnergyCoverageText { get; set; }

    /// <summary>True when there is a coverage shortfall to admit to.</summary>
    [ObservableProperty]
    public partial bool HasEnergyCoverageNote { get; set; }

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
    /// The apps ranked below the visible list, shown only when the user asks for them.
    /// </summary>
    /// <remarks>
    /// The flyout is a glance surface, and the question it answers in one look is "what is
    /// using my battery". The tail answers a different question, "is this particular thing
    /// running", which is worth answering but not worth the height, so it goes behind a
    /// disclosure that opens in place.
    /// </remarks>
    public ObservableCollection<EnergyRowViewModel> OverflowRows { get; } = [];

    /// <summary>True when there are further apps to disclose.</summary>
    [ObservableProperty]
    public partial bool HasOverflowRows { get; set; }

    /// <summary>How the disclosure describes what is inside it.</summary>
    /// <remarks>
    /// It counts the rows it holds and claims nothing beyond them. The macOS version can
    /// say "+169 more apps" because it has the whole tail in memory; here the tail is
    /// fetched with a limit, so a total would be a number nobody counted.
    /// </remarks>
    [ObservableProperty]
    public partial string OverflowHeaderText { get; set; }

    /// <summary>What those apps drew between them, in the unit the period uses.</summary>
    [ObservableProperty]
    public partial string OverflowValueText { get; set; }

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
    /// Generated observations, most severe first.
    /// </summary>
    /// <remarks>
    /// This is the part of the macOS version that makes it feel like it has an opinion
    /// rather than just a readout, and the engine behind it has been written and tested in
    /// Core since early on without anything ever showing its output.
    /// </remarks>
    public ObservableCollection<InsightRowViewModel> Insights { get; } = [];

    /// <summary>True when there is at least one observation worth showing.</summary>
    [ObservableProperty]
    public partial bool HasInsights { get; set; }

    /// <summary>
    /// Applies a freshly generated set of observations.
    /// </summary>
    /// <remarks>
    /// Capped, because the flyout is a glance surface and an unbounded list of advice would
    /// push the app ranking, which is why most people opened it, below the fold. The engine
    /// returns them most severe first, so the cap keeps the ones that matter.
    /// </remarks>
    public void UpdateInsights(IReadOnlyList<Insight> insights)
    {
        Insights.Clear();
        foreach (var insight in insights.Take(MaximumInsights))
        {
            Insights.Add(new InsightRowViewModel(insight));
        }

        HasInsights = Insights.Count > 0;
    }

    /// <summary>How many observations the flyout will show at once.</summary>
    private const int MaximumInsights = 3;

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
    /// <remarks>
    /// The ranking is only rewritten while the live session is selected. A snapshot
    /// arrives every few seconds, and letting it overwrite a stored period would make the
    /// selector look broken: the user would pick "Week" and watch it revert.
    /// </remarks>
    public void Update(PowerSnapshot snapshot, ElectricityRate rate)
    {
        var sample = snapshot.Sample;

        Severity = snapshot.Severity;
        WattsText = PowerFormatter.Watts(sample?.SystemWatts);
        SourceText = sample is null
            ? "Waiting for a reading"
            : MeasurementSource.Label(sample.Tier, sample.OnAc);

        UpdateBattery(sample, snapshot.Remaining);
        UpdateRails(sample);
        UpdateNotice(sample);

        if (IsLiveRange)
        {
            ApplyRanking(
                EnergyRankingBuilder.FromLive(snapshot.Attribution),
                EnergyRange.Session,
                rate);
        }

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
        // The split itself is decided in Core, where it is covered by tests: which rails
        // count as consumers, what to do when they add up to more than the system reading,
        // and how small a remainder has to be before stating it would be noise.
        var breakdown = RailBreakdownBuilder.Build(sample);

        SyncRows(Rails, breakdown.Segments.Count, () => new RailRowViewModel(), (row, index) =>
        {
            var segment = breakdown.Segments[index];

            row.Rail = segment.Rail;
            row.Label = segment.Label;
            row.WattsText = PowerFormatter.Watts(segment.Watts);
        });

        // Each column of the bar is set from the segment that is there, and zeroed when
        // that rail was not metered. A rail the hardware does not report is absent, not
        // zero watts, and the legend above says which is which; the fraction is only the
        // width of a column that will not be drawn at all.
        CpuFraction = FractionOf(breakdown, PowerRail.Cpu);
        GpuFraction = FractionOf(breakdown, PowerRail.Gpu);
        NpuFraction = FractionOf(breakdown, PowerRail.Npu);
        RemainderFraction = FractionOf(breakdown, PowerRail.System);

        RailTotalText = breakdown.IsEmpty ? string.Empty : PowerFormatter.Watts(breakdown.TotalWatts);
        RailCaptionText = breakdown.Caption();

        HasSupply = breakdown.SupplyWatts is not null;
        SupplyText = breakdown.SupplyWatts is { } supply
            ? $"Charger is delivering {PowerFormatter.Watts(supply)}"
            : string.Empty;

        HasRails = !breakdown.IsEmpty;
    }

    /// <summary>Width of one column of the stacked bar, or zero when that rail is absent.</summary>
    private static double FractionOf(RailBreakdown breakdown, PowerRail rail)
    {
        foreach (var segment in breakdown.Segments)
        {
            if (segment.Rail == rail) return segment.Fraction;
        }

        return 0;
    }

    /// <summary>
    /// Decides whether the flyout owes the user a status message about where its numbers
    /// came from.
    /// </summary>
    /// <remarks>
    /// The measurement tier is the reason this port exists: on hardware with an energy
    /// meter the wattage is measured while plugged in, which is precisely what the macOS
    /// version cannot do. Where that is not available the difference is a caveat, and a
    /// caveat about the headline number belongs next to it rather than in a diagnostics
    /// report nobody opens.
    /// </remarks>
    private void UpdateNotice(PowerSample? sample)
    {
        // No sample at all is the opening state rather than a broken machine, and the
        // readout already says it is waiting for a reading.
        var notice = sample is null
            ? MeasurementNotice.None
            : MeasurementNotice.For(sample.Tier, sample.OnAc);

        NoticeTitle = notice.Title;
        NoticeMessage = notice.Message;
        NoticeSeverity = notice.Severity;
        HasNotice = notice.IsPresent;

        // The source line and the notice say the same thing from opposite ends: one
        // states what was measured, the other what was not. Showing both would print the
        // caveat twice under a single number.
        HasSourceLine = !notice.IsPresent;
    }

    /// <summary>
    /// Applies a ranking built for one period, whether it came from the live sampling
    /// loop or from the store.
    /// </summary>
    /// <remarks>
    /// <para>
    /// One entry point for both sources, so the two cannot drift apart in how they label
    /// themselves. What differs between them is only the unit: a live session reports the
    /// average draw right now, and a stored period reports the energy that was actually
    /// accumulated. Watts over a week would be an average of averages that nobody asked
    /// for, and watt-hours over four seconds is a number too small to read.
    /// </para>
    /// <para>
    /// An empty ranking falls back to reserved rows rather than to an empty list, so the
    /// flyout keeps its height while a period with nothing in it is selected.
    /// </para>
    /// </remarks>
    public void ApplyRanking(EnergyRanking ranking, EnergyRange range, ElectricityRate rate)
    {
        ArgumentNullException.ThrowIfNull(ranking);

        var isLive = range == EnergyRange.Session;

        if (ranking.IsEmpty)
        {
            ReservePlaceholderRows();
            ClearOverflow();
            HasEnergyRows = false;
            EnergyWindowText = EmptyCaptionFor(range);
            EnergyCoverageText = ranking.CoverageCaption();
            HasEnergyCoverageNote = EnergyCoverageText.Length > 0;
            return;
        }

        SyncRows(EnergyRows, ranking.Rows.Count, () => new EnergyRowViewModel(), (row, index) =>
        {
            ApplyRow(row, ranking.Rows[index], isLive, rate, isFirstRow: index == 0);
        });

        SyncRows(OverflowRows, ranking.OverflowRows.Count, () => new EnergyRowViewModel(), (row, index) =>
        {
            // The disclosed rows are their own grouped list, so the first of them is the
            // one drawn without a divider above it.
            ApplyRow(row, ranking.OverflowRows[index], isLive, rate, isFirstRow: index == 0);
        });

        HasOverflowRows = ranking.HasOverflow;
        OverflowHeaderText = ranking.OverflowRows.Count == 1
            ? "1 more app"
            : $"{ranking.OverflowRows.Count} more apps";
        OverflowValueText = isLive
            ? PowerFormatter.Watts(ranking.OverflowWatts)
            : PowerFormatter.Energy(ranking.OverflowWattHours);

        HasEnergyRows = true;
        EnergyWindowText = isLive
            ? $"Measured over the last {PowerFormatter.FormatElapsed(ranking.Window)}, {PowerFormatter.Energy(ranking.SystemWattHours)} total."
            : $"{CaptionFor(range)}, {PowerFormatter.Energy(ranking.SystemWattHours)} total.";

        EnergyCoverageText = ranking.CoverageCaption();
        HasEnergyCoverageNote = EnergyCoverageText.Length > 0;
    }

    /// <summary>
    /// Fills one list row from one ranking row.
    /// </summary>
    /// <remarks>
    /// Shared by the visible list and the disclosure so the two are filled by identical
    /// rules. A disclosed row that formatted its figures differently would look like a
    /// different measurement rather than the continuation of one ranking.
    /// </remarks>
    private void ApplyRow(
        EnergyRowViewModel row,
        EnergyRankingRow source,
        bool isLive,
        ElectricityRate rate,
        bool isFirstRow)
    {
        row.AppId = source.AppId;
        row.DisplayName = source.DisplayName;
        row.ValueText = isLive
            ? PowerFormatter.Watts(source.Watts)
            : PowerFormatter.Energy(source.WattHours);
        row.CostText = isLive
            ? MoneyFormatter.Format(
                CostCalculator.AnnualCostOfSustainedWatts(source.Watts, rate), rate.Currency) + " a year"
            : MoneyFormatter.Format(CostCalculator.CostOf(source.WattHours, rate), rate.Currency);
        row.IsPlatform = source.IsPlatform;
        row.IsPlaceholder = false;
        row.IsFirstRow = isFirstRow;
        row.BarFraction = source.BarFraction;

        UpdateIcon(row, source.AppId, source.IsPlatform, source.ProcessIds);
    }

    /// <summary>
    /// Empties the disclosure, so a period with nothing behind it does not offer to show
    /// the previous period's tail.
    /// </summary>
    private void ClearOverflow()
    {
        OverflowRows.Clear();
        HasOverflowRows = false;
        OverflowHeaderText = string.Empty;
        OverflowValueText = string.Empty;
    }

    /// <summary>How a populated stored period introduces itself.</summary>
    private static string CaptionFor(EnergyRange range) => range switch    {
        EnergyRange.Today => "Since midnight",
        EnergyRange.Week => "Over the last 7 days",
        _ => "Across all recorded history",
    };

    /// <summary>
    /// What the list says when the period holds nothing.
    /// </summary>
    /// <remarks>
    /// Each of these is a different fact and they are worth distinguishing. The live
    /// session is still filling its first window, whereas an empty stored period means
    /// Juice was not running, and telling the user to wait would be wrong there.
    /// </remarks>
    private static string EmptyCaptionFor(EnergyRange range) => range switch
    {
        EnergyRange.Session => "Collecting the first sampling window.",
        EnergyRange.Today => "Nothing recorded since midnight.",
        EnergyRange.Week => "Nothing recorded in the last 7 days.",
        _ => "No history recorded yet.",
    };

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
            row.ValueText = string.Empty;
            row.CostText = string.Empty;
            row.Icon = null;
            row.IsPlatform = false;
            row.IsPlaceholder = true;
            row.IsFirstRow = index == 0;
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
}
