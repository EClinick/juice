using CommunityToolkit.Mvvm.ComponentModel;
using Juice.Core.Power;

namespace Juice.App.ViewModels;

/// <summary>One metered rail in the flyout's breakdown strip.</summary>
public sealed partial class RailRowViewModel : ObservableObject
{
    /// <summary>Creates an empty row for the flyout to fill in.</summary>
    public RailRowViewModel()
    {
        // Partial properties cannot carry initialisers, so the empty defaults are set
        // here. Rows are created before their values are known and must never render as
        // null.
        Name = string.Empty;
        WattsText = string.Empty;
    }

    /// <summary>Rail name, for example "CPU".</summary>
    [ObservableProperty]
    public partial string Name { get; set; }

    /// <summary>Formatted wattage for the rail.</summary>
    [ObservableProperty]
    public partial string WattsText { get; set; }

    /// <summary>Which rail this row reports.</summary>
    /// <remarks>
    /// The card's accent strip is chosen in XAML from the four flags below rather than
    /// from a brush handed over by this view model. A brush resolved in code is captured
    /// from whichever theme dictionary was active at the time, so it would keep its old
    /// colour after the user switched between light and dark.
    /// </remarks>
    [ObservableProperty]
    [NotifyPropertyChangedFor(nameof(IsCpu))]
    [NotifyPropertyChangedFor(nameof(IsGpu))]
    [NotifyPropertyChangedFor(nameof(IsNpu))]
    [NotifyPropertyChangedFor(nameof(IsSupply))]
    public partial PowerRail Rail { get; set; }

    /// <summary>True when this row reports the CPU rail.</summary>
    public bool IsCpu => Rail is PowerRail.Cpu;

    /// <summary>True when this row reports the GPU rail.</summary>
    public bool IsGpu => Rail is PowerRail.Gpu;

    /// <summary>True when this row reports the NPU rail.</summary>
    public bool IsNpu => Rail is PowerRail.Npu;

    /// <summary>True when this row reports the supply rail.</summary>
    public bool IsSupply => Rail is PowerRail.Supply;
}
