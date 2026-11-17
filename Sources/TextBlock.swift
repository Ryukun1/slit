import Foundation
import ApplicationServices

/// A logical block of text — a paragraph, code block, or column of text.
/// Lines within a block are vertically contiguous and horizontally aligned.
struct TextBlock: Identifiable, Equatable {
    let id = UUID()
    let lines: [TextLine]

    /// The bounding rect enclosing all lines in this block. Stored, because it
    /// is read inside sort comparators and hit tests — as a computed property
    /// every comparison re-walked all the lines.
    let boundingRect: CGRect

    init(lines: [TextLine]) {
        self.lines = lines
        self.boundingRect = lines.dropFirst().reduce(lines.first?.rect ?? .zero) {
            $0.union($1.rect)
        }
    }

    /// Whether a point falls inside (or near) this block.
    func contains(_ point: CGPoint, padding: CGFloat = 30) -> Bool {
        boundingRect.insetBy(dx: -padding, dy: -padding).contains(point)
    }
}

/// Groups individual text lines into logical blocks based on spatial proximity,
/// then merges blocks that belong to the same column of text.
enum TextBlockClusterer {

    /// Cluster lines into blocks, then merge vertically adjacent blocks
    /// in the same column into larger content regions.
    private static let logClustering =
        ProcessInfo.processInfo.environment["SLIT_TIMING"] == "1"

    /// How much bigger than the typical line gap a gap must be to break a
    /// paragraph. Mirrors `AppSettings.paragraphBreakSensitivity`, cached here
    /// because clustering runs off the main actor.
    nonisolated(unsafe) static var breakSensitivity: Double = 1.8

    static func cluster(_ lines: [TextLine]) -> [TextBlock] {
        guard !lines.isEmpty else { return [] }

        // Pre-filter: remove likely UI chrome
        let contentLines = filterOutChrome(lines)
        if logClustering, contentLines.count < lines.count {
            let dropped = lines.filter { line in
                !contentLines.contains { $0.id == line.id }
            }
            print("[cluster] chrome filter dropped \(dropped.count)/\(lines.count):")
            for d in dropped.prefix(12) {
                print("[cluster]   \"\(d.text.prefix(40))\" y=\(Int(d.rect.midY))")
            }
        }
        guard !contentLines.isEmpty else { return [] }

        // Sort by Y position (top to bottom)
        let sorted = contentLines.sorted { $0.rect.minY < $1.rect.minY }

        // Estimate typical line height from the median
        let heights = sorted.map(\.rect.height).sorted()
        let medianHeight = heights[heights.count / 2]

        // Phase 1: Group lines into paragraphs.
        //
        // A paragraph break is a vertical gap noticeably larger than the gap
        // between lines *within* a paragraph, so measure the typical gap on
        // this page rather than assuming one. Body text is the common case, so
        // the median gap is a good estimate of intra-paragraph leading; a break
        // is anything meaningfully above it.
        let gaps = zip(sorted, sorted.dropFirst())
            .map { $1.rect.minY - $0.rect.maxY }
            .filter { $0 >= 0 && $0 < medianHeight * 4 }
            .sorted()
        let medianGap = gaps.isEmpty ? medianHeight * 0.4 : gaps[gaps.count / 2]

        // Break when the gap exceeds the typical line gap by a clear margin.
        //
        // The floor guards against sub-pixel jitter splitting tightly-leaded
        // text, but it has to scale with the sensitivity too — a fixed floor
        // swamps the low end of the range and makes the control inert there.
        let sensitivity = CGFloat(breakSensitivity)
        let maxVerticalGap = max(
            medianGap * sensitivity,
            medianHeight * 0.3 * sensitivity
        )
        let maxHorizontalOffset = medianHeight * 4.0

        // Group into columns first. Sorting by Y alone interleaves lines from
        // side-by-side columns and separate windows, so consecutive entries
        // often belong to different places on screen — the horizontal test then
        // fails on every pair and every line becomes its own paragraph.
        let columns = groupIntoColumns(sorted, tolerance: maxHorizontalOffset)

        // Within a column, split on vertical gaps.
        var paragraphs: [[TextLine]] = []
        for column in columns {
            var currentParagraph: [TextLine] = [column[0]]

            for currLine in column.dropFirst() {
                let prevLine = currentParagraph.last!
                let verticalGap = currLine.rect.minY - prevLine.rect.maxY

                if verticalGap <= maxVerticalGap {
                    currentParagraph.append(currLine)
                } else {
                    paragraphs.append(currentParagraph)
                    currentParagraph = [currLine]
                }
            }
            paragraphs.append(currentParagraph)
        }

        // Paragraphs stand on their own — a gap bigger than the line spacing
        // *is* the paragraph boundary, so merging them back into page-sized
        // columns would undo Phase 1. Phase 2 now only rejoins fragments that
        // were split spuriously (e.g. a hanging indent or a one-line orphan
        // sitting at normal line spacing).
        let blocks = rejoinSplitFragments(
            paragraphs.map { TextBlock(lines: $0) },
            maxGap: maxVerticalGap
        )

        if logClustering {
            print("[cluster] \(contentLines.count) lines → \(paragraphs.count) paragraphs → \(blocks.count) blocks (medianHeight \(Int(medianHeight)), medianGap \(Int(medianGap)), breakAt \(Int(maxVerticalGap)))")
            for (i, b) in blocks.enumerated().prefix(20) {
                let r = b.boundingRect
                print("[cluster]   block \(i + 1): \(b.lines.count) lines, y \(Int(r.minY))–\(Int(r.maxY)), x \(Int(r.minX))–\(Int(r.maxX)) — \"\(b.lines.first?.text.prefix(30) ?? "")\"")
            }
        }

        return blocks
    }

    /// Group lines into vertical columns of text.
    ///
    /// A line joins a column when it overlaps that column horizontally; this
    /// keeps side-by-side columns and separate windows apart so the paragraph
    /// pass can compare vertically-adjacent lines that actually belong together.
    /// Each returned column is sorted top-to-bottom.
    private static func groupIntoColumns(
        _ lines: [TextLine], tolerance: CGFloat
    ) -> [[TextLine]] {
        var columns: [[TextLine]] = []
        var bounds: [CGRect] = []

        for line in lines {
            // Prefer the column whose horizontal span best matches this line.
            var bestIndex: Int?
            var bestOverlap: CGFloat = 0

            for (i, bound) in bounds.enumerated() {
                let overlapLeft = max(bound.minX, line.rect.minX)
                let overlapRight = min(bound.maxX, line.rect.maxX)
                let overlap = overlapRight - overlapLeft
                let smaller = min(bound.width, line.rect.width)
                guard smaller > 0 else { continue }

                // Require real overlap, or near-adjacency for hanging indents.
                let ratio = overlap / smaller
                if ratio > 0.35 || (overlap > -tolerance && ratio > 0.15) {
                    if overlap > bestOverlap {
                        bestOverlap = overlap
                        bestIndex = i
                    }
                }
            }

            if let index = bestIndex {
                columns[index].append(line)
                bounds[index] = bounds[index].union(line.rect)
            } else {
                columns.append([line])
                bounds.append(line.rect)
            }
        }

        return columns.map { $0.sorted { $0.rect.minY < $1.rect.minY } }
    }

    /// Rejoin blocks that a strict gap test split apart even though they read
    /// as one paragraph — the gap between them is no larger than the gap that
    /// holds lines together, and they share a left edge.
    private static func rejoinSplitFragments(
        _ blocks: [TextBlock], maxGap: CGFloat
    ) -> [TextBlock] {
        guard blocks.count > 1 else { return blocks }

        let ordered = blocks.sorted { $0.boundingRect.minY < $1.boundingRect.minY }
        var result: [TextBlock] = []
        var current = ordered[0]

        for next in ordered.dropFirst() {
            let a = current.boundingRect
            let b = next.boundingRect
            let gap = b.minY - a.maxY
            // Same column: left edges close together, and they overlap in X.
            let sameColumn = abs(a.minX - b.minX) < a.height
                && hasSignificantHorizontalOverlap(a, b)

            if gap <= maxGap && sameColumn {
                current = TextBlock(
                    lines: (current.lines + next.lines)
                        .sorted { $0.rect.minY < $1.rect.minY }
                )
            } else {
                result.append(current)
                current = next
            }
        }
        result.append(current)
        return result
    }

    /// Merge blocks that are in the same horizontal column and vertically close.
    private static func mergeColumnBlocks(_ blocks: [TextBlock], maxGap: CGFloat) -> [TextBlock] {
        guard blocks.count > 1 else { return blocks }

        var merged: [TextBlock] = []
        var used = Set<Int>()

        for i in 0..<blocks.count {
            if used.contains(i) { continue }

            var combinedLines = blocks[i].lines
            used.insert(i)

            // Keep merging any block that overlaps horizontally and is close vertically
            var changed = true
            while changed {
                changed = false
                let currentBounds = TextBlock(lines: combinedLines).boundingRect

                for j in 0..<blocks.count {
                    if used.contains(j) { continue }

                    let candidate = blocks[j]
                    let candidateBounds = candidate.boundingRect

                    let verticalGap = verticalDistance(currentBounds, candidateBounds)
                    let horizontallyAligned = hasSignificantHorizontalOverlap(
                        currentBounds, candidateBounds
                    )

                    if verticalGap <= maxGap && horizontallyAligned {
                        combinedLines.append(contentsOf: candidate.lines)
                        used.insert(j)
                        changed = true
                    }
                }
            }

            merged.append(TextBlock(lines: combinedLines.sorted { $0.rect.minY < $1.rect.minY }))
        }

        return merged
    }

    /// Vertical distance between two rects (0 if overlapping).
    private static func verticalDistance(_ a: CGRect, _ b: CGRect) -> CGFloat {
        if a.maxY < b.minY {
            return b.minY - a.maxY
        } else if b.maxY < a.minY {
            return a.minY - b.maxY
        }
        return 0 // overlapping vertically
    }

    /// Check if two rects have significant horizontal overlap (at least 30% of the smaller width).
    private static func hasSignificantHorizontalOverlap(_ a: CGRect, _ b: CGRect) -> Bool {
        let overlapLeft = max(a.minX, b.minX)
        let overlapRight = min(a.maxX, b.maxX)
        let overlap = max(0, overlapRight - overlapLeft)
        let smallerWidth = min(a.width, b.width)
        return smallerWidth > 0 && overlap / smallerWidth > 0.3
    }

    /// Check if two rects overlap horizontally (i.e., same column of text).
    private static func hasHorizontalOverlap(_ a: CGRect, _ b: CGRect, tolerance: CGFloat) -> Bool {
        let aLeft = a.minX - tolerance
        let aRight = a.maxX + tolerance
        let bLeft = b.minX
        let bRight = b.maxX

        return aLeft < bRight && bLeft < aRight
    }

    // MARK: - UI chrome filtering

    /// Filters out single-character labels and text inside window toolbars/tab bars.
    private static func filterOutChrome(_ lines: [TextLine]) -> [TextLine] {
        guard lines.count > 3 else { return lines }

        // Get the frontmost window's toolbar height to exclude its chrome
        let toolbarCutoff = frontmostWindowToolbarBottom()

        return lines.filter { line in
            let trimmed = line.text.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.count < 2 { return false }

            // Skip lines inside the window toolbar area
            if let cutoff = toolbarCutoff, line.rect.midY < cutoff {
                return false
            }

            return true
        }
    }

    /// Get the Y coordinate below which the frontmost window's toolbar ends.
    /// Returns nil if it can't be determined.
    private static func frontmostWindowToolbarBottom() -> CGFloat? {
        let systemWide = AXUIElementCreateSystemWide()
        var appRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(systemWide, kAXFocusedApplicationAttribute as CFString, &appRef) == .success,
              let app = appRef else { return nil }

        let axApp = app as! AXUIElement

        // Get the focused window
        var windowRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(axApp, kAXFocusedWindowAttribute as CFString, &windowRef) == .success,
              let window = windowRef else { return nil }

        let axWindow = window as! AXUIElement

        // Get window position and size
        var posRef: CFTypeRef?
        var sizeRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(axWindow, kAXPositionAttribute as CFString, &posRef) == .success,
              AXUIElementCopyAttributeValue(axWindow, kAXSizeAttribute as CFString, &sizeRef) == .success,
              let posVal = posRef, let sizeVal = sizeRef else { return nil }

        var windowPos = CGPoint.zero
        var windowSize = CGSize.zero
        AXValueGetValue(posVal as! AXValue, .cgPoint, &windowPos)
        AXValueGetValue(sizeVal as! AXValue, .cgSize, &windowSize)

        // The toolbar/tab bar area is typically the top ~90px of the window
        // (title bar ~28px + toolbar ~40px + tab bar ~30px for browsers)
        let toolbarHeight: CGFloat = 90
        return windowPos.y + toolbarHeight
    }
}
