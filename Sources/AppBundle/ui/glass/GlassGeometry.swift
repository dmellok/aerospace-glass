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
}
