import AppKit
import SwiftUI

/// A borderless, transparent, click-through window used as a screen overlay.
final class OverlayWindow: NSWindow {
    init(screen: NSScreen) {
        super.init(
            contentRect: screen.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        self.level = .screenSaver
        self.isOpaque = false
        self.backgroundColor = .clear
        self.ignoresMouseEvents = true
        self.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        self.sharingType = .none
        self.hasShadow = false
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    /// Set the SwiftUI content view.
    func setOverlayContent<V: View>(_ view: V) {
        contentView = NSHostingView(rootView: view)
    }
}
