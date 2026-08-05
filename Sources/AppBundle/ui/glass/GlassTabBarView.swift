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
///
/// Tabs are draggable. The gesture itself only moves the chip and reports positions; where the drop
/// lands — reorder, another group's bar, a split of some other cell, a tear-off — is decided by the
/// same ``DropTarget`` machinery that window drags use, via the `onDrag*` callbacks.
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
    var onClose: (UInt32) -> ()
    var onDragChanged: (UInt32) -> ()
    var onDragEnded: (UInt32, CGSize) -> ()

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
                    onSelect: { onSelect(item.id) },
                    onClose: { onClose(item.id) },
                    onDragChanged: { onDragChanged(item.id) },
                    onDragEnded: { onDragEnded(item.id, $0) },
                )
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
    var onSelect: () -> ()
    var onClose: () -> ()
    var onDragChanged: () -> ()
    var onDragEnded: (CGSize) -> ()

    @State private var isHovered = false
    @State private var dragTranslation: CGSize? = nil

    private var iconSide: CGFloat { fontSize + 3 }
    private var shape: RoundedRectangle { RoundedRectangle(cornerRadius: cornerRadius, style: .continuous) }
    private var isDragging: Bool { dragTranslation != nil }

    var body: some View {
        HStack(spacing: 5) {
            if showIcons, let icon = item.icon {
                Image(nsImage: icon)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: iconSide, height: iconSide)
                    .opacity(item.isActive ? 1 : 0.7)
            }
            Text(item.title)
                .font(.system(size: fontSize, weight: item.isActive ? .semibold : .regular))
                .lineLimit(1)
                .truncationMode(.tail)
                .foregroundStyle(foreground)
        }
        // Symmetric padding keeps icon+title centered while staying clear of the close button
        // anchored at the leading edge
        .padding(.horizontal, iconSide + 8)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            shape.fill(fill)
                // A hovered tab lifts one step up the bar's value ramp, so the bar answers
                // "what happens if I click here" before the click
                .overlay(shape.fill(.white.opacity(isHovered && !item.isActive ? 0.08 : 0)))
        )
        .overlay {
            // The active tab gets a hairline instead of a heavier fill: visible on any backdrop
            // without breaking the value ramp the three tints establish
            if item.isActive {
                shape.strokeBorder(.white.opacity(0.25), lineWidth: 1)
            }
        }
        .overlay(alignment: .leading) {
            if isHovered && !isDragging {
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: max(fontSize - 3, 7), weight: .bold))
                        .foregroundStyle(foreground.opacity(0.8))
                        .frame(width: iconSide, height: iconSide)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(.leading, 5)
                .transition(.opacity)
            }
        }
        .compositingGroup()
        .shadow(color: .black.opacity(isDragging ? 0.35 : item.isActive ? 0.15 : 0), radius: isDragging ? 6 : 2, y: 1)
        .opacity(isDragging ? 0.85 : 1)
        .scaleEffect(isDragging ? 1.03 : 1)
        .offset(dragTranslation ?? .zero)
        .zIndex(isDragging ? 1 : 0)
        .contentShape(Rectangle())
        .onTapGesture(perform: onSelect)
        .gesture(
            DragGesture(minimumDistance: 8)
                .onChanged { value in
                    dragTranslation = value.translation
                    onDragChanged()
                }
                .onEnded { value in
                    dragTranslation = nil
                    onDragEnded(value.translation)
                },
        )
        .onHover { isHovered = $0 }
        .animation(.easeOut(duration: 0.12), value: isHovered)
        .animation(.easeOut(duration: 0.12), value: isDragging)
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
