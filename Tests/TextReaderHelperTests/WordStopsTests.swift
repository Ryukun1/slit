import AppKit
import CoreGraphics
import Testing
@testable import TextReaderHelper

/// Word-by-word reveal must stop in the space after a word: never part-way
/// through it, and never far enough to show the start of the next one.
struct WordStopsTests {
    // MARK: Blank runs between letters

    @Test("Gaps are the blank runs between the first and last letter")
    func gapsIgnoreTheMargins() {
        let ink = [false, false, true, true, false, false, false, true, false, true, false]

        #expect(WordStops.gaps(inkColumns: ink) == [4..<7, 8..<9])
    }

    @Test("A blank line has no gaps")
    func blankLineHasNoGaps() {
        #expect(WordStops.gaps(inkColumns: [false, false, false]).isEmpty)
    }

    // MARK: Choosing where to stop

    @Test("A stop lands in the middle of the space nearest the estimate")
    func stopSnapsToTheSpace() {
        // Letters 2 wide with 1-wide gaps inside words; an 8-wide space at 40.
        let gaps: [Range<CGFloat>] = [30..<31, 33..<34, 40..<48, 51..<52]

        // The estimate sits just inside the last letter of the word.
        let stops = WordStops.stops(estimates: [38], gaps: gaps, lineHeight: 30)

        #expect(stops == [44])
    }

    @Test("Gaps between letters are too narrow to stop in")
    func letterGapsAreIgnored() {
        let gaps: [Range<CGFloat>] = [30..<31, 33..<34]

        // No space near the estimate: keep the estimate rather than cut a word.
        #expect(WordStops.stops(estimates: [32], gaps: gaps, lineHeight: 30) == [32])
    }

    @Test("A space far from the estimate is not used")
    func distantSpaceIsNotUsed() {
        let gaps: [Range<CGFloat>] = [200..<210]

        #expect(WordStops.stops(estimates: [50], gaps: gaps, lineHeight: 30) == [50])
    }

    @Test("Two words never stop in the same space")
    func eachStopHasItsOwnSpace() {
        let gaps: [Range<CGFloat>] = [40..<48, 60..<68]

        // Both estimates are closest to the first space.
        let stops = WordStops.stops(estimates: [42, 50], gaps: gaps, lineHeight: 30)

        #expect(stops == [44, 64])
    }

    // MARK: From real pixels

    private static let scale: CGFloat = 2
    private static let frame = CGRect(x: 300, y: 500, width: 620, height: 60)
    private static let textOrigin = CGPoint(x: 20, y: 18)
    private static let font = NSFont.systemFont(ofSize: 16)
    private static let sentence = "the words being read. The rest of the page is still there,"

    private static func attributed(_ string: String, color: NSColor) -> NSAttributedString {
        NSAttributedString(string: string, attributes: [.font: font, .foregroundColor: color])
    }

    /// A capture of one line of text, as the screen would show it.
    private static func capture(
        text: NSColor = .black, background: NSColor = .white, underlined: Bool = false
    ) throws -> LuminanceMap {
        let width = Int(frame.width * scale), height = Int(frame.height * scale)
        let context = try #require(CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: scale, y: -scale)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
        background.setFill()
        CGRect(origin: .zero, size: frame.size).fill()
        attributed(sentence, color: text).draw(at: textOrigin)
        if underlined {
            text.setFill()
            CGRect(x: textOrigin.x, y: textOrigin.y + 19, width: 560, height: 1).fill()
        }
        NSGraphicsContext.restoreGraphicsState()
        let image = try #require(context.makeImage())
        return try #require(LuminanceMap(image: image))
    }

    /// Where each word really starts and ends on screen.
    private static var wordExtents: [ClosedRange<CGFloat>] {
        WordSegmenter.words(in: sentence).map { word in
            let before = attributed(String(sentence[..<word.range.lowerBound]), color: .black).size().width
            let through = attributed(String(sentence[..<word.range.upperBound]), color: .black).size().width
            return (frame.minX + textOrigin.x + before)...(frame.minX + textOrigin.x + through)
        }
    }

    private static var lineRect: CGRect {
        let size = attributed(sentence, color: .black).size()
        return CGRect(
            x: frame.minX + textOrigin.x, y: frame.minY + textOrigin.y,
            width: size.width, height: size.height
        )
    }

    /// Word boxes as OCR reports them: roughly right, a few points off.
    private static func roughBoxes(shiftedBy shift: CGFloat) -> [CGRect] {
        wordExtents.map {
            CGRect(
                x: $0.lowerBound + shift, y: lineRect.minY,
                width: $0.upperBound - $0.lowerBound, height: lineRect.height
            )
        }
    }

    private func expectStopsBetweenWords(_ stops: [CGFloat]) {
        let extents = Self.wordExtents
        #expect(stops.count == extents.count - 1)
        for (index, stop) in stops.enumerated() {
            // Past the end of this word, and before the start of the next.
            #expect(stop >= extents[index].upperBound - 0.5, "cuts word \(index)")
            #expect(stop <= extents[index + 1].lowerBound + 0.5, "shows word \(index + 1)")
        }
    }

    @Test("Stops fall in the spaces even when the word boxes are a few points off",
          arguments: [-3.0, 0.0, 3.0])
    func stopsFallInSpaces(shift: Double) throws {
        let stops = WordStops.stops(
            forLine: Self.lineRect, wordRects: Self.roughBoxes(shiftedBy: CGFloat(shift)),
            in: try Self.capture(), frame: Self.frame
        )

        expectStopsBetweenWords(stops)
    }

    @Test("Light text on a dark page works the same")
    func lightOnDark() throws {
        let stops = WordStops.stops(
            forLine: Self.lineRect, wordRects: Self.roughBoxes(shiftedBy: 3),
            in: try Self.capture(text: .white, background: NSColor(white: 0.12, alpha: 1)),
            frame: Self.frame
        )

        expectStopsBetweenWords(stops)
    }

    @Test("An underline running through the spaces does not hide them")
    func underlinedText() throws {
        let stops = WordStops.stops(
            forLine: Self.lineRect, wordRects: Self.roughBoxes(shiftedBy: 3),
            in: try Self.capture(underlined: true), frame: Self.frame
        )

        expectStopsBetweenWords(stops)
    }

    @Test("Without usable word boxes there are no stops, so the caller estimates")
    func missingBoxesGiveNoStops() throws {
        let boxes = Self.roughBoxes(shiftedBy: 0).enumerated().map { $0.offset == 2 ? CGRect.null : $0.element }

        let stops = WordStops.stops(
            forLine: Self.lineRect, wordRects: boxes, in: try Self.capture(), frame: Self.frame
        )

        #expect(stops.isEmpty)
    }

    // MARK: Text Slit draws itself (OpenDyslexic)

    /// Draws `sentence` the way the OpenDyslexic layer does: from a left
    /// edge, squeezed horizontally by a fit scale.
    private static func captureRendered(font: NSFont, squeeze: CGFloat, left: CGFloat) throws -> LuminanceMap {
        let width = Int(frame.width * scale), height = Int(frame.height * scale)
        let context = try #require(CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: scale, y: -scale)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
        NSColor.white.setFill()
        CGRect(origin: .zero, size: frame.size).fill()
        context.translateBy(x: left, y: 0)
        context.scaleBy(x: squeeze, y: 1)
        NSAttributedString(string: sentence, attributes: [.font: font, .foregroundColor: NSColor.black])
            .draw(at: CGPoint(x: 0, y: 14))
        NSGraphicsContext.restoreGraphicsState()
        let image = try #require(context.makeImage())
        return try #require(LuminanceMap(image: image))
    }

    @Test("For text Slit draws itself, stops are measured from the font and land in the spaces",
          arguments: [1.0, 0.88, 0.7])
    func renderedTextStops(squeeze: Double) throws {
        let font = NSFont(name: "Verdana", size: 14) ?? NSFont.systemFont(ofSize: 14)
        let left: CGFloat = 24
        let map = try Self.captureRendered(font: font, squeeze: CGFloat(squeeze), left: left)

        let stops = WordStops.stops(
            forRenderedText: Self.sentence, font: font, scale: CGFloat(squeeze), leftEdge: left
        )

        #expect(stops.count == WordSegmenter.words(in: Self.sentence).count - 1)
        #expect(stops == stops.sorted())
        // No ink in the pixel columns at each stop: it is in a space.
        let ink = WordStops.inkColumns(in: map, columns: 0..<map.width, rows: 0..<map.height)
        for stop in stops {
            let column = Int((stop * Self.scale).rounded())
            #expect(!ink[column - 1] && !ink[column] && !ink[column + 1], "stop at \(stop) touches a letter")
        }
    }

    @Test("A single word has no stops")
    func renderedSingleWord() {
        let font = NSFont.systemFont(ofSize: 14)

        #expect(WordStops.stops(forRenderedText: "word", font: font, scale: 1, leftEdge: 0).isEmpty)
    }
}
