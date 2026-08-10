import AppKit
import SwiftUI

/// The window hosting ``GlassSettingsView``.
///
/// A plain `NSWindow` rather than a SwiftUI `Settings` scene: AeroSpace runs as an accessory app
/// with no Dock icon, and this has to be openable from the menu bar and brought forward on a second
/// click rather than opening twice.
@MainActor
enum GlassSettingsWindow {
    private static var window: NSWindow?

    static func open() {
        if let window {
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            return
        }
        let hosting = NSHostingController(rootView: GlassSettingsView())
        let window = NSWindow(contentViewController: hosting)
        window.title = "Glass Settings"
        window.styleMask = [.titled, .closable, .miniaturizable]
        window.isReleasedWhenClosed = false
        window.center()
        // AeroSpace manages windows, and a settings panel that its own tiler grabbed and resized
        // would be absurd. Floating keeps it out of the tiling tree.
        window.level = .floating
        self.window = window
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }
}
