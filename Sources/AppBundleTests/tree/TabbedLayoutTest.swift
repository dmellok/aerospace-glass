@testable import AppBundle
import Common
import XCTest

@MainActor
final class TabbedLayoutTest: XCTestCase {
    override func setUp() async throws { setUpWorkspacesForTests() }

    /// Every tab occupies the whole container, so all of them must be resized when the container
    /// changes size — not just the one currently on top.
    func testEveryTabIsResized_notJustTheVisibleOne() async throws {
        let workspace = Workspace.get(byName: name)
        let root = workspace.rootTilingContainer
        root.changeOrientation(.h)
        let tabbed = TilingContainer(parent: root, adaptiveWeight: 1, .h, .tabbed, index: INDEX_BIND_LAST)
        let tab1 = TestWindow.new(id: 1, parent: tabbed)
        let tab2 = TestWindow.new(id: 2, parent: tabbed)
        let tab3 = TestWindow.new(id: 3, parent: tabbed)
        tab1.markAsMostRecentChild() // tab1 is the visible one

        try await workspace.layoutWorkspace()

        let visible = try XCTUnwrap(tab1.lastAppliedLayoutPhysicalRect)
        assertSameRect(tab2.lastAppliedLayoutPhysicalRect, visible)
        assertSameRect(tab3.lastAppliedLayoutPhysicalRect, visible)
        assertSameRect(try await tab2.getAxRect(.nonCancellable), visible)
        assertSameRect(try await tab3.getAxRect(.nonCancellable), visible)
    }

    /// Shrinking the container — here by adding a sibling below it — has to reach every tab.
    /// Otherwise the hidden tabs keep the full height they had before and overflow their tile.
    func testHiddenTabsShrinkWithTheContainer() async throws {
        let workspace = Workspace.get(byName: name)
        let root = workspace.rootTilingContainer
        root.changeOrientation(.v)
        let tabbed = TilingContainer(parent: root, adaptiveWeight: 1, .h, .tabbed, index: INDEX_BIND_LAST)
        let tab1 = TestWindow.new(id: 1, parent: tabbed)
        let tab2 = TestWindow.new(id: 2, parent: tabbed)
        tab1.markAsMostRecentChild()

        try await workspace.layoutWorkspace()
        let heightBefore = try XCTUnwrap(tab2.lastAppliedLayoutPhysicalRect).height

        // A new window below the tab group halves the height available to it
        TestWindow.new(id: 3, parent: root)
        try await workspace.layoutWorkspace()

        let visible = try XCTUnwrap(tab1.lastAppliedLayoutPhysicalRect)
        let hidden = try XCTUnwrap(tab2.lastAppliedLayoutPhysicalRect)
        XCTAssertLessThan(hidden.height, heightBefore, "the hidden tab kept its old height")
        assertSameRect(hidden, visible)
    }
}

private func assertSameRect(
    _ actual: Rect?,
    _ expected: Rect,
    file: StaticString = #filePath,
    line: UInt = #line,
) {
    guard let actual else { return XCTFail("expected a rect, got nil", file: file, line: line) }
    XCTAssertEqual(
        [actual.topLeftX, actual.topLeftY, actual.width, actual.height],
        [expected.topLeftX, expected.topLeftY, expected.width, expected.height],
        file: file,
        line: line,
    )
}
