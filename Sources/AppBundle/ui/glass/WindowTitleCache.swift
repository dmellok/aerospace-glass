import AppKit

/// Window titles come from the Accessibility API, which is asynchronous and can be slow for a
/// misbehaving app. The tab bar renders from this cache immediately and refreshes itself once the
/// real titles land, so a stalled app can never stall the layout pass.
@MainActor
final class WindowTitleCache {
    private var cache: [UInt32: String] = [:]
    private var inFlight: Set<UInt32> = []

    func title(of windowId: UInt32) -> String? {
        guard let title = cache[windowId], !title.isEmpty else { return nil }
        return title
    }

    /// Kick off a fetch for every id that isn't cached yet, and drop entries we no longer render.
    /// `onUpdate` fires once per title that actually changed.
    func prefetch(_ windowIds: [UInt32], onUpdate: @escaping @MainActor () -> ()) {
        let wanted = Set(windowIds)
        for stale in cache.keys where !wanted.contains(stale) {
            cache.removeValue(forKey: stale)
        }
        for windowId in wanted where !inFlight.contains(windowId) {
            guard let window = Window.get(byId: windowId) else { continue }
            inFlight.insert(windowId)
            Task.startUnstructured { @MainActor [weak self] in
                let title = try? await window.getTitle(.nonCancellable)
                guard let self else { return }
                self.inFlight.remove(windowId)
                guard let title, !title.isEmpty, self.cache[windowId] != title else { return }
                self.cache[windowId] = title
                onUpdate()
            }
        }
    }
}
