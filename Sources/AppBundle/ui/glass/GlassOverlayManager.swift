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
    private var handlePanels: [ObjectIdentifier: GlassPanel<GlassResizeHandleView>] = [:]
    /// What each border panel was last given. A refresh session runs on every AX notification, and
    /// handing SwiftUI an identical view each time makes it rebuild a glass surface that hasn't
    /// changed - which is real GPU work repeated for nothing.
    private var renderedBorders: [UInt32: (view: GlassBorderView, frame: NSRect)] = [:]
    /// Weights and pointer position at the moment a handle drag began, so every tick is measured
    /// from the start rather than accumulating rounding from the previous one.
    private var handleDragStart: [ObjectIdentifier: (before: CGFloat, after: CGFloat, mouse: CGPoint)] = [:]
    /// The handle currently being dragged. Its panel is left where it is for the duration: moving
    /// it out from under the pointer mid-drag is how a resize turns into a fight.
    private var draggingHandle: ObjectIdentifier? = nil
    private var handleLayoutTask: Task<Void, Never>? = nil
    private var pendingHandleDrag: HandleSpec? = nil
    private let titles = WindowTitleCache()
    private let frames = WindowFrameCache()
    private let alerts = WindowAlertCache()

    private init() {}

    func refresh() {
        guard TrayMenuModel.shared.isEnabled else {
            hideAll()
            return
        }
        var borders: [BorderSpec] = []
        var tabBars: [TabBarSpec] = []
        var handles: [HandleSpec] = []
        let focusedWindowId = focus.windowOrNil?.windowId

        for monitor in monitors {
            let workspace = monitor.activeWorkspace
            // An aerospace-fullscreen window covers the whole workspace (same Space, unlike macOS
            // native fullscreen), so any decoration on this monitor would float on top of it
            if workspace.rootTilingContainer.mostRecentWindowRecursive?.isFullscreen == true { continue }
            collect(node: workspace.rootTilingContainer, focusedWindowId: focusedWindowId, &borders, &tabBars, &handles)
        }

        syncBorders(borders)
        syncTabBars(tabBars)
        syncHandles(handles)
        // Sheet state is read for the windows on screen only, and badge polling runs on its own
        // timer, so neither adds an AX round trip to the layout pass.
        alerts.prefetch(borders.map(\.windowId) + tabBars.flatMap { $0.windowIds }) { [weak self] in
            self?.refresh()
        }
        alerts.syncBadgePolling { [weak self] in self?.refresh() }
        titles.prefetch(tabBars.flatMap { $0.windowIds }) { [weak self] in
            // Titles arrive asynchronously from the AX API. Re-render the bars in place rather than
            // triggering another refresh session, which would loop.
            self?.rerenderTabBarTitles()
        }
    }

    /// Hand the manager a frame someone else has already read, so the borders can be drawn from it
    /// now rather than after the asynchronous fetch returns. See ``WindowFrameCache/record``.
    func noteObservedFrame(windowId: UInt32, applied: Rect, actual: Rect) {
        frames.record(windowId: windowId, applied: applied, actual: actual)
    }

    func hideAll() {
        for panel in borderPanels.values { panel.orderOut(nil) }
        for panel in tabPanels.values { panel.orderOut(nil) }
        for panel in handlePanels.values { panel.orderOut(nil) }
        GlassDropPreviewController.shared.hide()
    }

    // MARK: - Collecting

    private func collect(
        node: TreeNode,
        focusedWindowId: UInt32?,
        _ borders: inout [BorderSpec],
        _ tabBars: inout [TabBarSpec],
        _ handles: inout [HandleSpec],
    ) {
        switch node.nodeCases {
            case .window(let window):
                guard config.glass.borders.enabled,
                      let rect = window.lastAppliedLayoutPhysicalRect,
                      !window.isHiddenInCorner else { return }
                let isFocused = window.windowId == focusedWindowId
                let isAlerting = alerts.alert(for: window.windowId, appName: window.app.name) != nil
                // An alerting window is bordered even when unfocused borders are off. Being seen
                // from a window you aren't in is the entire point of the alert color.
                if isFocused || isAlerting || config.glass.borders.showInactive {
                    borders.append(BorderSpec(
                        windowId: window.windowId,
                        rect: rect,
                        isFocused: isFocused,
                        appBundleId: window.app.rawAppBundleId,
                        isAlerting: isAlerting,
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
                // A handle sits in each gap between adjacent tiles, which only exists in a `tiles`
                // container: stacked layouts share one rect, so there is no gap to grab.
                if config.glass.handles.enabled, container.layout == .tiles, container.children.count > 1 {
                    for (before, after) in zip(container.children, container.children.dropFirst()) {
                        if let gap = gapRect(between: before, and: after, container.orientation) {
                            handles.append(HandleSpec(
                                id: ObjectIdentifier(before),
                                rect: gap,
                                orientation: container.orientation,
                                before: before,
                                after: after,
                            ))
                        }
                    }
                }
                for child in visible {
                    collect(node: child, focusedWindowId: focusedWindowId, &borders, &tabBars, &handles)
                }
            case .workspace, .floatingWindowsContainer, .macosMinimizedWindowsContainer,
                 .macosFullscreenWindowsContainer, .macosPopupWindowsContainer,
                 .macosHiddenAppsWindowsContainer:
                return
        }
    }

    // MARK: - Borders

    private func syncBorders(_ specs: [BorderSpec]) {
        let cfg = config.glass.themed().borders
        var stale = Set(borderPanels.keys)
        for spec in specs {
            stale.remove(spec.windowId)
            // Draw around where the window really is, not where the layout pass put it — some
            // windows refuse the exact frame (terminals snap to their cell grid). The real frame
            // arrives asynchronously; until then the intended rect is the best guess.
            let rect = frames.actualRect(of: spec.windowId, applied: spec.rect) ?? spec.rect
            let outset = CGFloat(cfg.padding + cfg.width)
            let frame = rect.inset(by: -outset).toCocoaRect
            // An explicit per-app override wins over what the window server reports, which in turn
            // beats the one configured radius — that last one is only right by coincidence, since
            // windows disagree about their corners.
            let detected = cfg.detectCornerRadius ? WindowCornerRadius.of(spec.windowId) : nil
            let radius = spec.appBundleId.flatMap { cfg.appCornerRadius[$0] }
                ?? detected.map(Double.init)
                ?? cfg.cornerRadius
            // An alerting window takes the alert color whether or not it has focus: the whole
            // point is to be seen from a window you aren't in.
            let base = spec.isFocused ? cfg.activeColor : cfg.inactiveColor
            let ring = spec.isAlerting
                ? (config.glass.alerts.borderColor ?? cfg.activeColor.complement)
                : base
            let view = GlassBorderView(
                cornerRadius: CGFloat(radius) + outset,
                lineWidth: CGFloat(cfg.width),
                strokeWidth: CGFloat(cfg.strokeWidth),
                color: Color(ring.toNSColor),
            )
            let panel = borderPanels.getOrPut(spec.windowId) {
                renderedBorders[spec.windowId] = (view, frame)
                return GlassPanel(content: view, clickThrough: true)
            }
            let previous = renderedBorders[spec.windowId]
            if previous?.view != view {
                panel.rootView = view
            }
            if previous?.frame != frame {
                panel.setFrameInstantly(frame)
            }
            renderedBorders[spec.windowId] = (view, frame)
            panel.showIfNeeded()
        }
        for windowId in stale {
            borderPanels.removeValue(forKey: windowId)?.orderOut(nil)
            renderedBorders.removeValue(forKey: windowId)
        }
        WindowCornerRadius.forgetAllExcept(specs.map(\.windowId).toSet())
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

    // MARK: - Resize handles

    /// The gap between two adjacent tiles, widened to the configured hit area and centred on the
    /// gap itself so the strip stays where the eye expects it however wide the grab area is.
    private func gapRect(between before: TreeNode, and after: TreeNode, _ orientation: Orientation) -> Rect? {
        guard let a = before.lastAppliedLayoutPhysicalRect, let b = after.lastAppliedLayoutPhysicalRect else {
            return nil
        }
        let thickness = CGFloat(max(config.glass.handles.thickness, 4))
        if orientation == .h {
            let center = (a.maxX + b.minX) / 2
            return Rect(topLeftX: center - thickness / 2, topLeftY: a.topLeftY, width: thickness, height: a.height)
        } else {
            let center = (a.maxY + b.minY) / 2
            return Rect(topLeftX: a.topLeftX, topLeftY: center - thickness / 2, width: a.width, height: thickness)
        }
    }

    private func syncHandles(_ specs: [HandleSpec]) {
        var stale = Set(handlePanels.keys)
        let color = config.glass.handles.color ?? config.glass.themed().borders.activeColor
        for spec in specs {
            stale.remove(spec.id)
            let view = GlassResizeHandleView(
                orientation: spec.orientation,
                color: Color(color.toNSColor),
                onDragChanged: { [weak self] in
                    self?.handleDragged(spec)
                },
                onDragStarted: { [weak self] in
                    self?.draggingHandle = spec.id
                    isDraggingGlassHandle = true
                },
                onDragEnded: { [weak self] in
                    guard let self else { return }
                    self.handleDragStart.removeValue(forKey: spec.id)
                    self.draggingHandle = nil
                    self.pendingHandleDrag = nil
                    isDraggingGlassHandle = false
                    // One full session at the end puts the tree back through normalization, which
                    // the per-tick layout deliberately skips.
                    scheduleCancellableCompleteRefreshSession(.glassResizeHandle)
                },
            )
            let panel = handlePanels.getOrPut(spec.id) { GlassPanel(content: view, clickThrough: false) }
            // The handle being dragged keeps both its view and its frame: replacing the view
            // restarts the gesture, and moving the frame moves the target out from under the
            // pointer. It is repositioned once the drag ends.
            if spec.id != draggingHandle {
                panel.rootView = view
                panel.setFrameInstantly(spec.rect.toCocoaRect)
            }
            panel.showIfNeeded()
        }
        for id in stale {
            handlePanels.removeValue(forKey: id)?.orderOut(nil)
            handleDragStart.removeValue(forKey: id)
        }
    }

    /// A drag tick. Ticks arrive far faster than windows can actually be moved, so the newest one
    /// is remembered and applied as soon as the previous layout pass finishes. Running a complete
    /// refresh session per tick — window detection, focus round trips, normalization, two layout
    /// passes — is what made this crawl, and cancelling the previous session on every tick meant
    /// hardly any of them ever finished.
    private func handleDragged(_ spec: HandleSpec) {
        pendingHandleDrag = spec
        guard handleLayoutTask == nil else { return }
        pumpHandleDrag()
    }

    private func pumpHandleDrag() {
        guard let spec = pendingHandleDrag else {
            handleLayoutTask = nil
            return
        }
        pendingHandleDrag = nil
        guard spec.before.isBound, spec.after.isBound else { return }

        let start = handleDragStart.getOrPut(spec.id) {
            (spec.before.getWeight(spec.orientation), spec.after.getWeight(spec.orientation), mouseLocation)
        }
        // Measured against the pointer's own position, so the handle's panel moving underneath it
        // can't feed back into the delta.
        let delta = spec.orientation == .h
            ? mouseLocation.x - start.mouse.x
            : mouseLocation.y - start.mouse.y
        // Neither side may be squeezed out of existence: past the minimum the drag simply stops
        // rather than collapsing a window you would then have to hunt for.
        let minimum: CGFloat = 80
        guard start.before + start.after > minimum * 2 else { return }
        let clamped = min(max(delta, minimum - start.before), start.after - minimum)
        spec.before.setWeight(spec.orientation, start.before + clamped)
        spec.after.setWeight(spec.orientation, start.after - clamped)

        handleLayoutTask = Task.startUnstructured { @MainActor [weak self] in
            // Just the layout: the tree hasn't changed shape, only two weights, so none of the
            // detection or normalization a full session does has anything to say here.
            try? await layoutWorkspaces()
            guard let self else { return }
            self.handleLayoutTask = nil
            self.pumpHandleDrag()
        }
    }

    // MARK: - Tab bars

    private func syncTabBars(_ specs: [TabBarSpec]) {
        var stale = Set(tabPanels.keys)
        for spec in specs {
            stale.remove(spec.container)
            let panel = tabPanels.getOrPut(spec.container) {
                GlassPanel(content: tabBarView(spec), clickThrough: false)
            }
            panel.rootView = tabBarView(spec)
            // Middle-drag anywhere on the bar picks up the whole group and moves it as one node
            // through the same drop targets a single window resolves against
            panel.onMiddleDrag = { [group = spec.group] phase in
                switch phase {
                    case .began, .moved:
                        groupDragChanged(group: group)
                    case .ended:
                        Task.startUnstructured { @MainActor in
                            await groupDragEnded(group: group)
                        }
                }
            }
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
        let cfg = config.glass.themed().tabs
        let items = spec.windowIds.map { windowId -> GlassTabItem in
            let window = Window.get(byId: windowId)
            return GlassTabItem(
                id: windowId,
                title: titles.title(of: windowId) ?? window?.app.name ?? "Window \(windowId)",
                icon: (window as? MacWindow)?.macApp.nsApp.icon,
                isActive: windowId == spec.activeWindowId,
                isAlerting: alerts.alert(for: windowId, appName: window?.app.name) != nil,
            )
        }
        return GlassTabBarView(
            items: items,
            cornerRadius: CGFloat(cfg.cornerRadius),
            fontSize: CGFloat(cfg.fontSize),
            showIcons: cfg.showIcons,
            fixedWidth: cfg.fixedWidth ? CGFloat(cfg.width) : nil,
            isFlat: cfg.style == .flat,
            barTint: Color(cfg.barTint.toNSColor),
            inactiveTint: Color(cfg.inactiveTint.toNSColor),
            activeTint: Color(cfg.activeTint.toNSColor),
            alertTint: Color((config.glass.alerts.tabTint ?? cfg.activeTint.complement).toNSColor),
            // A configured label color wins; otherwise it is derived from the fill it sits on.
            activeForeground: Color((cfg.activeTextColor ?? cfg.activeTint.legibleGlassColor).toNSColor),
            inactiveForeground: Color((cfg.textColor ?? cfg.inactiveTint.legibleGlassColor).toNSColor),
            activeBorder: cfg.activeBorderColor.map { Color($0.toNSColor) },
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
    GlassDropPreviewController.shared.update(point: point, target: resolveDropTarget(point, dragged: dragged), dragged: dragged)
}

@MainActor
private func tabDragEnded(windowId: UInt32, group: TilingContainer?, translation: CGSize) async {
    GlassDropPreviewController.shared.hide()
    guard let window = Window.get(byId: windowId) else { return }
    guard let guardd = RunSessionGuard.isServerEnabled else { return }
    try? await runLightSession(.glassTabBarDrop, guardd) {
        guard let group, let dragged = tabDragNode(windowId: windowId, group: group) else { return }
        let target = resolveDropTarget(mouseLocation, dragged: dragged)
        // Shuffling tabs among their own siblings changes the order and nothing else. Whichever tab
        // was showing keeps showing, so that reordering the bar can't pull the rug out from under
        // the window being worked in. Every other drop moves the window somewhere new, and focus
        // should follow it there.
        var isReorderWithinBar = false
        if case .tabBar(let targetGroup, _) = target, dragged.parent === targetGroup {
            isReorderWithinBar = true
        }
        let wasShowing = group.mostRecentChild

        if let target {
            applyDrop(target, dragged: dragged)
        } else if abs(translation.height) > tabTearOffThreshold {
            // Dropped on nothing in particular but clearly outside the bar: the browser tear-off
            // gesture. The tab leaves the group and becomes a tile right next to it.
            tearOutOfTabGroup(dragged, from: group)
        } else {
            return // A drop on its own tab or another dead zone: the tab snaps back
        }

        if isReorderWithinBar {
            // Rebinding the node during the move marks it most recent, so the tab that was showing
            // has to be put back on top explicitly.
            if let wasShowing, wasShowing.parent === group { wasShowing.markAsMostRecentChild() }
        } else {
            _ = window.focusWindow()
        }
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

/// A tick of a middle-button drag on a tab bar: the dragged node is the whole group.
@MainActor
private func groupDragChanged(group: TilingContainer?) {
    guard let group, group.isBound, group.layout == .tabbed else { return }
    let point = mouseLocation
    GlassDropPreviewController.shared.update(point: point, target: resolveDropTarget(point, dragged: group), dragged: group)
}

@MainActor
private func groupDragEnded(group: TilingContainer?) async {
    GlassDropPreviewController.shared.hide()
    guard let group, group.isBound, group.layout == .tabbed else { return }
    guard let guardd = RunSessionGuard.isServerEnabled else { return }
    try? await runLightSession(.glassTabBarDrop, guardd) {
        // A plain middle-click resolves to the group's own cell, which is a dead zone: no-op
        guard let target = resolveDropTarget(mouseLocation, dragged: group) else { return }
        applyDrop(target, dragged: group)
        _ = group.mostRecentWindowRecursive?.focusWindow()
    }
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
    let isAlerting: Bool
}

private struct HandleSpec {
    let id: ObjectIdentifier
    let rect: Rect
    let orientation: Orientation
    let before: TreeNode
    let after: TreeNode
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
