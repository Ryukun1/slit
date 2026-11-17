import AppKit
import SwiftUI

/// Decides whether Slit shows up in the Dock and the ⌘-Tab switcher.
///
/// Slit lives in the menu bar, and macOS leaves menu-bar-only apps out of
/// both, which made the Settings window unreachable with ⌘-Tab once another
/// app covered it. So while one of Slit's own windows is open it becomes a
/// regular app, and goes back to menu-bar-only when the last one closes.
@MainActor
final class AppPresence {
    static let shared = AppPresence()

    private enum Icon {
        static let canvas: CGFloat = 256
        /// Dock icons leave a margin around the artwork.
        static let margin: CGFloat = 26
        static let scale: CGFloat = 2
    }

    private let applyPolicy: (NSApplication.ActivationPolicy) -> Void
    private var closeObservers: [ObjectIdentifier: NSObjectProtocol] = [:]

    init(
        applyPolicy: @escaping (NSApplication.ActivationPolicy) -> Void = {
            NSApp.setActivationPolicy($0)
        }
    ) {
        self.applyPolicy = applyPolicy
    }

    var hasOpenWindows: Bool { !closeObservers.isEmpty }

    /// Call when one of Slit's regular windows is shown or brought forward.
    func windowOpened(_ window: NSWindow) {
        let id = ObjectIdentifier(window)
        guard closeObservers[id] == nil else { return }

        closeObservers[id] = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification, object: window, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.windowClosed(id)
            }
        }
        applyPolicy(.regular)
    }

    private func windowClosed(_ id: ObjectIdentifier) {
        guard let observer = closeObservers.removeValue(forKey: id) else { return }
        NotificationCenter.default.removeObserver(observer)
        applyPolicy(hasOpenWindows ? .regular : .accessory)
    }

    /// Slit ships without an icon file, so the Dock and ⌘-Tab would show the
    /// generic app icon. Draw the logo and use that while running.
    func installAppIcon() {
        let artwork = LogoView(size: Icon.canvas - Icon.margin * 2)
            .padding(Icon.margin)
        let renderer = ImageRenderer(content: artwork)
        renderer.scale = Icon.scale
        guard let image = renderer.nsImage else { return }
        NSApp.applicationIconImage = image
    }
}
