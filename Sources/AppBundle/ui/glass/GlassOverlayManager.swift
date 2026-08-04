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
                    borders.append(BorderSpec(windowId: window.windowId, rect: rect, isFocused: isFocused))
                }
            case .tilingContainer(let container):
                if config.glass.tabs.enabled, container.layout == .tabbed, let barRect = container.lastAppliedTabBarRect {
                    let windows = container.children.compactMap { $0.allLeafWindowsRecursive.first }
                    if !windows.isEmpty {
                        tabBars.append(TabBarSpec(
                            container: ObjectIdentifier(container),
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
            let outset = CGFloat(cfg.padding + cfg.width)
            let frame = spec.rect.inset(by: -outset).toCocoaRect
            let view = GlassBorderView(
                cornerRadius: CGFloat(cfg.cornerRadius) + outset,
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

private struct BorderSpec {
    let windowId: UInt32
    let rect: Rect
    let isFocused: Bool
}

private struct TabBarSpec {
    let container: ObjectIdentifier
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
