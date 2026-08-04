import SwiftUI

/// A rounded-rectangle ring: the outer rounded rect with a concentric inner one subtracted.
///
/// Filled with `FillStyle(eoFill: true)` (or handed to `glassEffect(_:in:)`, which fills using the
/// even-odd rule) this yields a hollow frame, so the window underneath stays visible and the
/// decoration reads as a border rather than a panel.
struct RoundedRingShape: Shape {
    var cornerRadius: CGFloat
    var lineWidth: CGFloat

    nonisolated func path(in rect: CGRect) -> Path {
        var path = Path(roundedRect: rect, cornerRadius: cornerRadius, style: .continuous)
        let inner = rect.insetBy(dx: lineWidth, dy: lineWidth)
        guard inner.width > 0 && inner.height > 0 else { return path }
        path.addPath(Path(
            roundedRect: inner,
            cornerRadius: max(cornerRadius - lineWidth, 0),
            style: .continuous,
        ))
        return path
    }
}
