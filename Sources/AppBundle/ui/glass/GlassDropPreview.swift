import AppKit
import Common
import SwiftUI

/// The overlay shown while a window or tab is being dragged: every cell of the target workspace's
/// layout is outlined so the splits are visible, and the slot the drop would land in is filled with
/// blurred glass. Purely derived state, like the rest of the glass decorations — it renders the
/// ``DropTarget`` the drag logic resolved and never mutates the tree.
@MainActor
final class GlassDropPreviewController {
    static let shared = GlassDropPreviewController()
    private var panel: GlassPanel<GlassDropPreviewView>? = nil

    private init() {}

    /// `dragged` lets the preview tell a reorder inside a bar from a drop that restructures the
    /// tree. Pass it whenever it's known; nil just means the full preview.
    func update(point: CGPoint, target: DropTarget?, dragged: TreeNode? = nil) {
        guard TrayMenuModel.shared.isEnabled, config.glass.dropPreview.enabled else {
            hide()
            return
        }
        let monitor = point.monitorApproximation
        let workspace = monitor.activeWorkspace
        let origin = monitor.visibleRect

        // Dragging a tab within the bar it already belongs to only moves it among its siblings:
        // the layout doesn't change, so sketching every cell and filling the target says nothing
        // and buries the bar - the thing being reordered - under the preview. The caret is the
        // whole story there.
        var isReorderWithinBar = false
        if case .tabBar(let group, _) = target, let dragged, dragged.parent === group {
            isReorderWithinBar = true
        }

        var cells: [Rect] = []
        if !isReorderWithinBar, !workspace.rootTilingContainer.isEffectivelyEmpty {
            collectCells(workspace.rootTilingContainer, &cells)
        }
        var (highlight, caret) = target.flatMap(highlightGeometry) ?? (nil, nil)
        if isReorderWithinBar { highlight = nil }

        let cfg = config.glass.themed().dropPreview
        let view = GlassDropPreviewView(
            cells: cells.map { $0.relative(to: origin) },
            highlight: highlight.map { $0.relative(to: origin) },
            caret: caret.map { $0.relative(to: origin) },
            cornerRadius: CGFloat(cfg.cornerRadius),
            tint: Color(cfg.tint.toNSColor),
            stroke: Color(cfg.strokeColor.toNSColor),
            cellColor: Color(cfg.cellColor.toNSColor),
        )
        let panel: GlassPanel<GlassDropPreviewView>
        if let existing = self.panel {
            panel = existing
        } else {
            panel = GlassPanel(content: view, clickThrough: true)
            self.panel = panel
        }
        panel.rootView = view
        panel.setFrameInstantly(origin.toCocoaRect)
        panel.showIfNeeded()
    }

    func hide() {
        panel?.orderOut(nil)
    }

    /// The visible cells of the layout: leaf windows, except that a `tabbed` container is one cell
    /// (its tabs share the rect and travel together).
    private func collectCells(_ node: TreeNode, _ out: inout [Rect]) {
        switch node.tilingTreeNodeCasesOrDie() {
            case .window(let window):
                if let rect = window.lastAppliedLayoutPhysicalRect { out.append(rect) }
            case .tilingContainer(let container):
                if container.layout == .tabbed {
                    if let rect = container.lastAppliedLayoutPhysicalRect { out.append(rect) }
                } else {
                    for child in container.children { collectCells(child, &out) }
                }
        }
    }

    private func highlightGeometry(_ target: DropTarget) -> (highlight: Rect?, caret: Rect?) {
        switch target {
            case .tabBar(let group, let index):
                guard let bar = group.lastAppliedTabBarRect else { return (nil, nil) }
                return (bar, caretRect(in: bar, tabCount: group.children.count, index: index))
            case .tabGroup(let group):
                guard let rect = group.lastAppliedLayoutPhysicalRect else { return (nil, nil) }
                // Highlight only the content area, so the bar keeps reading as its own drop zone
                if let bar = group.lastAppliedTabBarRect {
                    let topInset = bar.maxY + CGFloat(config.glass.tabs.spacing) - rect.minY
                    return (
                        Rect(topLeftX: rect.minX, topLeftY: rect.minY + topInset, width: rect.width, height: rect.height - topInset),
                        nil,
                    )
                }
                return (rect, nil)
            case .newTabGroup(let window):
                guard let rect = window.lastAppliedLayoutPhysicalRect else { return (nil, nil) }
                // The caret doubles as a hint of the tab bar the drop will grow across the cell's top
                return (rect, Rect(topLeftX: rect.minX + 6, topLeftY: rect.minY + 6, width: rect.width - 12, height: 3))
            case .split(let cell, let edge):
                guard let rect = cell.lastAppliedLayoutPhysicalRect else { return (nil, nil) }
                return (rect.half(on: edge), nil)
            case .swap(let window):
                return (window.lastAppliedLayoutPhysicalRect, nil)
            case .emptyWorkspace(let workspace):
                return (workspace.workspaceMonitor.visibleRectPaddedByOuterGaps, nil)
        }
    }

    /// The insertion caret between two tabs. Tab geometry mirrors ``GlassTabBarView``: an HStack
    /// with 3pt padding and 3pt spacing dividing the bar into equal-width tabs.
    private func caretRect(in bar: Rect, tabCount: Int, index: Int) -> Rect? {
        guard tabCount > 0 else { return nil }
        let pad: CGFloat = 3
        let spacing: CGFloat = 3
        let tabWidth = (bar.width - 2 * pad - spacing * CGFloat(tabCount - 1)) / CGFloat(tabCount)
        guard tabWidth > 0 else { return nil }
        let x: CGFloat = switch index {
            case 0: bar.minX + pad
            case tabCount...: bar.maxX - pad
            default: bar.minX + pad + CGFloat(index) * (tabWidth + spacing) - spacing / 2
        }
        return Rect(topLeftX: x - 1.5, topLeftY: bar.minY + 4, width: 3, height: bar.height - 8)
    }
}

extension Rect {
    /// The half of the rect touching the given edge — the area a `split` drop would hand to the
    /// dragged window.
    fileprivate func half(on edge: CardinalDirection) -> Rect {
        switch edge {
            case .left: Rect(topLeftX: minX, topLeftY: minY, width: width / 2, height: height)
            case .right: Rect(topLeftX: minX + width / 2, topLeftY: minY, width: width / 2, height: height)
            case .up: Rect(topLeftX: minX, topLeftY: minY, width: width, height: height / 2)
            case .down: Rect(topLeftX: minX, topLeftY: minY + height / 2, width: width, height: height / 2)
        }
    }

    /// This rect in the coordinate space of `origin`'s top-left corner (SwiftUI's top-leading).
    fileprivate func relative(to origin: Rect) -> CGRect {
        CGRect(x: minX - origin.minX, y: minY - origin.minY, width: width, height: height)
    }
}

struct GlassDropPreviewView: View {
    var cells: [CGRect]
    var highlight: CGRect?
    var caret: CGRect?
    var cornerRadius: CGFloat
    var tint: Color
    var stroke: Color
    var cellColor: Color

    var body: some View {
        ZStack(alignment: .topLeading) {
            ForEach(Array(cells.enumerated()), id: \.offset) { _, rect in
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(cellColor, lineWidth: 1.5)
                    .frame(width: rect.width, height: rect.height)
                    .offset(x: rect.minX, y: rect.minY)
            }
            if let highlight {
                GlassHighlightZone(rect: highlight, cornerRadius: cornerRadius, tint: tint, stroke: stroke)
            }
            if let caret {
                Capsule()
                    .fill(stroke)
                    .frame(width: caret.width, height: caret.height)
                    .offset(x: caret.minX, y: caret.minY)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .animation(.easeOut(duration: 0.12), value: highlight)
        .animation(.easeOut(duration: 0.12), value: caret)
    }
}

/// The blurred glass fill marking the active drop slot. Like the tab bar strip, the blur is
/// composited by the window server, so it picks up whatever windows sit underneath.
private struct GlassHighlightZone: View {
    var rect: CGRect
    var cornerRadius: CGFloat
    var tint: Color
    var stroke: Color

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        Group {
            if #available(macOS 26.0, *) {
                Color.clear.glassEffect(.regular.tint(tint), in: shape)
            } else {
                Color.clear
                    .background(.ultraThinMaterial, in: shape)
                    .background(shape.fill(tint))
            }
        }
        .overlay(shape.strokeBorder(stroke, lineWidth: 2))
        .frame(width: rect.width, height: rect.height)
        .offset(x: rect.minX, y: rect.minY)
    }
}
