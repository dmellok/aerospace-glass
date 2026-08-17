import AppKit
import Common

/// 1/φ. The larger part of a golden section, as a fraction of the whole.
private let goldenMajor: CGFloat = 0.6180339887

extension TilingContainer {
    /// Rearrange this container's windows into a Fibonacci spiral.
    ///
    /// Each window takes the golden section of what is left and the remainder is split the other
    /// way, so the layout winds inward: the first window takes 62% of the width, the next 62% of
    /// the remaining height, and so on. The last two share their space evenly, since there is
    /// nothing left to spiral into.
    ///
    /// The windows keep their order. Only the shape of the tree changes, so which window is where
    /// stays predictable rather than being reshuffled by the rearrangement.
    @MainActor
    func spiralize() {
        let windows = allLeafWindowsRecursive
        guard windows.count > 1 else { return }
        // Weights are read as sizes, and the layout pass hands out any difference between their sum
        // and the real extent equally among the children. Weights summing to less than the extent
        // therefore drift toward equal halves - which is how a golden section becomes a 54/46 one.
        // Starting from the container's real size keeps that difference at zero.
        let rect = lastAppliedLayoutPhysicalRect
            ?? nodeMonitor?.visibleRect
            ?? Rect(topLeftX: 0, topLeftY: 0, width: 1600, height: 1000)

        // Detach everything first: the intermediate containers are rebuilt from scratch, and a
        // window still bound to one of them would be carried into the new tree by accident.
        for window in windows { window.unbindFromParent() }
        for child in children { child.unbindFromParent() }

        build(windows, into: self, orientation: .h, width: rect.width, height: rect.height)
    }

    /// Bind `windows` under `container`, spiralling into a fresh child container each time.
    @MainActor
    private func build(
        _ windows: [Window],
        into container: TilingContainer,
        orientation: Orientation,
        width: CGFloat,
        height: CGFloat,
    ) {
        container.layout = .tiles
        container.setOwnOrientation(orientation)
        guard let first = windows.first else { return }
        let rest = Array(windows.dropFirst())
        /// The extent being divided: a horizontal container splits width, a vertical one height.
        let extent = orientation == .h ? width : height

        // Two left: they share this container rather than nesting one more level, which would
        // leave a container holding a single window for normalization to dissolve anyway.
        if rest.count <= 1 {
            first.bind(
                to: container,
                adaptiveWeight: rest.isEmpty ? WEIGHT_AUTO : extent * goldenMajor,
                index: INDEX_BIND_LAST,
            )
            for window in rest {
                window.bind(to: container, adaptiveWeight: extent * (1 - goldenMajor), index: INDEX_BIND_LAST)
            }
            return
        }

        let major = extent * goldenMajor
        let minor = extent - major
        first.bind(to: container, adaptiveWeight: major, index: INDEX_BIND_LAST)
        let next = TilingContainer(
            parent: container,
            adaptiveWeight: minor,
            orientation.opposite,
            .tiles,
            index: INDEX_BIND_LAST,
        )
        // What is left after this window: the split axis shrinks, the other axis is untouched.
        build(
            rest,
            into: next,
            orientation: orientation.opposite,
            width: orientation == .h ? minor : width,
            height: orientation == .h ? height : minor,
        )
    }
}

@MainActor
extension Workspace {
    /// Apply ``GlassLayoutConfig/accordion`` to every accordion container on this workspace.
    ///
    /// Accordion is a layout you can only reach deliberately, but it is easy to reach by accident
    /// with a mistyped binding, and hard to recognise once you are in it. This turns it into
    /// something else the moment it appears.
    func applyGlassAccordionPolicy() {
        let mode = config.glass.layout.accordion
        guard mode != .keep else { return }
        var containers: [TilingContainer] = []
        func collect(_ node: TreeNode) {
            if let container = node as? TilingContainer, container.layout == .accordion {
                containers.append(container)
            }
            for child in node.children { collect(child) }
        }
        collect(rootTilingContainer)
        for container in containers {
            switch mode {
                case .keep: break
                case .tiles: container.layout = .tiles
                case .spiral: container.spiralize()
            }
        }
    }
}
