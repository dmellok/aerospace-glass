import AppKit
import Common
import SwiftUI

/// The grab strip drawn in the gap between two tiles.
///
/// Invisible until pointed at, because a divider you can see on every gap turns a tiled workspace
/// into a grid of lines. The panel behind it is the hit area, which is deliberately wider than the
/// visible bar: a 4pt gap is a hard target, and widening the *drawing* to match would be ugly.
struct GlassResizeHandleView: View {
    var orientation: Orientation
    var color: Color
    /// Fires on every tick. The delta is deliberately not taken from the gesture: the handle's
    /// panel moves as the gap it sits in moves, so a translation measured in the view's own
    /// coordinates feeds back on itself. The manager reads the pointer instead.
    var onDragChanged: () -> ()
    var onDragStarted: () -> ()
    var onDragEnded: () -> ()

    @State private var isHovered = false
    @State private var isDragging = false

    private var isVertical: Bool { orientation == .h }

    var body: some View {
        ZStack {
            // A clear layer so the whole hit area takes the drag, not just the visible pill.
            Color.clear.contentShape(Rectangle())
            Capsule()
                .fill(color)
                .frame(
                    width: isVertical ? 4 : 40,
                    height: isVertical ? 40 : 4,
                )
                .opacity(isDragging ? 1 : (isHovered ? 0.85 : 0))
        }
        .animation(.easeOut(duration: 0.12), value: isHovered)
        .animation(.easeOut(duration: 0.12), value: isDragging)
        .onContinuousHover { phase in
            switch phase {
                case .active:
                    if !isHovered {
                        isHovered = true
                        // The cursor is the affordance that says this gap is grabbable at all.
                        (isVertical ? NSCursor.resizeLeftRight : NSCursor.resizeUpDown).push()
                    }
                case .ended:
                    if isHovered {
                        isHovered = false
                        if !isDragging { NSCursor.pop() }
                    }
            }
        }
        .gesture(
            DragGesture(minimumDistance: 1)
                .onChanged { _ in
                    if !isDragging {
                        isDragging = true
                        onDragStarted()
                    }
                    onDragChanged()
                }
                .onEnded { _ in
                    isDragging = false
                    if !isHovered { NSCursor.pop() }
                    onDragEnded()
                },
        )
    }
}
