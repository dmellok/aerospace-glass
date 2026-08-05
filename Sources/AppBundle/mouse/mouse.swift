import AppKit

@MainActor var currentlyManipulatedWithMouseWindowId: UInt32? = nil
/// Where releasing the currently dragged tiling window would put it. Refreshed on every drag tick
/// by ``moveWithMouse``, consumed on mouse-up by ``resetManipulatedWithMouseIfPossible``.
@MainActor var pendingDropTarget: DropTarget? = nil
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
