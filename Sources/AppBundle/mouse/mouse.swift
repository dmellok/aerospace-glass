import AppKit

@MainActor var currentlyManipulatedWithMouseWindowId: UInt32? = nil
/// Where releasing the currently dragged tiling window would put it. Refreshed on every drag tick
/// by ``moveWithMouse``, consumed on mouse-up by ``resetManipulatedWithMouseIfPossible``.
@MainActor var pendingDropTarget: DropTarget? = nil

/// What the physical drag in progress is. A resize from a window's left or top edge changes the
/// origin too, so it fires the same AX moved notifications a title-bar drag does — the two can
/// only be told apart by whether the size is changing. Until that's known the drag is unclassified
/// and neither path does anything destructive.
enum MouseDragKind {
    case move, resize
}

@MainActor var currentMouseDragKind: MouseDragKind? = nil
/// The window size and mouse position at the first tick of the drag, the baseline the
/// classification compares against.
@MainActor var mouseDragInitial: (windowId: UInt32, width: CGFloat, height: CGFloat, mouse: CGPoint)? = nil
var isLeftMouseButtonDown: Bool { NSEvent.pressedMouseButtons == 1 }

@MainActor
func isManipulatedWithMouse(_ window: Window) async throws -> Bool {
    try await (!window.isHiddenInCorner && // Don't allow to resize/move windows of hidden workspaces
        isLeftMouseButtonDown &&
        (currentlyManipulatedWithMouseWindowId == nil || window.windowId == currentlyManipulatedWithMouseWindowId))
        .andAsync { @Sendable @MainActor in try await getNativeFocusedWindow(.cancellable) == window }
}

/// Same motivation as in monitorFrameNormalized
var mouseLocation: CGPoint { NSEvent.mouseLocation.withYAxisFlipped }
