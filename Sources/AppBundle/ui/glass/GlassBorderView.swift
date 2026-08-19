import AppKit
import SwiftUI

struct GlassBorderView: View, Equatable {
    var cornerRadius: CGFloat
    var lineWidth: CGFloat
    /// Points of solid accent drawn along the ring's outer edge. The remaining width stays tinted
    /// glass, so this trades glass for definition: at `lineWidth` the ring is a flat stroke and no
    /// glass shows at all, at 0 it is pure glass with nothing to anchor it against a busy backdrop.
    var strokeWidth: CGFloat
    var color: Color

    private var ring: RoundedRingShape {
        RoundedRingShape(cornerRadius: cornerRadius, lineWidth: lineWidth)
    }

    private var outline: RoundedRectangle {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
    }

    /// The accent, clamped so it can never exceed the ring it is drawn inside.
    private var accent: CGFloat { min(max(strokeWidth, 0), lineWidth) }

    var body: some View {
        Group {
            // A solid accent as wide as the ring hides the glass completely. Computing a live
            // backdrop blur underneath it is invisible work the GPU repeats for every bordered
            // window, forever, so the ring is drawn as a plain stroke instead.
            if accent >= lineWidth {
                outline.inset(by: lineWidth / 2).stroke(color, lineWidth: lineWidth)
            } else if #available(macOS 26.0, *) {
                // Liquid Glass refracts and blurs whatever the window server has composited behind
                // the panel, which for an overlay is the desktop and the neighbouring app windows.
                //
                // glassEffect(_:in:) fills its shape with the non-zero winding rule, so handing it
                // the ring directly would fill the hole back in and frost the whole window. Fill the
                // outer shape and punch the hole with an explicit even-odd mask instead.
                outline
                    .glassEffect(.regular.tint(color), in: outline)
                    .mask(ring.fill(style: FillStyle(eoFill: true)))
                    // A hairline of the accent along the outer edge. Glass alone reads as neutral
                    // grey against a busy backdrop and the tint is lost; a stroke the full width of
                    // the ring hides the glass entirely. Keeping it thin leaves the refraction
                    // visible while still naming the focus color.
                    .overlay {
                        if accent > 0 {
                            outline.inset(by: accent / 2).stroke(color, lineWidth: accent)
                        }
                    }
            } else {
                // No Liquid Glass here, so the blur material is the whole effect and the accent is
                // laid over it at the same proportion.
                ring
                    .fill(.ultraThinMaterial, style: FillStyle(eoFill: true))
                    .overlay {
                        if accent > 0 {
                            outline.inset(by: accent / 2).stroke(color, lineWidth: accent)
                        }
                    }
            }
        }
        .allowsHitTesting(false)
    }
}
