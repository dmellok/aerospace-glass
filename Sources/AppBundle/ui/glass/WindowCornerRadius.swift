import AppKit

/// The corner radius a window is actually drawn with, asked of the window server.
///
/// A border ring only looks right if its corners match the window's, and windows disagree: on
/// macOS 26 a Safari window is 26pt and a VS Code window is 16pt. A single configured radius is
/// wrong for one of them, which is why `glass.borders.app-corner-radius` exists as an escape
/// hatch — a table nobody wants to maintain by hand.
///
/// `SLSWindowIteratorGetCornerRadii` reports the real value, but it is a private SkyLight symbol,
/// so it is resolved with `dlsym` at startup rather than linked. When it is missing — anything
/// before macOS 26, or a release where Apple drops it — every lookup returns nil and the caller
/// falls back to the configured radius. Nothing here is load-bearing: the feature degrades to
/// exactly the behaviour that came before it.
@MainActor
enum WindowCornerRadius {
    private typealias FnMainConnectionID = @convention(c) () -> Int32
    private typealias FnQueryWindows = @convention(c) (Int32, CFArray, UInt32) -> Unmanaged<CFTypeRef>?
    private typealias FnQueryResultCopyWindows = @convention(c) (CFTypeRef) -> Unmanaged<CFTypeRef>?
    private typealias FnIteratorGetCount = @convention(c) (CFTypeRef) -> Int32
    private typealias FnIteratorAdvance = @convention(c) (CFTypeRef) -> Bool
    private typealias FnIteratorGetCornerRadii = @convention(c) (CFTypeRef) -> Unmanaged<CFArray>?

    private struct SkyLight {
        let connectionId: Int32
        let queryWindows: FnQueryWindows
        let queryResultCopyWindows: FnQueryResultCopyWindows
        let iteratorGetCount: FnIteratorGetCount
        let iteratorAdvance: FnIteratorAdvance
        let iteratorGetCornerRadii: FnIteratorGetCornerRadii
    }

    private static let skyLight: SkyLight? = {
        guard let lib = dlopen(
            "/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight",
            RTLD_LAZY | RTLD_LOCAL,
        ) else { return nil }
        func symbol<T>(_ name: String, _ type: T.Type) -> T? {
            dlsym(lib, name).map { unsafeBitCast($0, to: type) }
        }
        guard let mainConnectionId = symbol("SLSMainConnectionID", FnMainConnectionID.self),
              let queryWindows = symbol("SLSWindowQueryWindows", FnQueryWindows.self),
              let queryResultCopyWindows = symbol("SLSWindowQueryResultCopyWindows", FnQueryResultCopyWindows.self),
              let iteratorGetCount = symbol("SLSWindowIteratorGetCount", FnIteratorGetCount.self),
              let iteratorAdvance = symbol("SLSWindowIteratorAdvance", FnIteratorAdvance.self),
              let iteratorGetCornerRadii = symbol("SLSWindowIteratorGetCornerRadii", FnIteratorGetCornerRadii.self)
        else { return nil }
        return SkyLight(
            connectionId: mainConnectionId(),
            queryWindows: queryWindows,
            queryResultCopyWindows: queryResultCopyWindows,
            iteratorGetCount: iteratorGetCount,
            iteratorAdvance: iteratorAdvance,
            iteratorGetCornerRadii: iteratorGetCornerRadii,
        )
    }()

    /// True when the window server can be asked at all. False on older macOS, where every lookup
    /// returns nil.
    static var isAvailable: Bool { skyLight != nil }

    /// nil is cached too: a window that reports nothing keeps reporting nothing, and the query is
    /// a synchronous round trip to the window server on the layout path.
    private static var cache: [UInt32: CGFloat?] = [:]

    /// The window's own corner radius, or nil when it can't be determined.
    static func of(_ windowId: UInt32) -> CGFloat? {
        if let cached = cache[windowId] { return cached }
        let radius = query(windowId)
        cache[windowId] = radius
        return radius
    }

    static func forget(_ windowId: UInt32) {
        cache.removeValue(forKey: windowId)
    }

    static func forgetAllExcept(_ live: Set<UInt32>) {
        cache = cache.filter { live.contains($0.key) }
    }

    private static func query(_ windowId: UInt32) -> CGFloat? {
        guard let sky = skyLight else { return nil }
        let targets = [windowId] as CFArray
        guard let query = sky.queryWindows(sky.connectionId, targets, 0)?.takeRetainedValue(),
              let iterator = sky.queryResultCopyWindows(query)?.takeRetainedValue(),
              sky.iteratorGetCount(iterator) > 0,
              sky.iteratorAdvance(iterator),
              let radii = sky.iteratorGetCornerRadii(iterator)?.takeRetainedValue() as? [NSNumber],
              // The four corners come back separately. They agree on every window seen so far, and
              // the ring can only be drawn with one radius, so take the first.
              let first = radii.first
        else { return nil }
        let radius = CGFloat(first.doubleValue)
        return radius > 0 ? radius : nil
    }
}
