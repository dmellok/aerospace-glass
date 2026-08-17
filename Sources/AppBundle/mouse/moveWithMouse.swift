import AppKit
import Common

@MainActor
private var moveWithMouseTask: Task<(), any Error>? = nil

func movedObs(_: AXObserver, ax: AXUIElement, notif: CFString, _: UnsafeMutableRawPointer?) {
    let windowId = ax.containingWindowId()
    let notif = notif as String
    Task.startUnstructured { @MainActor in
        guard let token: RunSessionGuard = .isServerEnabled else { return }
        // A glass handle drag is already moving these windows deliberately; treating its output as
        // a user dragging a window edge would have two controllers writing the same weights. The
        // button check keeps a stale flag from disabling mouse manipulation for good: no drag can
        // be in progress once the button is up, whatever the flag says.
        if isDraggingGlassHandle && isLeftMouseButtonDown { return }
        guard let windowId, let window = Window.get(byId: windowId), try await isManipulatedWithMouse(window) else {
            scheduleCancellableCompleteRefreshSession(.ax(notif))
            return
        }
        moveWithMouseTask?.cancel()
        moveWithMouseTask = Task.startUnstructured {
            try checkCancellation()
            try await runLightSession(.ax(notif), token) {
                try await moveWithMouse(window)
            }
        }
    }
}

@MainActor
private func moveWithMouse(_ window: Window) async throws { // todo cover with tests
    resetClosedWindowsCache()
    switch window.windowParentCases {
        case .floatingWindowsContainer:
            try await moveFloatingWindow(window)
        case .macosFullscreenWindowsContainer, .macosMinimizedWindowsContainer, .macosPopupWindowsContainer, .macosHiddenAppsWindowsContainer:
            return // Unconventional windows can't be moved with mouse
        case .tilingContainer:
            try await moveTilingWindow(window)
        case .unbound: return
    }
}

@MainActor
private func moveFloatingWindow(_ window: Window) async throws {
    guard let targetWorkspace = try await window.getCenter(.cancellable)?.monitorApproximation.activeWorkspace else { return }
    guard let parent = window.parent else { return }
    if targetWorkspace != parent {
        window.bindAsFloatingWindow(to: targetWorkspace)
    }
}

/// A dragged tiling window no longer rearranges the tree while the mouse moves. Each tick only
/// resolves where a release would put it and renders that as the glass drop preview; the mutation
/// itself happens on mouse-up in ``resetManipulatedWithMouseIfPossible``. This is what lets a drop
/// join a tab group or slot into a split instead of merely swapping with whatever is underneath.
///
/// Ticks arrive for left/top-edge resizes too (they change the origin), so nothing destructive
/// happens until the drag is confirmed as a move: the mouse traveled while the size stayed put.
@MainActor
private func moveTilingWindow(_ window: Window) async throws {
    currentlyManipulatedWithMouseWindowId = window.windowId
    if currentMouseDragKind == .resize { return } // The resize path owns this drag
    let mouse = mouseLocation
    guard let rect = try await window.getAxRect(.cancellable) else { return }
    if mouseDragInitial?.windowId != window.windowId {
        mouseDragInitial = (window.windowId, rect.width, rect.height, mouse)
    }
    guard let initial = mouseDragInitial else { return }
    if currentMouseDragKind == nil {
        if abs(rect.width - initial.width) > 5 || abs(rect.height - initial.height) > 5 {
            currentMouseDragKind = .resize
            return
        }
        if CGPoint(x: mouse.x - initial.mouse.x, y: mouse.y - initial.mouse.y).vectorLength > 10 {
            currentMouseDragKind = .move
        } else {
            return // Too early to tell a title-bar drag from an edge resize
        }
    }
    // Confirmed move. Only now is the layout rect dropped — the resize path needs it intact
    window.lastAppliedLayoutPhysicalRect = nil
    let target = resolveDropTarget(mouse, dragged: window)
    pendingDropTarget = target
    GlassDropPreviewController.shared.update(point: mouse, target: target)
}

@MainActor
func swapWindows(mruDominant window1: Window, _ window2: Window) {
    swapTreeNodes(window1, window2)
}

extension CGPoint {
    @MainActor
    func findWindowRecursively(
        in tree: TilingContainer,
        virtual: Bool,
        fullscreenCoversAll: Bool,
    ) -> Window? {
        if fullscreenCoversAll {
            if let window = tree.mostRecentWindowRecursive, window.isFullscreen {
                return window
            }
        }
        return _findWindowRecursively(in: tree, virtual: virtual)
    }

    @MainActor
    private func _findWindowRecursively(in tree: TilingContainer, virtual: Bool) -> Window? {
        let point = self
        let target: TreeNode? = switch tree.layout {
            case .tiles:
                tree.children.first(where: {
                    (virtual ? $0.lastAppliedLayoutVirtualRect : $0.lastAppliedLayoutPhysicalRect)?.contains(point) == true
                })
            case .accordion, .tabbed:
                tree.mostRecentChild
        }
        guard let target else { return nil }
        return switch target.tilingTreeNodeCasesOrDie() {
            case .window(let window): window
            case .tilingContainer(let container): _findWindowRecursively(in: container, virtual: virtual)
        }
    }
}
