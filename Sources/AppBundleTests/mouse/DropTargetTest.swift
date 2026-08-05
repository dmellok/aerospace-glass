@testable import AppBundle
import Common
import XCTest

@MainActor
final class DropTargetTest: XCTestCase {
    override func setUp() async throws { setUpWorkspacesForTests() }

    // MARK: - applyDrop

    func testApplyDrop_splitSameOrientation_insertsBesideTarget() {
        let root = Workspace.get(byName: name).rootTilingContainer
        let window1 = TestWindow.new(id: 1, parent: root)
        let window2 = TestWindow.new(id: 2, parent: root)
        TestWindow.new(id: 3, parent: root)

        applyDrop(.split(window2, .right), dragged: window1)

        assertEquals(root.layoutDescription, .h_tiles([.window(2), .window(1), .window(3)]))
    }

    func testApplyDrop_splitOppositeOrientation_wrapsTargetInNewSplit() {
        let root = Workspace.get(byName: name).rootTilingContainer
        let window1 = TestWindow.new(id: 1, parent: root)
        let window2 = TestWindow.new(id: 2, parent: root)

        applyDrop(.split(window2, .down), dragged: window1)

        assertEquals(root.layoutDescription, .h_tiles([.v_tiles([.window(2), .window(1)])]))
    }

    func testApplyDrop_splitUp_putsDraggedBeforeTarget() {
        let root = Workspace.get(byName: name).rootTilingContainer
        let window1 = TestWindow.new(id: 1, parent: root)
        let window2 = TestWindow.new(id: 2, parent: root)

        applyDrop(.split(window2, .up), dragged: window1)

        assertEquals(root.layoutDescription, .h_tiles([.v_tiles([.window(1), .window(2)])]))
    }

    func testApplyDrop_splitWholeTabGroup() {
        let root = Workspace.get(byName: name).rootTilingContainer
        let tabbed = TilingContainer(parent: root, adaptiveWeight: 1, .h, .tabbed, index: INDEX_BIND_LAST)
        TestWindow.new(id: 1, parent: tabbed)
        TestWindow.new(id: 2, parent: tabbed)
        let window3 = TestWindow.new(id: 3, parent: root)

        applyDrop(.split(tabbed, .down), dragged: window3)

        assertEquals(root.layoutDescription, .h_tiles([.v_tiles([.tabbed([.window(1), .window(2)]), .window(3)])]))
    }

    func testApplyDrop_splitRootTabGroup_growsNewRootAroundIt() {
        let workspace = Workspace.get(byName: name)
        check(workspace.focusWorkspace()) // Make it the monitor's active workspace for hit-testing
        let root = workspace.rootTilingContainer
        root.layout = .tabbed
        TestWindow.new(id: 1, parent: root)
        // A drag from another workspace: the dragged node stays bound there until the drop
        let otherWorkspace = Workspace.get(byName: name + "-other")
        let window2 = TestWindow.new(id: 2, parent: otherWorkspace.rootTilingContainer)

        applyDrop(.split(root, .right), dragged: window2)

        assertEquals(
            workspace.rootTilingContainer.layoutDescription,
            .h_tiles([.tabbed([.window(1)]), .window(2)]),
        )
    }

    func testApplyDrop_tabBarInsert() {
        let root = Workspace.get(byName: name).rootTilingContainer
        let tabbed = TilingContainer(parent: root, adaptiveWeight: 1, .h, .tabbed, index: INDEX_BIND_LAST)
        TestWindow.new(id: 1, parent: tabbed)
        TestWindow.new(id: 2, parent: tabbed)
        let window3 = TestWindow.new(id: 3, parent: root)

        applyDrop(.tabBar(group: tabbed, insertIndex: 1), dragged: window3)

        assertEquals(root.layoutDescription, .h_tiles([.tabbed([.window(1), .window(3), .window(2)])]))
    }

    func testApplyDrop_tabBarReorderWithinOwnGroup() {
        let root = Workspace.get(byName: name).rootTilingContainer
        let tabbed = TilingContainer(parent: root, adaptiveWeight: 1, .h, .tabbed, index: INDEX_BIND_LAST)
        let window1 = TestWindow.new(id: 1, parent: tabbed)
        TestWindow.new(id: 2, parent: tabbed)
        TestWindow.new(id: 3, parent: tabbed)

        // Dropping the first tab at the bar's right end: the vacated slot shifts the index by one
        applyDrop(.tabBar(group: tabbed, insertIndex: 3), dragged: window1)

        assertEquals(root.layoutDescription, .h_tiles([.tabbed([.window(2), .window(3), .window(1)])]))
    }

    func testApplyDrop_tabGroupBodyAppendsLast() {
        let root = Workspace.get(byName: name).rootTilingContainer
        let tabbed = TilingContainer(parent: root, adaptiveWeight: 1, .h, .tabbed, index: INDEX_BIND_LAST)
        TestWindow.new(id: 1, parent: tabbed)
        TestWindow.new(id: 2, parent: tabbed)
        let window3 = TestWindow.new(id: 3, parent: root)

        applyDrop(.tabGroup(tabbed), dragged: window3)

        assertEquals(root.layoutDescription, .h_tiles([.tabbed([.window(1), .window(2), .window(3)])]))
    }

    func testApplyDrop_swap() {
        let root = Workspace.get(byName: name).rootTilingContainer
        let window1 = TestWindow.new(id: 1, parent: root)
        TestWindow.new(id: 2, parent: root)
        let window3 = TestWindow.new(id: 3, parent: root)

        applyDrop(.swap(window3), dragged: window1)

        assertEquals(root.layoutDescription, .h_tiles([.window(3), .window(2), .window(1)]))
    }

    func testApplyDrop_newTabGroup_wrapsTargetAndDraggedInTabs() {
        let root = Workspace.get(byName: name).rootTilingContainer
        let window1 = TestWindow.new(id: 1, parent: root)
        TestWindow.new(id: 2, parent: root)
        let window3 = TestWindow.new(id: 3, parent: root)

        applyDrop(.newTabGroup(window3), dragged: window1)

        assertEquals(root.layoutDescription, .h_tiles([.window(2), .tabbed([.window(3), .window(1)])]))
    }

    func testApplyDrop_moveWholeGroupBesideAnotherWindow() {
        let root = Workspace.get(byName: name).rootTilingContainer
        let tabbed = TilingContainer(parent: root, adaptiveWeight: 1, .h, .tabbed, index: INDEX_BIND_LAST)
        TestWindow.new(id: 1, parent: tabbed)
        TestWindow.new(id: 2, parent: tabbed)
        let window3 = TestWindow.new(id: 3, parent: root)

        applyDrop(.split(window3, .down), dragged: tabbed)

        assertEquals(root.layoutDescription, .h_tiles([.v_tiles([.window(3), .tabbed([.window(1), .window(2)])])]))
    }

    func testApplyDrop_groupIntoItsOwnDescendant_isRefused() {
        let root = Workspace.get(byName: name).rootTilingContainer
        let outer = TilingContainer(parent: root, adaptiveWeight: 1, .h, .tabbed, index: INDEX_BIND_LAST)
        TestWindow.new(id: 1, parent: outer)
        let inner = TilingContainer(parent: outer, adaptiveWeight: 1, .h, .tabbed, index: INDEX_BIND_LAST)
        TestWindow.new(id: 2, parent: inner)

        applyDrop(.tabBar(group: inner, insertIndex: 0), dragged: outer)
        applyDrop(.tabGroup(inner), dragged: outer)

        assertEquals(root.layoutDescription, .h_tiles([.tabbed([.window(1), .tabbed([.window(2)])])]))
    }

    // MARK: - move --tab-group

    func testMoveTabGroup_movesWholeGroup() async {
        let root = Workspace.get(byName: name).rootTilingContainer
        let tabbed = TilingContainer(parent: root, adaptiveWeight: 1, .h, .tabbed, index: INDEX_BIND_LAST)
        assertEquals(TestWindow.new(id: 1, parent: tabbed).focusWindow(), true)
        TestWindow.new(id: 2, parent: tabbed)
        TestWindow.new(id: 3, parent: root)

        await parseCommand("move --tab-group right").cmdOrDie.run(.defaultEnv, .emptyStdin)

        assertEquals(root.layoutDescription, .h_tiles([.window(3), .tabbed([.window(1), .window(2)])]))
    }

    func testMoveTabGroup_outsideAGroup_movesJustTheWindow() async {
        let root = Workspace.get(byName: name).rootTilingContainer
        assertEquals(TestWindow.new(id: 1, parent: root).focusWindow(), true)
        TestWindow.new(id: 2, parent: root)

        await parseCommand("move --tab-group right").cmdOrDie.run(.defaultEnv, .emptyStdin)

        assertEquals(root.layoutDescription, .h_tiles([.window(2), .window(1)]))
    }

    // MARK: - resolveDropTarget

    func testResolve_centerOfAnotherWindow_isSwap() async throws {
        let workspace = Workspace.get(byName: name)
        check(workspace.focusWorkspace()) // Make it the monitor's active workspace for hit-testing
        let root = workspace.rootTilingContainer
        let window1 = TestWindow.new(id: 1, parent: root)
        let window2 = TestWindow.new(id: 2, parent: root)
        try await workspace.layoutWorkspace()

        let center = try XCTUnwrap(window2.lastAppliedLayoutPhysicalRect).center
        guard case .swap(let target)? = resolveDropTarget(center, dragged: window1) else {
            return XCTFail("expected .swap")
        }
        assertEquals(target.windowId, 2)
    }

    func testResolve_edgeOfAnotherWindow_isSplit() async throws {
        let workspace = Workspace.get(byName: name)
        check(workspace.focusWorkspace()) // Make it the monitor's active workspace for hit-testing
        let root = workspace.rootTilingContainer
        let window1 = TestWindow.new(id: 1, parent: root)
        let window2 = TestWindow.new(id: 2, parent: root)
        try await workspace.layoutWorkspace()

        let rect = try XCTUnwrap(window2.lastAppliedLayoutPhysicalRect)
        let nearBottom = CGPoint(x: rect.center.x, y: rect.maxY - rect.height * 0.05)
        guard case .split(let cell, .down)? = resolveDropTarget(nearBottom, dragged: window1) else {
            return XCTFail("expected .split(_, .down)")
        }
        assertEquals((cell as? Window)?.windowId, 2)
    }

    func testResolve_ownCell_isNil() async throws {
        let workspace = Workspace.get(byName: name)
        check(workspace.focusWorkspace()) // Make it the monitor's active workspace for hit-testing
        let root = workspace.rootTilingContainer
        let window1 = TestWindow.new(id: 1, parent: root)
        TestWindow.new(id: 2, parent: root)
        try await workspace.layoutWorkspace()

        let center = try XCTUnwrap(window1.lastAppliedLayoutPhysicalRect).center
        assertNil(resolveDropTarget(center, dragged: window1))
    }

    func testResolve_tabBarStrip_isTabBarInsert() async throws {
        let workspace = Workspace.get(byName: name)
        check(workspace.focusWorkspace()) // Make it the monitor's active workspace for hit-testing
        let root = workspace.rootTilingContainer
        let tabbed = TilingContainer(parent: root, adaptiveWeight: 1, .h, .tabbed, index: INDEX_BIND_LAST)
        TestWindow.new(id: 1, parent: tabbed)
        TestWindow.new(id: 2, parent: tabbed)
        let window3 = TestWindow.new(id: 3, parent: root)
        try await workspace.layoutWorkspace()

        let bar = try XCTUnwrap(tabbed.lastAppliedTabBarRect)
        let barEnd = CGPoint(x: bar.maxX - 1, y: bar.center.y)
        guard case .tabBar(let group, let index)? = resolveDropTarget(barEnd, dragged: window3) else {
            return XCTFail("expected .tabBar")
        }
        assertEquals(group, tabbed)
        assertEquals(index, 2)
    }

    func testResolve_tabGroupBody_isTabGroup() async throws {
        let workspace = Workspace.get(byName: name)
        check(workspace.focusWorkspace()) // Make it the monitor's active workspace for hit-testing
        let root = workspace.rootTilingContainer
        let tabbed = TilingContainer(parent: root, adaptiveWeight: 1, .h, .tabbed, index: INDEX_BIND_LAST)
        TestWindow.new(id: 1, parent: tabbed)
        TestWindow.new(id: 2, parent: tabbed)
        let window3 = TestWindow.new(id: 3, parent: root)
        try await workspace.layoutWorkspace()

        let center = try XCTUnwrap(tabbed.lastAppliedLayoutPhysicalRect).center
        guard case .tabGroup(let group)? = resolveDropTarget(center, dragged: window3) else {
            return XCTFail("expected .tabGroup")
        }
        assertEquals(group, tabbed)
    }

    func testResolve_topEdgeOfWorkspace_offersNewTabGroup() async throws {
        let workspace = Workspace.get(byName: name)
        check(workspace.focusWorkspace()) // Make it the monitor's active workspace for hit-testing
        let root = workspace.rootTilingContainer
        let window1 = TestWindow.new(id: 1, parent: root)
        let window2 = TestWindow.new(id: 2, parent: root)
        try await workspace.layoutWorkspace()

        let rect = try XCTUnwrap(window2.lastAppliedLayoutPhysicalRect)
        let topEdge = CGPoint(x: rect.center.x, y: rect.minY + 1)
        guard case .newTabGroup(let target)? = resolveDropTarget(topEdge, dragged: window1) else {
            return XCTFail("expected .newTabGroup")
        }
        assertEquals(target.windowId, 2)
    }

    func testResolve_topEdgeOverOwnCell_isNil() async throws {
        let workspace = Workspace.get(byName: name)
        check(workspace.focusWorkspace()) // Make it the monitor's active workspace for hit-testing
        let root = workspace.rootTilingContainer
        let window1 = TestWindow.new(id: 1, parent: root)
        TestWindow.new(id: 2, parent: root)
        try await workspace.layoutWorkspace()

        let rect = try XCTUnwrap(window1.lastAppliedLayoutPhysicalRect)
        assertNil(resolveDropTarget(CGPoint(x: rect.center.x, y: rect.minY + 1), dragged: window1))
    }

    func testResolve_groupDragOverItsOwnBar_isNil() async throws {
        let workspace = Workspace.get(byName: name)
        check(workspace.focusWorkspace()) // Make it the monitor's active workspace for hit-testing
        let root = workspace.rootTilingContainer
        let tabbed = TilingContainer(parent: root, adaptiveWeight: 1, .h, .tabbed, index: INDEX_BIND_LAST)
        TestWindow.new(id: 1, parent: tabbed)
        TestWindow.new(id: 2, parent: tabbed)
        TestWindow.new(id: 3, parent: root)
        try await workspace.layoutWorkspace()

        // A plain middle-click: releasing over the group's own bar must be a no-op
        let bar = try XCTUnwrap(tabbed.lastAppliedTabBarRect)
        assertNil(resolveDropTarget(bar.center, dragged: tabbed))
    }

    func testResolve_gapBetweenWindows_resolvesToNearestCell() async throws {
        config.gaps.inner.horizontal = .constant(20)
        let workspace = Workspace.get(byName: name)
        check(workspace.focusWorkspace()) // Make it the monitor's active workspace for hit-testing
        let root = workspace.rootTilingContainer
        let window1 = TestWindow.new(id: 1, parent: root)
        let window2 = TestWindow.new(id: 2, parent: root)
        try await workspace.layoutWorkspace()

        // Just inside the inner gap, on window2's side of it
        let rect2 = try XCTUnwrap(window2.lastAppliedLayoutPhysicalRect)
        let inGap = CGPoint(x: rect2.minX - 2, y: rect2.center.y)
        guard case .split(let cell, .left)? = resolveDropTarget(inGap, dragged: window1) else {
            return XCTFail("expected .split(_, .left)")
        }
        assertEquals((cell as? Window)?.windowId, 2)
    }
}
