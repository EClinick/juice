using Microsoft.UI.Composition;
using Microsoft.UI.Composition.SystemBackdrops;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Media;

namespace Juice.App.Views;

/// <summary>
/// Desktop acrylic for surfaces that sit above the taskbar the way the shell's own
/// flyouts do.
/// </summary>
/// <remarks>
/// The declarative <c>DesktopAcrylicBackdrop</c> element has no <c>Kind</c> property in
/// Windows App SDK 2.3, so the only route to choosing a variant is
/// <see cref="DesktopAcrylicController"/>, which does. Wrapping that in a
/// <see cref="SystemBackdrop"/> keeps the choice declarative at the point of use: the
/// window still says which material it wants in XAML, and no window code-behind carries
/// colour or opacity values.
///
/// The variant is <see cref="DesktopAcrylicKind.Base"/>, which is what the volume and
/// network flyouts use and is the material that reads as the taskbar's dark translucent
/// grey. An earlier version used <see cref="DesktopAcrylicKind.Thin"/> on the reasoning
/// that a flyout should let the window behind it read through. That was the wrong reading
/// of the guidance: thin acrylic is for transient surfaces layered over app content, such
/// as tooltips and context menus, and against a bright desktop it left the panel washed
/// out and the text fighting whatever happened to be behind it.
///
/// Only <see cref="DesktopAcrylicController.Kind"/> is set. Setting tint and luminosity
/// opacities by hand, as an earlier attempt did, silently opts the controller out of its
/// theme-derived defaults for tint and fallback colour, which is why that attempt
/// rendered a light panel on a fully dark system. Leaving every colour to the controller
/// keeps the material correct in light, dark and high contrast without a table of
/// hand-tuned constants to maintain.
/// </remarks>
public sealed class FlyoutAcrylicBackdrop : SystemBackdrop
{
    private DesktopAcrylicController? _controller;
    private SystemBackdropConfiguration? _configuration;
    private ICompositionSupportsSystemBackdrop? _target;
    private XamlRoot? _xamlRoot;

    /// <summary>Attaches the thin acrylic controller to a window that asked for it.</summary>
    /// <param name="connectedTarget">The window or island receiving the backdrop.</param>
    /// <param name="xamlRoot">The XAML root the backdrop reads its theme from.</param>
    protected override void OnTargetConnected(ICompositionSupportsSystemBackdrop connectedTarget, XamlRoot xamlRoot)
    {
        base.OnTargetConnected(connectedTarget, xamlRoot);

        _target = connectedTarget;
        _xamlRoot = xamlRoot;

        // The base configuration tracks the root's ActualTheme and the system's
        // high contrast and energy-saver states, so the material follows the theme the
        // flyout has been given rather than the process default.
        _configuration = GetDefaultSystemBackdropConfiguration(connectedTarget, xamlRoot);

        if (!DesktopAcrylicController.IsSupported())
        {
            return;
        }

        _controller ??= new DesktopAcrylicController { Kind = DesktopAcrylicKind.Base };
        _controller.SetSystemBackdropConfiguration(_configuration);
        _controller.AddSystemBackdropTarget(connectedTarget);
    }

    /// <summary>
    /// Re-reads the default configuration after the system changed something the material
    /// depends on.
    /// </summary>
    /// <param name="target">The window or island whose configuration changed. Not used.</param>
    /// <param name="xamlRoot">The XAML root the backdrop reads its theme from. Not used.</param>
    /// <remarks>
    /// <para>
    /// Overriding this is not optional for anyone who calls
    /// <see cref="SystemBackdrop.GetDefaultSystemBackdropConfiguration"/>. Left to the base
    /// implementation it fails with <c>E_INVALIDARG</c>, which crosses the WinRT boundary
    /// as an unhandled <see cref="ArgumentException"/> and takes the process down.
    /// </para>
    /// <para>
    /// The crash sat here undiscovered because nothing ever changed the flyout's theme
    /// after construction: the taskbar theme was read once and applied once. The moment
    /// the flyout started following a live light or dark switch, every switch killed the
    /// app. High contrast and energy saver changes raise the same callback.
    /// </para>
    /// <para>
    /// The arguments are deliberately ignored in favour of the pair captured at connect
    /// time. Passing the projected <paramref name="target"/> straight back into
    /// <c>GetDefaultSystemBackdropConfiguration</c> fails with the same
    /// <c>E_INVALIDARG</c>, naming <c>target</c>, so the marshalled instance handed to
    /// this callback is not one the framework will accept.
    /// </para>
    /// </remarks>
    protected override void OnDefaultSystemBackdropConfigurationChanged(
        ICompositionSupportsSystemBackdrop target,
        XamlRoot xamlRoot)
    {
        if (_target is null || _xamlRoot is null) return;

        _configuration = GetDefaultSystemBackdropConfiguration(_target, _xamlRoot);
        _controller?.SetSystemBackdropConfiguration(_configuration);
    }

    /// <summary>Releases the controller when the window goes away.</summary>
    /// <param name="disconnectedTarget">The window or island losing the backdrop.</param>
    protected override void OnTargetDisconnected(ICompositionSupportsSystemBackdrop disconnectedTarget)
    {
        base.OnTargetDisconnected(disconnectedTarget);

        _controller?.RemoveSystemBackdropTarget(disconnectedTarget);
        _controller?.Dispose();
        _controller = null;
        _configuration = null;
        _target = null;
        _xamlRoot = null;
    }
}
