@testable import AppBundle
import Common
import XCTest

@MainActor
final class SpiralTest: XCTestCase {
    override func setUp() async throws { setUpWorkspacesForTests() }

    /// The shape of a spiral: a window and a container at every level, the container running the
    /// other way, until the last level holds the final two windows.
    func testShapeAlternatesOrientationAndNestsRight() {
        let workspace = Workspace.get(byName: name)
        let root = workspace.rootTilingContainer
        for id in 1 ... 4 { TestWindow.new(id: UInt32(id), parent: root) }

        root.spiralize()

        XCTAssertEqual(root.orientation, .h)
        XCTAssertEqual(root.children.count, 2)
        XCTAssertEqual((root.children[0] as? Window)?.windowId, 1)

        guard let second = root.children[1] as? TilingContainer else { return XCTFail("expected a nested container") }
        XCTAssertEqual(second.orientation, .v, "each level runs the other way")
        XCTAssertEqual((second.children[0] as? Window)?.windowId, 2)

        guard let third = second.children[1] as? TilingContainer else { return XCTFail("expected a nested container") }
        XCTAssertEqual(third.orientation, .h)
        // The last two share a container rather than nesting once more for a single window.
        XCTAssertEqual(third.children.compactMap { ($0 as? Window)?.windowId }, [3, 4])
    }

    /// Rearranging must not reshuffle which window is which, or a spiral would be unusable: you'd
    /// have to find your windows again every time it ran.
    func testKeepsWindowOrder() {
        let workspace = Workspace.get(byName: name)
        let root = workspace.rootTilingContainer
        for id in 1 ... 5 { TestWindow.new(id: UInt32(id), parent: root) }

        root.spiralize()

        XCTAssertEqual(root.allLeafWindowsRecursive.map(\.windowId), [1, 2, 3, 4, 5])
    }

    /// Each split is a golden section, which is what makes it a spiral rather than a staircase of
    /// equal halves.
    func testSplitsInGoldenRatio() {
        let workspace = Workspace.get(byName: name)
        let root = workspace.rootTilingContainer
        for id in 1 ... 3 { TestWindow.new(id: UInt32(id), parent: root) }

        root.spiralize()

        let major = root.children[0].getWeight(.h)
        let minor = root.children[1].getWeight(.h)
        XCTAssertEqual(major / (major + minor), 0.618, accuracy: 0.01)
    }

    /// One window is already the whole space; there is nothing to spiral into.
    func testSingleWindowIsLeftAlone() {
        let workspace = Workspace.get(byName: name)
        let root = workspace.rootTilingContainer
        TestWindow.new(id: 1, parent: root)

        root.spiralize()

        XCTAssertEqual(root.children.count, 1)
        XCTAssertEqual(root.allLeafWindowsRecursive.map(\.windowId), [1])
    }

    /// Two windows are one split, not a spiral, and should share the container evenly rather than
    /// nesting a container holding a single window.
    func testTwoWindowsShareOneContainer() {
        let workspace = Workspace.get(byName: name)
        let root = workspace.rootTilingContainer
        for id in 1 ... 2 { TestWindow.new(id: UInt32(id), parent: root) }

        root.spiralize()

        XCTAssertEqual(root.children.compactMap { ($0 as? Window)?.windowId }, [1, 2])
    }

    /// The policy is what turns accordion off: with `spiral` an accordion container comes back as
    /// a spiral, and with `keep` it is left exactly as it was.
    func testAccordionPolicyConverts() {
        let workspace = Workspace.get(byName: name)
        let root = workspace.rootTilingContainer
        root.layout = .accordion
        for id in 1 ... 3 { TestWindow.new(id: UInt32(id), parent: root) }

        config.glass.layout.accordion = .keep
        workspace.applyGlassAccordionPolicy()
        XCTAssertEqual(root.layout, .accordion, "keep must not touch it")

        config.glass.layout.accordion = .spiral
        workspace.applyGlassAccordionPolicy()
        XCTAssertEqual(root.layout, .tiles)
        XCTAssertEqual(root.children.count, 2, "a spiral splits into a window and the rest")
        config.glass.layout.accordion = .keep
    }
}
