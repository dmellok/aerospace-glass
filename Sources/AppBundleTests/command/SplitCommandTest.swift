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

    /// The split container is created immediately and must survive the flatten normalization, which
    /// would otherwise dissolve it while it still holds only the split window — leaving nothing for
    /// a second window to be moved into.
    func testSplitSurvivesFlattenNormalization() async {
        config.enableNormalizationFlattenContainers = true
        let workspace = Workspace.get(byName: name)
        let root = workspace.rootTilingContainer
        let window1 = TestWindow.new(id: 1, parent: root)
        TestWindow.new(id: 2, parent: root)
        assertEquals(window1.focusWindow(), true)

        let result = await parseCommand("split vertical").cmdOrDie.run(.defaultEnv, .emptyStdin)
        workspace.normalizeContainers()

        assertEquals(result.exitCode.rawValue, 0)
        assertEquals(root.layoutDescription, .h_tiles([.v_tiles([.window(1)]), .window(2)]))
    }

    /// A window moved into a fresh split stacks inside it rather than landing beside it.
    func testWindowMovedIntoASplitStacksInsideIt() async {
        config.enableNormalizationFlattenContainers = true
        let workspace = Workspace.get(byName: name)
        let window1 = TestWindow.new(id: 1, parent: workspace.rootTilingContainer)
        let window2 = TestWindow.new(id: 2, parent: workspace.rootTilingContainer)
        TestWindow.new(id: 3, parent: workspace.rootTilingContainer)
        assertEquals(window1.focusWindow(), true)
        await parseCommand("split vertical").cmdOrDie.run(.defaultEnv, .emptyStdin)

        assertEquals(window2.focusWindow(), true)
        await parseCommand("move left").cmdOrDie.run(.defaultEnv, .emptyStdin)
        workspace.normalizeContainers()

        assertEquals(
            workspace.rootTilingContainer.layoutDescription,
            .h_tiles([.v_tiles([.window(1), .window(2)]), .window(3)]),
        )
    }

    /// Splitting from inside a tab divides the whole tab group. Splitting the focused tab instead
    /// would nest the split within it, leaving the other tabs at the container's full size while
    /// only the visible one shrank.
    func testSplitFromInsideATabSplitsTheWholeGroup() async {
        config.enableNormalizationFlattenContainers = true
        let workspace = Workspace.get(byName: name)
        let root = workspace.rootTilingContainer
        let tabbed = TilingContainer(parent: root, adaptiveWeight: 1, .h, .tabbed, index: INDEX_BIND_LAST)
        let tab1 = TestWindow.new(id: 1, parent: tabbed)
        TestWindow.new(id: 2, parent: tabbed)
        TestWindow.new(id: 3, parent: root)
        assertEquals(tab1.focusWindow(), true)

        await parseCommand("split vertical").cmdOrDie.run(.defaultEnv, .emptyStdin)
        workspace.normalizeContainers()

        // The tab group as a whole sits inside the new split, with both tabs intact
        assertEquals(tabbed.parent as? TilingContainer !== root, true)
        assertEquals(tabbed.children.count, 2)
        assertEquals((tabbed.parent as? TilingContainer)?.orientation, Orientation.v)
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
