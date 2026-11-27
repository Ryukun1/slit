import AppKit
import CoreGraphics
import Testing
@testable import TextReaderHelper

/// The colour drawn behind the OpenDyslexic text must match what is behind
/// the original line, not just the page around it.
struct BackgroundSamplerTests {
    private static let white = RGBA(255, 255, 255)
    private static let yellow = RGBA(255, 236, 140)
    private static let codeGrey = RGBA(240, 241, 244)
    private static let ink = RGBA(20, 20, 20)

    /// A line of "text" 300×20 pt at (50, 40) in a 400×100 pt capture.
    private static let line = CGRect(x: 50, y: 40, width: 300, height: 20)

    @Test("A highlighted line gets the highlight colour, not the page colour")
    func highlightedLine() throws {
        let image = Self.capture(page: Self.white, band: Self.yellow, glyphCover: 0.3)

        let color = try #require(BackgroundSampler.background(
            of: Self.line, in: image, origin: .zero, pixelsPerPoint: 1
        ))

        Self.expect(color, equals: Self.yellow)
    }

    @Test("Dense dark text does not darken the background")
    func denseText() throws {
        let image = Self.capture(page: Self.codeGrey, band: Self.codeGrey, glyphCover: 0.45)

        let color = try #require(BackgroundSampler.background(
            of: Self.line, in: image, origin: .zero, pixelsPerPoint: 1
        ))

        Self.expect(color, equals: Self.codeGrey)
    }

    @Test("Neighbouring lines close above and below are ignored")
    func tightLineSpacing() throws {
        // Lines 4 pt apart: the old 20 pt ring landed on their glyphs.
        let image = Self.capture(page: Self.white, band: Self.white, glyphCover: 0.35, neighbourGap: 4)

        let color = try #require(BackgroundSampler.background(
            of: Self.line, in: image, origin: .zero, pixelsPerPoint: 1
        ))

        Self.expect(color, equals: Self.white)
    }

    @Test("Slight noise in the background is averaged, not split")
    func noisyBackground() throws {
        let image = Self.capture(page: Self.white, band: RGBA(247, 248, 250), glyphCover: 0.3, noise: 3)

        let color = try #require(BackgroundSampler.background(
            of: Self.line, in: image, origin: .zero, pixelsPerPoint: 1
        ))

        Self.expect(color, equals: RGBA(247, 248, 250), tolerance: 2)
    }

    @Test("With no clear colour behind the line, the page around it is used")
    func noDominantColour() throws {
        let image = Self.capture(page: Self.codeGrey, band: nil, glyphCover: 0, stripes: true)

        let color = try #require(BackgroundSampler.background(
            of: Self.line, in: image, origin: .zero, pixelsPerPoint: 1
        ))

        Self.expect(color, equals: Self.codeGrey)
    }

    @Test("Retina captures and offset origins map the line to the right pixels")
    func scaleAndOrigin() throws {
        let image = Self.capture(page: Self.white, band: Self.yellow, glyphCover: 0.3, scale: 2)
        // The capture starts at (1000, 500) on screen; the line is offset to match.
        let onScreen = Self.line.offsetBy(dx: 1000, dy: 500)

        let color = try #require(BackgroundSampler.background(
            of: onScreen, in: image, origin: CGPoint(x: 1000, y: 500), pixelsPerPoint: 2
        ))

        Self.expect(color, equals: Self.yellow)
    }

    @Test("Colours from a Display P3 capture come out right in sRGB")
    func displayP3() throws {
        let p3 = try #require(CGColorSpace(name: CGColorSpace.displayP3))
        let image = Self.capture(page: Self.white, band: RGBA(230, 245, 255), glyphCover: 0.3, space: p3)
        let expected = try #require(NSColor(
            displayP3Red: 230 / 255, green: 245 / 255, blue: 1, alpha: 1
        ).usingColorSpace(.sRGB))

        let color = try #require(BackgroundSampler.background(
            of: Self.line, in: image, origin: .zero, pixelsPerPoint: 1
        ))

        #expect(abs(color.redComponent - expected.redComponent) < 0.01)
        #expect(abs(color.greenComponent - expected.greenComponent) < 0.01)
        #expect(abs(color.blueComponent - expected.blueComponent) < 0.01)
    }

    @Test("A line off the edge of the capture still returns a colour, or none")
    func outsideCapture() {
        let image = Self.capture(page: Self.white, band: Self.white, glyphCover: 0.3)
        let offscreen = CGRect(x: 900, y: 900, width: 100, height: 20)

        #expect(BackgroundSampler.background(
            of: offscreen, in: image, origin: .zero, pixelsPerPoint: 1
        ) == nil)
    }

    // MARK: - Synthetic captures

    struct RGBA: Equatable {
        let r: UInt8, g: UInt8, b: UInt8
        init(_ r: UInt8, _ g: UInt8, _ b: UInt8) { (self.r, self.g, self.b) = (r, g, b) }
    }

    /// Draws a 400×100 pt "screen": the page colour, an optional band behind
    /// `line`, dark glyph blocks covering `glyphCover` of the line, and
    /// optionally neighbouring text lines `neighbourGap` pt above and below.
    private static func capture(
        page: RGBA, band: RGBA?, glyphCover: Double,
        neighbourGap: CGFloat? = nil, noise: Int = 0, stripes: Bool = false,
        scale: CGFloat = 1, space: CGColorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
    ) -> CGImage {
        let width = Int(400 * scale), height = Int(100 * scale)
        let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        // Draw in top-left-origin points, like screen coordinates.
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: scale, y: -scale)

        // Colours are given as components in the capture's own colour space.
        func fillRaw(_ rect: CGRect, _ color: RGBA) {
            let components = [CGFloat(color.r) / 255, CGFloat(color.g) / 255, CGFloat(color.b) / 255, 1]
            context.setFillColor(CGColor(colorSpace: space, components: components)!)
            context.fill(rect)
        }

        fillRaw(CGRect(x: 0, y: 0, width: 400, height: 100), page)
        let bandRect = line.insetBy(dx: -BackgroundSampler.linePadding, dy: -BackgroundSampler.linePadding)
        if let band {
            fillRaw(bandRect, band)
            if noise > 0 {
                var seed: UInt64 = 42
                for x in stride(from: bandRect.minX, to: bandRect.maxX, by: 1) {
                    for y in stride(from: bandRect.minY, to: bandRect.maxY, by: 1) {
                        seed = seed &* 6364136223846793005 &+ 1442695040888963407
                        let delta = Int(seed >> 60) % (noise * 2 + 1) - noise
                        func shift(_ v: UInt8) -> UInt8 { UInt8(clamping: Int(v) + delta) }
                        fillRaw(CGRect(x: x, y: y, width: 1, height: 1),
                                RGBA(shift(band.r), shift(band.g), shift(band.b)))
                    }
                }
            }
        }
        if stripes {
            // Every 2 pt a different colour: no colour dominates the band.
            let palette = [RGBA(200, 30, 30), RGBA(30, 200, 30), RGBA(30, 30, 200), RGBA(200, 200, 30),
                           RGBA(30, 200, 200), RGBA(200, 30, 200), RGBA(120, 120, 120)]
            for (i, x) in stride(from: bandRect.minX, to: bandRect.maxX, by: 2).enumerated() {
                fillRaw(CGRect(x: x, y: bandRect.minY, width: 2, height: bandRect.height),
                        palette[i % palette.count])
            }
        }
        drawGlyphs(in: line, cover: glyphCover, fill: fillRaw)
        if let gap = neighbourGap {
            drawGlyphs(in: line.offsetBy(dx: 0, dy: -(line.height + gap)), cover: 0.5, fill: fillRaw)
            drawGlyphs(in: line.offsetBy(dx: 0, dy: line.height + gap), cover: 0.5, fill: fillRaw)
        }
        return context.makeImage()!
    }

    /// Vertical strokes in a few shades, like anti-aliased letters.
    private static func drawGlyphs(in rect: CGRect, cover: Double, fill: (CGRect, RGBA) -> Void) {
        guard cover > 0 else { return }
        let shades = [ink, RGBA(60, 60, 60), RGBA(110, 110, 110), RGBA(170, 170, 170)]
        let pitch: CGFloat = 6
        let stroke = pitch * CGFloat(cover)
        for (i, x) in stride(from: rect.minX, to: rect.maxX, by: pitch).enumerated() {
            fill(CGRect(x: x, y: rect.minY + 3, width: stroke, height: rect.height - 6), shades[i % shades.count])
        }
    }

    private static func expect(_ color: NSColor, equals expected: RGBA, tolerance: Double = 1) {
        let srgb = color.usingColorSpace(.sRGB)!
        #expect(abs(srgb.redComponent * 255 - Double(expected.r)) <= tolerance)
        #expect(abs(srgb.greenComponent * 255 - Double(expected.g)) <= tolerance)
        #expect(abs(srgb.blueComponent * 255 - Double(expected.b)) <= tolerance)
    }
}
