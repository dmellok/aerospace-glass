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
    var legibleForeground: NSColor {
        let backdrop = 0.45
        func over(_ channel: Double) -> Double { alpha * channel + (1 - alpha) * backdrop }
        let luminance = 0.2126 * over(red) + 0.7152 * over(green) + 0.0722 * over(blue)
        return luminance > 0.55
            ? NSColor(srgbRed: 0, green: 0, blue: 0, alpha: 0.88)
            : NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.92)
    }
}
