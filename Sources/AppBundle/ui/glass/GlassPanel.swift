import AppKit
import SwiftUI

/// Base class for the decorations this fork draws on top of managed windows.
///
/// Unlike ``NSPanelHud`` these panels are not HUDs: they are unshadowed, they sit just above
/// ordinary windows, and they are repositioned on every layout pass, so they must never animate.
class GlassPanel<Content: View>: NSPanel {
    private let hostingView: NSHostingView<Content>

    init(content: Content, clickThrough: Bool) {
        hostingView = GlassHostingView(rootView: content)
        super.init(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false,
        )
        isFloatingPanel = true
        // Assign after isFloatingPanel, which itself sets the level. .floating (3) sits above
        // ordinary windows but stays clipped below the menu bar, which is what we want.
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        isReleasedWhenClosed = false
        hidesOnDeactivate = false
        isMovableByWindowBackground = false
        // NSWindow.isOpaque is true even for borderless windows. Without this the panel renders as
        // a black rectangle no matter what backgroundColor says.
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        animationBehavior = .none
        ignoresMouseEvents = clickThrough
        // Keep the window manager from trying to tile its own decorations
        setAccessibilitySubrole(.unknown)

        hostingView.autoresizingMask = [.width, .height]
        contentView = NSView()
        contentView?.addSubview(hostingView)
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    /// AppKit otherwise clamps panel frames into the screen's `visibleFrame`, which would shove a
    /// decoration belonging to a window near the screen edge out of alignment with it.
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }

    var rootView: Content {
        get { hostingView.rootView }
        set { hostingView.rootView = newValue }
    }

    /// Move the panel without implicit animation. The window manager repositions decorations on
    /// every refresh, and Core Animation's default frame animation would smear them across the
    /// screen behind the windows they belong to.
    func setFrameInstantly(_ frame: NSRect) {
        guard self.frame != frame else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        setFrame(frame, display: false)
        hostingView.frame = NSRect(origin: .zero, size: frame.size)
        CATransaction.commit()
    }

    func showIfNeeded() {
        // Never makeKeyAndOrderFront: that would activate the app and steal focus
        if !isVisible { orderFrontRegardless() }
    }
}

/// Without `acceptsFirstMouse` the first click on a tab is swallowed, because the panel's app is
/// not the active one — which is the normal state for a decoration.
private final class GlassHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}
