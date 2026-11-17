import AppKit
import CoreGraphics
import Testing
@testable import TextReaderHelper

/// The whole path on a real page image: OCR finds the lines and rough word
/// boxes, and the stops still land in the spaces between the words.
@MainActor
@Suite(.serialized)
struct WordStopsOCRTests {
    private static let scale: CGFloat = 2
    private static let frame = CGRect(x: 0, y: 0, width: 760, height: 300)
    private static let left: CGFloat = 56
    private static let top: CGFloat = 44
    private static let lineStep: CGFloat = 27
    private static let text = [
        "Reading on a screen is harder than it looks, because every line",
        "competes with its neighbours for attention. A narrow opening",
        "that follows the eye removes that competition and leaves only",
        "the words being read. The rest of the page is still there,",
        "but covered, so the shape of the paragraph stays in view",
        "and it is easy to find the way back after looking away.",
        "Word by word, the opening grows along the current line,",
        "and the lines already read can stay open above it.",
    ]

    private static func attributed(_ string: String, font: NSFont) -> NSAttributedString {
        NSAttributedString(string: string, attributes: [.font: font, .foregroundColor: NSColor.black])
    }

    private static func page(font: NSFont) throws -> CGImage {
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
        frame.fill()
        for (index, line) in text.enumerated() {
            attributed(line, font: font).draw(at: CGPoint(x: left, y: top + CGFloat(index) * lineStep))
        }
        NSGraphicsContext.restoreGraphicsState()
        return try #require(context.makeImage())
    }

    private static func wordExtents(_ line: String, font: NSFont) -> [ClosedRange<CGFloat>] {
        WordSegmenter.words(in: line).map { word in
            let before = attributed(String(line[..<word.range.lowerBound]), font: font).size().width
            let through = attributed(String(line[..<word.range.upperBound]), font: font).size().width
            return (left + before)...(left + through)
        }
    }

    @Test("On a real page, every stop is in the space after its word",
          arguments: ["Helvetica", "Times New Roman", "Georgia", "Verdana"])
    func stopsOnARealPage(fontName: String) async throws {
        let font = try #require(NSFont(name: fontName, size: 15))
        // Asked for directly, not through the shared word-by-word setting:
        // other tests change that setting while this one is waiting on OCR.
        let lines = await TextDetector.performOCR(
            on: try Self.page(font: font), in: Self.frame, measuringWordSpaces: true
        )

        var checked = 0
        for expected in Self.text {
            // Only lines OCR read word for word can be compared.
            guard let line = lines.first(where: { $0.text == expected }) else { continue }
            let extents = Self.wordExtents(expected, font: font)
            #expect(line.revealStops.count == extents.count - 1)
            for (index, stop) in line.revealStops.enumerated() {
                #expect(stop >= extents[index].upperBound - 0.75,
                        "cuts word \(index) of \"\(expected)\" by \(extents[index].upperBound - stop)")
                #expect(stop <= extents[index + 1].lowerBound + 0.75,
                        "shows word \(index + 1) of \"\(expected)\" by \(stop - extents[index + 1].lowerBound)")
            }
            checked += 1
        }
        // The check means nothing if OCR misread most of the page.
        #expect(checked >= Self.text.count - 2)
    }
}
