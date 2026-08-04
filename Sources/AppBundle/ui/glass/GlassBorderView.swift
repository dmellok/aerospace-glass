import AppKit
import SwiftUI

struct GlassBorderView: View {
    var cornerRadius: CGFloat
    var lineWidth: CGFloat
    var color: Color

    private var ring: RoundedRingShape {
        RoundedRingShape(cornerRadius: cornerRadius, lineWidth: lineWidth)
    }

    var body: some View {
        Group {
            if #available(macOS 26.0, *) {
                // Liquid Glass refracts and blurs whatever the window server has composited behind
                // the panel, which for an overlay is the desktop and the neighbouring app windows.
                ring.glassEffect(.regular.tint(color), in: ring)
            } else {
                ring
                    .fill(.ultraThinMaterial, style: FillStyle(eoFill: true))
                    .overlay(ring.fill(color, style: FillStyle(eoFill: true)))
            }
        }
        .allowsHitTesting(false)
    }
}
