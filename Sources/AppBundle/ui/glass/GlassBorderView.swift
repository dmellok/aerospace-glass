import AppKit
import SwiftUI

struct GlassBorderView: View {
    var cornerRadius: CGFloat
    var lineWidth: CGFloat
    var color: Color

    private var ring: RoundedRingShape {
        RoundedRingShape(cornerRadius: cornerRadius, lineWidth: lineWidth)
    }

    private var outline: RoundedRectangle {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
    }

    var body: some View {
        Group {
            if #available(macOS 26.0, *) {
                // Liquid Glass refracts and blurs whatever the window server has composited behind
                // the panel, which for an overlay is the desktop and the neighbouring app windows.
                //
                // glassEffect(_:in:) fills its shape with the non-zero winding rule, so handing it
                // the ring directly would fill the hole back in and frost the whole window. Fill the
                // outer shape and punch the hole with an explicit even-odd mask instead.
                outline
                    .glassEffect(.regular.tint(color), in: outline)
                    .mask(ring.fill(style: FillStyle(eoFill: true)))
                    // At a few points wide the glass reads as neutral grey and the tint is lost, so
                    // the accent color is stroked on top. The glass underneath still supplies the
                    // refracted edge that makes the border sit in the macOS 26 visual language.
                    .overlay(outline.inset(by: lineWidth / 2).stroke(color, lineWidth: lineWidth))
            } else {
                ring
                    .fill(.ultraThinMaterial, style: FillStyle(eoFill: true))
                    .overlay(ring.fill(color, style: FillStyle(eoFill: true)))
            }
        }
        .allowsHitTesting(false)
    }
}
