import AppKit
import Common

/// i3 keeps floating windows above the tiled layer. macOS offers no way to pin another process's
/// window at a higher level, so this is approximated the way raise-based window managers do it: at
/// the end of every refresh session, any floating window that ended up beneath a tiled window is
/// raised with the Accessibility raise action (which does not shift focus).
///
/// Only windows that are actually buried are raised. In the steady state — floats already on top —
/// no AX calls are made at all, which is what guarantees the raise -> AX notification -> refresh
/// cycle terminates instead of ping-ponging forever.
@MainActor
func raiseFloatingWindows() {
    guard config.floatingWindowsOnTop else { return }
    // Front-to-back order of everything on screen. Window ids and their ordering are public
    // information — unlike titles, they don't require the Screen Recording permission.
    guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else { return }
    var zIndex: [UInt32: Int] = [:] // smaller index = closer to the front
    for (index, info) in list.enumerated() {
        if let id = (info[kCGWindowNumber as String] as? NSNumber)?.uint32Value {
            zIndex[id] = index
        }
    }
    let focused = focus.windowOrNil
    for monitor in monitors {
        let workspace = monitor.activeWorkspace
        guard let frontmostTiledZ = workspace.rootTilingContainer.allLeafWindowsRecursive
            .compactMap({ zIndex[$0.windowId] })
            .min() else { continue }
        let buried = workspace.floatingWindows
            .filter { zIndex[$0.windowId].map { $0 > frontmostTiledZ } == true }
            .sorted { (zIndex[$0.windowId] ?? .max) > (zIndex[$1.windowId] ?? .max) } // raise backmost first to keep their relative order
        for window in buried {
            window.nativeRaise()
        }
        // Raising buried floats must not cover the focused floating window
        if let focused, !buried.isEmpty, buried.last != focused,
           focused.parent is FloatingWindowsContainer, focused.nodeWorkspace == workspace
        {
            focused.nativeRaise()
        }
    }
}
