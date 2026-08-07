import AppKit

extension GlassConfig {
    /// The config with the wallpaper's palette mapped onto it, or unchanged when wallpaper theming
    /// is off or the desktop picture can't be sampled.
    ///
    /// Mapping colors to roles happens here rather than in the sampler, so ``WallpaperPalette``
    /// stays a statement about the picture and this stays a statement about the decorations.
    @MainActor
    func themed() -> GlassConfig {
        guard theme.fromWallpaper,
              let palette = WallpaperTheme.palette(multi: theme.palette == .multi)
        else { return self }
        var themed = self

        // The bar stacks: strip, unselected tabs one step up, selected tab in the accent. Label
        // colors keep deferring to an explicit setting — those keys mean "derive it" when unset,
        // and the palette is just a better derivation.
        themed.tabs.barTint = palette.surface
        themed.tabs.inactiveTint = palette.elevated
        themed.tabs.activeTint = palette.accent
        themed.tabs.textColor = tabs.textColor ?? palette.onElevated
        themed.tabs.activeTextColor = tabs.activeTextColor ?? palette.onAccent
        themed.tabs.activeBorderColor = tabs.activeBorderColor ?? palette.accent

        // Focus is the accent; everything unfocused recedes into the surface it sits on.
        themed.borders.activeColor = palette.accent
        themed.borders.inactiveColor = palette.secondary.withAlpha(0.55)

        // The preview stays mostly transparent whatever the palette says — it is drawn over the
        // layout it is describing, and a solid fill would hide the thing being previewed.
        themed.dropPreview.strokeColor = palette.accent.withAlpha(0.9)
        themed.dropPreview.tint = palette.accent.withAlpha(0.1)
        themed.dropPreview.cellColor = palette.onSurface.withAlpha(0.25)

        return themed
    }
}

extension GlassColor {
    func withAlpha(_ alpha: Double) -> GlassColor {
        GlassColor(red: red, green: green, blue: blue, alpha: alpha)
    }
}
