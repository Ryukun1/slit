import CoreGraphics
import Foundation

/// Finds the paragraphs under the pointer while ⌘ is held, so the overlay can
/// outline the one a click would select before the click happens.
///
/// Detection means a screen capture and an OCR pass, so it is not run for
/// every ⌘ press: only once ⌘ has been held for a moment, and never when the
/// press turns out to be a keyboard shortcut.
@MainActor
final class HoverPreview {
    /// One detection pass: the paragraphs found, and the window they are in.
    struct Scan {
        let blocks: [TextBlock]
        /// Frame of the window under the pointer, or nil over the desktop.
        let window: CGRect?
    }

    private enum Timing {
        /// How long ⌘ must be held before detecting. Long enough that ⌘C,
        /// ⌘V and ⌘Tab never trigger it.
        static let holdDelay: Duration = .milliseconds(200)
        /// Quiet period after scrolling before detecting again.
        static let settleDelay: Duration = .milliseconds(250)
        /// How often a moving pointer is checked for having changed window.
        static let windowCheckInterval: TimeInterval = 0.15
    }

    private let state: AppState
    private let holdDelay: Duration
    private let settleDelay: Duration
    private let windowCheckInterval: TimeInterval
    private let scan: (CGPoint) async -> Scan
    private let windowAt: (CGPoint) -> CGRect?

    /// The scheduled or running detection, exposed so tests can wait for it.
    private(set) var pendingWork: Task<Void, Never>?
    /// True from ⌘ going down until it is released or the press is cancelled.
    private var isArmed = false
    /// Bumped whenever earlier work becomes irrelevant.
    private var generation = 0
    private var latestPointer: CGPoint = .zero
    /// The window the current paragraphs came from; nil until a scan lands.
    private var scannedWindow: ScannedWindow?
    private var lastWindowCheck = Date.distantPast

    /// Wraps the frame so "no scan yet" and "scanned the desktop" differ.
    private struct ScannedWindow {
        let frame: CGRect?
    }

    init(
        state: AppState,
        holdDelay: Duration = Timing.holdDelay,
        settleDelay: Duration = Timing.settleDelay,
        windowCheckInterval: TimeInterval = Timing.windowCheckInterval,
        scan: @escaping (CGPoint) async -> Scan = HoverPreview.liveScan,
        windowAt: @escaping (CGPoint) -> CGRect? = { TextDetector.windowFrame(at: $0) }
    ) {
        self.state = state
        self.holdDelay = holdDelay
        self.settleDelay = settleDelay
        self.windowCheckInterval = windowCheckInterval
        self.scan = scan
        self.windowAt = windowAt
    }

    /// ⌘ went down with the pointer at `point`.
    func begin(at point: CGPoint) {
        cancel()
        guard AppSettings.shared.hoverPreviewEnabled else { return }
        isArmed = true
        scheduleScan(at: point, after: holdDelay)
    }

    /// The pointer moved while ⌘ is held.
    func pointerMoved(to point: CGPoint) {
        guard isArmed else { return }
        latestPointer = point
        // No result yet: the pending scan reads `latestPointer` when it runs.
        guard let scannedWindow else { return }

        state.updatePreview(at: point)

        let now = Date()
        guard now.timeIntervalSince(lastWindowCheck) >= windowCheckInterval else { return }
        lastWindowCheck = now
        if windowAt(point) != scannedWindow.frame {
            // These paragraphs belong to a window the pointer has left.
            state.clearPreview()
            scheduleScan(at: point, after: .zero)
        }
    }

    /// The page under the pointer scrolled, so the outline no longer lines up.
    func contentMoved(at point: CGPoint) {
        guard isArmed else { return }
        state.clearPreview()
        scheduleScan(at: point, after: settleDelay)
    }

    /// ⌘ was released, or the press became a click, a shortcut or a drag.
    func cancel() {
        isArmed = false
        generation += 1
        pendingWork?.cancel()
        pendingWork = nil
        scannedWindow = nil
        state.clearPreview()
    }

    private func scheduleScan(at point: CGPoint, after delay: Duration) {
        generation += 1
        let expected = generation
        latestPointer = point
        scannedWindow = nil
        pendingWork?.cancel()
        pendingWork = Task { [weak self] in
            if delay > .zero {
                try? await Task.sleep(for: delay)
            }
            guard let self, self.isCurrent(expected) else { return }
            let result = await self.scan(self.latestPointer)
            // ⌘ may have been released, or the page scrolled, while OCR ran.
            guard self.isCurrent(expected) else { return }
            self.scannedWindow = ScannedWindow(frame: result.window)
            self.state.showPreview(blocks: result.blocks, pointer: self.latestPointer)
        }
    }

    private func isCurrent(_ expected: Int) -> Bool {
        !Task.isCancelled && generation == expected && state.mode == .selecting
    }

    /// The real detector: the same pass a ⌘+click runs, so the outline and
    /// the click agree on what a paragraph is.
    static func liveScan(_ point: CGPoint) async -> Scan {
        let window = TextDetector.windowFrame(at: point)
        let blocks = await TextDetector.detectBlocks(near: point)
        return Scan(blocks: blocks, window: window)
    }
}
