import CoreGraphics
import Foundation

/// Turns raw detected lines into paragraphs with a recursive XY-cut.
///
/// A region is split left/right wherever a vertical gutter runs through it;
/// failing that, it is split top/bottom wherever the vertical gap is clearly
/// larger than that region's own line spacing. A region that can be cut
/// neither way is one paragraph.
///
/// This is the single place layout is decided: the block the click lands in
/// *is* the selection, so the "Paragraph size" setting governs it directly.
/// Pure — no Accessibility calls, no shared state — so it is safe off the main
/// actor and can be tested with synthetic rects.
enum LayoutAnalyzer {

    struct Options: Sendable {
        /// How many times the normal line gap a gap must be to break a paragraph.
        var breakSensitivity: Double = 1.8
        /// Toolbar strip of the target window (screen coordinates). Lines whose
        /// centre falls inside it are treated as chrome and dropped.
        var chromeBand: CGRect? = nil
    }

    private enum Tuning {
        static let maxDepth = 12
        /// A gutter must be at least this many line-heights wide (and `minGutterPoints`).
        static let gutterLineHeights: CGFloat = 1.2
        static let minGutterPoints: CGFloat = 12
        static let histogramBucket: CGFloat = 4
        /// Gutter coverage allowed, as a share of the busiest X position, so a
        /// stray line bridging two columns does not hide the gutter.
        static let gutterCoverageShare = 5
        /// With fewer gaps than this there is nothing to take a median of.
        static let minGapsForMedian = 3
        /// Prior for single-spaced text when a region is too small to measure.
        static let priorLineGapHeights: CGFloat = 0.6
        /// No real line gap exceeds this many line-heights.
        static let maxLineGapHeights: CGFloat = 1.5
        static let gapFloorHeights: CGFloat = 0.3
        static let minChromeFilterLineCount = 4
    }

    static func paragraphs(from lines: [TextLine], options: Options = Options()) -> [TextBlock] {
        let content = removingChrome(lines, band: options.chromeBand)
        guard !content.isEmpty else { return [] }

        return segment(content, sensitivity: CGFloat(options.breakSensitivity), depth: 0)
            .map { TextBlock(lines: $0.sorted(by: readingOrder)) }
            .sorted { readingOrder($0.boundingRect, $1.boundingRect) }
    }

    /// Lines that survive the chrome filter. Exposed so the debug overlay can
    /// show what was dropped without re-implementing the rule.
    static func removingChrome(_ lines: [TextLine], band: CGRect?) -> [TextLine] {
        guard lines.count >= Tuning.minChromeFilterLineCount else { return lines }
        return lines.filter { line in
            let trimmed = line.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.count >= 2 else { return false }
            if let band, band.contains(CGPoint(x: line.rect.midX, y: line.rect.midY)) {
                return false
            }
            return true
        }
    }

    // MARK: - Recursive cut

    private static func segment(
        _ lines: [TextLine], sensitivity: CGFloat, depth: Int
    ) -> [[TextLine]] {
        guard lines.count > 1, depth < Tuning.maxDepth else { return [lines] }
        let lineHeight = median(lines.map(\.rect.height))

        let columns = splitAtGutters(lines, lineHeight: lineHeight)
        if columns.count > 1 {
            return columns.flatMap { segment($0, sensitivity: sensitivity, depth: depth + 1) }
        }

        let strips = splitAtVerticalGaps(lines, lineHeight: lineHeight, sensitivity: sensitivity)
        if strips.count > 1 {
            return strips.flatMap { segment($0, sensitivity: sensitivity, depth: depth + 1) }
        }

        return [lines]
    }

    /// Left/right split at vertical gutters, or `[lines]` if there are none.
    private static func splitAtGutters(_ lines: [TextLine], lineHeight: CGFloat) -> [[TextLine]] {
        let minX = lines.map(\.rect.minX).min() ?? 0
        let maxX = lines.map(\.rect.maxX).max() ?? 0
        let bucket = Tuning.histogramBucket
        let bucketCount = Int((maxX - minX) / bucket) + 1
        guard bucketCount > 2 else { return [lines] }

        let coverage = lines.reduce(into: [Int](repeating: 0, count: bucketCount)) { counts, line in
            let first = max(0, Int((line.rect.minX - minX) / bucket))
            let last = min(bucketCount - 1, Int((line.rect.maxX - minX) / bucket))
            guard first <= last else { return }
            for index in first...last { counts[index] += 1 }
        }

        let threshold = max(1, (coverage.max() ?? 0) / Tuning.gutterCoverageShare)
        let minRun = max(2, Int(max(lineHeight * Tuning.gutterLineHeights, Tuning.minGutterPoints) / bucket))

        // Runs of low coverage bounded by text on both sides. A run touching
        // either edge is a ragged margin, not a gutter.
        var cutXs: [CGFloat] = []
        var runStart: Int?
        for (index, count) in coverage.enumerated() {
            if count < threshold {
                if runStart == nil { runStart = index }
            } else if let start = runStart {
                if start > 0, index - start >= minRun {
                    cutXs.append(minX + CGFloat(start + index) / 2 * bucket)
                }
                runStart = nil
            }
        }
        guard !cutXs.isEmpty else { return [lines] }

        let groups = Dictionary(grouping: lines) { line in
            cutXs.filter { line.rect.midX > $0 }.count
        }
        let columns = groups.keys.sorted().compactMap { groups[$0] }
        return columns.count > 1 ? columns : [lines]
    }

    /// Top/bottom split at gaps clearly larger than this region's line spacing.
    private static func splitAtVerticalGaps(
        _ lines: [TextLine], lineHeight: CGFloat, sensitivity: CGFloat
    ) -> [[TextLine]] {
        // Rows: lines that overlap vertically (e.g. two fragments of one row).
        let sorted = lines.sorted { $0.rect.minY < $1.rect.minY }
        var rows: [[TextLine]] = []
        var rowBottom = -CGFloat.greatestFiniteMagnitude
        var gaps: [CGFloat] = []
        for line in sorted {
            if rows.isEmpty || line.rect.minY > rowBottom {
                if !rows.isEmpty { gaps.append(line.rect.minY - rowBottom) }
                rows.append([line])
                rowBottom = line.rect.maxY
            } else {
                rows[rows.count - 1].append(line)
                rowBottom = max(rowBottom, line.rect.maxY)
            }
        }
        guard rows.count > 1 else { return [lines] }

        let breakGap = breakThreshold(gaps: gaps, lineHeight: lineHeight, sensitivity: sensitivity)

        var strips: [[TextLine]] = [rows[0]]
        for (row, gap) in zip(rows.dropFirst(), gaps) {
            if gap > breakGap {
                strips.append(row)
            } else {
                strips[strips.count - 1].append(contentsOf: row)
            }
        }
        return strips
    }

    /// The gap above which two rows belong to different paragraphs.
    private static func breakThreshold(
        gaps: [CGFloat], lineHeight: CGFloat, sensitivity: CGFloat
    ) -> CGFloat {
        let measured: CGFloat
        if gaps.count >= Tuning.minGapsForMedian {
            // Body text dominates, so the median gap is the line gap.
            measured = min(median(gaps), lineHeight * Tuning.maxLineGapHeights)
        } else {
            // Too few rows to measure: trust the smallest gap, but never
            // beyond what single-spaced text plausibly looks like.
            measured = min(gaps.min() ?? 0, lineHeight * Tuning.priorLineGapHeights)
        }
        return max(measured, lineHeight * Tuning.gapFloorHeights) * sensitivity
    }

    // MARK: - Helpers

    private static func median(_ values: [CGFloat]) -> CGFloat {
        guard !values.isEmpty else { return 0 }
        return values.sorted()[values.count / 2]
    }

    private static func readingOrder(_ a: TextLine, _ b: TextLine) -> Bool {
        readingOrder(a.rect, b.rect)
    }

    private static func readingOrder(_ a: CGRect, _ b: CGRect) -> Bool {
        a.minY != b.minY ? a.minY < b.minY : a.minX < b.minX
    }
}

extension TextLine {
    /// True when `other` is this same on-screen line from a different detection
    /// pass. Every pass mints new ids, so identity has to be geometric.
    func isSameLine(as other: TextLine) -> Bool {
        let overlap = rect.intersection(other.rect)
        guard !overlap.isNull else { return false }
        return overlap.height >= min(rect.height, other.rect.height) * 0.5
            && overlap.width >= min(rect.width, other.rect.width) * 0.5
    }
}
