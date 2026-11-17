import CoreGraphics
import Testing
@testable import TextReaderHelper

/// Shared fixtures: two paragraphs stacked in one window.
@MainActor
private enum Page {
    static let window = CGRect(x: 0, y: 0, width: 800, height: 600)
    static let otherWindow = CGRect(x: 900, y: 0, width: 600, height: 600)

    static func block(top: CGFloat, lines: Int = 3) -> TextBlock {
        TextBlock(lines: (0..<lines).map { index in
            TextLine(
                text: "Line \(index)",
                rect: CGRect(x: 100, y: top + CGFloat(index) * 30, width: 400, height: 20)
            )
        })
    }

    static let first = block(top: 100)
    static let second = block(top: 320)
    static let insideFirst = CGPoint(x: 200, y: 130)
    static let insideSecond = CGPoint(x: 200, y: 350)
    static let farFromText = CGPoint(x: 200, y: 580 + TextDetector.maxSnapDistance)
}

/// What the overlay is told to outline while ⌘ is held.
@MainActor
@Suite(.serialized)
struct PreviewStateTests {
    private let state = AppState()

    @Test("Hovering a paragraph outlines exactly what a click would select")
    func outlinesHoveredParagraph() {
        state.beginSelecting()
        state.showPreview(blocks: [Page.first, Page.second], pointer: Page.insideFirst)

        #expect(state.previewRect == Page.first.boundingRect)
    }

    @Test("Moving to another paragraph moves the outline")
    func followsPointerBetweenParagraphs() {
        state.beginSelecting()
        state.showPreview(blocks: [Page.first, Page.second], pointer: Page.insideFirst)

        state.updatePreview(at: Page.insideSecond)

        #expect(state.previewRect == Page.second.boundingRect)
    }

    @Test("Nothing is outlined where a click would select nothing")
    func noOutlineAwayFromText() {
        state.beginSelecting()
        state.showPreview(blocks: [Page.first, Page.second], pointer: Page.farFromText)

        #expect(state.previewRect == nil)
    }

    @Test("The outline exists only while choosing a paragraph")
    func noOutlineOutsideSelecting() {
        state.showPreview(blocks: [Page.first], pointer: Page.insideFirst)
        #expect(state.previewRect == nil)

        state.beginSelecting()
        state.showPreview(blocks: [Page.first], pointer: Page.insideFirst)
        #expect(state.previewRect != nil)

        state.beginDetecting(at: Page.insideFirst)
        #expect(state.previewRect == nil)
        state.updatePreview(at: Page.insideFirst)
        #expect(state.previewRect == nil)
    }

    @Test("Releasing ⌘ removes the outline")
    func deactivateClearsOutline() {
        state.beginSelecting()
        state.showPreview(blocks: [Page.first], pointer: Page.insideFirst)

        state.deactivate()

        #expect(state.previewRect == nil)
    }

    @Test("A drag-area gesture takes over from the outline")
    func dragAreaHidesOutline() {
        state.beginSelecting()
        state.showPreview(blocks: [Page.first], pointer: Page.insideFirst)

        state.optionAreaStart = Page.insideFirst
        state.updatePreview(at: Page.insideFirst)

        #expect(state.previewRect == nil)
    }
}

/// When detection for the preview runs, and when its result is used.
@MainActor
@Suite(.serialized)
struct HoverPreviewTests {
    /// Records what was asked of the detector and answers from a script.
    @MainActor
    private final class FakeScreen {
        var scans: [CGPoint] = []
        var blocks: [TextBlock] = [Page.first, Page.second]
        var windowUnderPointer: CGRect? = Page.window

        func scan(_ point: CGPoint) async -> HoverPreview.Scan {
            scans.append(point)
            return HoverPreview.Scan(blocks: blocks, window: windowUnderPointer)
        }
    }

    private let state = AppState()
    private let screen = FakeScreen()

    init() {
        AppSettings.shared.hoverPreviewEnabled = true
    }

    private func makePreview() -> HoverPreview {
        let screen = screen
        return HoverPreview(
            state: state,
            holdDelay: .zero,
            windowCheckInterval: 0,
            scan: { await screen.scan($0) },
            windowAt: { _ in screen.windowUnderPointer }
        )
    }

    @Test("Holding ⌘ over a paragraph outlines it")
    func holdingCommandShowsOutline() async {
        let preview = makePreview()
        state.beginSelecting()

        preview.begin(at: Page.insideFirst)
        await preview.pendingWork?.value

        #expect(screen.scans == [Page.insideFirst])
        #expect(state.previewRect == Page.first.boundingRect)
    }

    @Test("A keyboard shortcut or click cancels the preview before it shows")
    func cancelDiscardsResult() async {
        let preview = makePreview()
        state.beginSelecting()

        preview.begin(at: Page.insideFirst)
        let work = preview.pendingWork
        preview.cancel()
        await work?.value

        #expect(state.previewRect == nil)
    }

    @Test("Releasing ⌘ mid-detection leaves nothing behind")
    func releaseDuringDetectionShowsNothing() async {
        let preview = makePreview()
        state.beginSelecting()

        preview.begin(at: Page.insideFirst)
        state.deactivate()
        await preview.pendingWork?.value

        #expect(state.previewRect == nil)
    }

    @Test("Moving within the same window reuses the detection")
    func sameWindowDoesNotRescan() async {
        let preview = makePreview()
        state.beginSelecting()
        preview.begin(at: Page.insideFirst)
        await preview.pendingWork?.value

        preview.pointerMoved(to: Page.insideSecond)
        await preview.pendingWork?.value

        #expect(screen.scans.count == 1)
        #expect(state.previewRect == Page.second.boundingRect)
    }

    @Test("Moving onto another window detects that window instead")
    func otherWindowRescans() async {
        let preview = makePreview()
        state.beginSelecting()
        preview.begin(at: Page.insideFirst)
        await preview.pendingWork?.value

        let overThere = CGPoint(x: 1000, y: 200)
        let foreign = TextBlock(lines: [
            TextLine(text: "Elsewhere", rect: CGRect(x: 950, y: 190, width: 300, height: 20))
        ])
        screen.windowUnderPointer = Page.otherWindow
        screen.blocks = [foreign]
        preview.pointerMoved(to: overThere)
        await preview.pendingWork?.value

        #expect(screen.scans == [Page.insideFirst, overThere])
        #expect(state.previewRect == foreign.boundingRect)
    }

    @Test("Scrolling drops the outline and detects again once it settles")
    func scrollingRescans() async {
        let preview = makePreview()
        state.beginSelecting()
        preview.begin(at: Page.insideFirst)
        await preview.pendingWork?.value

        preview.contentMoved(at: Page.insideFirst)
        #expect(state.previewRect == nil)
        await preview.pendingWork?.value

        #expect(screen.scans.count == 2)
        #expect(state.previewRect == Page.first.boundingRect)
    }

    @Test("Nothing is detected when the preview is switched off")
    func disabledSettingDoesNothing() async {
        AppSettings.shared.hoverPreviewEnabled = false
        defer { AppSettings.shared.hoverPreviewEnabled = true }
        let preview = makePreview()
        state.beginSelecting()

        preview.begin(at: Page.insideFirst)
        await preview.pendingWork?.value

        #expect(screen.scans.isEmpty)
        #expect(state.previewRect == nil)
    }
}
