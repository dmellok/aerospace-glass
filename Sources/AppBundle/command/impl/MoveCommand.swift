import AppKit
import Common

struct MoveCommand: Command {
    let args: MoveCmdArgs
    /*conforms*/ let shouldResetClosedWindowsCache = true

    func run(_ env: CmdEnv, _ io: CmdIo) async -> BinaryExitCode {
        let direction = args.direction.val
        guard let target = args.resolveTargetOrReportError(env, io) else { return .fail }
        guard let currentWindow = target.windowOrNil else {
            return .fail(io.err(noWindowIsFocused))
        }
        if await shouldFailBecauseFullscreen_nonCancellable(
            window: currentWindow,
            failIfFullscreen: args.failIfFullscreen,
            failIfMacosNativeFullscreen: args.failIfMacosNativeFullscreen,
        ) {
            return .fail
        }
        // What actually moves: the window, or - with --tab-group - the whole tabbed group around
        // it. Falls back to the window alone when it is not inside a tab group.
        let movingNode: TreeNode = args.wholeTabGroup
            ? currentWindow.parents.filterIsInstance(of: TilingContainer.self).first(where: { $0.layout == .tabbed }) ?? currentWindow
            : currentWindow

        // A tab group that is the root container has no siblings to move among: the only move
        // that means anything is to the monitor in that direction
        if movingNode.parent is Workspace {
            return moveNodeToMonitor(movingNode, focusedWindow: currentWindow, direction: direction, io, args, env)
        }
        switch (movingNode as? Window)?.windowParentCases {
            case .unbound: return .fail
            case .floatingWindowsContainer: // floating window
                return await moveFloating(window: currentWindow, direction: direction, io)
            case .macosMinimizedWindowsContainer, .macosFullscreenWindowsContainer, .macosHiddenAppsWindowsContainer:
                return .fail(io.err(moveOutMacosUnconventionalWindow))
            case .macosPopupWindowsContainer:
                return .fail(io.err(bugPrompt())) // Impossible
            case .tilingContainer, nil: // nil: movingNode is a tab group, whose parent is always a tiling container here
                guard let parent = movingNode.parent as? TilingContainer else { return .fail(io.err(bugPrompt())) }
                guard let indexOfCurrent = movingNode.ownIndex else { return .fail(io.err(bugPrompt())) }
                let indexOfSiblingTarget = indexOfCurrent + direction.focusOffset
                if parent.orientation == direction.orientation && parent.children.indices.contains(indexOfSiblingTarget) {
                    switch parent.children[indexOfSiblingTarget].tilingTreeNodeCasesOrDie() {
                        case .tilingContainer(let topLevelSiblingTargetContainer):
                            return deepMoveIn(node: movingNode, into: topLevelSiblingTargetContainer, moveDirection: direction, io)
                        case .window: // "swap windows"
                            let prevBinding = movingNode.unbindFromParent()
                            movingNode.bind(to: parent, adaptiveWeight: prevBinding.adaptiveWeight, index: indexOfSiblingTarget)
                            return .succ
                    }
                } else {
                    return moveOut(node: movingNode, focusedWindow: currentWindow, direction: direction, io, args, env)
                }
        }
    }
}

/// How far one `move` nudges a floating window, in points. i3 moves floating windows by a fixed
/// step per key press instead of rearranging the tree; 10px there assumes key repeat, 30pt here
/// makes each press count.
private let floatingMoveStep: CGFloat = 30

@MainActor private func moveFloating(window: Window, direction: CardinalDirection, _ io: CmdIo) async -> BinaryExitCode {
    guard let rect = try? await window.getAxRect(.cancellable) else {
        return .fail(io.err("Can't read the window frame"))
    }
    let (dx, dy): (CGFloat, CGFloat) = switch direction {
        case .left: (-floatingMoveStep, 0)
        case .right: (floatingMoveStep, 0)
        case .up: (0, -floatingMoveStep)
        case .down: (0, floatingMoveStep)
    }
    window.setAxFrame(CGPoint(x: rect.topLeftX + dx, y: rect.topLeftY + dy), nil)
    return .succ
}

@MainActor private func hitWorkspaceBoundaries(
    _ node: TreeNode,
    focusedWindow: Window,
    _ workspace: Workspace,
    _ io: CmdIo,
    _ args: MoveCmdArgs,
    _ direction: CardinalDirection,
    _ env: CmdEnv,
) -> BinaryExitCode {
    switch args.boundaries {
        case .workspace:
            switch args.boundariesAction {
                case .stop: return .succ
                case .fail: return .fail
                case .createImplicitContainer:
                    createImplicitContainerAndMoveNode(node, workspace, direction)
                    return .succ
            }
        case .allMonitorsOuterFrame:
            guard let (monitors, index) = node.nodeMonitor?.findRelativeMonitor(inDirection: direction) else {
                return .fail(io.err("Should never happen. Can't find the current monitor"))
            }

            if monitors.indices.contains(index) {
                if let window = node as? Window {
                    let moveNodeToMonitorArgs = MoveNodeToMonitorCmdArgs(target: .direction(direction))
                        .copy(\.windowId, window.windowId)
                        .copy(\.focusFollowsWindow, focus.windowOrNil == window)

                    return MoveNodeToMonitorCommand(args: moveNodeToMonitorArgs).run(env, io)
                }
                // A whole tab group: no window id to hand to move-node-to-monitor, move it directly
                let targetWorkspace = monitors[index].activeWorkspace
                node.bind(to: targetWorkspace.rootTilingContainer, adaptiveWeight: WEIGHT_AUTO, index: INDEX_BIND_LAST)
                _ = focusedWindow.focusWindow()
                return .succ
            } else {
                return hitAllMonitorsOuterFrameBoundaries(node, workspace, args, direction)
            }
    }
}

@MainActor private func hitAllMonitorsOuterFrameBoundaries(
    _ node: TreeNode,
    _ workspace: Workspace,
    _ args: MoveCmdArgs,
    _ direction: CardinalDirection,
) -> BinaryExitCode {
    switch args.boundariesAction {
        case .stop: return .succ
        case .fail: return .fail
        case .createImplicitContainer:
            createImplicitContainerAndMoveNode(node, workspace, direction)
            return .succ
    }
}

/// Whole-group move for a group that is the workspace's root container: the only in-tree "beside"
/// is another monitor's workspace.
@MainActor private func moveNodeToMonitor(
    _ node: TreeNode,
    focusedWindow: Window,
    direction: CardinalDirection,
    _ io: CmdIo,
    _ args: MoveCmdArgs,
    _ env: CmdEnv,
) -> BinaryExitCode {
    guard let (monitors, index) = node.nodeMonitor?.findRelativeMonitor(inDirection: direction) else {
        return .fail(io.err("Should never happen. Can't find the current monitor"))
    }
    guard monitors.indices.contains(index) else {
        return args.boundariesAction == .fail ? .fail : .succ
    }
    let targetWorkspace = monitors[index].activeWorkspace
    node.bind(to: targetWorkspace.rootTilingContainer, adaptiveWeight: WEIGHT_AUTO, index: INDEX_BIND_LAST)
    _ = focusedWindow.focusWindow()
    return .succ
}

private let moveOutMacosUnconventionalWindow = "moving macOS fullscreen, minimized windows and windows of hidden apps isn't yet supported. This behavior is subject to change"

@MainActor private func moveOut(
    node: TreeNode,
    focusedWindow: Window,
    direction: CardinalDirection,
    _ io: CmdIo,
    _ args: MoveCmdArgs,
    _ env: CmdEnv,
) -> BinaryExitCode {
    let innerMostTilingContainer = node.parents.first(where: {
        return switch $0.parent?.cases {
            case .tilingContainer(let parent): parent.orientation == direction.orientation
            // Stop searching: we have hit the workspace
            case nil, .workspace: true
            // Impossible: tilingContainer's parent can only be a workspace or tilingContainer
            case .floatingWindowsContainer,
                 .macosMinimizedWindowsContainer,
                 .macosFullscreenWindowsContainer,
                 .macosHiddenAppsWindowsContainer,
                 .macosPopupWindowsContainer: true
        }
    }) as? TilingContainer
    guard let innerMostTilingContainer else { return .fail(io.err(bugPrompt())) } // Impossible
    switch innerMostTilingContainer.tilingContainerParentCases {
        case .unbound: return .fail
        case .tilingContainer(let parent):
            check(parent.orientation == direction.orientation)
            guard let ownIndex = innerMostTilingContainer.ownIndex else { return .fail(io.err(bugPrompt())) }
            node.bind(to: parent, adaptiveWeight: WEIGHT_AUTO, index: ownIndex + direction.insertionOffset)
            return .succ
        case .workspace(let parent):
            return hitWorkspaceBoundaries(node, focusedWindow: focusedWindow, parent, io, args, direction, env)
    }
}

@MainActor private func createImplicitContainerAndMoveNode(
    _ node: TreeNode,
    _ workspace: Workspace,
    _ direction: CardinalDirection,
) {
    let prevRoot = workspace.rootTilingContainer
    prevRoot.unbindFromParent()
    // Force tiles layout
    _ = TilingContainer(parent: workspace, adaptiveWeight: WEIGHT_AUTO, direction.orientation, .tiles, index: 0)
    check(prevRoot != workspace.rootTilingContainer)
    prevRoot.bind(to: workspace.rootTilingContainer, adaptiveWeight: WEIGHT_AUTO, index: 0)
    node.bind(to: workspace.rootTilingContainer, adaptiveWeight: WEIGHT_AUTO, index: direction.insertionOffset)
}

@MainActor private func deepMoveIn(node: TreeNode, into container: TilingContainer, moveDirection: CardinalDirection, _ io: CmdIo) -> BinaryExitCode {
    let deepTarget = container.tilingTreeNodeCasesOrDie().findDeepMoveInTargetRecursive(moveDirection.orientation)
    switch deepTarget {
        case .tilingContainer(let deepTarget):
            node.bind(to: deepTarget, adaptiveWeight: WEIGHT_AUTO, index: 0)
        case .window(let deepTarget):
            guard let parent = deepTarget.parent as? TilingContainer else { return .fail(io.err(bugPrompt())) }
            guard let deepTargetIndex = deepTarget.ownIndex else { return .fail(io.err(bugPrompt())) }
            node.bind(to: parent, adaptiveWeight: WEIGHT_AUTO, index: deepTargetIndex + 1)
    }
    return .succ
}

extension TilingTreeNodeCases {
    @MainActor fileprivate func findDeepMoveInTargetRecursive(_ orientation: Orientation) -> TilingTreeNodeCases {
        switch self {
            case .window:
                self
            // A tabbed container is a terminal target: a window moved into it becomes a new tab
            // rather than descending into whatever the visible tab currently holds.
            case .tilingContainer(let container) where container.layout == .tabbed:
                .tilingContainer(container)
            case .tilingContainer(let container) where container.orientation == orientation:
                .tilingContainer(container)
            case .tilingContainer(let container):
                container.mostRecentChild.orDie("Empty containers must be detached during normalization")
                    .tilingTreeNodeCasesOrDie()
                    .findDeepMoveInTargetRecursive(orientation)
        }
    }
}

func shouldFailBecauseFullscreen_nonCancellable(
    window: Window,
    failIfFullscreen: Bool,
    failIfMacosNativeFullscreen: Bool,
) async -> Bool {
    if failIfFullscreen && window.isFullscreen {
        return true
    }
    if failIfMacosNativeFullscreen {
        if true == (try? await window.isMacosFullscreen(.nonCancellable)) {
            return true
        }
    }
    return false
}
