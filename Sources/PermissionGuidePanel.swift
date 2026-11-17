import AppKit
import Combine
import SwiftUI

/// A small floating card that appears when Slit sends someone to System
/// Settings for a permission. It lists the steps, waits, and notices the
/// grant by itself — the trip to Settings and back is where people get lost,
/// and a modal alert that says "then quit and reopen" leaves them there.
///
/// The panel never takes focus from System Settings, and nothing exists while
/// it is hidden.
@MainActor
final class PermissionGuidePanel {
    static let shared = PermissionGuidePanel()

    private enum Layout {
        static let screenMargin: CGFloat = 20
    }

    private enum Timing {
        /// After this long without a grant, the likely cause is a stale entry
        /// left by an earlier copy of the app.
        static let staleAfter: Duration = .seconds(12)
        /// How long the "granted" state stays up before the card leaves.
        static let successLinger: Duration = .milliseconds(1600)
    }

    private var panel: NSPanel?
    private var state: PermissionGuideState?
    private var grantObservation: AnyCancellable?
    private var staleTask: Task<Void, Never>?
    private var dismissTask: Task<Void, Never>?

    private init() {}

    func show(for kind: PermissionKind) {
        dismiss()

        let state = PermissionGuideState(kind: kind)
        let card = PermissionGuideCard(
            state: state,
            onOpenSettings: { Permissions.shared.openSettings(for: kind) },
            onStartOver: { Permissions.shared.startOver(kind) },
            onRelaunch: { Permissions.shared.relaunch() },
            onClose: { [weak self] in self?.dismiss() }
        )

        let panel = GuidePanel(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .floating
        panel.isMovableByWindowBackground = true
        panel.isReleasedWhenClosed = false
        // Panels hide when their app is not frontmost by default, which is
        // exactly when this one is needed: System Settings is in front.
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.contentView = NSHostingView(rootView: card)

        self.panel = panel
        self.state = state
        sizeToFit(anchorTopRight: true)
        panel.orderFrontRegardless()

        Permissions.shared.beginWatching()
        grantObservation = Permissions.shared.publisher(for: kind)
            .removeDuplicates()
            .filter { $0 }
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                Task { @MainActor in self?.handleGranted() }
            }

        staleTask = Task { [weak self] in
            try? await Task.sleep(for: Timing.staleAfter)
            guard !Task.isCancelled else { return }
            self?.markStale()
        }
    }

    func dismiss() {
        staleTask?.cancel()
        staleTask = nil
        dismissTask?.cancel()
        dismissTask = nil
        grantObservation = nil
        guard let panel else { return }
        panel.orderOut(nil)
        self.panel = nil
        state = nil
        Permissions.shared.endWatching()
    }

    private func handleGranted() {
        guard let state, !state.isGranted else { return }
        staleTask?.cancel()
        state.isStale = false
        state.isGranted = true
        sizeToFit(anchorTopRight: false)

        // A Screen Recording grant needs a relaunch to take effect, so the
        // card stays and offers one. Accessibility is live already.
        guard !state.kind.appliesAfterRelaunch else { return }
        dismissTask = Task { [weak self] in
            try? await Task.sleep(for: Timing.successLinger)
            guard !Task.isCancelled else { return }
            self?.dismiss()
        }
    }

    private func markStale() {
        guard let state, !state.isGranted else { return }
        state.isStale = true
        sizeToFit(anchorTopRight: false)
    }

    /// Resize the panel to its content. The card grows when the hint appears;
    /// keep its top edge where it is so it grows downwards.
    private func sizeToFit(anchorTopRight: Bool) {
        guard let panel, let host = panel.contentView else { return }
        host.layoutSubtreeIfNeeded()
        let size = host.fittingSize

        let origin: NSPoint
        if anchorTopRight {
            let visible = (NSScreen.main ?? NSScreen.screens.first)?.visibleFrame ?? .zero
            origin = NSPoint(
                x: visible.maxX - size.width - Layout.screenMargin,
                y: visible.maxY - size.height - Layout.screenMargin
            )
        } else {
            origin = NSPoint(x: panel.frame.minX, y: panel.frame.maxY - size.height)
        }
        panel.setFrame(NSRect(origin: origin, size: size), display: true, animate: !anchorTopRight)
    }
}

/// Borderless panels refuse key status by default, which would leave the
/// card's buttons needing a first click just to wake the window.
private final class GuidePanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

/// What the card is currently showing.
@MainActor
final class PermissionGuideState: ObservableObject {
    let kind: PermissionKind
    @Published var isGranted = false
    @Published var isStale = false

    init(kind: PermissionKind) {
        self.kind = kind
    }
}

struct PermissionGuideCard: View {
    @ObservedObject var state: PermissionGuideState
    let onOpenSettings: () -> Void
    let onStartOver: () -> Void
    let onRelaunch: () -> Void
    let onClose: () -> Void

    private enum Metrics {
        static let width: CGFloat = 320
        static let cornerRadius: CGFloat = 14
        static let padding: CGFloat = 14
        static let stepBadge: CGFloat = 16
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header

            VStack(alignment: .leading, spacing: 6) {
                step(1, "Open Privacy & Security › \(state.kind.title) in System Settings.")
                step(2, "Turn on the switch next to Slit.")
                step(3, "Come back. This card notices by itself.")
            }

            status

            if state.isStale, !state.isGranted {
                staleHint
            }
        }
        .padding(Metrics.padding)
        .frame(width: Metrics.width, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: Metrics.cornerRadius, style: .continuous)
                .fill(SlitPalette.background)
                .overlay(
                    RoundedRectangle(cornerRadius: Metrics.cornerRadius, style: .continuous)
                        .strokeBorder(SlitPalette.rule, lineWidth: 1)
                )
        )
        .preferredColorScheme(.dark)
        .animation(.easeOut(duration: 0.2), value: state.isGranted)
        .animation(.easeOut(duration: 0.2), value: state.isStale)
    }

    private var header: some View {
        HStack(spacing: 7) {
            Image(systemName: state.kind.symbolName)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(SlitPalette.accent)
            Text("One more step")
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(SlitPalette.ink)
            Text(state.kind.title)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(SlitPalette.inkSoft)
                .lineLimit(1)
            Spacer(minLength: 12)
            Button(action: onClose) {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 14))
                    .foregroundStyle(SlitPalette.inkSoft)
            }
            .buttonStyle(.plain)
            .help("Close")
            .accessibilityLabel("Close")
        }
    }

    @ViewBuilder
    private var status: some View {
        HStack(spacing: 7) {
            if state.isGranted {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(SlitPalette.granted)
                Text("Permission granted")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(SlitPalette.granted)
                if state.kind.appliesAfterRelaunch {
                    Spacer(minLength: 8)
                    Button("Relaunch to apply", action: onRelaunch)
                        .controlSize(.small)
                        .buttonStyle(.borderedProminent)
                        .tint(SlitPalette.accent)
                }
            } else {
                ProgressView()
                    .controlSize(.small)
                Text("Waiting for the switch…")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(SlitPalette.inkSoft)
                    .lineLimit(1)
                    .fixedSize()
                Spacer(minLength: 8)
                Button("Open Settings", action: onOpenSettings)
                    .controlSize(.small)
            }
        }
        .padding(.top, 2)
    }

    private var staleHint: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(staleText)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(SlitPalette.inkSoft)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                if state.kind.appliesAfterRelaunch {
                    // macOS may only report this grant to a new process, so a
                    // relaunch is the first thing to try.
                    Button("Relaunch Slit", action: onRelaunch)
                        .controlSize(.small)
                }
                Button("Start over", action: onStartOver)
                    .controlSize(.small)
            }
        }
        .padding(.top, 2)
    }

    private var staleText: String {
        state.kind.appliesAfterRelaunch
            ? "Switch already on? Relaunch Slit so macOS applies it. If it is still "
                + "not picked up after that, the entry belongs to an earlier copy of "
                + "Slit: Start over removes it and asks again."
            : "Switch already on? That entry belongs to an earlier copy of Slit, "
                + "and macOS no longer honours it. Start over removes it and asks again."
    }

    private func step(_ number: Int, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("\(number)")
                .font(.system(size: 10, weight: .bold, design: .rounded))
                .foregroundStyle(SlitPalette.background)
                .frame(width: Metrics.stepBadge, height: Metrics.stepBadge)
                .background(Circle().fill(SlitPalette.accent))
                .accessibilityHidden(true)
            Text(text)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(SlitPalette.ink)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Step \(number): \(text)")
    }
}
