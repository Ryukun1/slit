import Foundation
import AppKit

/// Represents a detected line of text with its screen-coordinate bounding box.
struct TextLine: Identifiable, Equatable {
    let id = UUID()
    let text: String
    let rect: CGRect
    let confidence: Float // 0.0 - 1.0, from OCR. 1.0 for accessibility-detected lines.
    let isReliableText: Bool // false if likely math/symbols/garbled
    /// Word-by-word reveal: the screen x where the opening stops after each
    /// word but the last, in the space before the next word (`WordStops`).
    /// Aligned to `WordSegmenter.words(in:)`. Empty when there is no word
    /// geometry (e.g. the Accessibility path), in which case callers fall
    /// back to a proportional estimate.
    let revealStops: [CGFloat]

    init(text: String, rect: CGRect, confidence: Float = 1.0, revealStops: [CGFloat] = []) {
        self.text = text
        self.rect = rect
        self.confidence = confidence
        self.revealStops = revealStops
        self.isReliableText = Self.checkReliability(text: text, confidence: confidence)
    }

    /// Check if this line is reliably readable text (not math/symbols/garbled).
    private static func checkReliability(text: String, confidence: Float) -> Bool {
        // Low OCR confidence = unreliable
        if confidence < 0.5 { return false }

        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }

        // Count "normal" alphanumeric + common punctuation vs special characters
        let normalChars = CharacterSet.alphanumerics
            .union(.whitespaces)
            .union(CharacterSet(charactersIn: ".,;:!?'-\"()"))
        let specialCount = trimmed.unicodeScalars.filter { !normalChars.contains($0) }.count
        let totalCount = trimmed.unicodeScalars.count

        // If more than 30% special characters, likely math/symbols
        if totalCount > 0 && CGFloat(specialCount) / CGFloat(totalCount) > 0.3 {
            return false
        }

        return true
    }
}

/// One debug outline: the region a click inside a block would select.
struct DebugSelection: Identifiable, Equatable {
    let id: UUID
    let rect: CGRect
    let lineCount: Int
}

extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}

/// A single detected line, and whether it survived into a usable block.
struct DebugLine: Identifiable, Equatable {
    let id: UUID
    let rect: CGRect
    /// False when clustering or the chrome filter dropped this line — it was
    /// detected, but a ⌘+click can never select it.
    let usable: Bool
    /// OCR confidence, 1.0 for accessibility-sourced lines.
    let confidence: Float
    /// Index of the paragraph this line belongs to, or nil if it was discarded.
    /// Drives the shared colour between a line and its paragraph.
    let paragraphIndex: Int?
}

/// The three modes the app can be in.
enum AppMode: Equatable {
    /// Nothing happening — waiting for Command press.
    case idle
    /// Command is held — waiting for a click to detect text.
    case selecting
    /// Click happened — detecting text, showing loading indicator.
    case detecting
    /// Overlay is locked on a region; dimming is active.
    case active
}

/// Observable state shared across the app.
@MainActor
final class AppState: ObservableObject {
    @Published var mode: AppMode = .idle
    @Published var detectedLines: [TextLine] = []
    @Published var detectedBlocks: [TextBlock] = []
    @Published var activeLineIndex: Int? = nil
    /// Not @Published: nothing renders from it, and publishing it re-evaluated
    /// the whole overlay view on every mouse-moved event, system-wide.
    var mousePosition: CGPoint = .zero
    @Published var overlayRegion: CGRect = .zero
    @Published var clickPoint: CGPoint = .zero
    /// Drag-area start (where Command was first pressed).
    @Published var optionAreaStart: CGPoint? = nil
    /// Drag-area current end point (mouse position).
    @Published var optionAreaCurrent: CGPoint? = nil
    @Published var isDetecting = false

    /// While ⌘ is held: the region a click at the pointer would select, in
    /// screen coordinates, or nil where a click would select nothing.
    @Published private(set) var previewRect: CGRect? = nil
    /// Paragraphs found for the preview. Kept apart from `detectedBlocks`,
    /// which belongs to the session a click starts.
    private var previewBlocks: [TextBlock] = []

    /// Debug: Command held — preview in red what a click would select.
    /// Purely diagnostic; does not affect selection or reading.
    @Published var debugBlocksVisible = false
    /// Blocks detected for the debug overlay, independent of `detectedBlocks`
    /// (which only holds the blocks from the last real activation).
    @Published var debugBlocks: [TextBlock] = []
    /// The exact region a click at the current mouse position would select —
    /// the block narrowed by column, vertical section and selection size.
    @Published var debugSelectionRect: CGRect? = nil
    /// Line count inside `debugSelectionRect`.
    @Published var debugSelectionLineCount: Int = 0
    /// One entry per block: the region a click at that block's centre would
    /// select, so every paragraph is outlined at once.
    @Published var debugAllSelections: [DebugSelection] = []
    /// Every line the detector produced, including ones clustering or the
    /// chrome filter discarded. Shown as thin outlines under the paragraphs.
    @Published var debugAllLines: [DebugLine] = []
    /// True while the page is scrolling and the outlines no longer match what
    /// is on screen. The overlay dims itself until re-detection finishes.
    @Published var debugStale = false
    /// Raw detected lines from the last debug pass, kept so the break threshold
    /// can be re-tuned without re-running OCR.
    private var debugSourceLines: [TextLine] = []
    /// Toolbar strip that applied to `debugSourceLines`, kept for re-clustering.
    private var debugChromeBand: CGRect?

    /// Re-run clustering on the cached lines with a new break threshold.
    /// Cheap — no capture, no OCR, just regrouping.
    func recomputeDebugClustering(sensitivity: Double) {
        guard !debugSourceLines.isEmpty else { return }
        debugBlocks = LayoutAnalyzer.paragraphs(
            from: debugSourceLines,
            options: .init(breakSensitivity: sensitivity, chromeBand: debugChromeBand)
        )
        computeDebugLines(from: debugSourceLines, chromeBand: debugChromeBand)
        computeAllDebugSelections()
    }

    /// Classify every detected line as usable (it ended up in a block a click
    /// could select) or discarded by clustering / the chrome filter.
    func computeDebugLines(from allLines: [TextLine], chromeBand: CGRect? = nil) {
        debugSourceLines = allLines
        debugChromeBand = chromeBand

        // Map each line to the paragraph it ended up in, so the overlay can
        // colour them alike.
        var paragraphOf: [UUID: Int] = [:]
        for (index, block) in debugBlocks.enumerated() {
            for line in block.lines { paragraphOf[line.id] = index }
        }

        debugAllLines = allLines.map { line in
            let index = paragraphOf[line.id]
            return DebugLine(
                id: line.id,
                rect: line.rect,
                usable: index != nil,
                confidence: line.confidence,
                paragraphIndex: index
            )
        }
    }

    /// The selection region for every detected block. A block is a paragraph,
    /// so this is exactly what a click inside it would select.
    func computeAllDebugSelections() {
        debugAllSelections = debugBlocks.compactMap { block in
            guard !block.lines.isEmpty else { return nil }
            return DebugSelection(
                id: block.id, rect: block.boundingRect, lineCount: block.lines.count
            )
        }
    }

    /// Recompute the click-preview for `point` from the already-detected
    /// debug blocks. Mirrors what `detectAndActivate` + `activate` would do.
    func updateDebugSelection(at point: CGPoint) {
        guard debugBlocksVisible, !debugBlocks.isEmpty,
              let block = TextDetector.findBlock(at: point, from: debugBlocks) else {
            debugSelectionRect = nil
            debugSelectionLineCount = 0
            return
        }
        let lines = selectionLines(in: block)
        guard !lines.isEmpty else {
            debugSelectionRect = nil
            debugSelectionLineCount = 0
            return
        }
        debugSelectionRect = boundingRect(of: lines)
        debugSelectionLineCount = lines.count
    }

    /// Manual word-reveal mode: how many words of the leading line are currently
    /// revealed. Each click reveals one more word; a click once the whole line
    /// is shown moves the window to the next line. Ignored when mode is off.
    @Published var revealedWordCount: Int = 1

    /// Manual word-reveal mode: index of the top line in the visible rolling
    /// window. The window spans `windowTopIndex ... activeLineIndex` (the
    /// leading line). Completed lines above the leading line linger fully
    /// shown; the window holds at most `visibleLines` lines and rolls down one
    /// line at a time once full. Cursor-up scrolls this window back up over
    /// already-read lines.
    @Published var windowTopIndex: Int = 0

    /// Manual word-reveal mode: the furthest point the reader has revealed.
    /// Scrolling back up to re-read and coming back down never goes past it —
    /// only a click reveals new text.
    private var frontierLineIndex = 0
    private var frontierWordCount = 1

    /// Bumped whenever a detection starts or the session ends. A detection
    /// that finishes late compares against it to learn it was cancelled
    /// (Escape) or superseded, instead of activating a stale result.
    private(set) var detectionGeneration = 0

    /// Auto-advance timer
    private var autoAdvanceTimer: Timer? = nil

    /// Whether the slit currently tracks the pointer.
    private enum PointerFollow {
        /// Just activated: the slit sits on the first line and stays there
        /// until the pointer has clearly moved. `anchorY` is where the pointer
        /// was first seen after activation; nil until then.
        case holding(anchorY: CGFloat?)
        case following
    }

    private var pointerFollow: PointerFollow = .following

    /// Smallest vertical pointer travel that resumes following, for selections
    /// whose lines are very short.
    private static let minimumFollowResumeDistance: CGFloat = 8

    /// Transition to selecting mode when Command is pressed.
    func beginSelecting() {
        guard mode == .idle else { return }
        mode = .selecting
        detectedLines = []
        detectedBlocks = []
        activeLineIndex = nil
        clearPreview()
    }

    // MARK: - Hover preview

    /// Take freshly detected paragraphs and outline the one under `pointer`.
    func showPreview(blocks: [TextBlock], pointer: CGPoint) {
        previewBlocks = blocks
        updatePreview(at: pointer)
    }

    /// Re-aim the outline as the pointer moves. Publishes only when the
    /// outlined paragraph changes, not on every mouse move.
    func updatePreview(at point: CGPoint) {
        let rect = previewTarget(at: point)
        if rect != previewRect { previewRect = rect }
    }

    func clearPreview() {
        previewBlocks = []
        if previewRect != nil { previewRect = nil }
    }

    /// Mirrors what a click does: `findBlock`, then that block's lines.
    private func previewTarget(at point: CGPoint) -> CGRect? {
        guard mode == .selecting, optionAreaStart == nil,
              let block = TextDetector.findBlock(at: point, from: previewBlocks) else {
            return nil
        }
        let lines = selectionLines(in: block)
        return lines.isEmpty ? nil : boundingRect(of: lines)
    }

    // MARK: - Area preview

    /// Every line found on the page during an Option-drag.
    private var areaPreviewLines: [TextLine] = []

    /// The lines an in-progress Option-drag would select, top to bottom, in
    /// screen coordinates. Empty when there is no drag or it covers nothing.
    @Published private(set) var areaPreviewLineRects: [CGRect] = []

    /// The region those lines span: what the reading panel would frame.
    var areaPreviewRect: CGRect? {
        guard let first = areaPreviewLineRects.first else { return nil }
        return areaPreviewLineRects.dropFirst().reduce(first) { $0.union($1) }
    }

    /// Take freshly detected lines and mark those the drag covers.
    func showAreaPreview(lines: [TextLine]) {
        areaPreviewLines = lines
        updateAreaPreview()
    }

    /// Re-aim the marks as the drag moves. Publishes only when the lines
    /// covered change, not on every mouse move.
    func updateAreaPreview() {
        let rects = areaPreviewTargets()
        if rects != areaPreviewLineRects { areaPreviewLineRects = rects }
    }

    func clearAreaPreview() {
        areaPreviewLines = []
        if !areaPreviewLineRects.isEmpty { areaPreviewLineRects = [] }
    }

    /// Mirrors what releasing the drag does: the lines inside it.
    private func areaPreviewTargets() -> [CGRect] {
        guard let start = optionAreaStart, let end = optionAreaCurrent else { return [] }
        return Self.lines(areaPreviewLines, inAreaFrom: start, to: end).map(\.rect)
    }

    /// Start detecting text — show loading indicator.
    func beginDetecting(at point: CGPoint) {
        clickPoint = point
        detectionGeneration += 1
        clearPreview()
        mode = .detecting
        isDetecting = true
    }

    /// The lines a click inside `block` selects, top to bottom.
    ///
    /// `LayoutAnalyzer` already cut the page down to paragraphs, so a block is
    /// the selection — there is no second, differently-tuned paragraph pass
    /// here to disagree with it.
    func selectionLines(in block: TextBlock) -> [TextLine] {
        block.lines.sorted { $0.rect.minY < $1.rect.minY }
    }

    /// Activate on a specific text block.
    /// Splits horizontally into columns, then vertically into sections,
    /// keeping only the part the user clicked on.
    func activate(block: TextBlock) {
        let limitedSection = selectionLines(in: block)

        detectedLines = limitedSection
        overlayRegion = boundingRect(of: limitedSection)

        openSlitOnFirstLine()

        mode = .active

        // Start auto-advance if enabled
        startAutoAdvanceIfNeeded()
    }

    /// Activate a brand-new selection from a dragged rectangle (Option-drag
    /// without a prior selection).
    ///
    /// Takes every detected line, not one block: a drag across several
    /// paragraphs has to select all of them, not just the one under its centre.
    func activateArea(lines: [TextLine], from start: CGPoint, to end: CGPoint) {
        let linesInArea = Self.lines(lines, inAreaFrom: start, to: end)

        guard !linesInArea.isEmpty else {
            isDetecting = false
            deactivate()
            return
        }

        clickPoint = CGPoint(x: (start.x + end.x) / 2, y: (start.y + end.y) / 2)
        detectedLines = linesInArea
        overlayRegion = boundingRect(of: linesInArea)
        openSlitOnFirstLine()
        mode = .active
        startAutoAdvanceIfNeeded()
    }

    /// Every session starts with the slit open on the first line of the
    /// selection, in every reading mode. Leaving it unset until the pointer
    /// moved showed a dimmed box with no opening whenever the click landed
    /// beside the text rather than on a line.
    private func openSlitOnFirstLine() {
        if AppSettings.shared.manualWordModeEnabled {
            // Manual word-reveal also resets its window and revealed words.
            startManualReveal()
        } else {
            activeLineIndex = detectedLines.isEmpty ? nil : 0
        }
        pointerFollow = .holding(anchorY: nil)
    }

    /// Whether a pointer at `mouseY` should move the slit.
    ///
    /// Right after activation the pointer is still wherever the click landed,
    /// often lines away from the first one, so its next twitch would drag the
    /// slit straight off the start. Following resumes once the pointer has
    /// travelled about a line's height from that spot.
    private func shouldFollowPointer(at mouseY: CGFloat) -> Bool {
        switch pointerFollow {
        case .following:
            return true
        case .holding(anchorY: nil):
            pointerFollow = .holding(anchorY: mouseY)
            return false
        case .holding(anchorY: let anchorY?):
            guard abs(mouseY - anchorY) >= followResumeDistance else { return false }
            pointerFollow = .following
            return true
        }
    }

    private var followResumeDistance: CGFloat {
        guard !detectedLines.isEmpty else { return Self.minimumFollowResumeDistance }
        let averageHeight = detectedLines.map(\.rect.height).reduce(0, +)
            / CGFloat(detectedLines.count)
        return max(Self.minimumFollowResumeDistance, averageHeight)
    }

    /// Add the paragraph at `point` to the current selection (Option+click).
    /// When it sits in the same column as the selection, everything between
    /// the two comes along too.
    func addToSelection(block: TextBlock, from blocks: [TextBlock], near point: CGPoint) {
        guard mode == .active else { return }

        let selection = overlayRegion
        let target = block.boundingRect
        let shared = min(selection.maxX, target.maxX) - max(selection.minX, target.minX)
        let sameColumn = shared >= min(selection.width, target.width) * Self.sameColumnShare

        let span = selection.union(target)
        let between: [TextLine] = sameColumn
            ? blocks.flatMap(\.lines).filter { line in
                let overlap = min(line.rect.maxX, span.maxX) - max(line.rect.minX, span.minX)
                return line.rect.midY >= span.minY && line.rect.midY <= span.maxY
                    && overlap >= line.rect.width * Self.sameColumnShare
            }
            : []

        mergeIntoSelection(block.lines + between, focusY: point.y)
    }

    /// Add the lines inside a dragged rectangle to the current selection
    /// (Option-drag while reading).
    func addAreaToSelection(lines: [TextLine], from start: CGPoint, to end: CGPoint) {
        guard mode == .active else { return }
        mergeIntoSelection(Self.lines(lines, inAreaFrom: start, to: end), focusY: end.y)
    }

    /// Horizontal overlap (as a share of the narrower side) above which two
    /// regions count as the same column.
    private static let sameColumnShare: CGFloat = 0.5

    /// Lines whose centre falls inside the rectangle spanned by two points.
    private static func lines(
        _ lines: [TextLine], inAreaFrom start: CGPoint, to end: CGPoint
    ) -> [TextLine] {
        let area = CGRect(
            x: min(start.x, end.x), y: min(start.y, end.y),
            width: abs(end.x - start.x), height: abs(end.y - start.y)
        )
        return lines
            .filter { area.contains(CGPoint(x: $0.rect.midX, y: $0.rect.midY)) }
            .sorted { $0.rect.minY < $1.rect.minY }
    }

    /// Merge freshly detected lines into the selection, skipping any already
    /// in it, then move the slit to the line nearest `focusY`.
    ///
    /// Every detection pass mints new line ids, so "already in it" has to be
    /// decided by position — comparing ids never matched, and each
    /// Option+click doubled the lines it re-detected.
    private func mergeIntoSelection(_ candidates: [TextLine], focusY: CGFloat) {
        let added = candidates.reduce(into: [TextLine]()) { fresh, line in
            let known = detectedLines.contains { $0.isSameLine(as: line) }
                || fresh.contains { $0.isSameLine(as: line) }
            if !known { fresh.append(line) }
        }
        guard !added.isEmpty else { return }

        let merged = (detectedLines + added).sorted { $0.rect.minY < $1.rect.minY }
        detectedLines = merged
        overlayRegion = boundingRect(of: merged)
        activeLineIndex = merged.indices.min {
            abs(merged[$0].rect.midY - focusY) < abs(merged[$1].rect.midY - focusY)
        }
    }

    private func boundingRect(of lines: [TextLine]) -> CGRect {
        guard let first = lines.first else { return .zero }
        return lines.dropFirst().reduce(first.rect) { $0.union($1.rect) }
    }

    /// Advance to the next line (click inside overlay or down arrow).
    /// In manual word-reveal mode this rolls the window down toward the frontier.
    func advanceToNextLine() {
        guard mode == .active, !detectedLines.isEmpty else { return }
        if AppSettings.shared.manualWordModeEnabled {
            scrollWindowDown()
            return
        }
        if let current = activeLineIndex {
            let next = current + 1
            if next < detectedLines.count {
                activeLineIndex = next
                scrollIfNeeded(lineIndex: next)
            }
        } else {
            activeLineIndex = 0
        }
        resetWordReveal()
        resetAutoAdvanceTimer()
    }

    /// Go to the previous line (up arrow).
    /// In manual word-reveal mode this scrolls the window up over read lines.
    func advanceToPreviousLine() {
        guard mode == .active, !detectedLines.isEmpty else { return }
        if AppSettings.shared.manualWordModeEnabled {
            scrollWindowUp()
            return
        }
        if let current = activeLineIndex {
            let prev = current - 1
            if prev >= 0 {
                activeLineIndex = prev
                scrollIfNeeded(lineIndex: prev)
            }
        } else {
            activeLineIndex = detectedLines.count - 1
        }
        resetWordReveal()
        resetAutoAdvanceTimer()
    }

    /// Scroll the underlying window if the active line is near the edge of the screen.
    private func scrollIfNeeded(lineIndex: Int) {
        guard lineIndex < detectedLines.count else { return }
        let line = detectedLines[lineIndex]
        guard let screen = NSScreen.main else { return }
        let visibleFrame = screen.visibleFrame

        let lineBottom = line.rect.maxY
        let lineTop = line.rect.minY
        let margin: CGFloat = 50

        // Near bottom of screen — scroll down
        if lineBottom > visibleFrame.maxY - margin && lineIndex >= detectedLines.count - 2 {
            postScroll(direction: .down)
        }
        // Near top of screen — scroll up
        else if lineTop < visibleFrame.minY + margin && lineIndex <= 1 {
            postScroll(direction: .up)
        }
    }

    private enum ScrollDirection { case up, down }

    private func postScroll(direction: ScrollDirection) {
        let scrollAmount: Int32 = direction == .down ? -3 : 3
        // Scroll at the center of the overlay region
        scrollPage(scrollAmount, CGPoint(x: overlayRegion.midX, y: overlayRegion.midY))
    }

    /// Scrolls the page under the selection by `lines` at `point`. A property
    /// so tests can replace it and never send real scroll events.
    var scrollPage: (_ lines: Int32, _ point: CGPoint) -> Void = AppState.postScrollEvent

    private static func postScrollEvent(lines: Int32, at point: CGPoint) {
        guard let event = CGEvent(
            scrollWheelEvent2Source: nil, units: .line, wheelCount: 1,
            wheel1: lines, wheel2: 0, wheel3: 0
        ) else { return }
        event.location = point
        event.post(tap: .cghidEventTap)
    }

    /// Update which line is highlighted based on mouse Y.
    /// If no valid line is found, keeps the current highlight. The first call
    /// after activation only records where the pointer is; see
    /// `shouldFollowPointer(at:)`.
    ///
    /// In manual word-reveal mode the slit is click-driven, but cursor Y is
    /// still used to walk the rolling window *up* over already-read lines (and
    /// back down toward the frontier). New words are only ever revealed by
    /// clicking — never by moving the cursor.
    func updateActiveLine(mouseY: CGFloat) {
        guard mode == .active, !detectedLines.isEmpty else { return }

        if AppSettings.shared.manualWordModeEnabled {
            updateManualWindow(mouseY: mouseY)
            return
        }

        guard shouldFollowPointer(at: mouseY) else { return }

        if let newIndex = LineSnapper.nearestLineIndex(
            mouseY: mouseY, lines: detectedLines, current: activeLineIndex
        ) {
            if newIndex != activeLineIndex {
                activeLineIndex = newIndex
            }
        }
    }

    /// Manual mode: when the cursor moves above the window's leading line,
    /// scroll the window up over already-read text; when it moves back below,
    /// scroll back down toward the frontier. One line per step, so fast cursor
    /// moves don't skip lines.
    private func updateManualWindow(mouseY: CGFloat) {
        guard let leading = activeLineIndex,
              let nearest = LineSnapper.nearestLineIndex(mouseY: mouseY, lines: detectedLines)
        else { return }

        if nearest < leading {
            scrollWindowUp()
        } else if nearest > leading {
            scrollWindowDown()
        }
    }

    // MARK: - Manual word reveal

    /// Number of reveal words on the line at `index` (punctuation attaches to
    /// the preceding word). At least 1 so a non-empty line always reveals.
    func wordCount(forLine index: Int) -> Int {
        guard index >= 0, index < detectedLines.count else { return 0 }
        return WordSegmenter.count(in: detectedLines[index].text)
    }

    /// Reset the reveal so only the first word of the leading line is shown.
    func resetWordReveal() {
        revealedWordCount = 1
    }

    /// Begin manual word-reveal at the first word of the first line.
    private func startManualReveal() {
        activeLineIndex = detectedLines.isEmpty ? nil : 0
        windowTopIndex = 0
        frontierLineIndex = 0
        frontierWordCount = 1
        resetWordReveal()
    }

    /// The rolling-window height (lines kept visible at once): the Visible
    /// lines setting, or the whole selection when read text stays visible.
    private var manualWindowSize: Int {
        if AppSettings.shared.keepReadTextVisible {
            return max(1, detectedLines.count)
        }
        return max(1, AppSettings.shared.visibleLines)
    }

    /// Manual word-reveal click handler. Reveals one more word of the leading
    /// line; once the whole line is shown, the window advances to the next line
    /// (lingering completed lines stack above, up to the window size, then the
    /// window rolls down one line at a time).
    func revealNextWordOrAdvance() {
        guard mode == .active, !detectedLines.isEmpty else { return }
        guard let idx = activeLineIndex else {
            startManualReveal()
            return
        }

        // Re-reading above the frontier: a click walks back down toward it
        // rather than revealing anything new.
        guard idx >= frontierLineIndex else {
            scrollWindowDown()
            return
        }
        frontierLineIndex = idx

        let total = wordCount(forLine: idx)
        if revealedWordCount < total {
            // More words remain on the leading line — reveal the next one.
            revealedWordCount += 1
            frontierWordCount = revealedWordCount
        } else {
            // Leading line fully shown — advance the window to the next line.
            advanceWindowDown()
        }
    }

    /// Move the rolling window forward one line. The leading line becomes a
    /// lingering completed line; a new leading line enters at the bottom. Once
    /// the window is full (`manualWindowSize`), the top line drops off so the
    /// window slides down one line at a time. Resets the word reveal.
    private func advanceWindowDown() {
        guard let idx = activeLineIndex else { return }
        let next = idx + 1
        guard next < detectedLines.count else { return } // already at last line

        activeLineIndex = next
        frontierLineIndex = next
        frontierWordCount = 1
        // Grow the window until it reaches its size, then roll the top down.
        if next - windowTopIndex + 1 > manualWindowSize {
            windowTopIndex = next - manualWindowSize + 1
        }
        resetWordReveal()
        scrollIfNeeded(lineIndex: next)
        resetAutoAdvanceTimer()
    }

    /// Scroll the rolling window back up over already-read lines (cursor up or
    /// up arrow). The whole window shifts up one line; the leading line becomes
    /// fully shown (you're re-reading covered text, not revealing new words).
    func scrollWindowUp() {
        guard mode == .active, !detectedLines.isEmpty else { return }
        guard windowTopIndex > 0, let idx = activeLineIndex else { return }

        windowTopIndex -= 1
        activeLineIndex = idx - 1
        // A re-covered line is shown in full — we're walking back, not revealing.
        revealedWordCount = wordCount(forLine: max(0, idx - 1))
        scrollIfNeeded(lineIndex: windowTopIndex)
        resetAutoAdvanceTimer()
    }

    /// Scroll the rolling window back down toward the reading frontier (cursor
    /// down / down arrow after having scrolled up). Stops at the furthest line
    /// the reader had already reached.
    func scrollWindowDown() {
        guard mode == .active, !detectedLines.isEmpty else { return }
        // Never past the frontier: moving the cursor or pressing ↓ must not
        // reveal text the reader has not clicked through yet.
        guard let idx = activeLineIndex, idx < frontierLineIndex,
              idx + 1 < detectedLines.count else { return }

        let next = idx + 1
        activeLineIndex = next
        if next - windowTopIndex + 1 > manualWindowSize {
            windowTopIndex = next - manualWindowSize + 1
        }
        // Lines above the frontier were read in full; the frontier line comes
        // back exactly as far as it had been revealed.
        revealedWordCount = next == frontierLineIndex
            ? frontierWordCount
            : wordCount(forLine: next)
        scrollIfNeeded(lineIndex: next)
        resetAutoAdvanceTimer()
    }

    // MARK: - Auto-advance

    func startAutoAdvanceIfNeeded() {
        stopAutoAdvance()
        let settings = AppSettings.shared
        guard settings.autoAdvanceEnabled else { return }

        autoAdvanceTimer = Timer.scheduledTimer(
            withTimeInterval: settings.autoAdvanceSeconds,
            repeats: true
        ) { [weak self] _ in
            DispatchQueue.main.async {
                self?.advanceToNextLine()
            }
        }
    }

    private func resetAutoAdvanceTimer() {
        let settings = AppSettings.shared
        guard settings.autoAdvanceEnabled else { return }
        stopAutoAdvance()
        autoAdvanceTimer = Timer.scheduledTimer(
            withTimeInterval: settings.autoAdvanceSeconds,
            repeats: true
        ) { [weak self] _ in
            DispatchQueue.main.async {
                self?.advanceToNextLine()
            }
        }
    }

    private func stopAutoAdvance() {
        autoAdvanceTimer?.invalidate()
        autoAdvanceTimer = nil
    }

    /// Deactivate — back to idle.
    func deactivate() {
        pointerFollow = .following
        clearPreview()
        stopAutoAdvance()
        detectionGeneration += 1
        mode = .idle
        detectedLines = []
        detectedBlocks = []
        activeLineIndex = nil
        isDetecting = false
        clearAreaPreview()
        optionAreaStart = nil
        optionAreaCurrent = nil
        revealedWordCount = 1
        windowTopIndex = 0
        frontierLineIndex = 0
        frontierWordCount = 1
    }
}
