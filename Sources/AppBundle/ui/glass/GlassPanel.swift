import AppKit
import SwiftUI

/// Base class for the decorations this fork draws on top of managed windows.
///
/// Unlike ``NSPanelHud`` these panels are not HUDs: they are unshadowed, they sit at a level just
/// above ordinary windows, and they are repositioned on every layout pass, so they must never
/// animate their frame changes.
class GlassPanel<Content: View>: NSPanel {
    private var hostingView: NSHostingView<Content>

    init(content: Content, clickThrough: Bool) {
        hostingView = NSHostingView(rootView: content)
        super.init(
            contentRect: .zero,
            styleMask: [.nonactivatingPanel, .borderless],
            backing: .buffered,
            defer: false,
        )
        // Above normal windows, below the menu bar and below HUD panels such as SecureInputPanel
        level = NSWindow.Level(Int(CGWindowLevelForKey(.floatingWindow)))
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle, .stationary]
        isReleasedWhenClosed = false
        hidesOnDeactivate = false
        isMovableByWindowBackground = false
        isOpaque = false
        hasShadow = false
        backgroundColor = .clear
        ignoresMouseEvents = clickThrough
        // Decorations must never steal focus from the window they decorate
        becomesKeyOnlyIfNeeded = true

        hostingView.autoresizingMask = [.width, .height]
        contentView = NSView()
        contentView?.addSubview(hostingView)
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    var rootView: Content {
        get { hostingView.rootView }
        set { hostingView.rootView = newValue }
    }

    /// Move the panel without implicit animation. The window manager repositions decorations on
    /// every refresh, and Core Animation's default 0.25s frame animation would smear them across
    /// the screen behind the windows they belong to.
    func setFrameInstantly(_ frame: NSRect) {
        guard self.frame != frame else { return }
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0
            ctx.allowsImplicitAnimation = false
            setFrame(frame, display: false)
        }
        hostingView.frame = NSRect(origin: .zero, size: frame.size)
    }

    func showIfNeeded() {
        if !isVisible { orderFrontRegardless() }
    }
}
