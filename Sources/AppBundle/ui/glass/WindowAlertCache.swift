import AppKit

/// Which windows are asking for attention, and why.
///
/// Two unrelated signals, deliberately kept apart because they mean different things and are read
/// in completely different ways:
///
/// - **Sheet** — the window is blocked on a dialog. Per window, and precise. The documented
///   `AXSheets` attribute comes back empty for the sheets AppKit actually puts up and `AXModal`
///   stays false on the parent, so the signal that works is a child element with role `AXSheet`.
///   Read asynchronously for visible windows only, like titles, so a stalled app can't stall the
///   layout pass.
/// - **Badge** — the app has an unread count on its Dock icon. Per *app*, so every window of that
///   app is flagged, and only as accurate as the app's own badging. There is no notification when a
///   badge changes, so the Dock's accessibility tree is polled on a slow timer, well away from the
///   layout path.
@MainActor
final class WindowAlertCache {
    enum Alert {
        /// Blocked on an attached dialog.
        case sheet
        /// The app's Dock icon carries a badge.
        case badge
    }

    private var sheets: Set<UInt32> = []
    private var inFlight: Set<UInt32> = []
    private var badgedApps: Set<String> = []
    private var badgeTimer: Timer?
    private var onBadgeChange: (@MainActor () -> ())?

    /// Why this window is alerting, or nil. A sheet outranks a badge: being blocked on a dialog is
    /// about this window, where a badge is only about the app it belongs to.
    func alert(for windowId: UInt32, appName: String?) -> Alert? {
        if config.glass.alerts.onSheet, sheets.contains(windowId) { return .sheet }
        if config.glass.alerts.onBadge, let appName, badgedApps.contains(appName) { return .badge }
        return nil
    }

    /// Refresh sheet state for the windows currently on screen, and drop anything else.
    /// `onUpdate` fires when a window's state actually changed.
    func prefetch(_ windowIds: [UInt32], onUpdate: @escaping @MainActor () -> ()) {
        guard config.glass.alerts.onSheet else {
            if !sheets.isEmpty { sheets.removeAll(); onUpdate() }
            return
        }
        let wanted = Set(windowIds)
        let dropped = sheets.subtracting(wanted)
        sheets.subtract(dropped)

        for windowId in wanted where !inFlight.contains(windowId) {
            guard let window = Window.get(byId: windowId) as? MacWindow else { continue }
            inFlight.insert(windowId)
            Task.startUnstructured { @MainActor [weak self] in
                let hasSheet = (try? await window.hasSheet(.nonCancellable)) ?? false
                guard let self else { return }
                self.inFlight.remove(windowId)
                let had = self.sheets.contains(windowId)
                guard had != hasSheet else { return }
                if hasSheet { self.sheets.insert(windowId) } else { self.sheets.remove(windowId) }
                onUpdate()
            }
        }
    }

    // MARK: - Dock badges

    /// Start or stop polling depending on whether anything is asking for badges.
    func syncBadgePolling(onChange: @escaping @MainActor () -> ()) {
        onBadgeChange = onChange
        let wanted = config.glass.alerts.onBadge
        if wanted, badgeTimer == nil {
            let interval = max(config.glass.alerts.badgePollSeconds, 1)
            badgeTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { _ in
                Task.startUnstructured { @MainActor [weak self] in self?.pollBadges() }
            }
            pollBadges()
        } else if !wanted, badgeTimer != nil {
            badgeTimer?.invalidate()
            badgeTimer = nil
            if !badgedApps.isEmpty { badgedApps.removeAll(); onChange() }
        }
    }

    private func pollBadges() {
        let current = WindowAlertCache.readDockBadges()
        guard current != badgedApps else { return }
        badgedApps = current
        onBadgeChange?()
    }

    /// The names of apps whose Dock icon currently shows a badge.
    ///
    /// The badge lives on the Dock's own accessibility tree as `AXStatusLabel`. Its contents are
    /// whatever the app asked for — a count, or a dot for apps configured to show one — so the only
    /// thing read from it is whether there is anything there at all.
    private static func readDockBadges() -> Set<String> {
        guard let dock = NSRunningApplication
            .runningApplications(withBundleIdentifier: "com.apple.dock").first
        else { return [] }
        let axDock = AXUIElementCreateApplication(dock.processIdentifier)
        func attribute(_ element: AXUIElement, _ key: String) -> CFTypeRef? {
            var value: CFTypeRef?
            return AXUIElementCopyAttributeValue(element, key as CFString, &value) == .success ? value : nil
        }
        guard let lists = attribute(axDock, kAXChildrenAttribute) as? [AXUIElement] else { return [] }
        var badged: Set<String> = []
        for list in lists {
            guard let items = attribute(list, kAXChildrenAttribute) as? [AXUIElement] else { continue }
            for item in items {
                guard let title = attribute(item, kAXTitleAttribute) as? String,
                      let badge = attribute(item, "AXStatusLabel") as? String,
                      !badge.isEmpty
                else { continue }
                badged.insert(title)
            }
        }
        return badged
    }
}
