import AppKit
import Testing
@testable import TextReaderHelper

/// Slit is a menu-bar app, which macOS leaves out of the Dock and ⌘-Tab.
/// While one of its windows is open it becomes a regular app, so the window
/// can be reached like any other.
@MainActor
@Suite(.serialized)
struct AppPresenceTests {
    private final class PolicyLog {
        var applied: [NSApplication.ActivationPolicy] = []
    }

    private let log = PolicyLog()

    private func makePresence() -> AppPresence {
        let log = log
        return AppPresence(applyPolicy: { log.applied.append($0) })
    }

    private func makeWindow() -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 100, height: 100),
            styleMask: [.titled, .closable], backing: .buffered, defer: true
        )
        window.isReleasedWhenClosed = false
        return window
    }

    private func close(_ window: NSWindow) {
        NotificationCenter.default.post(name: NSWindow.willCloseNotification, object: window)
    }

    @Test("Opening a window puts Slit in the Dock and ⌘-Tab")
    func openingWindowMakesAppRegular() {
        let presence = makePresence()

        presence.windowOpened(makeWindow())

        #expect(log.applied == [.regular])
        #expect(presence.hasOpenWindows)
    }

    @Test("Closing the last window returns Slit to the menu bar only")
    func closingLastWindowMakesAppAccessory() {
        let presence = makePresence()
        let window = makeWindow()
        presence.windowOpened(window)

        close(window)

        #expect(log.applied == [.regular, .accessory])
        #expect(!presence.hasOpenWindows)
    }

    @Test("Slit stays in ⌘-Tab until every window is closed")
    func staysRegularWhileAnyWindowIsOpen() {
        let presence = makePresence()
        let settings = makeWindow()
        let permissions = makeWindow()
        presence.windowOpened(settings)
        presence.windowOpened(permissions)

        close(settings)
        #expect(log.applied.last == .regular)
        #expect(presence.hasOpenWindows)

        close(permissions)
        #expect(log.applied.last == .accessory)
    }

    @Test("Bringing an open window forward again does not count it twice")
    func reopeningSameWindowCountsOnce() {
        let presence = makePresence()
        let window = makeWindow()
        presence.windowOpened(window)
        presence.windowOpened(window)

        close(window)

        #expect(log.applied.last == .accessory)
        #expect(!presence.hasOpenWindows)
    }

    @Test("Another app's window closing changes nothing")
    func unrelatedWindowClosingIsIgnored() {
        let presence = makePresence()
        presence.windowOpened(makeWindow())

        close(makeWindow())

        #expect(log.applied == [.regular])
        #expect(presence.hasOpenWindows)
    }
}
