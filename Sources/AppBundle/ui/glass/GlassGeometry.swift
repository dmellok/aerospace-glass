import AppKit

extension Rect {
    /// AeroSpace's ``Rect`` has its origin in the top left corner of the main monitor with the y-axis
    /// pointing down. AppKit wants the bottom left corner with the y-axis pointing up. This is the
    /// inverse of ``CGRect/monitorFrameNormalized()``.
    @MainActor
    var toCocoaRect: NSRect {
        NSRect(
            x: topLeftX,
            y: mainMonitor.height - topLeftY - height,
            width: width,
            height: height,
        )
    }

    func inset(by delta: CGFloat) -> Rect {
        Rect(
            topLeftX: topLeftX + delta,
            topLeftY: topLeftY + delta,
            width: width - 2 * delta,
            height: height - 2 * delta,
        )
    }
}

extension GlassColor {
    var toNSColor: NSColor {
        NSColor(srgbRed: red, green: green, blue: blue, alpha: alpha)
    }

    /// Black or white, whichever stays legible on top of this fill.
    ///
    /// The decorations float over arbitrary application content, so the system light/dark appearance
    /// says nothing useful about what a label will sit on — only the configured fill does. The fill
    /// is composited over the glass, approximated here as a mid grey.
    var legibleForeground: NSColor { legibleGlassColor.toNSColor }

    /// The opposite side of the colour wheel, kept at a similar brightness. An alert has to read as
    /// "not the normal colour" at a glance, and the complement does that whatever the theme is
    /// tuned to — including a palette sampled from a wallpaper nobody chose in advance.
    var complement: GlassColor {
        var hue: CGFloat = 0, saturation: CGFloat = 0, brightness: CGFloat = 0, alphaOut: CGFloat = 0
        let ns = toNSColor.usingColorSpace(.sRGB) ?? .red
        ns.getHue(&hue, saturation: &saturation, brightness: &brightness, alpha: &alphaOut)
        // A grey has no hue to oppose, so it becomes a warm amber instead of staying grey.
        let rotated = saturation < 0.15
            ? NSColor(hue: 0.08, saturation: 0.85, brightness: max(brightness, 0.75), alpha: alphaOut)
            : NSColor(
                hue: (hue + 0.5).truncatingRemainder(dividingBy: 1),
                saturation: min(max(saturation, 0.6), 1),
                brightness: min(max(brightness, 0.7), 1),
                alpha: alphaOut,
            )
        let srgb = rotated.usingColorSpace(.sRGB) ?? rotated
        return GlassColor(
            red: Double(srgb.redComponent),
            green: Double(srgb.greenComponent),
            blue: Double(srgb.blueComponent),
            alpha: Double(srgb.alphaComponent),
        )
    }

    /// As ``legibleForeground``, in the config's own color type so a configured override can
    /// substitute for it without either side knowing which it got.
    var legibleGlassColor: GlassColor {
        let backdrop = 0.45
        func over(_ channel: Double) -> Double { alpha * channel + (1 - alpha) * backdrop }
        let luminance = 0.2126 * over(red) + 0.7152 * over(green) + 0.0722 * over(blue)
        return luminance > 0.55
            ? GlassColor(red: 0, green: 0, blue: 0, alpha: 0.88)
            : GlassColor(red: 1, green: 1, blue: 1, alpha: 0.92)
    }
}

/// Where the tabs sit inside a bar.
///
/// Three things need this and must agree: the bar draws the tabs, the drag logic turns a cursor
/// position into an insertion index, and the preview draws the caret at that index. They used to
/// each assume tabs divide the bar equally, which stops being true the moment tabs have a fixed
/// width, so the arithmetic lives here once.
@MainActor
struct GlassTabLayout {
    /// Inset of the tab row from the bar's edges, matching the bar view's padding.
    static let inset: CGFloat = 3
    /// Gap between neighbouring tabs.
    static let spacing: CGFloat = 3

    let barMinX: CGFloat
    let barMaxX: CGFloat
    let count: Int
    /// Width of one tab. Fixed-width tabs still shrink once they no longer fit, the way a browser
    /// narrows its tabs rather than overflowing the bar.
    let slotWidth: CGFloat

    init(barMinX: CGFloat, barWidth: CGFloat, count: Int) {
        self.barMinX = barMinX
        self.barMaxX = barMinX + barWidth
        self.count = count
        let content = max(barWidth - Self.inset * 2, 0)
        let equal = count > 0
            ? max((content - Self.spacing * CGFloat(count - 1)) / CGFloat(count), 0)
            : content
        let cfg = config.glass.tabs
        slotWidth = cfg.fixedWidth ? min(CGFloat(cfg.width), equal) : equal
    }

    func slotOrigin(_ index: Int) -> CGFloat {
        barMinX + Self.inset + CGFloat(index) * (slotWidth + Self.spacing)
    }

    /// The gap the cursor is nearest, as an index into the children.
    func insertIndex(atX x: CGFloat) -> Int {
        guard count > 0, slotWidth > 0 else { return 0 }
        let offset = x - barMinX - Self.inset
        let index = Int((offset / (slotWidth + Self.spacing)).rounded())
        return min(max(index, 0), count)
    }

    /// The caret drawn in the gap at `index`, or nil when there is no room to draw one.
    func caretX(_ index: Int) -> CGFloat? {
        guard count > 0, slotWidth > 0 else { return nil }
        if index <= 0 { return barMinX + Self.inset }
        return min(slotOrigin(index) - Self.spacing / 2, barMaxX - Self.inset)
    }
}
