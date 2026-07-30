using CommunityToolkit.Mvvm.ComponentModel;
using Juice.Core.Insights;

namespace Juice.App.ViewModels;

/// <summary>One generated observation, as the flyout draws it.</summary>
/// <remarks>
/// The engine produces insights with a severity and a stable id; this adds only what
/// drawing needs. The glyph and the severity flags are derived here rather than in Core,
/// because Core has no opinion about Segoe Fluent Icons and should not acquire one.
/// </remarks>
public sealed partial class InsightRowViewModel : ObservableObject
{
    /// <summary>Creates a row from a generated insight.</summary>
    public InsightRowViewModel(Insight insight)
    {
        Id = insight.Id;
        Title = insight.Title;
        Detail = insight.Detail;
        Severity = insight.Severity;
        Glyph = GlyphFor(insight.Kind);
        SeverityLabel = LabelFor(insight.Severity);
    }

    /// <summary>Stable identifier, so a refresh can tell rows apart.</summary>
    public string Id { get; }

    /// <summary>The headline, which is a complete sentence on its own.</summary>
    public string Title { get; }

    /// <summary>The supporting figures behind the headline.</summary>
    public string Detail { get; }

    /// <summary>How much attention it deserves, which drives the accent.</summary>
    public InsightSeverity Severity { get; }

    /// <summary>Segoe Fluent Icons glyph describing the kind of observation.</summary>
    public string Glyph { get; }

    /// <summary>
    /// The severity in words, so it is not carried by colour alone.
    /// </summary>
    /// <remarks>
    /// The tinted icon is the only visual signal of severity, and a tint is exactly the
    /// signal that a colour blind user, a high contrast theme and a screen reader all
    /// miss. Saying it in the automation name costs nothing and is the difference between
    /// the severity being conveyed and merely being drawn.
    /// </remarks>
    public string SeverityLabel { get; }

    /// <summary>
    /// True when the observation is worth acting on.
    /// </summary>
    /// <remarks>
    /// The three severities are exposed as flags rather than as a brush because a brush
    /// chosen here is the instance from whichever theme dictionary happened to be active
    /// when the row was built, and bindings inside a DataTemplate are not reachable from
    /// the window's <c>Bindings.Update()</c>. A row that handed over a brush would keep
    /// painting the old theme's colour after a light or dark switch. Flags let the
    /// template pick the brush declaratively with ThemeResource, which is what makes it
    /// follow the system theme, including high contrast. The rail strips and the ranking
    /// bars are built the same way and for the same reason.
    /// </remarks>
    public bool IsWarning => Severity == InsightSeverity.Warning;

    /// <summary>True when the observation is worth looking at.</summary>
    public bool IsNotice => Severity == InsightSeverity.Notice;

    /// <summary>True when the observation is merely worth knowing.</summary>
    public bool IsInfo => Severity == InsightSeverity.Info;

    /// <summary>
    /// A glyph per kind, so the icon says something the text does not have to repeat.
    /// </summary>
    /// <remarks>
    /// Chosen from Segoe Fluent Icons rather than emoji, both because emoji render
    /// inconsistently across themes and because the notification area is not the place for
    /// them. The macOS version uses a lightbulb for every insight; distinguishing them
    /// costs nothing and makes a list of three scannable.
    /// </remarks>
    private static string GlyphFor(InsightKind kind) => kind switch
    {
        // Speed dial: draw is away from where it usually sits.
        InsightKind.DrainAnomaly => "\uEC4A",

        // Single app, above its own normal.
        InsightKind.AppAnomaly => "\uE7EE",

        // Ranking over a period.
        InsightKind.HogOfWeek => "\uE9D9",

        // Battery, for anything about charging behaviour.
        InsightKind.ChargingHabit => "\uE83E",

        _ => "\uE946",
    };

    /// <summary>The severity as a word a screen reader can read out.</summary>
    private static string LabelFor(InsightSeverity severity) => severity switch
    {
        InsightSeverity.Warning => "Warning",
        InsightSeverity.Notice => "Notice",
        _ => "Note",
    };
}
