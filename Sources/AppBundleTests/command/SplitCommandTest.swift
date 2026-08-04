@testable import AppBundle
import Common
import XCTest

@MainActor
final class SplitCommandTest: XCTestCase {
    override func setUp() async throws { setUpWorkspacesForTests() }

    func testSplit() async {
        let root = Workspace.get(byName: name).rootTilingContainer.apply {
            assertEquals(TestWindow.new(id: 1, parent: $0).focusWindow(), true)
            TestWindow.new(id: 2, parent: $0)
        }

        await parseCommand("split vertical").cmdOrDie.run(.defaultEnv, .emptyStdin)
        assertEquals(root.layoutDescription, .h_tiles([
            .v_tiles([
                .window(1),
            ]),
            .window(2),
        ]))
    }

    func testSplitOppositeOrientation() async {
        let root = Workspace.get(byName: name).rootTilingContainer.apply {
            assertEquals(TestWindow.new(id: 1, parent: $0).focusWindow(), true)
            TestWindow.new(id: 2, parent: $0)
        }

        await parseCommand("split opposite").cmdOrDie.run(.defaultEnv, .emptyStdin)
        assertEquals(root.layoutDescription, .h_tiles([
            .v_tiles([
                .window(1),
            ]),
            .window(2),
        ]))
    }

    func testChangeOrientation() async {
        let root = Workspace.get(byName: name).rootTilingContainer.apply {
            TilingContainer.newVTiles(parent: $0, adaptiveWeight: 1).apply {
                assertEquals(TestWindow.new(id: 1, parent: $0).focusWindow(), true)
            }
            TestWindow.new(id: 2, parent: $0)
        }

        await parseCommand("split horizontal").cmdOrDie.run(.defaultEnv, .emptyStdin)
        assertEquals(root.layoutDescription, .h_tiles([
            .h_tiles([
                .window(1),
            ]),
            .window(2),
        ]))
    }

    /// With the flatten normalization on (the default), `split` must not fail and must not restructure
    /// the tree eagerly. It records i3's intent, which the next window to open beside it consumes.
    func testSplitIsDeferredWhenFlattenNormalizationIsEnabled() async {
        config.enableNormalizationFlattenContainers = true
        let window1 = TestWindow.new(id: 1, parent: Workspace.get(byName: name).rootTilingContainer)
        assertEquals(window1.focusWindow(), true)
        let root = Workspace.get(byName: name).rootTilingContainer
        TestWindow.new(id: 2, parent: root)

        let result = await parseCommand("split vertical").cmdOrDie.run(.defaultEnv, .emptyStdin)

        assertEquals(result.exitCode.rawValue, 0)
        assertEquals(window1.pendingSplitOrientation, .v)
        // The tree is untouched until the next window actually arrives
        assertEquals(root.layoutDescription, .h_tiles([.window(1), .window(2)]))
    }

    /// Splitting from inside a tab must mark the whole tab group, not the focused tab. Marking the
    /// tab would nest the split inside it, leaving the other tabs at the container's full size while
    /// only the visible one shrank.
    func testSplitFromInsideATabMarksTheWholeGroup() async {
        config.enableNormalizationFlattenContainers = true
        let root = Workspace.get(byName: name).rootTilingContainer
        let tabbed = TilingContainer(parent: root, adaptiveWeight: 1, .h, .tabbed, index: INDEX_BIND_LAST)
        let tab1 = TestWindow.new(id: 1, parent: tabbed)
        let tab2 = TestWindow.new(id: 2, parent: tabbed)
        TestWindow.new(id: 3, parent: root)
        assertEquals(tab1.focusWindow(), true)

        await parseCommand("split vertical").cmdOrDie.run(.defaultEnv, .emptyStdin)

        assertEquals(tabbed.pendingSplitOrientation, .v)
        assertEquals(tab1.pendingSplitOrientation, nil)
        assertEquals(tab2.pendingSplitOrientation, nil)
    }

    func testToggleOrientation() async {
        let root = Workspace.get(byName: name).rootTilingContainer.apply {
            TilingContainer.newVTiles(parent: $0, adaptiveWeight: 1).apply {
                assertEquals(TestWindow.new(id: 1, parent: $0).focusWindow(), true)
            }
            TestWindow.new(id: 2, parent: $0)
        }

        await parseCommand("split opposite").cmdOrDie.run(.defaultEnv, .emptyStdin)
        assertEquals(root.layoutDescription, .h_tiles([
            .h_tiles([
                .window(1),
            ]),
            .window(2),
        ]))
    }
}
