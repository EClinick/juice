using CommunityToolkit.Mvvm.ComponentModel;
using Juice.Core.Power;

namespace Juice.App.ViewModels;

/// <summary>One component of the machine's draw, as the flyout's breakdown legend shows it.</summary>
/// <remarks>
/// The bar these rows label is drawn from fixed columns on the view model rather than from
/// this collection, because a stacked bar needs proportional widths and an items panel
/// cannot give them. Both are filled from one <see cref="Juice.Core.Presentation.RailBreakdown"/>
/// in a single pass, so the legend and the bar cannot disagree about what was measured.
/// </remarks>
public sealed partial class RailRowViewModel : ObservableObject
{
    /// <summary>Creates an empty row for the flyout to fill in.</summary>
    public RailRowViewModel()
    {
        // Partial properties cannot carry initialisers, so the empty defaults are set
        // here. Rows are created before their values are known and must never render as
        // null.
        Label = string.Empty;
        WattsText = string.Empty;
    }

    /// <summary>What the component is called, for example "Processor".</summary>
    [ObservableProperty]
    public partial string Label { get; set; }

    /// <summary>Formatted wattage for the component.</summary>
    [ObservableProperty]
    public partial string WattsText { get; set; }

    /// <summary>Which rail this row reports.</summary>
    /// <remarks>
    /// The legend's colour key is chosen in XAML from the four flags below rather than
    /// from a brush handed over by this view model. A brush resolved in code is captured
    /// from whichever theme dictionary was active at the time, so it would keep its old
    /// colour after the user switched between light and dark.
    /// </remarks>
    [ObservableProperty]
    [NotifyPropertyChangedFor(nameof(IsCpu))]
    [NotifyPropertyChangedFor(nameof(IsGpu))]
    [NotifyPropertyChangedFor(nameof(IsNpu))]
    [NotifyPropertyChangedFor(nameof(IsRemainder))]
    public partial PowerRail Rail { get; set; }

    /// <summary>True when this row reports the processor rails.</summary>
    public bool IsCpu => Rail is PowerRail.Cpu;

    /// <summary>True when this row reports the graphics rail.</summary>
    public bool IsGpu => Rail is PowerRail.Gpu;

    /// <summary>True when this row reports the neural engine rail.</summary>
    public bool IsNpu => Rail is PowerRail.Npu;

    /// <summary>
    /// True for the row carrying whatever the metered rails did not account for.
    /// </summary>
    /// <remarks>
    /// It is the system reading less the compute rails, a difference between two
    /// measurements rather than a rail the hardware reports, so it is drawn in the muted
    /// key the app ranking gives the same quantity.
    /// </remarks>
    public bool IsRemainder => Rail is PowerRail.System;
}
