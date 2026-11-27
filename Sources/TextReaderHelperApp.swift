import SwiftUI
import AppKit
import Combine

/// Plain AppKit entry point. Slit lives in the menu bar and owns its windows
/// itself, so it declares no SwiftUI scenes: the placeholder `Settings` scene
/// it used to declare opened an empty "Slit Settings" window at every launch.
@main
enum SlitMain {
    @MainActor
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        // `NSApplication.delegate` is weak; keep the delegate alive for the run.
        withExtendedLifetime(delegate) {
            app.run()
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?
    private var overlayWindow: OverlayWindow?
    private var settingsWindow: NSWindow?
    private var splashWindow: NSWindow?
    private var eventMonitor: EventMonitor?
    private let appState = AppState()
    private var overlayVisibilityObservation: AnyCancellable?
    private var accessibilityObservation: AnyCancellable?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Menu-bar only until one of Slit's windows opens; `AppPresence`
        // switches it into the Dock and ⌘-Tab for as long as one is.
        NSApp.setActivationPolicy(.accessory)
        AppPresence.shared.installAppIcon()
        AppSettings.shared.resolveConflicts()

        // Without a SwiftUI scene there is no default main menu, and with no
        // main menu ⌘W, ⌘Q and ⌘, do nothing in Slit's own windows.
        NSApp.mainMenu = MainMenu.make(
            settingsTarget: self, settingsAction: #selector(openSettings),
            updatesItem: Updater.shared.makeMenuItem()
        )

        // Set up menu bar
        setupMenuBar()

        // Set up overlay window
        setupOverlayWindow()

        // Event monitoring needs Accessibility. Start it the moment that is
        // granted: straight away if it already is, otherwise as soon as the
        // switch is turned on in System Settings, with no relaunch.
        eventMonitor = EventMonitor(appState: appState)
        accessibilityObservation = Permissions.shared.$accessibility
            .removeDuplicates()
            .filter { $0 }
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.eventMonitor?.start()
            }

        // Nothing works without both permissions, so say so up front, in a
        // window that explains each one and updates by itself.
        if !Permissions.shared.allGranted {
            PermissionsWindowController.shared.show()
        }

        // The overlay window is on screen only while it has something to
        // draw. Each of these can change that, so re-evaluate after any of
        // them, once the new value is in place.
        overlayVisibilityObservation = Publishers.MergeMany(
            appState.$mode.map { _ in () }.eraseToAnyPublisher(),
            appState.$optionAreaStart.map { _ in () }.eraseToAnyPublisher(),
            appState.$debugBlocksVisible.map { _ in () }.eraseToAnyPublisher(),
            appState.$previewRect.map { _ in () }.eraseToAnyPublisher()
        )
        .receive(on: RunLoop.main)
        .sink { [weak self] in
            self?.updateOverlayVisibility()
        }

        print("TextReaderHelper is running. Press Command to activate.")
    }

    // MARK: - Launch splash

    private func showLaunchSplash() {
        let splashView = SplashView()
        let hosting = NSHostingView(rootView: splashView)
        hosting.frame = NSRect(x: 0, y: 0, width: 220, height: 240)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 220, height: 240),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.level = .floating
        window.isReleasedWhenClosed = false
        window.collectionBehavior = [.canJoinAllSpaces, .transient, .ignoresCycle]
        window.contentView = hosting

        if let screen = NSScreen.main {
            let sf = screen.visibleFrame
            let origin = NSPoint(
                x: sf.midX - 110,
                y: sf.midY - 120
            )
            window.setFrameOrigin(origin)
        }

        window.alphaValue = 0
        window.orderFrontRegardless()
        splashWindow = window

        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.35
            window.animator().alphaValue = 1
        })

        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) { [weak self, weak window] in
            guard let window else { return }
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = 0.5
                window.animator().alphaValue = 0
            }, completionHandler: {
                Task { @MainActor in
                    window.orderOut(nil)
                    self?.splashWindow = nil
                }
            })
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        eventMonitor?.stop()
    }

    // MARK: - Setup

    private func setupMenuBar() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = statusItem?.button {
            button.image = Self.menuBarIcon()
            button.image?.isTemplate = true
        }

        let menu = NSMenu()

        let titleItem = NSMenuItem(title: "Text Reader Helper", action: nil, keyEquivalent: "")
        titleItem.attributedTitle = NSAttributedString(
            string: "Text Reader Helper",
            attributes: [.font: NSFont.systemFont(ofSize: 13, weight: .semibold)]
        )
        menu.addItem(titleItem)

        let subtitleItem = NSMenuItem(title: "⌘ Click to start reading", action: nil, keyEquivalent: "")
        subtitleItem.attributedTitle = NSAttributedString(
            string: "⌘ + Click to start reading",
            attributes: [
                .font: NSFont.systemFont(ofSize: 11),
                .foregroundColor: NSColor.secondaryLabelColor
            ]
        )
        menu.addItem(subtitleItem)

        menu.addItem(NSMenuItem.separator())

        let settingsItem = NSMenuItem(title: "Settings...", action: #selector(openSettings), keyEquivalent: ",")
        settingsItem.target = self
        settingsItem.image = NSImage(systemSymbolName: "gearshape", accessibilityDescription: "Settings")
        menu.addItem(settingsItem)

        let permissionsItem = NSMenuItem(
            title: "Permissions…", action: #selector(openPermissions), keyEquivalent: ""
        )
        permissionsItem.target = self
        permissionsItem.image = NSImage(
            systemSymbolName: "lock.shield", accessibilityDescription: "Permissions"
        )
        menu.addItem(permissionsItem)

        menu.addItem(Updater.shared.makeMenuItem())

        menu.addItem(NSMenuItem.separator())

        let quitItem = NSMenuItem(title: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        quitItem.image = NSImage(systemSymbolName: "xmark.circle", accessibilityDescription: "Quit")
        menu.addItem(quitItem)

        statusItem?.menu = menu
    }

    private func setupOverlayWindow() {
        guard let screen = NSScreen.main else { return }
        let window = OverlayWindow(screen: screen)
        let overlayView = DimOverlayView(appState: appState, screenFrame: screen.frame)
        window.setOverlayContent(overlayView)
        overlayWindow = window
    }

    // MARK: - Permissions window

    @objc private func openPermissions() {
        PermissionsWindowController.shared.show()
    }

    // MARK: - Settings window

    @objc private func openSettings() {
        if let existing = settingsWindow, existing.isVisible {
            AppPresence.shared.windowOpened(existing)
            existing.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let settingsView = SettingsView()
        let hostingView = NSHostingView(rootView: settingsView)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 760, height: 560),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.titlebarAppearsTransparent = true
        window.title = ""
        window.contentView = hostingView
        window.center()
        window.isReleasedWhenClosed = false
        // Use normal window level so it does not always float above other apps
        window.level = .normal

        AppPresence.shared.windowOpened(window)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        settingsWindow = window
    }

    // MARK: - State handling

    private func updateOverlayVisibility() {
        if overlayHasContent {
            overlayWindow?.orderFrontRegardless()
        } else {
            overlayWindow?.orderOut(nil)
        }
    }

    private var overlayHasContent: Bool {
        // Debug outlines can be up in any mode.
        if appState.debugBlocksVisible { return true }
        switch appState.mode {
        case .detecting, .active:
            // Loading bubble, then the reading panel.
            return true
        case .selecting:
            // A drag area being defined, or the ⌘ hover preview.
            return appState.optionAreaStart != nil || appState.previewRect != nil
        case .idle:
            return false
        }
    }

    // MARK: - Menu bar icon

    /// Monochrome template icon for the menu bar. Draws the Slit mark as a
    /// silhouette — 4 bars with a framed slit over the second bar. macOS
    /// tints it automatically based on the menu bar's appearance.
    static func menuBarIcon() -> NSImage {
        let size = NSSize(width: 18, height: 18)
        let image = NSImage(size: size, flipped: false) { rect in
            let ctx = NSGraphicsContext.current?.cgContext
            ctx?.setFillColor(NSColor.black.cgColor)
            ctx?.setStrokeColor(NSColor.black.cgColor)

            // Scale the 64pt design down into the rect
            let s = rect.width / 64.0

            // Flip Y so SVG-style (top-down) coordinates match NSImage
            ctx?.translateBy(x: 0, y: rect.height)
            ctx?.scaleBy(x: 1, y: -1)

            // 4 bars — same widths as the web logo
            let bars: [(x: CGFloat, y: CGFloat, w: CGFloat)] = [
                (10, 16, 34),
                (10, 26, 48),
                (10, 38, 40),
                (10, 48, 28)
            ]
            for b in bars {
                let path = NSBezierPath(
                    roundedRect: NSRect(x: b.x * s, y: b.y * s,
                                        width: b.w * s, height: 4 * s),
                    xRadius: 2 * s, yRadius: 2 * s
                )
                path.fill()
            }

            // Slit — outline only (so the bar underneath stays visible via the tint)
            let slit = NSBezierPath(
                roundedRect: NSRect(x: 6 * s, y: 23 * s,
                                    width: 52 * s, height: 10 * s),
                xRadius: 5 * s, yRadius: 5 * s
            )
            slit.lineWidth = 1.4 * s
            slit.stroke()
            return true
        }
        image.isTemplate = true
        return image
    }
}
