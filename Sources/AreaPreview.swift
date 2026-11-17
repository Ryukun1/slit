import CoreGraphics
import Foundation

/// Finds the lines on the page while an area is being dragged with Option
/// held, so the overlay can outline what releasing the drag would select.
///
/// The dragged rectangle is only a gesture: what gets selected is every line
/// whose centre falls inside it. Showing that as the drag moves means reading
/// the page once per drag, and not at all for a bare press of Option, which
/// is also how accented letters are typed.
@MainActor
final class AreaPreview {
    private enum Tuning {
        /// Pointer travel that makes a press of Option a drag. The same
        /// distance below which releasing selects nothing.
        static let dragDistance: CGFloat = 8
        /// Quiet period after scrolling before reading the page again.
        static let settleDelay: Duration = .milliseconds(250)
    }

    private let state: AppState
    private let dragDistance: CGFloat
    private let settleDelay: Duration
    private let scan: (CGPoint) async -> [TextLine]

    /// The scheduled or running page read, exposed so tests can wait for it.
    private(set) var pendingWork: Task<Void, Never>?
    /// Where Option went down; nil when no drag is in progress.
    private var start: CGPoint?
    /// A page read has been asked for during this drag.
    private var hasRequestedScan = false
    /// Bumped whenever earlier work becomes irrelevant.
    private var generation = 0

    init(
        state: AppState,
        dragDistance: CGFloat = Tuning.dragDistance,
        settleDelay: Duration = Tuning.settleDelay,
        scan: @escaping (CGPoint) async -> [TextLine] = AreaPreview.liveScan
    ) {
        self.state = state
        self.dragDistance = dragDistance
        self.settleDelay = settleDelay
        self.scan = scan
    }

    /// Option went down with the pointer at `point`.
    func begin(at point: CGPoint) {
        cancel()
        guard AppSettings.shared.dragSelectEnabled else { return }
        start = point
    }

    /// The pointer moved while Option is held.
    func pointerMoved(to point: CGPoint) {
        guard let start else { return }
        if hasRequestedScan {
            state.updateAreaPreview()
            return
        }
        let isDrag = abs(point.x - start.x) > dragDistance || abs(point.y - start.y) > dragDistance
        guard isDrag else { return }
        scheduleScan(after: .zero)
    }

    /// The page scrolled, so the lines found no longer line up with it.
    func contentMoved() {
        guard start != nil, hasRequestedScan else { return }
        state.clearAreaPreview()
        scheduleScan(after: settleDelay)
    }

    /// Option was released, or the drag was abandoned.
    func cancel() {
        start = nil
        hasRequestedScan = false
        generation += 1
        pendingWork?.cancel()
        pendingWork = nil
        state.clearAreaPreview()
    }

    private func scheduleScan(after delay: Duration) {
        hasRequestedScan = true
        generation += 1
        let expected = generation
        pendingWork?.cancel()
        pendingWork = Task { [weak self] in
            if delay > .zero {
                try? await Task.sleep(for: delay)
            }
            guard let self, self.isCurrent(expected), let point = self.scanPoint else { return }
            let lines = await self.scan(point)
            // Option may have been released, or the page scrolled, meanwhile.
            guard self.isCurrent(expected) else { return }
            self.state.showAreaPreview(lines: lines)
        }
    }

    private func isCurrent(_ expected: Int) -> Bool {
        !Task.isCancelled && generation == expected && state.optionAreaStart != nil
    }

    /// The middle of the drag so far: the same point the selection itself is
    /// detected around when the drag is released.
    private var scanPoint: CGPoint? {
        guard let start = state.optionAreaStart else { return nil }
        let end = state.optionAreaCurrent ?? start
        return CGPoint(x: (start.x + end.x) / 2, y: (start.y + end.y) / 2)
    }

    /// The real detector: the same pass releasing the drag runs.
    static func liveScan(_ point: CGPoint) async -> [TextLine] {
        await TextDetector.detectBlocks(near: point).flatMap(\.lines)
    }
}
