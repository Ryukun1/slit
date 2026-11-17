import AppKit
import CoreGraphics

/// Brightness of every pixel of a captured image, top row first.
struct LuminanceMap {
    let width: Int
    let height: Int
    let pixels: [UInt8]

    init?(image: CGImage) {
        let width = image.width, height = image.height
        guard width > 0, height > 0 else { return nil }
        var pixels = [UInt8](repeating: 0, count: width * height)
        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(
                data: buffer.baseAddress, width: width, height: height,
                bitsPerComponent: 8, bytesPerRow: width,
                space: CGColorSpaceCreateDeviceGray(),
                bitmapInfo: CGImageAlphaInfo.none.rawValue
            ) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { return nil }
        self.width = width
        self.height = height
        self.pixels = pixels
    }
}

/// Where the word-by-word reveal stops after each word of a line.
///
/// OCR reports a box per word, but only roughly: a few points out is normal,
/// which is enough to cut the last letter of a word or show the first letter
/// of the next. The spaces themselves are exact in the captured pixels, so
/// each stop is moved to the middle of the real space nearest OCR's estimate.
enum WordStops {
    /// A space must be at least this wide, as a share of the line's height,
    /// to stop in. Gaps between letters of one word are narrower.
    private static let minimumGapShare: CGFloat = 0.1
    /// How far from OCR's estimate a space may be, as a share of line height.
    private static let searchShare: CGFloat = 0.5
    /// Pixels this close to the page colour (of 255) are not text.
    private static let minimumContrast = 30
    /// A pixel counts as text when it differs from the page colour by at
    /// least this share of the strongest difference on the line.
    private static let inkShare = 0.35
    /// A horizontal run of text pixels longer than this many line heights is
    /// an underline or a rule, not a letter.
    private static let ruleLengthInLineHeights = 2
    private static let histogramBinWidth = 8

    /// Stops for one OCR line, in screen coordinates: one per word except the
    /// last. Empty when OCR gave no usable boxes, so the caller must estimate.
    static func stops(
        forLine lineRect: CGRect, wordRects: [CGRect], in map: LuminanceMap?, frame: CGRect
    ) -> [CGFloat] {
        guard let estimates = estimates(from: wordRects), !estimates.isEmpty else { return [] }
        let gaps = map.map { screenGaps(forLine: lineRect, in: $0, frame: frame) } ?? []
        return stops(estimates: estimates, gaps: gaps, lineHeight: lineRect.height)
    }

    /// Stops for text Slit draws itself (the OpenDyslexic layer), in the same
    /// coordinates as `leftEdge`. Nothing needs finding here: the font says
    /// exactly where each word ends and the next begins.
    ///
    /// - Parameters:
    ///   - scale: horizontal squeeze applied to the drawn text.
    ///   - leftEdge: where the text starts.
    static func stops(
        forRenderedText text: String, font: NSFont, scale: CGFloat, leftEdge: CGFloat
    ) -> [CGFloat] {
        let words = WordSegmenter.words(in: text)
        func width(_ part: Substring) -> CGFloat {
            (String(part) as NSString).size(withAttributes: [.font: font]).width
        }
        return zip(words, words.dropFirst()).map { word, next in
            let wordEnd = width(text[..<word.range.upperBound])
            // Measured back from the end of the next word, so it does not
            // depend on how trailing spaces are counted.
            let nextStart = width(text[..<next.range.upperBound]) - width(text[next.range])
            return leftEdge + (wordEnd + nextStart) / 2 * scale
        }
    }

    /// OCR's own idea of each stop: halfway between neighbouring word boxes.
    private static func estimates(from wordRects: [CGRect]) -> [CGFloat]? {
        guard wordRects.count >= 2,
              wordRects.allSatisfy({ !$0.isNull && !$0.isInfinite }) else { return nil }
        return zip(wordRects, wordRects.dropFirst()).map { ($0.maxX + $1.minX) / 2 }
    }

    /// Move each estimate to the middle of the best space near it. An estimate
    /// with no space nearby is kept as it is.
    static func stops(
        estimates: [CGFloat], gaps: [Range<CGFloat>], lineHeight: CGFloat
    ) -> [CGFloat] {
        let minimumWidth = lineHeight * minimumGapShare
        let reach = lineHeight * searchShare
        let spaces = gaps.filter { $0.upperBound - $0.lowerBound >= minimumWidth }

        return estimates.reduce(into: (stops: [CGFloat](), floor: -CGFloat.infinity)) { result, estimate in
            // Later words stop further right: a space is used once.
            let best = spaces
                .filter { $0.lowerBound >= result.floor && distance(from: estimate, to: $0) <= reach }
                // Prefer the nearest space, and a wide one over a narrow one.
                .min { score(estimate, $0) < score(estimate, $1) }
            if let best {
                result.stops.append((best.lowerBound + best.upperBound) / 2)
                result.floor = best.upperBound
            } else {
                result.stops.append(estimate)
                result.floor = max(result.floor, estimate)
            }
        }.stops
    }

    private static func distance(from point: CGFloat, to gap: Range<CGFloat>) -> CGFloat {
        max(gap.lowerBound - point, 0, point - gap.upperBound)
    }

    private static func score(_ estimate: CGFloat, _ gap: Range<CGFloat>) -> CGFloat {
        distance(from: estimate, to: gap) - (gap.upperBound - gap.lowerBound)
    }

    /// Runs of blank columns between the first and last column with text.
    static func gaps(inkColumns: [Bool]) -> [Range<Int>] {
        guard let first = inkColumns.firstIndex(of: true),
              let last = inkColumns.lastIndex(of: true) else { return [] }
        return (first...last).reduce(into: (gaps: [Range<Int>](), start: Int?.none)) { result, column in
            if inkColumns[column] {
                if let start = result.start { result.gaps.append(start..<column) }
                result.start = nil
            } else if result.start == nil {
                result.start = column
            }
        }.gaps
    }

    // MARK: - Pixels

    /// The blank runs of one line, converted to screen coordinates.
    private static func screenGaps(
        forLine lineRect: CGRect, in map: LuminanceMap, frame: CGRect
    ) -> [Range<CGFloat>] {
        guard frame.width > 0, frame.height > 0 else { return [] }
        let scaleX = CGFloat(map.width) / frame.width
        let scaleY = CGFloat(map.height) / frame.height
        let x0 = max(0, Int(((lineRect.minX - frame.minX) * scaleX).rounded(.down)))
        let x1 = min(map.width, Int(((lineRect.maxX - frame.minX) * scaleX).rounded(.up)))
        let y0 = max(0, Int(((lineRect.minY - frame.minY) * scaleY).rounded(.down)))
        let y1 = min(map.height, Int(((lineRect.maxY - frame.minY) * scaleY).rounded(.up)))
        guard x1 > x0, y1 > y0 else { return [] }

        let ink = inkColumns(in: map, columns: x0..<x1, rows: y0..<y1)
        return gaps(inkColumns: ink).map { gap in
            (frame.minX + CGFloat(x0 + gap.lowerBound) / scaleX)
                ..< (frame.minX + CGFloat(x0 + gap.upperBound) / scaleX)
        }
    }

    /// For each pixel column of the area, whether any of it is text.
    static func inkColumns(in map: LuminanceMap, columns: Range<Int>, rows: Range<Int>) -> [Bool] {
        let page = pageLuminance(in: map, columns: columns, rows: rows)
        return map.pixels.withUnsafeBufferPointer { pixels in
            let strongest = rows.reduce(0) { strongest, row in
                columns.reduce(strongest) { max($0, abs(Int(pixels[row * map.width + $1]) - page)) }
            }
            guard strongest >= minimumContrast else {
                return [Bool](repeating: false, count: columns.count)
            }
            let threshold = max(minimumContrast, Int(Double(strongest) * inkShare))
            let longestLetterRun = rows.count * ruleLengthInLineHeights
            var hasInk = [Bool](repeating: false, count: columns.count)

            for row in rows {
                var runStart: Int? = nil
                // One past the end, so a run touching the right edge is closed.
                for column in columns.lowerBound...columns.upperBound {
                    let isInk = column < columns.upperBound
                        && abs(Int(pixels[row * map.width + column]) - page) >= threshold
                    if isInk {
                        runStart = runStart ?? column
                    } else if let start = runStart {
                        // Letters only: an underline would fill every space.
                        if column - start <= longestLetterRun {
                            for inked in start..<column { hasInk[inked - columns.lowerBound] = true }
                        }
                        runStart = nil
                    }
                }
            }
            return hasInk
        }
    }

    /// The page colour behind the text: the most common brightness in the area.
    private static func pageLuminance(in map: LuminanceMap, columns: Range<Int>, rows: Range<Int>) -> Int {
        let counts = map.pixels.withUnsafeBufferPointer { pixels in
            rows.reduce(into: [Int](repeating: 0, count: 256 / histogramBinWidth)) { counts, row in
                for column in columns {
                    counts[Int(pixels[row * map.width + column]) / histogramBinWidth] += 1
                }
            }
        }
        let commonest = counts.indices.max { counts[$0] < counts[$1] } ?? 0
        return commonest * histogramBinWidth + histogramBinWidth / 2
    }
}
