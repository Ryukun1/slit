import SwiftUI
import AppKit
import CoreGraphics

/// The main overlay view — dims or blurs the detected text block,
/// with a clear cutout for the active line.
struct DimOverlayView: View {
    @ObservedObject var appState: AppState
    @ObservedObject var settings = AppSettings.shared
    let screenFrame: CGRect
    /// Captures part of the screen: the page to blur, and its colours for
    /// the OpenDyslexic layer. A property so previews and tests can draw the
    /// overlay without touching the real screen. A nil scale means the
    /// screen's own.
    var captureScreenRegion: (_ region: CGRect, _ scale: CGFloat?) async -> CGImage? = {
        await ScreenCapture.region($0, scale: $1)
    }

    @State private var bezelRect: CGRect = .zero
    @State private var bezelCornerRadius: CGFloat = 200
    @State private var bezelOpacity: Double = 0
    @State private var isFocused = false
    /// Set once per-line background colors have been sampled, so the dyslexic
    /// text layer does not flash default colors before they resolve.
    @State private var dyslexicColorsReady = false
    @State private var capturedImage: NSImage? = nil

    /// The smoothly animated cutout/highlight rect (the leading line in manual
    /// word-reveal mode; the active line otherwise).
    @State private var highlightRect: CGRect = .zero
    /// Manual word-reveal mode: the lingering completed-lines block above the
    /// leading line (full width). `.null` when there are no completed lines.
    @State private var completedLinesRect: CGRect = .null
    /// Manual word-reveal mode: index of the leading line, animated with the
    /// two rects so a move down to the next line can be drawn as a drop-down.
    @State private var slitLine: CGFloat = 0
    /// Manual word-reveal mode: where the opening is heading (not animated).
    @State private var slitArrival: SlitWindow.Arrival? = nil
    /// Tracks which line index we're on.
    @State private var displayedLineIndex: Int? = nil
    /// Cached colors for dyslexic overlay.
    @State private var cachedBgColor: NSColor = .white
    @State private var cachedTextColor: NSColor = .black
    /// Per-line background colors (sampled once on activation).
    @State private var cachedLineBgColors: [NSColor] = []
    /// Cached per-line rendered dyslexic text widths (set during rendering).
    @State private var dyslexicLineWidths: [CGFloat] = []

    /// Loading circle state.
    @State private var loadingCircleRect: CGRect = .zero
    @State private var loadingCircleOpacity: Double = 0
    @State private var loadingPulse = false

    var body: some View {
        ZStack {
            // Loading indicator during detection. It fades out as the panel
            // fades in, instead of blinking out first.
            if SlitOpening.showsLoadingBubble(
                isDetecting: appState.mode == .detecting,
                isActive: appState.mode == .active,
                panelIsOpening: isFocused
            ) {
                loadingIndicator
                    .allowsHitTesting(false)
                    .transition(.opacity.animation(.easeOut(duration: Self.bubbleFadeOut)))
            }

            // Drag-area string outline (Option + move gesture)
            // Only show once the mouse has moved a noticeable amount
            if let start = appState.optionAreaStart,
               let current = appState.optionAreaCurrent,
               (abs(current.x - start.x) > 4 || abs(current.y - start.y) > 4) {
                dragAreaBubble(start: start, current: current)
                    .allowsHitTesting(false)
            }

            // Option-drag: underline the lines releasing it would select.
            AreaUnderlines(lines: appState.areaPreviewLineRects.map(screenToView))
                .allowsHitTesting(false)

            // ⌘ held: outline the paragraph a click would select.
            HoverPreviewOutline(rect: appState.previewRect.map(panelRect(around:)))
                .allowsHitTesting(false)

            // Debug: Shift toggles paragraph outlines. While scrolling, the
            // boxes no longer line up with the text, so fade them until
            // re-detection catches up.
            if appState.debugBlocksVisible {
                debugBlockOutlines
                    .allowsHitTesting(false)
                    .opacity(appState.debugStale ? 0.25 : 1)
                    .animation(.easeOut(duration: 0.12), value: appState.debugStale)
            }

            if appState.mode == .active {
                // If dyslexic mode: render all lines in OpenDyslexic behind everything,
                // clipped to the bezel. The overlay dims/blurs on top, and the
                // highlight cutout reveals the dyslexic text underneath.
                // Replacement text layers wait for their sampled background
                // colors; showing them earlier would flash the wrong colors.
                if settings.dyslexicFontEnabled, isFocused, dyslexicColorsReady {
                    dyslexicTextLayer
                        .allowsHitTesting(false)
                }

                overlayContent
                    .allowsHitTesting(false)

                bezelBorder
                    .allowsHitTesting(false)

            }
        }
        .frame(width: screenFrame.width, height: screenFrame.height)
        .onChange(of: appState.mode) { newMode in
            switch newMode {
            case .detecting:
                startLoadingAnimation()
            case .active:
                if settings.overlayStyle == .blur {
                    // Capture first, then morph — starting the morph while the
                    // capture is still in flight makes the blur pop in partway
                    // through the animation instead of moving with it.
                    Task {
                        await captureScreen()
                        animateMorphIn()
                    }
                } else {
                    animateMorphIn()
                }
            default:
                isFocused = false
                bezelOpacity = 0
                loadingCircleOpacity = 0
                loadingPulse = false
                capturedImage = nil
                dyslexicColorsReady = false
                displayedLineIndex = nil
                cachedLineBgColors = []
                dyslexicLineWidths = []
                completedLinesRect = .null
                slitLine = 0
                slitArrival = nil
            }
        }
        .onChange(of: appState.activeLineIndex) { newIndex in
            displayedLineIndex = newIndex
            guard let idx = newIndex, idx < appState.detectedLines.count else { return }
            if settings.manualWordModeEnabled {
                // The manual cutout updater owns the whole opening; a single
                // ease keeps the move to the new line smooth with no recoil.
                withAnimation(Self.manualLineChangeAnimation) { updateManualCutouts() }
            } else {
                withAnimation(.spring(response: 0.3, dampingFraction: 0.82)) {
                    highlightRect = computeVisibleRect(centerIndex: idx)
                }
            }
        }
        // Manual mode: each click reveals one more word — glide the leading
        // line's edge out (no spring, no recoil).
        .onChange(of: appState.revealedWordCount) { _ in
            guard settings.manualWordModeEnabled, isFocused, !isChangingLine else { return }
            withAnimation(Self.manualRevealAnimation) { updateManualCutouts() }
        }
        // Manual mode: window scrolled up/down over read lines — move the whole
        // window block smoothly.
        .onChange(of: appState.windowTopIndex) { _ in
            guard settings.manualWordModeEnabled, isFocused, !isChangingLine else { return }
            withAnimation(Self.manualRevealAnimation) { updateManualCutouts() }
        }
        // Update bezel size when the selection grows (e.g. Option+click added a paragraph)
        .onChange(of: appState.overlayRegion) { newRegion in
            guard appState.mode == .active, isFocused else { return }
            let targetRect = panelRect(around: newRegion)
            withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) {
                bezelRect = targetRect
            }
        }
    }

    // MARK: - Overlay content

    @ViewBuilder
    private var overlayContent: some View {
        switch settings.overlayStyle {
        case .dim:
            dimOverlay
        case .blur:
            blurOverlay
        }
    }

    // MARK: - Dim mode (smooth animated cutout)

    @ViewBuilder
    private var dimOverlay: some View {
        // One shape for the whole session, with or without an opening. If the
        // panel were swapped for a different view once a line is shown, that
        // new view would have nothing to animate from and would appear at
        // full size in a single frame instead of growing out of the bubble.
        AnimatedDimShape(
            outerRect: bezelRect,
            outerCornerRadius: bezelCornerRadius,
            cutoutCornerRadius: 6,
            window: shownSlitLayout
        )
        .fill(Color.black.opacity(settings.dimOpacity), style: FillStyle(eoFill: true))
        .opacity(bezelOpacity)

        slitDecoration
    }

    /// The opening as drawn: none until a line is being shown.
    private var shownSlitLayout: SlitWindowLayout {
        displayedLineIndex != nil && isFocused ? slitLayout : SlitWindowLayout()
    }

    // MARK: - Blur mode (same cutout approach as dim, but with blurred image)

    @ViewBuilder
    private var blurOverlay: some View {
        if let image = capturedImage {
            // Blurred panel with the opening faded out of it, so the edge
            // between blurred and sharp text is soft rather than a hard line
            // that flickers as the slit crosses rows of text. One view for
            // the whole session, like the dim panel, so it has something to
            // animate from when it opens.
            BlurredPanel(
                image: image,
                size: screenFrame.size,
                blurRadius: settings.blurRadius,
                panelRect: bezelRect,
                panelCornerRadius: bezelCornerRadius,
                window: shownSlitLayout
            )
            .opacity(bezelOpacity)

            slitDecoration
        } else {
            dimOverlay
        }
    }

    /// The opening as the shapes draw it: both rects, plus what they need to
    /// turn a move down to the next line into a drop-down.
    private var slitLayout: SlitWindowLayout {
        SlitWindowLayout(
            upper: completedLinesRect, lower: highlightRect, line: slitLine, arrival: slitArrival
        )
    }

    /// The leading line has changed but the opening has not been moved to it
    /// yet. The line-change handler does that, with its own animation; the
    /// word and window handlers that fire on the same click leave it alone.
    private var isChangingLine: Bool {
        appState.activeLineIndex.map { CGFloat($0) } != slitLine
    }

    /// Tint and edge lines over the opening, the same in dim and blur mode.
    private var slitDecoration: some View {
        SlitDecoration(
            window: shownSlitLayout,
            tint: settings.highlightColorEnabled ? settings.highlightColor : nil,
            showsOutline: settings.slitOutlineEnabled
        )
        .opacity(bezelOpacity)
    }

    // MARK: - OpenDyslexic text layer

    /// Pre-rendered layer of ALL lines in OpenDyslexic, clipped to the bezel.
    @ViewBuilder
    private var dyslexicTextLayer: some View {
        let _ = Self.registerDyslexicFont
        let _ = updateDyslexicLineWidths()

        let bgColor = Color(nsColor: cachedBgColor)
        let textColor = Color(nsColor: cachedTextColor)

        let baseLeftEdge = bezelRect.minX + 16
        let minLineX = appState.detectedLines.map { screenToView($0.rect).minX }.min() ?? 0
        let paragraphFontSizes = computeParagraphFontSizes()

        ZStack {
            ForEach(Array(appState.detectedLines.enumerated()), id: \.element.id) { idx, line in
                let lineRect = screenToView(line.rect)
                let indent = lineRect.minX - minLineX
                let fontSize = idx < paragraphFontSizes.count ? paragraphFontSizes[idx] : max(8, lineRect.height * 0.65)
                let lineFont = Font(NSFont(name: "OpenDyslexic-Regular", size: fontSize)
                    ?? NSFont.systemFont(ofSize: fontSize))
                let fitScale = dyslexicFitScale(for: idx, fontSize: fontSize, indent: indent, baseLeftEdge: baseLeftEdge)

                if line.isReliableText {
                    let lineBg = idx < cachedLineBgColors.count ? Color(nsColor: cachedLineBgColors[idx]) : bgColor
                    let nsFont = NSFont(name: "OpenDyslexic-Regular", size: fontSize)
                        ?? NSFont.systemFont(ofSize: fontSize)
                    let dyslexicTextWidth = measureTextWidth(line.text, font: nsFont) * fitScale
                    let dyslexicTextHeight = nsFont.ascender - nsFont.descender + nsFont.leading

                    // Background — at least as wide as the original text, or wider if dyslexic text needs it
                    let bgWidth = max(lineRect.width + 8, dyslexicTextWidth + 8)
                    Rectangle()
                        .fill(lineBg)
                        .frame(width: bgWidth, height: max(dyslexicTextHeight, lineRect.height) + 2)
                        .position(x: lineRect.midX, y: lineRect.midY)

                    HStack {
                        Text(line.text)
                            .font(lineFont)
                            .foregroundColor(textColor)
                            .lineLimit(1)
                            .fixedSize(horizontal: true, vertical: false)
                            .scaleEffect(x: fitScale, y: 1.0, anchor: .leading)
                        Spacer()
                    }
                    .frame(height: lineRect.height)
                    .offset(x: baseLeftEdge + indent)
                    .position(x: screenFrame.width / 2, y: lineRect.midY)

                }
                // Unreliable lines (math/symbols) — nothing rendered,
                // original screen content shows through the slit
            }
        }
        .mask(
            Group {
                if settings.dyslexicFullPageMode || settings.overlayStyle == .blur {
                    // Full page or blur mode: show all text inside the bezel
                    // (blur mode handles the slit reveal via its own cutout)
                    RoundedRectangle(cornerRadius: 12)
                        .frame(width: bezelRect.width, height: bezelRect.height)
                        .position(x: bezelRect.midX, y: bezelRect.midY)
                        .frame(width: screenFrame.width, height: screenFrame.height)
                } else {
                    // Dim slit mode: only show the lines in the opening
                    RoundedRectangle(cornerRadius: 6)
                        .frame(width: bezelRect.width, height: dyslexicBand.height)
                        .position(x: bezelRect.midX, y: dyslexicBand.midY)
                        .frame(width: screenFrame.width, height: screenFrame.height)
                }
            }
        )
        .opacity(bezelOpacity)
    }

    /// Dim mode without Full page: the rows redrawn in OpenDyslexic. Normally
    /// the current line; in word-by-word mode the read lines above it too, so
    /// everything in the opening is in the same font.
    private var dyslexicBand: CGRect {
        guard settings.manualWordModeEnabled,
              !completedLinesRect.isNull, completedLinesRect.height > 0 else {
            return highlightRect
        }
        return highlightRect.union(completedLinesRect)
    }

    /// Compute the fitScale for a given line — same logic used by rendering and slit.
    private func dyslexicFitScale(for idx: Int, fontSize: CGFloat, indent: CGFloat, baseLeftEdge: CGFloat) -> CGFloat {
        let lines = appState.detectedLines
        guard idx < lines.count else { return Self.dyslexicScale }
        let nsFont = NSFont(name: "OpenDyslexic-Regular", size: fontSize)
            ?? NSFont.systemFont(ofSize: fontSize)
        let fullTextWidth = measureTextWidth(lines[idx].text, font: nsFont)
        let availableWidth = bezelRect.maxX - (baseLeftEdge + indent) - 16
        return min(Self.dyslexicScale, availableWidth / max(1, fullTextWidth))
    }

    /// Precompute per-line rendered widths for slit sizing.
    private func updateDyslexicLineWidths() {
        let lines = appState.detectedLines
        guard !lines.isEmpty else { return }
        let paragraphSizes = computeParagraphFontSizes()
        let baseLeftEdge = bezelRect.minX + 16
        let minLineX = lines.map { screenToView($0.rect).minX }.min() ?? 0

        var widths: [CGFloat] = []
        for (idx, line) in lines.enumerated() {
            let lineRect = screenToView(line.rect)
            let indent = lineRect.minX - minLineX
            let fontSize = idx < paragraphSizes.count ? paragraphSizes[idx] : max(8, lineRect.height * 0.65)
            let nsFont = NSFont(name: "OpenDyslexic-Regular", size: fontSize)
                ?? NSFont.systemFont(ofSize: fontSize)
            let fullWidth = measureTextWidth(line.text, font: nsFont)
            let fitScale = dyslexicFitScale(for: idx, fontSize: fontSize, indent: indent, baseLeftEdge: baseLeftEdge)
            widths.append(fullWidth * fitScale + indent + 16)
        }

        if widths != dyslexicLineWidths {
            DispatchQueue.main.async {
                self.dyslexicLineWidths = widths
            }
        }
    }

    private func measureTextWidth(_ text: String, font: NSFont) -> CGFloat {
        let attributes: [NSAttributedString.Key: Any] = [.font: font]
        let size = (text as NSString).size(withAttributes: attributes)
        return size.width
    }

    /// Sample every line's background from one capture and cache the results.
    ///
    /// Takes a single image spanning all lines, then crops each line's sample
    /// region out of it — one screen capture per activation instead of one per
    /// line, which is what made large selections slow to appear.
    private func cacheDyslexicColors(for lines: [TextLine]) async {
        guard let first = lines.first else { return }

        let union = lines.dropFirst().reduce(Self.sampleRect(around: first.rect)) {
            $0.union(Self.sampleRect(around: $1.rect))
        }

        guard let cgImage = await captureScreenRegion(union, 1) else {
            // Capture failed — fall back to a readable light default rather
            // than leaving the overlay unstyled.
            cachedBgColor = .white
            cachedTextColor = .black
            cachedLineBgColors = lines.map { _ in .white }
            // Still show the text layer: without this the font never
            // appeared at all when the capture failed.
            dyslexicColorsReady = true
            return
        }

        // Captured pixels per screen point, so line rects can be mapped into
        // the image regardless of the display's backing scale.
        let pxPerPoint = CGFloat(cgImage.width) / union.width

        let perLine: [NSColor] = lines.map { line in
            let rect = Self.sampleRect(around: line.rect)
            let cropped = CGRect(
                x: (rect.minX - union.minX) * pxPerPoint,
                y: (rect.minY - union.minY) * pxPerPoint,
                width: rect.width * pxPerPoint,
                height: rect.height * pxPerPoint
            ).integral.intersection(
                CGRect(x: 0, y: 0, width: cgImage.width, height: cgImage.height)
            )

            guard !cropped.isNull, cropped.width > 10, cropped.height > 10,
                  let slice = cgImage.cropping(to: cropped) else {
                return .white
            }
            return Self.dominantColor(in: NSBitmapImageRep(cgImage: slice))
        }

        cachedBgColor = perLine.first ?? .white
        cachedTextColor = (perLine.first ?? .white).isLight ? .black : .white
        cachedLineBgColors = perLine
        withAnimation(.easeIn(duration: 0.12)) {
            dyslexicColorsReady = true
        }
    }

    /// Sample the background color around a text line.
    /// Samples from left, right, above, and below the line, then picks
    /// the most common color (the actual page background).
    private func sampleBackgroundColor(at screenRect: CGRect) async -> NSColor {
        let sampleRect = Self.sampleRect(around: screenRect)
        // Color sampling reads flat background pixels, so 1x is plenty and
        // keeps the capture cheap.
        guard let cgImage = await ScreenCapture.region(sampleRect, scale: 1) else {
            return .white
        }
        return Self.dominantColor(in: NSBitmapImageRep(cgImage: cgImage))
    }

    /// The region sampled around a line — a margin on every side so the edges
    /// land on background rather than glyphs.
    private static func sampleRect(around screenRect: CGRect) -> CGRect {
        let margin: CGFloat = 20
        return CGRect(
            x: screenRect.minX - margin,
            y: screenRect.minY - margin,
            width: screenRect.width + margin * 2,
            height: screenRect.height + margin * 2
        )
    }

    /// Most common color around the edges of a bitmap — pure, no capture.
    private static func dominantColor(in bitmap: NSBitmapImageRep) -> NSColor {
        let w = bitmap.pixelsWide
        let h = bitmap.pixelsHigh
        guard w > 10, h > 10 else { return .white }

        // Sample from edges (where there's no text — just background)
        var colors: [(r: CGFloat, g: CGFloat, b: CGFloat)] = []

        // Left edge
        for y in stride(from: 3, to: h - 3, by: max(1, h / 6)) {
            if let c = bitmap.colorAt(x: 2, y: y)?.usingColorSpace(.sRGB) {
                colors.append((c.redComponent, c.greenComponent, c.blueComponent))
            }
        }
        // Right edge
        for y in stride(from: 3, to: h - 3, by: max(1, h / 6)) {
            if let c = bitmap.colorAt(x: w - 3, y: y)?.usingColorSpace(.sRGB) {
                colors.append((c.redComponent, c.greenComponent, c.blueComponent))
            }
        }
        // Top edge
        for x in stride(from: 3, to: w - 3, by: max(1, w / 8)) {
            if let c = bitmap.colorAt(x: x, y: 2)?.usingColorSpace(.sRGB) {
                colors.append((c.redComponent, c.greenComponent, c.blueComponent))
            }
        }
        // Bottom edge
        for x in stride(from: 3, to: w - 3, by: max(1, w / 8)) {
            if let c = bitmap.colorAt(x: x, y: h - 3)?.usingColorSpace(.sRGB) {
                colors.append((c.redComponent, c.greenComponent, c.blueComponent))
            }
        }

        guard !colors.isEmpty else { return .white }

        // Find the most common color — group similar colors and pick the biggest group
        // Quantize to reduce noise (round to nearest 0.05)
        let quantized = colors.map { (
            r: (($0.r * 20).rounded() / 20),
            g: (($0.g * 20).rounded() / 20),
            b: (($0.b * 20).rounded() / 20)
        )}

        // Count occurrences of each quantized color
        var counts: [String: (count: Int, r: CGFloat, g: CGFloat, b: CGFloat)] = [:]
        for c in quantized {
            let key = "\(c.r),\(c.g),\(c.b)"
            if let existing = counts[key] {
                counts[key] = (existing.count + 1, c.r, c.g, c.b)
            } else {
                counts[key] = (1, c.r, c.g, c.b)
            }
        }

        // Pick the most frequent color
        let best = counts.values.max { $0.count < $1.count }!
        // Now get the actual (non-quantized) average of pixels in this group
        let matching = colors.filter {
            abs($0.r - best.r) < 0.05 && abs($0.g - best.g) < 0.05 && abs($0.b - best.b) < 0.05
        }
        let r = matching.map(\.r).reduce(0, +) / CGFloat(matching.count)
        let g = matching.map(\.g).reduce(0, +) / CGFloat(matching.count)
        let b = matching.map(\.b).reduce(0, +) / CGFloat(matching.count)

        return NSColor(red: r, green: g, blue: b, alpha: 1.0)
    }

    /// Register the bundled OpenDyslexic font once.
    private static let registerDyslexicFont: Void = {
        registerFont(named: "OpenDyslexic-Regular")
    }()

    private static func registerFont(named name: String) {
        guard let url = Bundle.module.url(forResource: name, withExtension: "otf") else {
            print("Font \(name) not found in bundle")
            return
        }
        guard let data = try? Data(contentsOf: url),
              let provider = CGDataProvider(data: data as CFData),
              let cgFont = CGFont(provider) else {
            print("Failed to load font \(name)")
            return
        }
        CTFontManagerRegisterGraphicsFont(cgFont, nil)
    }


    // MARK: - Drag-area selection bubble

    /// Physics-driven string through 4 corner points. The corners chase their
    /// target positions with spring physics, lagging behind fast mouse movement.
    @ViewBuilder
    private func dragAreaBubble(start: CGPoint, current: CGPoint) -> some View {
        let startView = screenToView(CGRect(origin: start, size: .zero)).origin
        let currentView = screenToView(CGRect(origin: current, size: .zero)).origin

        PhysicsStringQuad(
            startPoint: startView,
            currentPoint: currentView,
            screenSize: CGSize(width: screenFrame.width, height: screenFrame.height)
        )
        .frame(width: screenFrame.width, height: screenFrame.height)
        .transition(.opacity)
    }

    // MARK: - Loading indicator

    @ViewBuilder
    private var loadingIndicator: some View {
        let size: CGFloat = loadingPulse ? 50 : 28

        Circle()
            .fill(Color.black.opacity(settings.dimOpacity))
            .frame(width: size, height: size)
            .overlay(
                Circle()
                    .strokeBorder(
                        LinearGradient(
                            colors: [Color.black.opacity(0.4), Color.black.opacity(0.15)],
                            startPoint: .top, endPoint: .bottom
                        ),
                        lineWidth: 1.5
                    )
            )
            .shadow(color: .black.opacity(0.15), radius: 10)
            .position(x: loadingCircleRect.midX, y: loadingCircleRect.midY)
            .opacity(loadingCircleOpacity)
    }

    /// How long the loading bubble takes to fade once the panel opens.
    private static let bubbleFadeOut: Double = 0.22

    private func startLoadingAnimation() {
        let clickPoint = screenToView(CGRect(origin: appState.clickPoint, size: .zero)).origin

        loadingCircleRect = CGRect(x: clickPoint.x - 18, y: clickPoint.y - 18, width: 36, height: 36)
        loadingCircleOpacity = 0
        loadingPulse = false

        // Fade in
        withAnimation(.easeOut(duration: 0.15)) {
            loadingCircleOpacity = 1
        }

        // Slow steady grow
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            withAnimation(.easeInOut(duration: 1.5).repeatForever(autoreverses: true)) {
                loadingPulse = true
            }
        }
    }

    // MARK: - Debug block outlines

    /// Every paragraph ⌘+click would select, outlined in red.
    ///
    /// One box per detected block, showing the region a click inside it would
    /// select — the block narrowed by column, vertical section and selection
    /// size. The box under the cursor is brightened, since selection depends on
    /// exactly where you click.
    @ViewBuilder
    private var debugBlockOutlines: some View {
        // Layer 1: every detected line, tinted with its paragraph's hue so it
        // is visible which lines were grouped together. Yellow = detected but
        // discarded, so no click can ever select it.
        ForEach(appState.debugAllLines) { line in
            let rect = screenToView(line.rect)
            let hue = line.paragraphIndex.map { Self.paragraphHue($0) } ?? .yellow

            Rectangle()
                .fill(hue.opacity(line.usable ? 0.18 : 0.28))
                .frame(width: rect.width, height: rect.height)
                .position(x: rect.midX, y: rect.midY)

            Rectangle()
                .stroke(hue.opacity(line.usable ? 0.6 : 0.9),
                        lineWidth: line.usable ? 1 : 1.5)
                .frame(width: rect.width, height: rect.height)
                .position(x: rect.midX, y: rect.midY)
        }

        // Layer 2: the paragraph regions a click would select. Each paragraph
        // gets its own hue so it is obvious which lines group together, with a
        // bracket down the left edge showing the block's vertical extent.
        ForEach(Array(appState.debugAllSelections.enumerated()), id: \.element.id) { index, selection in
            let rect = screenToView(selection.rect)
            let hue = Self.paragraphHue(index)
            let isHovered = appState.debugSelectionRect.map {
                $0.intersects(selection.rect) && abs($0.midY - selection.rect.midY) < 2
            } ?? false

            Rectangle()
                .fill(hue.opacity(isHovered ? 0.20 : 0.10))
                .frame(width: rect.width, height: rect.height)
                .position(x: rect.midX, y: rect.midY)

            RoundedRectangle(cornerRadius: 3)
                .stroke(hue.opacity(isHovered ? 1.0 : 0.75),
                        lineWidth: isHovered ? 2.5 : 1.5)
                .frame(width: rect.width, height: rect.height)
                .position(x: rect.midX, y: rect.midY)

            // Left bracket — makes the paragraph's span unmistakable.
            RoundedRectangle(cornerRadius: 2)
                .fill(hue)
                .frame(width: 4, height: rect.height)
                .position(x: rect.minX - 5, y: rect.midY)

            Text("¶\(index + 1) · \(selection.lineCount)L")
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .foregroundStyle(.black)
                .padding(.horizontal, 5)
                .padding(.vertical, 2)
                .background(hue.opacity(isHovered ? 1.0 : 0.85))
                .clipShape(RoundedRectangle(cornerRadius: 3))
                .position(x: rect.minX + 26, y: max(rect.minY - 9, 9))
        }

        // Summary + legend. On notched displays a centred badge lands behind
        // the notch, so split it into two halves that sit either side of it.
        debugSummaryBar

        // Live paragraph-size dial.
        debugSensitivityDial
    }

    /// Bottom-centre control for the paragraph-break threshold. Arrow keys
    /// adjust it while the overlay is up and the outlines re-split instantly.
    @ViewBuilder
    private var debugSensitivityDial: some View {
        let value = settings.paragraphBreakSensitivity
        let range: ClosedRange<Double> = 1.0...5.0
        let fraction = (value - range.lowerBound) / (range.upperBound - range.lowerBound)
        let trackWidth: CGFloat = 220

        VStack(spacing: 7) {
            HStack(spacing: 8) {
                Text("◀")
                    .foregroundStyle(.white.opacity(0.55))
                Text("paragraph size")
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.white)
                Text(String(format: "%.1f×", value))
                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                    .foregroundStyle(.white)
                    .frame(width: 40, alignment: .leading)
                Text("▶")
                    .foregroundStyle(.white.opacity(0.55))
            }
            .font(.system(size: 10, weight: .bold))

            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.white.opacity(0.18))
                    .frame(width: trackWidth, height: 5)

                Capsule()
                    .fill(Color.white.opacity(0.85))
                    .frame(width: max(6, trackWidth * fraction), height: 5)

                Circle()
                    .fill(.white)
                    .frame(width: 12, height: 12)
                    .offset(x: trackWidth * fraction - 6)
            }
            .frame(width: trackWidth, height: 12)

            HStack {
                Text("more, smaller ¶")
                Spacer()
                Text("fewer, larger ¶")
            }
            .font(.system(size: 9, weight: .medium, design: .monospaced))
            .foregroundStyle(.white.opacity(0.55))
            .frame(width: trackWidth)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(Color.black.opacity(0.85))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .position(x: screenFrame.width / 2, y: screenFrame.height - 70)
    }

    /// Counts on the left of the notch, legend on the right. Falls back to a
    /// single centred badge on displays without a notch.
    @ViewBuilder
    private var debugSummaryBar: some View {
        let dropped = appState.debugAllLines.filter { !$0.usable }.count
        let counts = "\(appState.debugAllSelections.count) paragraph\(appState.debugAllSelections.count == 1 ? "" : "s") · \(appState.debugAllLines.count) line\(appState.debugAllLines.count == 1 ? "" : "s")"

        let legend = HStack(spacing: 10) {
            Text("colour = paragraph")
            if dropped > 0 {
                legendSwatch(color: .yellow, label: "\(dropped) discarded")
            }
        }
        .font(.system(size: 10, weight: .medium, design: .monospaced))
        .foregroundStyle(.white.opacity(0.9))

        if let notch = Self.notchRect(in: screenFrame) {
            // Sit level with the notch, in the menu bar strip either side of it.
            let y = notch.midY

            HStack(spacing: 6) {
                Text(counts)
                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                    .foregroundStyle(.white)
                Text("· ⇧ to dismiss")
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.75))
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 3)
            .background(Color.black.opacity(0.82))
            .clipShape(RoundedRectangle(cornerRadius: 6))
            // Right-align against the notch's left edge, so the badge grows
            // leftwards and never slides under the notch as its text changes.
            .frame(maxWidth: notch.minX - 8, alignment: .trailing)
            .frame(width: screenFrame.width, alignment: .leading)
            .position(x: screenFrame.width / 2, y: y)

            legend
                .padding(.horizontal, 9)
                .padding(.vertical, 3)
                .background(Color.black.opacity(0.82))
                .clipShape(RoundedRectangle(cornerRadius: 6))
                // Left-align against the notch's right edge.
                .frame(maxWidth: screenFrame.width - notch.maxX - 8, alignment: .leading)
                .frame(width: screenFrame.width, alignment: .trailing)
                .position(x: screenFrame.width / 2, y: y)
        } else {
            VStack(spacing: 4) {
                Text("\(counts) · ⇧ to dismiss")
                    .font(.system(size: 12, weight: .bold, design: .monospaced))
                    .foregroundStyle(.white)
                legend
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Color.black.opacity(0.82))
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .position(x: screenFrame.width / 2, y: 38)
        }
    }

    /// The notch's rect in view coordinates (origin top-left), or nil on
    /// displays without one.
    ///
    /// macOS exposes the two usable strips beside the notch as
    /// `auxiliaryTopLeftArea` / `auxiliaryTopRightArea`; the gap between them is
    /// the notch itself.
    private static func notchRect(in screenFrame: CGRect) -> CGRect? {
        guard let screen = NSScreen.screens.first(where: { $0.frame == screenFrame })
                ?? NSScreen.main,
              screen.safeAreaInsets.top > 0,
              let left = screen.auxiliaryTopLeftArea,
              let right = screen.auxiliaryTopRightArea,
              right.minX > left.maxX
        else { return nil }

        return CGRect(
            x: left.maxX,
            y: 0,
            width: right.minX - left.maxX,
            height: screen.safeAreaInsets.top
        )
    }

    /// Distinct hue per paragraph, cycling. Adjacent paragraphs get
    /// well-separated hues so neighbouring blocks never look alike.
    private static func paragraphHue(_ index: Int) -> Color {
        let hues: [Double] = [0.0, 0.33, 0.58, 0.09, 0.78, 0.45, 0.88, 0.16]
        return Color(hue: hues[index % hues.count], saturation: 0.85, brightness: 1.0)
    }

    private func legendSwatch(color: Color, label: String) -> some View {
        HStack(spacing: 4) {
            RoundedRectangle(cornerRadius: 2)
                .fill(color.opacity(0.8))
                .frame(width: 10, height: 10)
            Text(label)
        }
    }

    // MARK: - Bezel border

    @ViewBuilder
    private var bezelBorder: some View {
        // Defined edge on the dim/blur box — visible enough to bound the panel,
        // dim enough not to draw the eye away from the text.
        MorphShape(rect: bezelRect, cornerRadius: bezelCornerRadius)
            .stroke(
                LinearGradient(
                    colors: [Color.white.opacity(0.4), Color.white.opacity(0.18)],
                    startPoint: .top,
                    endPoint: .bottom
                ),
                lineWidth: 1
            )
            .opacity(bezelOpacity)

        // Soft outer glow to lift the panel off the background.
        MorphShape(
            rect: bezelRect.insetBy(dx: -3, dy: -3),
            cornerRadius: bezelCornerRadius + 3
        )
        .stroke(Color.white.opacity(0.09), lineWidth: 3)
        .blur(radius: 6)
        .opacity(bezelOpacity)
    }

    // MARK: - Circle-to-rect morph animation

    private func animateMorphIn() {
        let baseRect = panelRect(around: appState.overlayRegion)
        // Widen the bezel when dyslexic font is on — OpenDyslexic is ~40% wider
        let dyslexicExtra: CGFloat = 0
        let targetRect = CGRect(
            x: baseRect.origin.x,
            y: baseRect.origin.y,
            width: baseRect.width + dyslexicExtra,
            height: baseRect.height
        )

        // Cache colors for dyslexic overlay — one capture covering every line,
        // then sample each line's background out of that single image. Capturing
        // per line would mean one screen capture per line of the paragraph.
        if settings.dyslexicFontEnabled, !appState.detectedLines.isEmpty {
            let lines = appState.detectedLines
            dyslexicColorsReady = false
            Task { await cacheDyslexicColors(for: lines) }
        }

        // Start from where the loading circle currently is, as a circle — the
        // panel then literally grows out of the bubble.
        bezelRect = loadingCircleRect
        bezelCornerRadius = loadingCircleRect.width / 2
        bezelOpacity = SlitOpening.panelStartOpacity(style: settings.overlayStyle)
        loadingPulse = false

        // Reveal the backdrop immediately at circle size, so the dim/blur is
        // already filling the bubble when the morph begins. Gating it behind
        // the morph is what made the panel appear to pop in afterwards.
        isFocused = true

        // Hand off from the spinner to the panel in one motion: the circle
        // fades as the panel takes its place, rather than clearing first.
        withAnimation(.easeOut(duration: Self.bubbleFadeOut)) {
            loadingCircleOpacity = 0
        }
        // The panel fades in quickly at the click point, then is seen
        // enlarging from there: it must not snap on, and must not still be
        // faint by the time it has grown.
        withAnimation(.easeOut(duration: SlitOpening.panelFadeInDuration)) {
            bezelOpacity = 1
        }

        // Initialize highlight rect
        let clickPoint = screenToView(CGRect(origin: appState.clickPoint, size: .zero)).origin

        // The slit's final shape: the real line the user clicked on. Computing
        // it needs the bezel at its target size (widths are clamped to it), so
        // set the bezel, measure, then restore for the morph to animate from.
        let savedBezel = bezelRect
        bezelRect = targetRect
        let targetHighlight: CGRect?
        if settings.manualWordModeEnabled {
            // Manual mode computes its own leading-line rect; take that as the
            // target so it opens out of the bubble like every other mode.
            updateManualCutouts()
            targetHighlight = appState.activeLineIndex == nil ? nil : highlightRect
            // Show the opening from this first frame, seeded in the bubble.
            // Left to the line-change handler, it would only appear after the
            // morph had started and would not travel out with the panel.
            displayedLineIndex = appState.activeLineIndex
        } else if let idx = appState.activeLineIndex ?? LineSnapper.nearestLineIndex(
            mouseY: appState.clickPoint.y, lines: appState.detectedLines
        ), idx < appState.detectedLines.count {
            targetHighlight = computeVisibleRect(centerIndex: idx)
            // The overlay only draws once a line is displayed. Activation
            // opens the slit on the first line, so `activeLineIndex` is normally
            // set already; set this directly anyway so the backdrop can never
            // wait for the first pointer move.
            displayedLineIndex = idx
        } else {
            targetHighlight = nil
        }
        bezelRect = savedBezel

        if let targetHighlight {
            // Seed the slit inside the loading circle, at the same point the
            // panel grows from, so it visibly expands out of the bubble and
            // travels to its line rather than appearing there on its own.
            highlightRect = SlitOpening.seedRect(
                bubble: loadingCircleRect, targetHeight: targetHighlight.height
            )
        } else {
            highlightRect = CGRect(
                x: clickPoint.x - 50, y: clickPoint.y - 10, width: 100, height: 20
            )
        }

        // Morph from circle into target rectangle. `isFocused` reveals the
        // overlay content (blur/dim) and `highlightRect` grows into the line's
        // shape — all in one transaction, so the bezel, the backdrop and the
        // slit animate together instead of in sequence.
        withAnimation(.spring(
            response: SlitOpening.panelGrowResponse,
            dampingFraction: SlitOpening.panelGrowDamping
        )) {
            bezelRect = targetRect
            bezelCornerRadius = 12
            if let targetHighlight {
                highlightRect = targetHighlight
            }
        }
    }

    // MARK: - Screen capture

    private func captureScreen() async {
        guard let cgImage = await captureScreenRegion(screenFrame, nil) else { return }

        capturedImage = NSImage(
            cgImage: cgImage,
            size: NSSize(width: screenFrame.width, height: screenFrame.height)
        )
    }

    // MARK: - Paragraph font size computation

    /// Compute a uniform font size per paragraph.
    /// Detects paragraphs as groups of consecutive lines that are vertically
    /// close and horizontally aligned. All lines in a paragraph share the
    /// same font size (the median of that paragraph).
    private func computeParagraphFontSizes() -> [CGFloat] {
        let lines = appState.detectedLines
        guard !lines.isEmpty else { return [] }

        let viewRects = lines.map { screenToView($0.rect) }
        let heights = viewRects.map(\.height)

        // Sort indices by Y so we walk lines top-to-bottom
        let sortedIndices = (0..<lines.count).sorted { viewRects[$0].minY < viewRects[$1].minY }

        // Build paragraphs by walking sorted lines and grouping consecutive
        // ones that are close vertically and aligned horizontally.
        var paragraphs: [[Int]] = []
        var currentPara: [Int] = []

        for sortedIdx in sortedIndices {
            let rect = viewRects[sortedIdx]

            if currentPara.isEmpty {
                currentPara.append(sortedIdx)
                continue
            }

            let prevIdx = currentPara.last!
            let prevRect = viewRects[prevIdx]
            let prevHeight = heights[prevIdx]
            let currHeight = heights[sortedIdx]

            // Vertical gap: distance between bottom of previous and top of current
            let gap = rect.minY - prevRect.maxY

            // Same paragraph if:
            //  1. Heights are similar — tolerance scales with how close the lines are
            //     (closer lines get more lenient tolerance, biasing toward same paragraph)
            //  2. Vertical gap is small (< 0.8 * line height) — close together
            //  3. Horizontal overlap exists — same column
            let avgHeight = (prevHeight + currHeight) / 2
            let heightRatio = max(prevHeight, currHeight) / max(min(prevHeight, currHeight), 1)

            // Closeness factor: 0 (touching) to 1 (gap == 0.8 * avgHeight)
            let closenessFactor = min(1.0, max(0, gap) / max(avgHeight * 0.8, 1))
            // Very close lines: allow up to 1.6x ratio (60% taller)
            // Far apart lines: only allow 1.25x ratio
            let heightTolerance = 1.6 - closenessFactor * 0.35
            let sameSize = heightRatio < heightTolerance

            let closeVertically = gap < avgHeight * 0.8
            let horizontalOverlap = max(0, min(prevRect.maxX, rect.maxX) - max(prevRect.minX, rect.minX)) > 0

            if sameSize && closeVertically && horizontalOverlap {
                currentPara.append(sortedIdx)
            } else {
                paragraphs.append(currentPara)
                currentPara = [sortedIdx]
            }
        }
        if !currentPara.isEmpty {
            paragraphs.append(currentPara)
        }

        // Assign each line the median height of its paragraph
        var fontSizes = [CGFloat](repeating: 0, count: lines.count)
        for paragraph in paragraphs {
            let paraHeights = paragraph.map { heights[$0] }.sorted()
            let median = paraHeights[paraHeights.count / 2]
            let fontSize = max(8, median * 0.65)
            for idx in paragraph {
                fontSizes[idx] = fontSize
            }
        }

        return fontSizes
    }

    // MARK: - Visible lines rect

    /// Characters with descenders (strokes below the baseline).
    // Shared dyslexic font constants — change these to adjust size/compression
    private static let dyslexicFontSize: CGFloat = 14
    private static let dyslexicScale: CGFloat = 0.88

    private static let descenderChars = CharacterSet(charactersIn: "gjpqyQÇçĝĵŷ")

    /// Animation for the manual word-reveal slit. A plain ease (no spring) so
    /// the slit glides outward smoothly and never overshoots/recoils when a new
    /// word appears or the line resets.
    private static let manualRevealAnimation: Animation = .easeInOut(duration: 0.16)
    /// Moving down a line covers more ground than revealing a word, so it is
    /// given a little longer.
    private static let manualLineChangeAnimation: Animation = .easeInOut(duration: 0.22)

    /// Compute the rect that covers the center line plus N lines above and below.
    private func computeVisibleRect(centerIndex: Int) -> CGRect {
        let lines = appState.detectedLines
        guard !lines.isEmpty else { return .zero }

        // Full page mode: cover all detected lines
        let startIdx: Int
        let endIdx: Int
        if settings.manualWordModeEnabled {
            // Manual mode stacks lines via the completed-lines block, so the
            // leading-line rect is always exactly one line. This comes first:
            // with OpenDyslexic's Full page on, the whole selection is redrawn
            // in the font but the opening still follows the words.
            startIdx = centerIndex
            endIdx = centerIndex
        } else if settings.dyslexicFontEnabled && settings.dyslexicFullPageMode {
            startIdx = 0
            endIdx = lines.count - 1
        } else {
            let extra = settings.visibleLines - 1
            startIdx = max(0, centerIndex - extra)
            endIdx = min(lines.count - 1, centerIndex + extra)
        }

        var rect = screenToView(lines[startIdx].rect)
        if startIdx < endIdx {
            for i in (startIdx + 1)...endIdx {
                rect = rect.union(screenToView(lines[i].rect))
            }
        }

        // Check if the bottom-most visible line has descender characters
        let bottomLine = lines[endIdx]
        let hasDescenders = bottomLine.text.unicodeScalars.contains { Self.descenderChars.contains($0) }

        // Less bottom padding when no descenders, even less when there are
        let bottomPadding: CGFloat = hasDescenders ? 1 : 2
        let topPadding: CGFloat = 3

        // When dyslexic font is on, measure actual text width and height
        let dyslexicExtra: CGFloat
        let heightAdjustment: CGFloat
        if settings.dyslexicFontEnabled {
            let _ = Self.registerDyslexicFont
            let dFont = NSFont(name: "OpenDyslexic-Regular", size: Self.dyslexicFontSize)
                ?? NSFont.systemFont(ofSize: Self.dyslexicFontSize)

            // Width
            let maxDyslexicWidth = (startIdx...endIdx).map { i in
                measureTextWidth(lines[i].text, font: dFont) * Self.dyslexicScale
            }.max() ?? 0
            dyslexicExtra = max(0, maxDyslexicWidth - rect.width)

            // Height
            let dyslexicLineHeight = dFont.ascender - dFont.descender + dFont.leading
            let originalHeight = rect.height / CGFloat(max(1, endIdx - startIdx + 1))
            heightAdjustment = max(0, dyslexicLineHeight - originalHeight)
        } else {
            dyslexicExtra = 0
            heightAdjustment = 0
        }

        // The bezel is the overlay region expanded by 16px on each side (32px total).
        // Cap the slit so it can never exceed the bezel width minus a small inset.
        let bezelWidth = rect.width + 32
        let maxAllowedSlitWidth = max(0, bezelWidth - 4) // leave 2px on each side

        let slitX: CGFloat
        let slitWidth: CGFloat

        if settings.dyslexicFontEnabled {
            // Match the rendered OpenDyslexic text exactly:
            // - Left edge: baseLeftEdge + minIndent (where the leftmost dyslexic line starts)
            // - Right edge: rightmost pixel of any visible dyslexic line
            let paragraphSizes = computeParagraphFontSizes()
            let baseLeftEdge = bezelRect.minX + 16
            let minLineX = lines.map { screenToView($0.rect).minX }.min() ?? 0

            var minTextX: CGFloat = .greatestFiniteMagnitude
            var maxTextX: CGFloat = 0
            for i in startIdx...endIdx {
                let lineRect = screenToView(lines[i].rect)
                let indent = lineRect.minX - minLineX
                let textLeft = baseLeftEdge + indent
                let fontSize = i < paragraphSizes.count ? paragraphSizes[i] : max(8, lineRect.height * 0.65)
                let nsFont = NSFont(name: "OpenDyslexic-Regular", size: fontSize)
                    ?? NSFont.systemFont(ofSize: fontSize)
                let fullWidth = measureTextWidth(lines[i].text, font: nsFont)
                let fitScale = dyslexicFitScale(for: i, fontSize: fontSize, indent: indent, baseLeftEdge: baseLeftEdge)
                let renderedWidth = fullWidth * fitScale

                minTextX = min(minTextX, textLeft)
                maxTextX = max(maxTextX, textLeft + renderedWidth)
            }

            let padding: CGFloat = 8
            let slitLeft = max(bezelRect.minX + 2, minTextX - padding)
            let slitRight = min(bezelRect.maxX - 2, maxTextX + padding)
            slitX = slitLeft
            slitWidth = max(0, slitRight - slitLeft)
        } else {
            let rawSlitWidth = rect.width + 16
            let finalWidth = min(rawSlitWidth, maxAllowedSlitWidth)
            slitX = rect.origin.x - 8
            slitWidth = finalWidth
        }

        // Manual word-reveal mode uses its own snug geometry: the slit hugs the
        // actual text and its right edge is clamped to the first N revealed
        // words, so override the computed slitX/slitWidth entirely.
        let finalX: CGFloat
        let finalWidth: CGFloat
        if let manual = manualRevealSlit(centerIndex: centerIndex) {
            finalX = manual.x
            finalWidth = manual.width
        } else {
            finalX = slitX
            finalWidth = slitWidth
        }

        return CGRect(
            x: finalX,
            y: rect.origin.y - topPadding - heightAdjustment / 2,
            width: finalWidth,
            height: rect.height + topPadding + bottomPadding + heightAdjustment
        )
    }

    /// Recompute the manual-mode opening from the current window state:
    /// `highlightRect` = the leading line clamped to its revealed words, and
    /// `completedLinesRect` = the block of lines already read
    /// (`SlitWindow.fullWidthLines`), empty if none. The two are drawn as one
    /// joined opening (`SlitWindow`). `slitLine` and `slitArrival` tell the
    /// shapes which line this is and which finished line sits above it.
    private func updateManualCutouts() {
        let lines = appState.detectedLines
        guard let leading = appState.activeLineIndex,
              leading >= 0, leading < lines.count else { return }

        // Leading line: single-line rect, word-clamped (computeVisibleRect uses
        // the manual single-line + word-reveal path).
        let lower = computeVisibleRect(centerIndex: leading)
        let readLines = SlitWindow.fullWidthLines(
            windowTop: appState.windowTopIndex, leading: leading
        )

        highlightRect = lower
        if let readLines {
            completedLinesRect = readLines
                .map(fullLineSlitRect(index:))
                .reduce(CGRect.null) { $0.union($1) }
        } else {
            // Nothing read yet: an empty block at the top of the leading
            // line, not a null rect, so the opening later grows downwards
            // from here instead of sweeping in from the screen corner.
            let line = fullLineSlitRect(index: leading)
            completedLinesRect = CGRect(x: line.minX, y: line.minY, width: line.width, height: 0)
        }
        slitLine = CGFloat(leading)
        slitArrival = SlitWindow.Arrival(
            line: leading,
            lower: lower,
            finished: readLines == nil ? .null : fullLineSlitRect(index: leading - 1)
        )
    }

    /// Side padding of the opening around the text in word-by-word mode.
    /// Shared by the current line and the full-width lines, so the two line
    /// up and a line does not shift when it changes from one to the other.
    private static let manualSidePadding: CGFloat = 4

    /// Full-width slit rect for a single completed line (no word clamp), padded
    /// to match the leading line's padding so the stack reads as one
    /// continuous window.
    private func fullLineSlitRect(index: Int) -> CGRect {
        let lines = appState.detectedLines
        guard index >= 0, index < lines.count else { return .null }
        let rect = screenToView(lines[index].rect)
        let text = manualLineGeometry(index: index)
        let topPadding: CGFloat = 3
        let bottomPadding: CGFloat = 2
        let taller = dyslexicHeightAdjustment(lineHeight: rect.height)
        return CGRect(
            x: text.left - Self.manualSidePadding,
            y: rect.origin.y - topPadding - taller / 2,
            width: text.width + Self.manualSidePadding * 2,
            height: rect.height + topPadding + bottomPadding + taller
        )
    }

    /// Where one line's text sits in word-by-word mode, in view coordinates,
    /// and where the opening stops after each word but the last.
    private struct ManualLineGeometry {
        let left: CGFloat
        let width: CGFloat
        let stops: [CGFloat]
    }

    /// The text as it is on the page, or, with OpenDyslexic on, as Slit
    /// redraws it: a different left edge, width and word positions.
    private func manualLineGeometry(index: Int) -> ManualLineGeometry {
        let lines = appState.detectedLines
        let line = lines[index]
        let lineRect = screenToView(line.rect)

        // Lines that are not redrawn (formulas, symbols) keep the page's own
        // geometry even with the font on.
        guard settings.dyslexicFontEnabled, line.isReliableText else {
            return ManualLineGeometry(
                left: lineRect.minX,
                width: lineRect.width,
                stops: line.revealStops.map { $0 - screenFrame.origin.x }
            )
        }

        // Same layout as `dyslexicTextLayer`.
        let _ = Self.registerDyslexicFont
        let paragraphSizes = computeParagraphFontSizes()
        let baseLeftEdge = bezelRect.minX + 16
        let minLineX = lines.map { screenToView($0.rect).minX }.min() ?? 0
        let indent = lineRect.minX - minLineX
        let fontSize = index < paragraphSizes.count
            ? paragraphSizes[index] : max(8, lineRect.height * 0.65)
        let font = NSFont(name: "OpenDyslexic-Regular", size: fontSize)
            ?? NSFont.systemFont(ofSize: fontSize)
        let fitScale = dyslexicFitScale(
            for: index, fontSize: fontSize, indent: indent, baseLeftEdge: baseLeftEdge
        )
        let left = baseLeftEdge + indent
        return ManualLineGeometry(
            left: left,
            width: measureTextWidth(line.text, font: font) * fitScale,
            stops: WordStops.stops(
                forRenderedText: line.text, font: font, scale: fitScale, leftEdge: left
            )
        )
    }

    /// How much taller than the page's line the OpenDyslexic line is; zero
    /// with the font off. Matches the adjustment in `computeVisibleRect`.
    private func dyslexicHeightAdjustment(lineHeight: CGFloat) -> CGFloat {
        guard settings.dyslexicFontEnabled else { return 0 }
        let _ = Self.registerDyslexicFont
        let font = NSFont(name: "OpenDyslexic-Regular", size: Self.dyslexicFontSize)
            ?? NSFont.systemFont(ofSize: Self.dyslexicFontSize)
        return max(0, font.ascender - font.descender + font.leading - lineHeight)
    }

    /// Manual word-reveal mode has its own snug slit geometry. Returns the slit
    /// `(x, width)` in view coordinates, hugging the line's text and stopping
    /// after the first `revealedWordCount` words. Returns `nil` when the mode
    /// is off so the caller keeps its normal slit.
    private func manualRevealSlit(centerIndex: Int) -> (x: CGFloat, width: CGFloat)? {
        guard settings.manualWordModeEnabled,
              centerIndex >= 0, centerIndex < appState.detectedLines.count else {
            return nil
        }

        // Snug padding around the revealed text — tighter than the default slit.
        let pad = Self.manualSidePadding
        let text = manualLineGeometry(index: centerIndex)
        let slitLeft = text.left - pad

        let line = appState.detectedLines[centerIndex]
        let words = WordSegmenter.words(in: line.text)
        let revealed = appState.revealedWordCount

        // Whole line shown (or single word) → cover all the text.
        if words.count <= 1 || revealed >= words.count {
            return (slitLeft, max(0, text.width + pad * 2))
        }

        // Preferred: the stop after the Nth word, in the middle of the space
        // before the next word. The opening ends exactly there, with no extra
        // margin, so it neither cuts this word nor shows the start of the next.
        if let edge = revealStop(in: text, revealedWords: revealed) {
            return (slitLeft, max(0, edge - slitLeft))
        }

        // Fallback (no word geometry, e.g. Accessibility path): proportional
        // estimate by character count using the same punctuation-aware split.
        let revealedChars = words.prefix(revealed).reduce(0) { $0 + $1.text.count + 1 }
        let totalChars = max(1, words.reduce(0) { $0 + $1.text.count + 1 })
        let fraction = min(1.0, CGFloat(revealedChars) / CGFloat(totalChars))
        return (slitLeft, max(0, text.width * fraction + pad * 2))
    }

    /// The view-space X where the opening stops after the `revealedWords`-th
    /// word. Returns `nil` when the line has no stops or they do not match
    /// the current segmentation.
    private func revealStop(in text: ManualLineGeometry, revealedWords: Int) -> CGFloat? {
        guard revealedWords >= 1, revealedWords <= text.stops.count else { return nil }
        let edge = text.stops[revealedWords - 1]
        // Guard against a wildly out-of-range value (OCR glitch).
        guard edge.isFinite, edge >= text.left - 2, edge <= text.left + text.width + 2 else {
            return nil
        }
        return edge
    }

    // MARK: - Coordinate conversion

    /// The reading panel's frame for a text region given in screen coordinates.
    private func panelRect(around region: CGRect) -> CGRect {
        screenToView(region).insetBy(
            dx: -SlitOpening.panelMargin.width, dy: -SlitOpening.panelMargin.height
        )
    }

    private func screenToView(_ rect: CGRect) -> CGRect {
        CGRect(
            x: rect.origin.x - screenFrame.origin.x,
            y: rect.origin.y - screenFrame.origin.y,
            width: rect.width, height: rect.height
        )
    }
}

// MARK: - Animatable shapes

extension NSColor {
    /// Whether this color is perceptually light (for choosing contrasting text).
    var isLight: Bool {
        guard let srgb = usingColorSpace(.sRGB) else { return true }
        let luminance = 0.299 * srgb.redComponent + 0.587 * srgb.greenComponent + 0.114 * srgb.blueComponent
        return luminance > 0.5
    }
}

/// A closed string through 4 corner points with bezeled (rounded) corners.
struct StringQuadShape: Shape {
    let corners: [CGPoint]
    var cornerRadius: CGFloat = 12

    func path(in _: CGRect) -> Path {
        var path = Path()
        guard corners.count == 4 else { return path }

        // For each corner: come in along the previous edge, curve through the corner,
        // and exit along the next edge. The curve uses a quadratic with the corner
        // point as the control point.
        for i in 0..<corners.count {
            let prev = corners[(i - 1 + corners.count) % corners.count]
            let curr = corners[i]
            let next = corners[(i + 1) % corners.count]

            // Distance from corner to start of curve (along incoming edge)
            let inDir = unit(from: curr, to: prev)
            let outDir = unit(from: curr, to: next)

            let inDist = min(cornerRadius, distance(prev, curr) / 2)
            let outDist = min(cornerRadius, distance(curr, next) / 2)

            let inPt = CGPoint(x: curr.x + inDir.x * inDist, y: curr.y + inDir.y * inDist)
            let outPt = CGPoint(x: curr.x + outDir.x * outDist, y: curr.y + outDir.y * outDist)

            if i == 0 {
                path.move(to: inPt)
            } else {
                path.addLine(to: inPt)
            }
            path.addQuadCurve(to: outPt, control: curr)
        }
        path.closeSubpath()
        return path
    }

    private func unit(from a: CGPoint, to b: CGPoint) -> CGPoint {
        let dx = b.x - a.x
        let dy = b.y - a.y
        let len = sqrt(dx * dx + dy * dy)
        return len > 0 ? CGPoint(x: dx / len, y: dy / len) : .zero
    }

    private func distance(_ a: CGPoint, _ b: CGPoint) -> CGFloat {
        let dx = b.x - a.x
        let dy = b.y - a.y
        return sqrt(dx * dx + dy * dy)
    }
}

/// Renders a 4-corner string outline whose corners chase their target positions
/// using spring physics — the string lags behind fast mouse movement and snaps back.
struct PhysicsStringQuad: View {
    let startPoint: CGPoint   // anchor — fixed corner
    let currentPoint: CGPoint // mouse — moving corner
    let screenSize: CGSize

    // Animated corner state. Corners 0..3 = top-left, top-right, bottom-right, bottom-left.
    @State private var positions: [CGPoint] = []
    @State private var velocities: [CGPoint] = []
    @State private var lastTick: TimeInterval = 0

    // Spring physics
    private let stiffness: CGFloat = 250
    private let damping: CGFloat = 18

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 120)) { timeline in
            content(now: timeline.date.timeIntervalSinceReferenceDate)
        }
    }

    @ViewBuilder
    private func content(now: TimeInterval) -> some View {
        let targets = computeTargets()
        let _ = updatePhysics(now: now, targets: targets)
        let pts = positions.count == 4 ? positions : targets
        StringQuadShape(corners: pts)
            .stroke(
                Color.blue.opacity(0.85),
                style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round)
            )
    }

    /// The four target corner positions based on start + current mouse.
    private func computeTargets() -> [CGPoint] {
        let minX = min(startPoint.x, currentPoint.x)
        let maxX = max(startPoint.x, currentPoint.x)
        let minY = min(startPoint.y, currentPoint.y)
        let maxY = max(startPoint.y, currentPoint.y)
        return [
            CGPoint(x: minX, y: minY),  // top-left
            CGPoint(x: maxX, y: minY),  // top-right
            CGPoint(x: maxX, y: maxY),  // bottom-right
            CGPoint(x: minX, y: maxY)   // bottom-left
        ]
    }

    private func updatePhysics(now: TimeInterval, targets: [CGPoint]) {
        // Initialize on first frame
        if positions.count != 4 {
            DispatchQueue.main.async {
                positions = targets
                velocities = Array(repeating: .zero, count: 4)
                lastTick = now
            }
            return
        }

        let dt: CGFloat = lastTick > 0 ? min(0.05, CGFloat(now - lastTick)) : 1.0 / 60
        DispatchQueue.main.async {
            lastTick = now
            var newPos = positions
            var newVel = velocities
            for i in 0..<4 {
                let target = targets[i]
                let pos = positions[i]
                let vel = velocities[i]

                // Spring force: F = -k * (pos - target) - c * vel
                let displacement = CGPoint(x: pos.x - target.x, y: pos.y - target.y)
                let force = CGPoint(
                    x: -stiffness * displacement.x - damping * vel.x,
                    y: -stiffness * displacement.y - damping * vel.y
                )

                let newV = CGPoint(x: vel.x + force.x * dt, y: vel.y + force.y * dt)
                let newP = CGPoint(x: pos.x + newV.x * dt, y: pos.y + newV.y * dt)

                newVel[i] = newV
                newPos[i] = newP
            }
            positions = newPos
            velocities = newVel
        }
    }
}

struct MorphShape: Shape {
    var rect: CGRect
    var cornerRadius: CGFloat

    var animatableData: AnimatablePair<CGRect.AnimatableData, CGFloat> {
        get { AnimatablePair(rect.animatableData, cornerRadius) }
        set {
            rect.animatableData = newValue.first
            cornerRadius = newValue.second
        }
    }

    func path(in _: CGRect) -> Path {
        Path(roundedRect: rect, cornerRadius: cornerRadius)
    }
}

/// Dim shape with animated cutout — the panel and the opening both
/// interpolate smoothly.
struct AnimatedDimShape: Shape {
    var outerRect: CGRect
    var outerCornerRadius: CGFloat
    var cutoutCornerRadius: CGFloat
    /// The opening cut out of the panel: the current line and, in manual
    /// word-reveal mode, the lines already read joined to it.
    var window: SlitWindowLayout

    var animatableData: AnimatablePair<
        AnimatablePair<CGRect.AnimatableData, AnimatablePair<CGFloat, CGFloat>>,
        SlitWindowLayout.AnimatableData
    > {
        get {
            AnimatablePair(
                AnimatablePair(
                    outerRect.animatableData,
                    AnimatablePair(outerCornerRadius, cutoutCornerRadius)
                ),
                window.animatableData
            )
        }
        set {
            outerRect.animatableData = newValue.first.first
            outerCornerRadius = newValue.first.second.first
            cutoutCornerRadius = newValue.first.second.second
            window.animatableData = newValue.second
        }
    }

    func path(in _: CGRect) -> Path {
        var path = Path()
        path.addRoundedRect(
            in: outerRect,
            cornerSize: CGSize(width: outerCornerRadius, height: outerCornerRadius)
        )
        // The opening is one joined shape. Filled even-odd, so it is cut out
        // of the panel.
        path.addPath(SlitWindow.outline(window, cornerRadius: cutoutCornerRadius))
        return path
    }
}
