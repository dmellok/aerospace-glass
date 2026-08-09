import AppKit
import Common

/// Where a drag would land if the mouse were released right now.
///
/// Both drag flavors funnel through this one model: windows dragged by their title bar
/// (``moveWithMouse``) and tabs dragged out of a glass tab bar. ``resolveDropTarget`` turns a mouse
/// location into a target, ``GlassDropPreviewController`` renders it, and ``applyDrop`` performs the
/// tree mutation on mouse-up. Resolution never mutates the tree, so it is safe to run on every drag
/// tick.
enum DropTarget {
    /// Over the tab bar strip of a `tabbed` container: insert as a tab at `insertIndex`.
    /// When the dragged node is already a tab of this group, this is a reorder.
    case tabBar(group: TilingContainer, insertIndex: Int)
    /// Over the body of a `tabbed` container: join the group as its last tab.
    case tabGroup(TilingContainer)
    /// In the tab zone at the top of the workspace, over a cell that has no tab group yet:
    /// wrap that window in a new `tabbed` container and join it as the second tab.
    case newTabGroup(Window)
    /// Near an edge of a cell: split that cell, placing the dragged node on the `edge` side.
    /// The target is a window, or a whole `tabbed` container (its tabs move together).
    case split(TreeNode, CardinalDirection)
    /// Over the center of a plain tile: exchange places with it.
    case swap(Window)
    /// Over a workspace with no tiled windows at all.
    case emptyWorkspace(Workspace)
}

/// The portion of a cell (per axis) that counts as its center. Outside the band the drop becomes a
/// split on the nearest edge.
private let centerBand: ClosedRange<Double> = 0.3 ... 0.7

@MainActor
func resolveDropTarget(_ point: CGPoint, dragged: TreeNode) -> DropTarget? {
    let workspace = point.monitorApproximation.activeWorkspace
    let root = workspace.rootTilingContainer
    if root.isEffectivelyEmpty {
        // No cell to land in. Still meaningful when the drag comes from elsewhere (another
        // workspace, or a tab group that stays behind on this workspace? impossible - then the
        // workspace wouldn't be empty)
        return dragged.nodeWorkspace == workspace ? nil : .emptyWorkspace(workspace)
    }
    if let barTarget = resolveTabBarTarget(point, in: root, dragged: dragged) {
        return barTarget
    }
    guard let cell = findDropCell(point, in: root) else { return nil }
    // Dropping a node onto its own subtree is meaningless
    if cell.parentsWithSelf.contains(dragged) { return nil }
    guard let rect = cell.lastAppliedLayoutVirtualRect ?? cell.lastAppliedLayoutPhysicalRect,
          rect.width > 0, rect.height > 0 else { return nil }
    // The tab zone: a band one bar tall along the top edge of every cell, wherever that cell sits
    // on the screen. Dropping there tabs the dragged window with the cell, creating the group if
    // there is none yet — an existing group's own bar was already hit-tested above. Skipped for
    // cells too short to draw a bar, the same threshold the layout pass uses.
    let barStrip = CGFloat(config.glass.tabs.height) + CGFloat(config.glass.tabs.spacing)
    if config.glass.tabs.enabled,
       rect.height > barStrip * 2,
       point.y < rect.minY + CGFloat(config.glass.tabs.height)
    {
        switch cell.tilingTreeNodeCasesOrDie() {
            case .tilingContainer(let group):
                if dragged.parent !== group { return .tabGroup(group) }
            case .window(let window):
                if window != dragged { return .newTabGroup(window) }
        }
        return nil
    }

    let u = (point.x - rect.minX) / rect.width
    let v = (point.y - rect.minY) / rect.height
    if centerBand.contains(u) && centerBand.contains(v) {
        switch cell.tilingTreeNodeCasesOrDie() {
            case .tilingContainer(let group): // Only tabbed containers are returned as cells
                return dragged.parent === group ? nil : .tabGroup(group)
            case .window(let window):
                return window == dragged ? nil : .swap(window)
        }
    }
    // The nearest edge in normalized coordinates, so a wide flat cell still offers its left and
    // right zones at a reachable size
    let edge: CardinalDirection = [(u, CardinalDirection.left), (1 - u, .right), (v, .up), (1 - v, .down)]
        .minByOrDie { $0.0 }.1
    return .split(cell, edge)
}

/// The topmost cell under `point`: a window, or a whole `tabbed` container. Points in gaps resolve
/// to the nearest sibling, so every point of a non-empty workspace lands somewhere.
@MainActor
private func findDropCell(_ point: CGPoint, in container: TilingContainer) -> TreeNode? {
    switch container.layout {
        case .tabbed:
            return container // The group is one cell; its tabs travel together
        case .accordion:
            guard let child = container.mostRecentChild else { return nil }
            return childOrRecurse(point, child)
        case .tiles:
            let child = container.children.first(where: {
                ($0.lastAppliedLayoutVirtualRect ?? $0.lastAppliedLayoutPhysicalRect)?.contains(point) == true
            }) ?? container.children.minBy { (child: TreeNode) -> Double in
                guard let rect = child.lastAppliedLayoutVirtualRect ?? child.lastAppliedLayoutPhysicalRect else { return .infinity }
                return abs(rect.center.getProjection(container.orientation) - point.getProjection(container.orientation))
            }
            guard let child else { return nil }
            return childOrRecurse(point, child)
    }
}

@MainActor
private func childOrRecurse(_ point: CGPoint, _ child: TreeNode) -> TreeNode? {
    switch child.tilingTreeNodeCasesOrDie() {
        case .window(let window): window
        case .tilingContainer(let container): findDropCell(point, in: container)
    }
}

/// Hit-test the reserved tab bar strips. Checked before cell resolution because the strip is carved
/// out of its container's rect.
@MainActor
private func resolveTabBarTarget(_ point: CGPoint, in container: TilingContainer, dragged: TreeNode) -> DropTarget? {
    // A bar inside the dragged subtree is not a target: binding a node into its own descendant
    // would tie the tree into a cycle
    if container.parentsWithSelf.contains(dragged) { return nil }
    if container.layout == .tabbed, let bar = container.lastAppliedTabBarRect, bar.contains(point) {
        let count = container.children.count
        guard count > 0, bar.width > 0 else { return nil }
        let layout = GlassTabLayout(barMinX: bar.minX, barWidth: bar.width, count: count)
        return .tabBar(group: container, insertIndex: layout.insertIndex(atX: point.x))
    }
    // Descend only into visible children: in a stacking container the hidden children overlap the
    // visible one, and a hidden nested group's bar must not swallow the drop meant for what's on top
    let visibleChildren = container.layout.isStacking
        ? [container.mostRecentChild].compactMap { $0 }
        : container.children
    for child in visibleChildren {
        if let childContainer = child as? TilingContainer,
           let hit = resolveTabBarTarget(point, in: childContainer, dragged: dragged)
        {
            return hit
        }
    }
    return nil
}

// MARK: - Applying

/// Perform the mutation a ``DropTarget`` describes. Runs at mouse-up, possibly a few events after
/// the target was resolved, so every referenced node is re-checked for still being in the tree.
@MainActor
func applyDrop(_ target: DropTarget, dragged: TreeNode) {
    guard dragged.isBound else { return }
    switch target {
        case .tabBar(let group, let insertIndex):
            // The subtree check matters for whole-group drags: binding a group into a descendant
            // would tie the tree into a cycle
            guard group.isBound, group.layout == .tabbed, !group.parentsWithSelf.contains(dragged) else { return }
            var index = insertIndex
            if dragged.parent === group, let ownIndex = dragged.ownIndex {
                if index > ownIndex { index -= 1 } // The gap the dragged tab leaves behind
            }
            let upperBound = group.children.count - (dragged.parent === group ? 1 : 0)
            dragged.bind(to: group, adaptiveWeight: WEIGHT_AUTO, index: min(max(index, 0), max(upperBound, 0)))
        case .tabGroup(let group):
            guard group.isBound, group.layout == .tabbed, dragged.parent !== group,
                  !group.parentsWithSelf.contains(dragged) else { return }
            dragged.bind(to: group, adaptiveWeight: WEIGHT_AUTO, index: INDEX_BIND_LAST)
        case .newTabGroup(let window):
            guard window.isBound, window != dragged, !window.parentsWithSelf.contains(dragged),
                  let parent = window.parent as? TilingContainer else { return }
            dragged.unbindFromParent()
            let binding = window.unbindFromParent()
            let group = TilingContainer(parent: parent, adaptiveWeight: binding.adaptiveWeight, .h, .tabbed, index: binding.index)
            window.bind(to: group, adaptiveWeight: WEIGHT_AUTO, index: 0)
            dragged.bind(to: group, adaptiveWeight: WEIGHT_AUTO, index: 1)
        case .swap(let window):
            guard window.isBound, window != dragged else { return }
            swapTreeNodes(dragged, window)
        case .split(let cell, let edge):
            guard cell.isBound, cell != dragged, !cell.parentsWithSelf.contains(dragged) else { return }
            insertBeside(cell, dragged: dragged, edge: edge)
        case .emptyWorkspace(let workspace):
            dragged.bind(to: workspace.rootTilingContainer, adaptiveWeight: WEIGHT_AUTO, index: INDEX_BIND_LAST)
    }
}

/// Place `dragged` on the `edge` side of `cell`, joining the parent split when its orientation
/// already runs that way and otherwise wrapping the cell in a new one — the same tree shapes the
/// `move` command produces, driven by geometry instead of a direction key.
@MainActor
private func insertBeside(_ cell: TreeNode, dragged: TreeNode, edge: CardinalDirection) {
    // Unbind first: if the two share a parent, the indices captured below stay valid
    dragged.unbindFromParent()
    switch cell.parent?.cases {
        case .tilingContainer(let parent) where parent.orientation == edge.orientation && parent.layout != .tabbed:
            guard let cellIndex = cell.ownIndex else { return }
            dragged.bind(to: parent, adaptiveWeight: WEIGHT_AUTO, index: cellIndex + edge.insertionOffset)
        case .tilingContainer(let parent):
            let binding = cell.unbindFromParent()
            let wrap = TilingContainer(parent: parent, adaptiveWeight: binding.adaptiveWeight, edge.orientation, .tiles, index: binding.index)
            cell.bind(to: wrap, adaptiveWeight: WEIGHT_AUTO, index: 0)
            dragged.bind(to: wrap, adaptiveWeight: WEIGHT_AUTO, index: edge.insertionOffset)
        case .workspace(let workspace):
            // The cell is the root container itself (a tab group filling the workspace):
            // grow a new root split around it
            cell.unbindFromParent()
            let newRoot = TilingContainer(parent: workspace, adaptiveWeight: 1, edge.orientation, .tiles, index: 0)
            cell.bind(to: newRoot, adaptiveWeight: WEIGHT_AUTO, index: 0)
            dragged.bind(to: newRoot, adaptiveWeight: WEIGHT_AUTO, index: edge.insertionOffset)
        default:
            // The cell left the tree between resolution and mouse-up. Put the window back where
            // it can always go rather than leaving it unbound
            if let workspace = cell.nodeWorkspace ?? dragged.nodeWorkspace {
                dragged.bind(to: workspace.rootTilingContainer, adaptiveWeight: WEIGHT_AUTO, index: INDEX_BIND_LAST)
            }
    }
}

/// ``swapWindows(mruDominant:_:)`` generalized to whole subtrees, so a tab dragged onto a tile can
/// trade places with it even when the tab is a nested container.
@MainActor
func swapTreeNodes(_ node1: TreeNode, _ node2: TreeNode) {
    if node1 == node2 { return }
    let binding2 = node2.unbindFromParent()
    let binding1 = node1.unbindFromParent()
    node2.bind(to: binding1.parent, adaptiveWeight: binding1.adaptiveWeight, index: binding1.index)
    node1.bind(to: binding2.parent, adaptiveWeight: binding2.adaptiveWeight, index: binding2.index)
}
