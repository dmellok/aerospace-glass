import AppKit

/// Where a window actually is, as opposed to where the layout pass put it. Some windows refuse the
/// exact frame they are given — terminals snap to their cell grid, other apps enforce minimum
/// sizes — and a border drawn around the intended rect visibly floats around such a window.
///
/// Like titles, actual frames come from the Accessibility API asynchronously: borders render from
/// the intended rect immediately and are nudged onto the real frame once it lands, so a stalled
/// app can never stall the layout pass.
@MainActor
final class WindowFrameCache {
    private var cache: [UInt32: (applied: Rect, actual: Rect)] = [:]
    private var inFlight: Set<UInt32> = []

    /// The last known actual frame, valid only while the layout pass still targets `applied`.
    func actualRect(of windowId: UInt32, applied: Rect) -> Rect? {
        guard let entry = cache[windowId], entry.applied.approximatelyEquals(applied) else { return nil }
        return entry.actual
    }

    /// Fetch the actual frame of every window whose applied rect changed since the last fetch, and
    /// drop entries we no longer decorate. `onUpdate` fires once per window that turned out to sit
    /// somewhere other than where the layout pass put it.
    func prefetch(_ windows: [(windowId: UInt32, applied: Rect)], onUpdate: @escaping @MainActor () -> ()) {
        let wanted = windows.map(\.windowId).toSet()
        for stale in cache.keys where !wanted.contains(stale) {
            cache.removeValue(forKey: stale)
        }
        for (windowId, applied) in windows {
            if inFlight.contains(windowId) || cache[windowId]?.applied.approximatelyEquals(applied) == true { continue }
            guard let window = Window.get(byId: windowId) else { continue }
            inFlight.insert(windowId)
            Task.startUnstructured { @MainActor [weak self] in
                let actual = try? await window.getAxRect(.nonCancellable)
                guard let self else { return }
                self.inFlight.remove(windowId)
                guard let actual else { return }
                self.cache[windowId] = (applied, actual)
                if !actual.approximatelyEquals(applied) { onUpdate() }
            }
        }
    }
}

extension Rect {
    /// Float-tolerant equality. Differences under a point are invisible under a 2-3pt border
    /// stroke, and treating them as real would nudge panels around forever.
    fileprivate func approximatelyEquals(_ other: Rect) -> Bool {
        abs(topLeftX - other.topLeftX) < 1 && abs(topLeftY - other.topLeftY) < 1
            && abs(width - other.width) < 1 && abs(height - other.height) < 1
    }
}
