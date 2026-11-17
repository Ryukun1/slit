import Foundation
import ApplicationServices
import CoreGraphics
import ScreenCaptureKit
import Vision
import AppKit

/// Detects lines of text on screen using Accessibility API (primary)
/// or Vision OCR (fallback). Returns clustered text blocks.
enum TextDetector {

    /// Detect all text blocks on the current screen near a point.
    /// Returns blocks sorted by distance to the given point.
    private static let logTimings =
        ProcessInfo.processInfo.environment["SLIT_TIMING"] == "1"

    /// Farthest a click may be from a paragraph and still select it. Beyond
    /// this the click was on empty space, and selecting some distant block
    /// would be a surprise.
    static let maxSnapDistance: CGFloat = 150

    /// Height of the strip at the top of a window treated as toolbar chrome
    /// (title bar ~28 + toolbar ~40 + tab bar ~30 in browsers).
    private static let toolbarHeight: CGFloat = 90

    static func detectBlocks(near point: CGPoint) async -> [TextBlock] {
        await detect(near: point).blocks
    }

    /// Detection result: the clustered blocks the app acts on, plus every raw
    /// line the winning detection stage produced. Lines that clustering or the
    /// chrome filter discarded appear only in `allLines`.
    struct DetectionResult {
        let blocks: [TextBlock]
        let allLines: [TextLine]
        /// The toolbar strip that was filtered out, so the same lines can be
        /// re-clustered later with identical rules.
        let chromeBand: CGRect?
    }

    /// Full-screen detection for the debug overlay.
    ///
    /// `detect(near:)` stops at the window under the click, which is right for
    /// selection but wrong for a view meant to show every paragraph on screen.
    /// This always OCRs the whole display the pointer is on.
    static func detectEverything(near point: CGPoint) async -> DetectionResult {
        let band = windowFrame(at: point).map { toolbarBand(of: $0) }
        let options = await layoutOptions(chromeBand: band)
        let ocrLines = await detectViaFullScreenOCR(containing: point)
        return DetectionResult(
            blocks: LayoutAnalyzer.paragraphs(from: ocrLines, options: options),
            allLines: ocrLines,
            chromeBand: band
        )
    }

    /// Run detection and return both the blocks and the raw lines behind them,
    /// so callers that need to show what was discarded do not have to re-run
    /// (or reimplement) the stage-selection logic.
    static func detect(near point: CGPoint) async -> DetectionResult {
        let started = Date()
        defer {
            if logTimings {
                let ms = Date().timeIntervalSince(started) * 1000
                print(String(format: "[timing] detectBlocks total %.0fms", ms))
            }
        }

        // The window under the pointer, not the focused one: ⌘+click works on
        // background windows too, and that is the text being pointed at.
        let window = windowFrame(at: point)
        // A click inside the toolbar strip means the user wants that text, so
        // the strip is only filtered when the click is elsewhere.
        let band = window.map { toolbarBand(of: $0) }.flatMap { $0.contains(point) ? nil : $0 }
        let options = await layoutOptions(chromeBand: band)

        func result(_ lines: [TextLine]) -> DetectionResult {
            DetectionResult(
                blocks: sortByDistance(
                    LayoutAnalyzer.paragraphs(from: lines, options: options), to: point
                ),
                allLines: lines,
                chromeBand: band
            )
        }

        if let window {
            let windowResult = result(await detectViaWindowOCR(window, near: point))
            if !windowResult.blocks.isEmpty { return windowResult }
        }

        // Fallback: the whole display the click is on.
        let screenResult = result(await detectViaFullScreenOCR(containing: point))
        if !screenResult.blocks.isEmpty { return screenResult }

        // Last fallback: accessibility
        return result(detectViaAccessibility(near: point))
    }

    /// Find the block a click at `point` selects, or nil if the click is not
    /// on or near any text.
    static func findBlock(at point: CGPoint, from blocks: [TextBlock]) -> TextBlock? {
        // A block that actually contains the point always wins — smallest
        // first, so a caption inside a larger region beats the region.
        let containing = blocks.filter { $0.boundingRect.contains(point) }
        if let hit = containing.min(by: {
            $0.boundingRect.width * $0.boundingRect.height
                < $1.boundingRect.width * $1.boundingRect.height
        }) {
            return hit
        }

        let nearest = blocks.min { a, b in
            distance(from: point, to: a.boundingRect) < distance(from: point, to: b.boundingRect)
        }
        guard let nearest,
              distance(from: point, to: nearest.boundingRect) <= maxSnapDistance else {
            return nil
        }
        return nearest
    }

    /// Main-actor settings copied into a value the off-actor analyzer can use.
    private static func layoutOptions(chromeBand: CGRect?) async -> LayoutAnalyzer.Options {
        let sensitivity = await MainActor.run { AppSettings.shared.paragraphBreakSensitivity }
        return LayoutAnalyzer.Options(breakSensitivity: sensitivity, chromeBand: chromeBand)
    }

    // MARK: - Accessibility API

    private static func detectViaAccessibility(near point: CGPoint) -> [TextLine] {
        let systemWide = AXUIElementCreateSystemWide()
        var axElement: AXUIElement?

        let result = AXUIElementCopyElementAtPosition(
            systemWide, Float(point.x), Float(point.y), &axElement
        )
        guard result == .success, let axElement else { return [] }

        // Walk up the hierarchy to find the biggest text container
        let textContainer = findBestTextContainer(from: axElement) ?? axElement

        // Extract all lines from the container and its children
        var lines = extractLinesFromElement(textContainer, depth: 0)

        // If we got very few lines, try the parent of the container too
        if lines.count < 3 {
            if let parent = getParent(of: textContainer) {
                let parentLines = extractLinesFromElement(parent, depth: 0)
                if parentLines.count > lines.count {
                    lines = parentLines
                }
            }
        }

        return lines
    }

    /// Walk up the AX hierarchy to find the best text container.
    /// Prefers larger containers (text areas, web areas, scroll areas)
    /// over small groups. Skips AXGroup unless it actually has text content.
    private static func findBestTextContainer(from element: AXUIElement) -> AXUIElement? {
        var current: AXUIElement? = element
        var bestContainer: AXUIElement? = nil
        var bestLineCount = 0

        // High-priority container roles — stop searching when we find these
        let topLevelRoles: Set<String> = [
            kAXTextAreaRole as String,
            kAXScrollAreaRole as String,
            "AXWebArea"
        ]

        // Roles that might contain text but aren't definitive
        let possibleRoles: Set<String> = [
            kAXGroupRole as String,
            kAXStaticTextRole as String,
            "AXSection",
            "AXArticle"
        ]

        for _ in 0..<15 {
            guard let el = current else { break }

            let role = getRole(of: el)

            if let role, topLevelRoles.contains(role) {
                // Found a top-level text container — use it
                return el
            }

            if let role, possibleRoles.contains(role) {
                // Check if this element has meaningful text
                let lineCount = quickLineCount(of: el)
                if lineCount > bestLineCount {
                    bestContainer = el
                    bestLineCount = lineCount
                }
            }

            // Move to parent
            current = getParent(of: el)
        }

        return bestContainer
    }

    private static func getRole(of element: AXUIElement) -> String? {
        var roleRef: CFTypeRef?
        AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &roleRef)
        return roleRef as? String
    }

    private static func getParent(of element: AXUIElement) -> AXUIElement? {
        var parentRef: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(element, kAXParentAttribute as CFString, &parentRef)
        guard result == .success, let parent = parentRef else { return nil }
        return (parent as! AXUIElement)
    }

    /// Quick check: how many lines of text does this element contain?
    private static func quickLineCount(of element: AXUIElement) -> Int {
        var valueRef: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &valueRef)
        if result == .success, let text = valueRef as? String {
            return text.components(separatedBy: .newlines).filter { !$0.isEmpty }.count
        }

        // Check children count as a proxy
        var childCountRef: CFTypeRef?
        let countResult = AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &childCountRef)
        if countResult == .success, let children = childCountRef as? [AXUIElement] {
            return children.count
        }
        return 0
    }

    private static func extractLinesFromElement(_ element: AXUIElement, depth: Int) -> [TextLine] {
        guard depth < 8 else { return [] } // prevent infinite recursion

        // Try to get the value (text content) of this element
        var valueRef: CFTypeRef?
        let valueResult = AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &valueRef)

        if valueResult == .success, let text = valueRef as? String, !text.isEmpty {
            let lines = extractLineRects(from: element, text: text)
            if !lines.isEmpty {
                return lines
            }
        }

        // Walk children to find text elements
        var childrenRef: CFTypeRef?
        let childResult = AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &childrenRef)

        guard childResult == .success, let children = childrenRef as? [AXUIElement] else {
            return []
        }

        var allLines: [TextLine] = []
        for child in children {
            let childLines = extractLinesFromElement(child, depth: depth + 1)
            allLines.append(contentsOf: childLines)
            if allLines.count > 1000 { break }
        }
        return allLines
    }

    private static func extractLineRects(from element: AXUIElement, text: String) -> [TextLine] {
        var lines: [TextLine] = []
        let nsText = text as NSString
        var lineStart = 0

        while lineStart < nsText.length {
            var lineEnd = lineStart
            var contentsEnd = lineStart
            nsText.getLineStart(nil, end: &lineEnd, contentsEnd: &contentsEnd, for: NSRange(location: lineStart, length: 0))

            let lineRange = CFRange(location: lineStart, length: contentsEnd - lineStart)

            if lineRange.length > 0 {
                var mutableRange = lineRange
                let range = AXValueCreate(.cfRange, &mutableRange)

                if let range {
                    var boundsRef: CFTypeRef?
                    let boundsResult = AXUIElementCopyParameterizedAttributeValue(
                        element,
                        kAXBoundsForRangeParameterizedAttribute as CFString,
                        range,
                        &boundsRef
                    )

                    if boundsResult == .success, let boundsValue = boundsRef {
                        var rect = CGRect.zero
                        if AXValueGetValue(boundsValue as! AXValue, .cgRect, &rect) {
                            let lineText = nsText.substring(with: NSRange(location: lineRange.location, length: lineRange.length))
                            if !lineText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                                lines.append(TextLine(text: lineText, rect: rect))
                            }
                        }
                    }
                }
            }

            lineStart = lineEnd
            if lineStart == lineEnd && lineEnd == contentsEnd {
                lineStart += 1
            }
        }

        return lines
    }

    // MARK: - Window and display geometry

    /// Frame of the topmost ordinary window under `point` (screen coordinates,
    /// origin top-left), ignoring Slit's own windows.
    ///
    /// The window list is front-to-back, so the first hit is the visible one.
    /// Bounds and owner need no permission and no Accessibility round-trip.
    static func windowFrame(at point: CGPoint) -> CGRect? {
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let windows = CGWindowListCopyWindowInfo(options, kCGNullWindowID)
                as? [[String: Any]] else { return nil }
        let ownPID = ProcessInfo.processInfo.processIdentifier

        for window in windows {
            guard (window[kCGWindowLayer as String] as? Int) == 0,
                  (window[kCGWindowOwnerPID as String] as? pid_t) != ownPID,
                  (window[kCGWindowAlpha as String] as? Double ?? 1) > 0,
                  let boundsValue = window[kCGWindowBounds as String],
                  let bounds = CGRect(dictionaryRepresentation: boundsValue as! CFDictionary),
                  bounds.contains(point) else { continue }
            return bounds
        }
        return nil
    }

    private static func toolbarBand(of window: CGRect) -> CGRect {
        CGRect(
            x: window.minX, y: window.minY,
            width: window.width, height: min(toolbarHeight, window.height)
        )
    }

    /// Bounds of the display containing `point`, in the same top-left global
    /// coordinates as event locations — unlike `NSScreen.frame`, whose origin
    /// is bottom-left and only coincides on the primary display.
    private static func displayBounds(containing point: CGPoint) -> CGRect {
        var display = CGMainDisplayID()
        var count: UInt32 = 0
        if CGGetDisplaysWithPoint(point, 1, &display, &count) != .success || count == 0 {
            display = CGMainDisplayID()
        }
        return CGDisplayBounds(display)
    }

    // MARK: - Vision OCR

    /// Detect text in one window, clipped to the display the click is on.
    private static func detectViaWindowOCR(_ window: CGRect, near point: CGPoint) async -> [TextLine] {
        let region = window.intersection(displayBounds(containing: point))
        guard !region.isNull, region.width > 50, region.height > 50,
              let image = await captureScreenRegion(region) else { return [] }
        return await performOCR(on: image, in: region)
    }

    private static func detectViaFullScreenOCR(containing point: CGPoint) async -> [TextLine] {
        // Full display bounds, not visibleFrame — visibleFrame excludes the
        // menu bar and Dock strips, so text there would never be detected.
        let screenFrame = displayBounds(containing: point)
        guard !screenFrame.isEmpty,
              let image = await captureScreenRegion(screenFrame) else {
            return []
        }
        return await performOCR(on: image, in: screenFrame)
    }

    /// Shared OCR logic — run Vision text recognition on an image within a given frame.
    static func performOCR(
        on image: CGImage, in frame: CGRect, measuringWordSpaces: Bool? = nil
    ) async -> [TextLine] {
        let ocrStart = Date()
        if logTimings {
            print("[timing]   OCR input \(image.width)x\(image.height)")
        }

        // `perform` blocks for the whole recognition, so run it on a GCD queue
        // rather than parking one of the cooperative pool's few threads. The
        // results are read after `perform` returns instead of from a
        // completion handler, so the continuation resumes exactly once on
        // every path.
        // Callers normally leave this to the word-by-word setting. Passing it
        // lets a caller decide without touching shared settings.
        let measuresWordSpaces: Bool
        if let measuringWordSpaces {
            measuresWordSpaces = measuringWordSpaces
        } else {
            measuresWordSpaces = await MainActor.run { AppSettings.shared.manualWordModeEnabled }
        }
        let lines: [TextLine] = await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let request = VNRecognizeTextRequest()
                request.recognitionLevel = .accurate
                request.usesLanguageCorrection = true
                // Vision defaults to 1/32 of image height, which on a full-screen
                // Retina capture is tall enough to discard ordinary body text.
                // Lower it so small text is still recognised.
                request.minimumTextHeight = 0.008

                do {
                    try VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
                } catch {
                    print("Vision OCR failed: \(error)")
                    continuation.resume(returning: [])
                    return
                }
                // Only word-by-word reveal needs the spaces between words
                // measured from the pixels; skip that work otherwise.
                let pixels = measuresWordSpaces ? LuminanceMap(image: image) : nil
                continuation.resume(
                    returning: (request.results ?? []).compactMap {
                        textLine(from: $0, in: frame, pixels: pixels)
                    }
                )
            }
        }

        if logTimings {
            let ms = Date().timeIntervalSince(ocrStart) * 1000
            print(String(format: "[timing]   Vision OCR %.0fms (%d lines)", ms, lines.count))
            let unreliable = lines.filter { !$0.isReliableText }
            if !unreliable.isEmpty {
                print("[ocr]   \(unreliable.count) line(s) flagged unreliable:")
                for u in unreliable.prefix(8) {
                    print(String(format: "[ocr]     \"%@\" conf=%.2f",
                                 String(u.text.prefix(40)), u.confidence))
                }
            }
        }
        return lines
    }

    /// One recognised line in screen coordinates, or nil if it has no text.
    private static func textLine(
        from observation: VNRecognizedTextObservation, in frame: CGRect, pixels: LuminanceMap?
    ) -> TextLine? {
        guard let candidate = observation.topCandidates(1).first else { return nil }
        let trimmed = candidate.string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let nb = observation.boundingBox // normalized, origin bottom-left
        let screenRect = CGRect(
            x: frame.origin.x + nb.origin.x * frame.width,
            y: frame.origin.y + (1.0 - nb.origin.y - nb.height) * frame.height,
            width: nb.width * frame.width,
            height: nb.height * frame.height
        )
        // Vision can map any substring back to its on-screen box, but only
        // roughly. `WordStops` turns those boxes into exact stopping points
        // by finding the real spaces between words in the captured pixels.
        let wordBoxes = wordRects(for: candidate, fullString: candidate.string, frame: frame)
        return TextLine(
            text: trimmed,
            rect: screenRect,
            confidence: candidate.confidence,
            revealStops: WordStops.stops(
                forLine: screenRect, wordRects: wordBoxes, in: pixels, frame: frame
            )
        )
    }

    /// Per-word screen rects for an OCR candidate, aligned to
    /// `WordSegmenter.words(in:)`. Uses Vision's `boundingBox(for:)` to map each
    /// word's character range to its on-screen box. A word whose box can't be
    /// resolved gets `.null` so callers can detect and skip it.
    private static func wordRects(
        for candidate: VNRecognizedText, fullString: String, frame: CGRect
    ) -> [CGRect] {
        let words = WordSegmenter.words(in: fullString)
        return words.map { word in
            guard let box = try? candidate.boundingBox(for: word.range) else {
                return CGRect.null
            }
            let nb = box.boundingBox // normalized, origin bottom-left
            return CGRect(
                x: frame.origin.x + nb.origin.x * frame.width,
                y: frame.origin.y + (1.0 - nb.origin.y - nb.height) * frame.height,
                width: nb.width * frame.width,
                height: nb.height * frame.height
            )
        }
    }

    /// Capture a screen region for OCR. 2x scale keeps small text legible to
    /// Vision on Retina displays.
    private static func captureScreenRegion(_ region: CGRect) async -> CGImage? {
        await ScreenCapture.region(region, scale: 2)
    }

    // MARK: - Helpers

    private static func sortByDistance(_ blocks: [TextBlock], to point: CGPoint) -> [TextBlock] {
        blocks.sorted { a, b in
            distance(from: point, to: a.boundingRect) < distance(from: point, to: b.boundingRect)
        }
    }

    private static func distance(from point: CGPoint, to rect: CGRect) -> CGFloat {
        let dx = max(rect.minX - point.x, 0, point.x - rect.maxX)
        let dy = max(rect.minY - point.y, 0, point.y - rect.maxY)
        return sqrt(dx * dx + dy * dy)
    }
}
