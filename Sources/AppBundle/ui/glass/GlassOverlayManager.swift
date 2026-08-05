import AppKit
import Common
import SwiftUI

/// Draws the glass decorations (window borders and tab bars for `tabbed` containers) on top of the
/// windows that AeroSpace manages.
///
/// The manager is purely derived state: ``refresh()`` runs at the end of every refresh session,
/// reads the geometry the layout pass already cached on the tree
/// (``TreeNode/lastAppliedLayoutPhysicalRect`` and ``TilingContainer/lastAppliedTabBarRect``), and
/// reconciles a pool of panels against it. Nothing here queries the Accessibility API, so it adds
/// no round-trips to the layout hot path.
@MainActor
final class GlassOverlayManager {
    static let shared = GlassOverlayManager()

    private var borderPanels: [UInt32: GlassPanel<GlassBorderView>] = [:]
    private var tabPanels: [ObjectIdentifier: GlassPanel<GlassTabBarView>] = [:]
    private let titles = WindowTitleCache()
    private let frames = WindowFrameCache()

    private init() {}

    func refresh() {
        guard TrayMenuModel.shared.isEnabled else {
            hideAll()
            return
        }
        var borders: [BorderSpec] = []
        var tabBars: [TabBarSpec] = []
        let focusedWindowId = focus.windowOrNil?.windowId

        for monitor in monitors {
            let workspace = monitor.activeWorkspace
            // An aerospace-fullscreen window covers the whole workspace (same Space, unlike macOS
            // native fullscreen), so any decoration on this monitor would float on top of it
            if workspace.rootTilingContainer.mostRecentWindowRecursive?.isFullscreen == true { continue }
            collect(node: workspace.rootTilingContainer, focusedWindowId: focusedWindowId, &borders, &tabBars)
        }

        syncBorders(borders)
        syncTabBars(tabBars)
        titles.prefetch(tabBars.flatMap { $0.windowIds }) { [weak self] in
            // Titles arrive asynchronously from the AX API. Re-render the bars in place rather than
            // triggering another refresh session, which would loop.
            self?.rerenderTabBarTitles()
        }
    }

    func hideAll() {
        for panel in borderPanels.values { panel.orderOut(nil) }
        for panel in tabPanels.values { panel.orderOut(nil) }
        GlassDropPreviewController.shared.hide()
    }

    // MARK: - Collecting

    private func collect(
        node: TreeNode,
        focusedWindowId: UInt32?,
        _ borders: inout [BorderSpec],
        _ tabBars: inout [TabBarSpec],
    ) {
        switch node.nodeCases {
            case .window(let window):
                guard config.glass.borders.enabled,
                      let rect = window.lastAppliedLayoutPhysicalRect,
                      !window.isHiddenInCorner else { return }
                let isFocused = window.windowId == focusedWindowId
                if isFocused || config.glass.borders.showInactive {
                    borders.append(BorderSpec(
                        windowId: window.windowId,
                        rect: rect,
                        isFocused: isFocused,
                        appBundleId: window.app.rawAppBundleId,
                    ))
                }
            case .tilingContainer(let container):
                if config.glass.tabs.enabled, container.layout == .tabbed, let barRect = container.lastAppliedTabBarRect {
                    let windows = container.children.compactMap { $0.allLeafWindowsRecursive.first }
                    if !windows.isEmpty {
                        tabBars.append(TabBarSpec(
                            container: ObjectIdentifier(container),
                            group: container,
                            rect: barRect,
                            windowIds: windows.map(\.windowId),
                            activeWindowId: container.mostRecentChild?.allLeafWindowsRecursive.first?.windowId,
                        ))
                    }
                }
                // In a tabbed container every child has the same rect, so decorating all of them
                // would stack identical borders on top of each other. Only the visible one counts.
                let visible = container.layout == .tabbed
                    ? [container.mostRecentChild].compactMap(id)
                    : container.children
                for child in visible {
                    collect(node: child, focusedWindowId: focusedWindowId, &borders, &tabBars)
                }
            case .workspace, .floatingWindowsContainer, .macosMinimizedWindowsContainer,
                 .macosFullscreenWindowsContainer, .macosPopupWindowsContainer,
                 .macosHiddenAppsWindowsContainer:
                return
        }
    }

    // MARK: - Borders

    private func syncBorders(_ specs: [BorderSpec]) {
        let cfg = config.glass.borders
        var stale = Set(borderPanels.keys)
        for spec in specs {
            stale.remove(spec.windowId)
            // Draw around where the window really is, not where the layout pass put it — some
            // windows refuse the exact frame (terminals snap to their cell grid). The real frame
            // arrives asynchronously; until then the intended rect is the best guess.
            let rect = frames.actualRect(of: spec.windowId, applied: spec.rect) ?? spec.rect
            let outset = CGFloat(cfg.padding + cfg.width)
            let frame = rect.inset(by: -outset).toCocoaRect
            let radius = spec.appBundleId.flatMap { cfg.appCornerRadius[$0] } ?? cfg.cornerRadius
            let view = GlassBorderView(
                cornerRadius: CGFloat(radius) + outset,
                lineWidth: CGFloat(cfg.width),
                color: Color((spec.isFocused ? cfg.activeColor : cfg.inactiveColor).toNSColor),
            )
            let panel = borderPanels.getOrPut(spec.windowId) {
                GlassPanel(content: view, clickThrough: true)
            }
            panel.rootView = view
            panel.setFrameInstantly(frame)
            panel.showIfNeeded()
        }
        for windowId in stale {
            borderPanels.removeValue(forKey: windowId)?.orderOut(nil)
        }
        liveBorderSpecs = specs
        frames.prefetch(specs.map { (windowId: $0.windowId, applied: $0.rect) }) { [weak self] in
            // A window turned out to sit somewhere other than where the layout pass put it.
            // Reposition the affected panels in place rather than triggering another refresh
            // session, which would loop.
            guard let self else { return }
            self.syncBorders(self.liveBorderSpecs)
        }
    }

    private var liveBorderSpecs: [BorderSpec] = []

    // MARK: - Tab bars

    private func syncTabBars(_ specs: [TabBarSpec]) {
        var stale = Set(tabPanels.keys)
        for spec in specs {
            stale.remove(spec.container)
            let panel = tabPanels.getOrPut(spec.container) {
                GlassPanel(content: tabBarView(spec), clickThrough: false)
            }
            panel.rootView = tabBarView(spec)
            panel.setFrameInstantly(spec.rect.toCocoaRect)
            panel.showIfNeeded()
            liveTabBarSpecs[spec.container] = spec
        }
        for container in stale {
            tabPanels.removeValue(forKey: container)?.orderOut(nil)
            liveTabBarSpecs.removeValue(forKey: container)
        }
    }

    private var liveTabBarSpecs: [ObjectIdentifier: TabBarSpec] = [:]

    private func rerenderTabBarTitles() {
        for (container, spec) in liveTabBarSpecs {
            tabPanels[container]?.rootView = tabBarView(spec)
        }
    }

    private func tabBarView(_ spec: TabBarSpec) -> GlassTabBarView {
        let cfg = config.glass.tabs
        let items = spec.windowIds.map { windowId -> GlassTabItem in
            let window = Window.get(byId: windowId)
            return GlassTabItem(
                id: windowId,
                title: titles.title(of: windowId) ?? window?.app.name ?? "Window \(windowId)",
                icon: (window as? MacWindow)?.macApp.nsApp.icon,
                isActive: windowId == spec.activeWindowId,
            )
        }
        return GlassTabBarView(
            items: items,
            cornerRadius: CGFloat(cfg.cornerRadius),
            fontSize: CGFloat(cfg.fontSize),
            showIcons: cfg.showIcons,
            barTint: Color(cfg.barTint.toNSColor),
            inactiveTint: Color(cfg.inactiveTint.toNSColor),
            activeTint: Color(cfg.activeTint.toNSColor),
            activeForeground: Color(cfg.activeTint.legibleForeground),
            inactiveForeground: Color(cfg.inactiveTint.legibleForeground),
            onSelect: { windowId in
                Task.startUnstructured { @MainActor in
                    await focusWindowFromTabBar(windowId)
                }
            },
            onClose: { windowId in
                Task.startUnstructured { @MainActor in
                    await closeWindowFromTabBar(windowId)
                }
            },
            onDragChanged: { [group = spec.group] windowId in
                Task.startUnstructured { @MainActor in
                    tabDragChanged(windowId: windowId, group: group)
                }
            },
            onDragEnded: { [group = spec.group] windowId, translation in
                Task.startUnstructured { @MainActor in
                    await tabDragEnded(windowId: windowId, group: group, translation: translation)
                }
            },
        )
    }
}

@MainActor
private func focusWindowFromTabBar(_ windowId: UInt32) async {
    guard let window = Window.get(byId: windowId) else { return }
    guard let guardd = RunSessionGuard.isServerEnabled else { return }
    try? await runLightSession(.glassTabBarClick, guardd) {
        _ = window.focusWindow()
    }
}

@MainActor
private func closeWindowFromTabBar(_ windowId: UInt32) async {
    guard let window = Window.get(byId: windowId) else { return }
    guard let guardd = RunSessionGuard.isServerEnabled else { return }
    try? await runLightSession(.glassTabBarClose, guardd) {
        window.closeAxWindow()
    }
}

/// How far past the bar a tab must be dragged before releasing it tears the window out of the
/// group, when the release point resolves to no drop target at all. Vertical distance only:
/// horizontal drags stay within the bar's own axis.
private let tabTearOffThreshold: CGFloat = 40

/// A drag tick from a tab chip: resolve where releasing here would land and render the preview.
/// Never mutates the tree — mutation waits for ``tabDragEnded``.
@MainActor
private func tabDragChanged(windowId: UInt32, group: TilingContainer?) {
    guard isLeftMouseButtonDown else { return } // A stray tick delivered after the drop
    guard let dragged = tabDragNode(windowId: windowId, group: group) else { return }
    let point = mouseLocation
    GlassDropPreviewController.shared.update(point: point, target: resolveDropTarget(point, dragged: dragged))
}

@MainActor
private func tabDragEnded(windowId: UInt32, group: TilingContainer?, translation: CGSize) async {
    GlassDropPreviewController.shared.hide()
    guard let window = Window.get(byId: windowId) else { return }
    guard let guardd = RunSessionGuard.isServerEnabled else { return }
    try? await runLightSession(.glassTabBarDrop, guardd) {
        guard let group, let dragged = tabDragNode(windowId: windowId, group: group) else { return }
        if let target = resolveDropTarget(mouseLocation, dragged: dragged) {
            applyDrop(target, dragged: dragged)
        } else if abs(translation.height) > tabTearOffThreshold {
            // Dropped on nothing in particular but clearly outside the bar: the browser tear-off
            // gesture. The tab leaves the group and becomes a tile right next to it.
            tearOutOfTabGroup(dragged, from: group)
        } else {
            return // A drop on its own tab or another dead zone: the tab snaps back
        }
        _ = window.focusWindow()
    }
}

/// The tab being dragged is the group's direct child on the window's path. Usually the window
/// itself, but a nested container moves as a whole, like its single tab suggests.
@MainActor
private func tabDragNode(windowId: UInt32, group: TilingContainer?) -> TreeNode? {
    guard let group, group.isBound, group.layout == .tabbed else { return nil }
    guard let window = Window.get(byId: windowId) else { return nil }
    return window.parentsWithSelf.first(where: { $0.parent === group })
}

@MainActor
private func tearOutOfTabGroup(_ tab: TreeNode, from tabGroup: TilingContainer) {
    guard tabGroup.children.count > 1 else { return } // A lone tab is already its own tile
    switch tabGroup.tilingContainerParentCases {
        case .unbound: return
        case .tilingContainer(let parent):
            guard let groupIndex = tabGroup.ownIndex else { return }
            tab.bind(to: parent, adaptiveWeight: WEIGHT_AUTO, index: groupIndex + 1)
        case .workspace(let workspace):
            // The group is the root container, so there is no parent to tile into yet
            tabGroup.unbindFromParent()
            let orientation: Orientation = switch config.defaultRootContainerOrientation {
                case .horizontal: .h
                case .vertical: .v
                case .auto: workspace.workspaceMonitor.width >= workspace.workspaceMonitor.height ? .h : .v
            }
            let newRoot = TilingContainer(parent: workspace, adaptiveWeight: 1, orientation, .tiles, index: 0)
            tabGroup.bind(to: newRoot, adaptiveWeight: WEIGHT_AUTO, index: 0)
            tab.bind(to: newRoot, adaptiveWeight: WEIGHT_AUTO, index: 1)
    }
}

private struct BorderSpec {
    let windowId: UInt32
    let rect: Rect
    let isFocused: Bool
    let appBundleId: String?
}

private struct TabBarSpec {
    let container: ObjectIdentifier
    /// The live container, for the drag callbacks. Weak: the spec cache must not keep a detached
    /// container alive after the tree drops it.
    weak var group: TilingContainer?
    let rect: Rect
    let windowIds: [UInt32]
    let activeWindowId: UInt32?
}

extension Dictionary {
    fileprivate mutating func getOrPut(_ key: Key, _ make: () -> Value) -> Value {
        if let existing = self[key] { return existing }
        let value = make()
        self[key] = value
        return value
    }
}
