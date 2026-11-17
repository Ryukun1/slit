import AppKit
import SwiftUI

/// Colours shared by Slit's windows — the same values as the settings window
/// and slit.app.
enum SlitPalette {
    static let background = Color(red: 0x0E / 255.0, green: 0x0E / 255.0, blue: 0x10 / 255.0)
    static let backgroundSoft = Color(red: 0x15 / 255.0, green: 0x15 / 255.0, blue: 0x18 / 255.0)
    static let ink = Color(red: 0xF2 / 255.0, green: 0xEE / 255.0, blue: 0xE6 / 255.0)
    static let inkSoft = Color(red: 0x8A / 255.0, green: 0x86 / 255.0, blue: 0x80 / 255.0)
    static let rule = Color(red: 0x23 / 255.0, green: 0x23 / 255.0, blue: 0x27 / 255.0)
    static let accent = Color(red: 0xC9 / 255.0, green: 0xA9 / 255.0, blue: 0x73 / 255.0)
    static let granted = Color(red: 0x7F / 255.0, green: 0xC8 / 255.0, blue: 0x8B / 255.0)
}

/// Owns the permissions window: shown on first launch when something is
/// missing, and from the menu at any time.
@MainActor
final class PermissionsWindowController {
    static let shared = PermissionsWindowController()

    private init() {}

    private var window: NSWindow?
    private var closeObserver: NSObjectProtocol?

    func show() {
        if let window {
            AppPresence.shared.windowOpened(window)
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let host = NSHostingView(
            rootView: PermissionsView(
                permissions: Permissions.shared,
                onClose: { [weak self] in self?.window?.close() }
            )
        )
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: host.fittingSize),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.titlebarAppearsTransparent = true
        window.title = ""
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.center()

        // Fast polling only while the window is up; balanced on close.
        Permissions.shared.beginWatching()
        closeObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification, object: window, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.windowDidClose() }
        }

        self.window = window
        AppPresence.shared.windowOpened(window)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func windowDidClose() {
        if let closeObserver {
            NotificationCenter.default.removeObserver(closeObserver)
        }
        closeObserver = nil
        window = nil
        Permissions.shared.endWatching()
    }
}

/// Every permission Slit uses: what it is for, whether it is granted, and a
/// button to grant it. Status updates by itself.
struct PermissionsView: View {
    @ObservedObject var permissions: Permissions
    let onClose: () -> Void

    private enum Metrics {
        static let width: CGFloat = 520
        static let footerGap: CGFloat = 20
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(.bottom, 22)

            Text("Slit needs two macOS permissions. Each one is explained below, "
                 + "and you can change them at any time in System Settings.")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(SlitPalette.inkSoft)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.bottom, 18)

            ForEach(PermissionKind.allCases) { kind in
                PermissionRow(
                    kind: kind,
                    isGranted: permissions.isGranted(kind),
                    onGrant: { permissions.request(kind) }
                )
            }
            SlitPalette.rule.frame(height: 1)

            footer
                .padding(.top, Metrics.footerGap)
        }
        .padding(.horizontal, 36)
        .padding(.top, 28)
        .padding(.bottom, 24)
        .frame(width: Metrics.width, alignment: .topLeading)
        .background(SlitPalette.background)
        .preferredColorScheme(.dark)
        .animation(.easeOut(duration: 0.2), value: permissions.accessibility)
        .animation(.easeOut(duration: 0.2), value: permissions.screenRecording)
    }

    private var header: some View {
        HStack(spacing: 14) {
            LogoView(size: 40)
            VStack(alignment: .leading, spacing: 2) {
                Text("Slit")
                    .font(.system(size: 20, weight: .bold))
                    .foregroundStyle(SlitPalette.ink)
                Text("Permissions")
                    .font(.system(size: 10, weight: .bold))
                    .tracking(1.2)
                    .textCase(.uppercase)
                    .foregroundStyle(SlitPalette.inkSoft)
            }
            Spacer()
        }
    }

    @ViewBuilder
    private var footer: some View {
        HStack(spacing: 10) {
            if permissions.allGranted {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(SlitPalette.granted)
                Text(permissions.needsRelaunch
                     ? "All set. Relaunch Slit to start reading."
                     : "All set. Hold ⌘ and click a paragraph to start.")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(SlitPalette.ink)
            } else {
                Text("Slit stays in the menu bar. Open this window again from there.")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(SlitPalette.inkSoft)
            }
            Spacer()
            if permissions.needsRelaunch {
                Button("Relaunch Slit") { permissions.relaunch() }
                    .buttonStyle(.borderedProminent)
                    .tint(SlitPalette.accent)
                    .keyboardShortcut(.defaultAction)
            } else {
                Button(permissions.allGranted ? "Done" : "Later", action: onClose)
                    .keyboardShortcut(permissions.allGranted ? .defaultAction : .cancelAction)
            }
        }
    }
}

private struct PermissionRow: View {
    let kind: PermissionKind
    let isGranted: Bool
    let onGrant: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            SlitPalette.rule.frame(height: 1)
            HStack(alignment: .top, spacing: 14) {
                Image(systemName: kind.symbolName)
                    .font(.system(size: 18, weight: .medium))
                    .foregroundStyle(isGranted ? SlitPalette.granted : SlitPalette.accent)
                    .frame(width: 24)
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 4) {
                    Text(kind.title)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(SlitPalette.ink)
                    Text(kind.reason)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(SlitPalette.inkSoft)
                        .fixedSize(horizontal: false, vertical: true)
                    // Kept in the layout when granted so the window, which is
                    // sized once, never has to change height.
                    Text(kind.withoutIt)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(SlitPalette.inkSoft.opacity(0.75))
                        .fixedSize(horizontal: false, vertical: true)
                        .opacity(isGranted ? 0 : 1)
                        .accessibilityHidden(isGranted)
                }

                Spacer(minLength: 12)

                if isGranted {
                    Label("Granted", systemImage: "checkmark.circle.fill")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(SlitPalette.granted)
                } else {
                    Button("Grant…", action: onGrant)
                        .accessibilityLabel("Grant \(kind.title)")
                }
            }
            .padding(.vertical, 14)
        }
    }
}
