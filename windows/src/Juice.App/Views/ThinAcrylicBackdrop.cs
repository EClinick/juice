using Microsoft.UI.Composition;
using Microsoft.UI.Composition.SystemBackdrops;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Media;

namespace Juice.App.Views;

/// <summary>
/// Desktop acrylic in its thin variant, for surfaces that should let the window behind
/// them read through the way the shell's own flyouts do.
/// </summary>
/// <remarks>
/// The declarative <c>DesktopAcrylicBackdrop</c> element has no <c>Kind</c> property in
/// Windows App SDK 2.3, so the only route to thin acrylic is
/// <see cref="DesktopAcrylicController"/>, which does. Wrapping that in a
/// <see cref="SystemBackdrop"/> keeps the choice declarative at the point of use: the
/// window still says which material it wants in XAML, and no window code-behind carries
/// colour or opacity values.
///
/// Only <see cref="DesktopAcrylicController.Kind"/> is set. Setting tint and luminosity
/// opacities by hand, as an earlier attempt did, silently opts the controller out of its
/// theme-derived defaults for tint and fallback colour, which is why that attempt
/// rendered a light panel on a fully dark system. Leaving every colour to the controller
/// keeps the material correct in light, dark and high contrast without a table of
/// hand-tuned constants to maintain.
/// </remarks>
public sealed class ThinAcrylicBackdrop : SystemBackdrop
{
    private DesktopAcrylicController? _controller;
    private SystemBackdropConfiguration? _configuration;

    /// <summary>Attaches the thin acrylic controller to a window that asked for it.</summary>
    /// <param name="connectedTarget">The window or island receiving the backdrop.</param>
    /// <param name="xamlRoot">The XAML root the backdrop reads its theme from.</param>
    protected override void OnTargetConnected(ICompositionSupportsSystemBackdrop connectedTarget, XamlRoot xamlRoot)
    {
        base.OnTargetConnected(connectedTarget, xamlRoot);

        // The base configuration tracks the root's ActualTheme and the system's
        // high contrast and energy-saver states, so the material follows the theme the
        // flyout has been given rather than the process default.
        _configuration ??= GetDefaultSystemBackdropConfiguration(connectedTarget, xamlRoot);

        if (!DesktopAcrylicController.IsSupported())
        {
            return;
        }

        _controller ??= new DesktopAcrylicController { Kind = DesktopAcrylicKind.Thin };
        _controller.SetSystemBackdropConfiguration(_configuration);
        _controller.AddSystemBackdropTarget(connectedTarget);
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
    }
}
