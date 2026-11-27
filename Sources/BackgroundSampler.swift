import AppKit
import CoreGraphics

/// Finds the colour behind a line of text in a screen capture, so the
/// OpenDyslexic text drawn over that line sits on a matching background.
///
/// It reads the pixels of the line's own band, where most pixels are the
/// background and the letters are a minority spread over many shades, and
/// takes the colour most of them share. That picks up a highlight, a code
/// block or a table stripe behind the words, which the page around the line
/// does not show. Only when no colour clearly dominates (a photo, a busy
/// pattern) does it fall back to the page in a ring around the line.
enum BackgroundSampler {
    /// Points added around the line's box, to include the gap above and
    /// below the letters without reaching the neighbouring lines.
    static let linePadding: CGFloat = 2
    /// Width of the fallback ring around the line, in points.
    static let ringMargin: CGFloat = 20
    /// The commonest colour must cover at least this share of the band to be
    /// taken as its background.
    static let minimumShare = 0.25
    /// Colours within this many levels (of 255) of the commonest one count as
    /// the same background, so slight noise or dithering is averaged in.
    static let tolerance = 6

    /// The background behind `line`, in sRGB.
    ///
    /// - Parameters:
    ///   - line: the line's frame in screen points (origin top-left).
    ///   - image: a capture whose top-left pixel is at `origin` on screen.
    ///   - pixelsPerPoint: the capture's scale.
    /// - Returns: nil when the line is not inside the capture.
    static func background(
        of line: CGRect, in image: CGImage, origin: CGPoint, pixelsPerPoint: CGFloat
    ) -> NSColor? {
        let band = line.insetBy(dx: -linePadding, dy: -linePadding)
        let bandPixels = pixelRect(band, origin: origin, scale: pixelsPerPoint)
        guard let inBand = pixels(of: image, in: bandPixels), !inBand.isEmpty else { return nil }

        if let dominant = dominantColor(in: inBand), dominant.share >= minimumShare {
            return dominant.color
        }

        let ring = line.insetBy(dx: -ringMargin, dy: -ringMargin)
        let ringPixels = pixels(
            of: image, in: pixelRect(ring, origin: origin, scale: pixelsPerPoint), excluding: bandPixels
        )
        return (ringPixels.flatMap(dominantColor(in:)) ?? dominantColor(in: inBand))?.color
    }

    // MARK: - Pixels

    struct Pixel: Equatable {
        let r: UInt8, g: UInt8, b: UInt8
    }

    /// The most common colour and the share of pixels that have it.
    static func dominantColor(in pixels: [Pixel]) -> (color: NSColor, share: Double)? {
        guard !pixels.isEmpty else { return nil }

        // Count coarse buckets (32 levels per channel) to find the commonest...
        var buckets: [Int: Int] = [:]
        for p in pixels {
            buckets[bucket(p), default: 0] += 1
        }
        guard let top = buckets.max(by: { $0.value < $1.value })?.key else { return nil }

        // ...then average the exact pixels near it, so a colour sitting on a
        // bucket boundary is not split in two.
        let centre = Pixel(r: UInt8((top >> 10) << 3 | 4), g: UInt8((top >> 5 & 31) << 3 | 4),
                           b: UInt8((top & 31) << 3 | 4))
        let near = pixels.filter { isNear($0, centre, within: 8) }
        let mean = average(near)
        let matching = pixels.filter { isNear($0, mean, within: tolerance) }
        guard !matching.isEmpty else { return nil }
        let exact = average(matching)

        let color = NSColor(
            srgbRed: CGFloat(exact.r) / 255, green: CGFloat(exact.g) / 255,
            blue: CGFloat(exact.b) / 255, alpha: 1
        )
        return (color, Double(matching.count) / Double(pixels.count))
    }

    /// Pixels of `rect` (in image pixels, origin top-left), converted to sRGB.
    /// Pixels inside `excluding` are left out. Nil if `rect` misses the image.
    static func pixels(of image: CGImage, in rect: CGRect, excluding: CGRect? = nil) -> [Pixel]? {
        let bounds = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        let clipped = rect.integral.intersection(bounds)
        guard !clipped.isNull, clipped.width >= 1, clipped.height >= 1,
              let crop = image.cropping(to: clipped),
              let srgb = CGColorSpace(name: CGColorSpace.sRGB)
        else { return nil }

        let width = crop.width, height = crop.height
        var data = [UInt8](repeating: 0, count: width * height * 4)
        let drawn: Bool = data.withUnsafeMutableBytes { buffer in
            guard let context = CGContext(
                data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                bytesPerRow: width * 4, space: srgb,
                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
            ) else { return false }
            // Drawing into an sRGB context converts from the capture's own
            // colour space (Display P3 on most Macs), so the colour we return
            // is the one SwiftUI will reproduce on screen.
            context.draw(crop, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { return nil }

        let skip = excluding.map { $0.integral.offsetBy(dx: -clipped.minX, dy: -clipped.minY) }
        var result: [Pixel] = []
        result.reserveCapacity(width * height)
        for y in 0..<height {
            for x in 0..<width {
                if let skip, skip.contains(CGPoint(x: CGFloat(x) + 0.5, y: CGFloat(y) + 0.5)) {
                    continue
                }
                let i = (y * width + x) * 4
                result.append(Pixel(r: data[i], g: data[i + 1], b: data[i + 2]))
            }
        }
        return result
    }

    // MARK: - Helpers

    /// A screen rect in points mapped into the capture's pixels.
    private static func pixelRect(_ rect: CGRect, origin: CGPoint, scale: CGFloat) -> CGRect {
        CGRect(
            x: (rect.minX - origin.x) * scale, y: (rect.minY - origin.y) * scale,
            width: rect.width * scale, height: rect.height * scale
        )
    }

    private static func bucket(_ p: Pixel) -> Int {
        Int(p.r >> 3) << 10 | Int(p.g >> 3) << 5 | Int(p.b >> 3)
    }

    private static func isNear(_ a: Pixel, _ b: Pixel, within limit: Int) -> Bool {
        abs(Int(a.r) - Int(b.r)) <= limit
            && abs(Int(a.g) - Int(b.g)) <= limit
            && abs(Int(a.b) - Int(b.b)) <= limit
    }

    private static func average(_ pixels: [Pixel]) -> Pixel {
        guard !pixels.isEmpty else { return Pixel(r: 0, g: 0, b: 0) }
        let n = pixels.count
        let r = pixels.reduce(0) { $0 + Int($1.r) }, g = pixels.reduce(0) { $0 + Int($1.g) },
            b = pixels.reduce(0) { $0 + Int($1.b) }
        return Pixel(r: UInt8((r + n / 2) / n), g: UInt8((g + n / 2) / n), b: UInt8((b + n / 2) / n))
    }
}
