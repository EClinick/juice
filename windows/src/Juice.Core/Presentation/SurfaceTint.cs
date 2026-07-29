namespace Juice.Core.Presentation;

/// <summary>
/// Decides how strongly a user-chosen accent colour may be laid over a surface that text
/// still has to be readable on.
/// </summary>
/// <remarks>
/// The accent is whatever colour the user picked, not one selected for legibility, so it
/// cannot be applied at a fixed strength. A bright accent over a dark panel drags the
/// background up toward the light text sitting on it, and a dark accent over a light panel
/// does the same in reverse. Either way what gets spent is contrast, so the pairings that
/// do that get less tint.
/// </remarks>
public static class SurfaceTint
{
    /// <summary>Strength used when the accent and the surface do not fight each other.</summary>
    public const double NormalAlpha = 0.12;

    /// <summary>Strength used when the accent runs opposite in brightness to the surface.</summary>
    public const double ContrastingAlpha = 0.07;

    /// <summary>At or above this luminance an accent counts as bright.</summary>
    public const double BrightLuminance = 0.65;

    /// <summary>Below this luminance an accent counts as dark.</summary>
    public const double DarkLuminance = 0.35;

    /// <summary>
    /// Alpha to apply to the accent tint, from 0 to 1.
    /// </summary>
    /// <param name="accentLuminance">Perceived brightness of the accent, from 0 to 1.</param>
    /// <param name="isSurfaceLight">True when the surface underneath the tint is a light one.</param>
    public static double AlphaFor(double accentLuminance, bool isSurfaceLight)
        => IsContrasting(accentLuminance, isSurfaceLight) ? ContrastingAlpha : NormalAlpha;

    /// <summary>True when the accent's brightness runs opposite to the surface's.</summary>
    /// <remarks>
    /// An unreadable luminance is treated as not contrasting. The normal strength is
    /// already conservative, so guessing wrong in that direction costs a little tint
    /// rather than a little text contrast.
    /// </remarks>
    public static bool IsContrasting(double accentLuminance, bool isSurfaceLight)
    {
        if (double.IsNaN(accentLuminance)) return false;

        return isSurfaceLight
            ? accentLuminance < DarkLuminance
            : accentLuminance >= BrightLuminance;
    }
}
