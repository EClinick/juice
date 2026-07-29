using CommunityToolkit.Mvvm.ComponentModel;
using Microsoft.UI.Xaml.Media;

namespace Juice.App.ViewModels;

/// <summary>
/// One row of the top energy users list.
/// </summary>
/// <remarks>
/// Rows are mutated in place rather than rebuilt, because the list refreshes as often as
/// every two seconds while the flyout is open and replacing the collection would reset
/// scroll position and restart the item animations on every tick.
/// </remarks>
public sealed partial class EnergyRowViewModel : ObservableObject
{
    /// <summary>Creates an empty row for the flyout to fill in.</summary>
    public EnergyRowViewModel()
    {
        // Partial properties cannot carry initialisers, so the empty defaults are set
        // here.
        DisplayName = string.Empty;
        WattsText = string.Empty;
        CostText = string.Empty;
        AppId = string.Empty;
    }

    /// <summary>
    /// Stable identity of the app this row currently shows.
    /// </summary>
    /// <remarks>
    /// Rows are re-used, and the icon for a row arrives asynchronously. This is what the
    /// icon callback checks before applying, so a slow lookup cannot paint its icon onto
    /// a row that has since been given to a different app.
    /// </remarks>
    public string AppId { get; set; }

    /// <summary>
    /// The app's real icon, or null when there is none to show.
    /// </summary>
    /// <remarks>
    /// Null covers both the platform row, which is a system indicator rather than an app,
    /// and an executable whose icon could not be extracted. Nothing generic is
    /// substituted: an invented icon would be a claim about which app this is.
    /// </remarks>
    [ObservableProperty]
    public partial ImageSource? Icon { get; set; }

    /// <summary>Friendly name of the app, or the platform row's label.</summary>
    [ObservableProperty]
    public partial string DisplayName { get; set; }

    /// <summary>Average wattage over the attribution window.</summary>
    [ObservableProperty]
    public partial string WattsText { get; set; }

    /// <summary>Annual cost of sustaining that wattage, at the current rate.</summary>
    [ObservableProperty]
    public partial string CostText { get; set; }

    /// <summary>
    /// True for the platform row. It is the display backlight, radios and regulator
    /// loss - real measured energy that belongs to no app, so it is shown as its own row
    /// rather than spread across the apps above it.
    /// </summary>
    [ObservableProperty]
    public partial bool IsPlatform { get; set; }

    /// <summary>
    /// True while this row is reserving space for a measurement that has not arrived yet.
    /// </summary>
    /// <remarks>
    /// Attribution needs two process samples several seconds apart, so the list is
    /// necessarily empty for the first few seconds after launch. Rendering that as an
    /// empty list made the flyout open short and then jump taller the moment the first
    /// window closed. Placeholder rows hold the steady state geometry from the outset, so
    /// data arriving changes what the rows say and not where anything sits.
    ///
    /// A placeholder carries no numbers at all. It is drawn as blank blocks rather than
    /// as zeroes or dashes, because a zero would be a measurement and there is not one.
    /// </remarks>
    [ObservableProperty]
    public partial bool IsPlaceholder { get; set; }

    /// <summary>
    /// This row's watts as a fraction of the largest row's, from 0 to 1. Sets the width
    /// of the ranking bar drawn behind the row.
    /// </summary>
    /// <remarks>
    /// It is the ratio of two measured averages and nothing else. The bar is never
    /// floored to a visible minimum, because a row that drew almost nothing has to look
    /// like it drew almost nothing.
    /// </remarks>
    [ObservableProperty]
    public partial double BarFraction { get; set; }
}
