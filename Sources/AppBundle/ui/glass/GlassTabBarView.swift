import AppKit
import SwiftUI

struct GlassTabItem: Identifiable {
    let id: UInt32 // windowId
    let title: String
    let icon: NSImage?
    let isActive: Bool
}

/// The tab bar drawn above a `tabbed` container: one blurred strip spanning the container, with the
/// tabs forming a value ramp against it — unselected a shade darker, the selected one the lightest
/// thing in the bar, so the highlight is the only element competing for attention.
struct GlassTabBarView: View {
    var items: [GlassTabItem]
    var cornerRadius: CGFloat
    var fontSize: CGFloat
    var showIcons: Bool
    var barTint: Color
    var inactiveTint: Color
    var activeTint: Color
    var activeForeground: Color
    var inactiveForeground: Color
    var onSelect: (UInt32) -> ()

    private var strip: RoundedRectangle {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
    }

    var body: some View {
        HStack(spacing: 3) {
            ForEach(items) { item in
                GlassTabView(
                    item: item,
                    cornerRadius: max(cornerRadius - 3, 2),
                    fontSize: fontSize,
                    showIcons: showIcons,
                    fill: item.isActive ? activeTint : inactiveTint,
                    foreground: item.isActive ? activeForeground : inactiveForeground,
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .contentShape(Rectangle())
                .onTapGesture { onSelect(item.id) }
            }
        }
        .padding(3)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .modifier(GlassStripBackground(shape: strip, tint: barTint))
    }
}

private struct GlassTabView: View {
    var item: GlassTabItem
    var cornerRadius: CGFloat
    var fontSize: CGFloat
    var showIcons: Bool
    var fill: Color
    var foreground: Color

    var body: some View {
        HStack(spacing: 5) {
            if showIcons, let icon = item.icon {
                Image(nsImage: icon)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: fontSize + 3, height: fontSize + 3)
                    .opacity(item.isActive ? 1 : 0.7)
            }
            Text(item.title)
                .font(.system(size: fontSize, weight: item.isActive ? .semibold : .regular))
                .lineLimit(1)
                .truncationMode(.tail)
                .foregroundStyle(foreground)
        }
        .padding(.horizontal, 8)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous).fill(fill))
    }
}

/// The blur behind the whole strip. The window server composites it, so it picks up the windows of
/// other applications sitting underneath, not just this process's own content.
private struct GlassStripBackground<S: Shape>: ViewModifier {
    var shape: S
    var tint: Color

    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            content.glassEffect(.regular.tint(tint), in: shape)
        } else {
            content
                .background(.ultraThinMaterial, in: shape)
                .background(shape.fill(tint))
        }
    }
}
