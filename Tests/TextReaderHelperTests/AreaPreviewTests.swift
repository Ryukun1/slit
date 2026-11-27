import CoreGraphics
import Testing
@testable import TextReaderHelper

/// Two paragraphs stacked on a page, and drags across them.
@MainActor
private enum AreaPage {
    static func lines(top: CGFloat, count: Int = 3) -> [TextLine] {
        (0..<count).map { index in
            TextLine(
                text: "Line \(index)",
                rect: CGRect(x: 100, y: top + CGFloat(index) * 30, width: 400, height: 20)
            )
        }
    }

    static let first = lines(top: 100)
    static let second = lines(top: 320)
    static let all = first + second
    static let firstRect = CGRect(x: 100, y: 100, width: 400, height: 80)
    static let bothRect = CGRect(x: 100, y: 100, width: 400, height: 300)

    static let dragStart = CGPoint(x: 80, y: 90)
    static let overFirst = CGPoint(x: 520, y: 190)
    static let overBoth = CGPoint(x: 520, y: 410)
    static let overNothing = CGPoint(x: 90, y: 95)
}

/// What the overlay is told to outline while an area is being dragged.
@MainActor
@Suite(.serialized)
struct AreaPreviewStateTests {
    private let state = AppState()

    private func drag(to point: CGPoint) {
        state.optionAreaStart = AreaPage.dragStart
        state.optionAreaCurrent = point
        state.updateAreaPreview()
    }

    @Test("The outline is exactly what releasing the drag would select")
    func outlineMatchesTheSelection() {
        state.beginSelecting()
        state.showAreaPreview(lines: AreaPage.all)
        drag(to: AreaPage.overFirst)
        let outlined = state.areaPreviewRect

        state.activateArea(lines: AreaPage.all, from: AreaPage.dragStart, to: AreaPage.overFirst)

        #expect(outlined == AreaPage.firstRect)
        #expect(state.overlayRegion == outlined)
    }

    @Test("Dragging further grows the outline to the lines now covered")
    func outlineGrowsWithTheDrag() {
        state.beginSelecting()
        state.showAreaPreview(lines: AreaPage.all)

        drag(to: AreaPage.overFirst)
        #expect(state.areaPreviewRect == AreaPage.firstRect)

        drag(to: AreaPage.overBoth)
        #expect(state.areaPreviewRect == AreaPage.bothRect)
    }

    @Test("Each line the drag would select is marked, and only those")
    func marksEachCoveredLine() {
        state.beginSelecting()
        state.showAreaPreview(lines: AreaPage.all)

        drag(to: AreaPage.overFirst)
        #expect(state.areaPreviewLineRects == AreaPage.first.map(\.rect))

        drag(to: AreaPage.overBoth)
        #expect(state.areaPreviewLineRects == AreaPage.all.map(\.rect))

        drag(to: AreaPage.overNothing)
        #expect(state.areaPreviewLineRects.isEmpty)
    }

    @Test("The marks go when the drag is over")
    func marksClear() {
        state.beginSelecting()
        state.showAreaPreview(lines: AreaPage.all)
        drag(to: AreaPage.overFirst)

        state.clearAreaPreview()

        #expect(state.areaPreviewLineRects.isEmpty)
    }

    @Test("A drag that covers no line outlines nothing")
    func nothingCoveredNothingOutlined() {
        state.beginSelecting()
        state.showAreaPreview(lines: AreaPage.all)

        drag(to: AreaPage.overNothing)

        #expect(state.areaPreviewRect == nil)
    }

    @Test("There is no outline once the drag is over")
    func noOutlineWithoutADrag() {
        state.beginSelecting()
        state.showAreaPreview(lines: AreaPage.all)
        drag(to: AreaPage.overFirst)

        state.clearAreaPreview()
        #expect(state.areaPreviewRect == nil)

        // Lines from the old scan must not come back on the next drag.
        drag(to: AreaPage.overFirst)
        #expect(state.areaPreviewRect == nil)
    }

    @Test("Ending the session removes the outline")
    func deactivateClearsOutline() {
        state.beginSelecting()
        state.showAreaPreview(lines: AreaPage.all)
        drag(to: AreaPage.overFirst)

        state.deactivate()

        #expect(state.areaPreviewRect == nil)
    }
}

/// When the page is read to find those lines.
@MainActor
@Suite(.serialized)
struct AreaPreviewScanTests {
    @MainActor
    private final class Screen {
        private(set) var scans = 0
        func scan(_: CGPoint) async -> [TextLine] {
            scans += 1
            return AreaPage.all
        }
    }

    private let state = AppState()
    private let screen = Screen()

    private func makePreview() -> AreaPreview {
        let screen = screen
        return AreaPreview(state: state, scan: { await screen.scan($0) })
    }

    /// What the event monitor does as the pointer moves with Option held.
    private func move(_ preview: AreaPreview, to point: CGPoint) {
        state.optionAreaCurrent = point
        preview.pointerMoved(to: point)
    }

    private func beginDrag(_ preview: AreaPreview) {
        state.beginSelecting()
        state.optionAreaStart = AreaPage.dragStart
        state.optionAreaCurrent = AreaPage.dragStart
        preview.begin(at: AreaPage.dragStart)
    }

    @Test("Pressing Option without dragging reads nothing from the screen")
    func noScanWithoutADrag() async {
        let preview = makePreview()
        beginDrag(preview)

        move(preview, to: CGPoint(x: AreaPage.dragStart.x + 2, y: AreaPage.dragStart.y + 2))
        await preview.pendingWork?.value

        #expect(screen.scans == 0)
        #expect(state.areaPreviewRect == nil)
    }

    @Test("Once a drag is under way the page is read once and the outline follows")
    func oneScanPerDrag() async {
        let preview = makePreview()
        beginDrag(preview)

        move(preview, to: AreaPage.overFirst)
        await preview.pendingWork?.value
        #expect(state.areaPreviewRect == AreaPage.firstRect)

        move(preview, to: AreaPage.overBoth)
        await preview.pendingWork?.value

        #expect(state.areaPreviewRect == AreaPage.bothRect)
        #expect(screen.scans == 1)
    }

    @Test("A result that arrives after Option is released is dropped")
    func lateResultIsDropped() async {
        let preview = makePreview()
        beginDrag(preview)
        move(preview, to: AreaPage.overFirst)
        let scanning = preview.pendingWork

        state.optionAreaStart = nil
        state.optionAreaCurrent = nil
        preview.cancel()
        await scanning?.value

        #expect(state.areaPreviewRect == nil)
    }

    @Test("Drag-select switched off means no outline and no scan")
    func respectsTheSetting() async {
        let settings = AppSettings.shared
        let wasEnabled = settings.dragSelectEnabled
        settings.dragSelectEnabled = false
        defer { settings.dragSelectEnabled = wasEnabled }
        let preview = makePreview()
        beginDrag(preview)

        move(preview, to: AreaPage.overFirst)
        await preview.pendingWork?.value

        #expect(screen.scans == 0)
    }
}

/// Where the underline of one line sits.
struct AreaUnderlineTests {
    private let line = CGRect(x: 100, y: 200, width: 380, height: 18)

    @Test("The underline runs the width of the line's text")
    func spansTheLine() {
        let underline = AreaUnderline.rect(under: line)

        #expect(underline.minX == line.minX)
        #expect(underline.maxX == line.maxX)
    }

    @Test("It sits just below the text, without touching it or the next line")
    func sitsJustBelow() {
        let underline = AreaUnderline.rect(under: line)

        #expect(underline.minY > line.maxY)
        #expect(underline.maxY <= line.maxY + 6)
    }

    @Test("It is a low wave, not a tall band")
    func isLow() {
        #expect(AreaUnderline.rect(under: line).height <= 5)
    }
}

/// The squiggle drawn inside an underline's band.
struct AreaSquiggleTests {
    private let band = AreaUnderline.rect(under: CGRect(x: 100, y: 200, width: 380, height: 18))

    @Test("The squiggle starts at the left of the line and ends at the right")
    func spansTheBand() throws {
        let path = AreaUnderline.squiggle(in: band)
        let end = try #require(path.currentPoint)

        #expect(abs(path.boundingRect.minX - band.minX) < 0.01)
        #expect(abs(end.x - band.maxX) < 0.01)
    }

    @Test("The stroke stays inside the band")
    func staysInsideTheBand() {
        let wave = AreaUnderline.squiggle(in: band).boundingRect
        let halfStroke = AreaUnderline.thickness / 2

        #expect(wave.minY >= band.minY + halfStroke - 0.01)
        #expect(wave.maxY <= band.maxY - halfStroke + 0.01)
    }

    @Test("It actually waves: it rises and falls across the line")
    func waves() {
        let wave = AreaUnderline.squiggle(in: band).boundingRect

        #expect(wave.height >= AreaUnderline.amplitude * 1.5)
    }

    @Test("A very short line still gets a whole wave, ending at its right edge", arguments: [1.0, 3.0, 7.0])
    func shortLine(width: CGFloat) throws {
        let short = AreaUnderline.rect(under: CGRect(x: 10, y: 10, width: width, height: 12))
        let end = try #require(AreaUnderline.squiggle(in: short).currentPoint)

        #expect(abs(end.x - short.maxX) < 0.01)
    }
}
