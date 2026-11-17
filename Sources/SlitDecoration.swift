import SwiftUI

/// Tint and edge lines drawn over the slit's opening. Shared by dim and blur
/// mode so the opening looks the same in both.
struct SlitDecoration: View {
    /// The opening: the lines already read and the current line.
    let window: SlitWindowLayout
    /// Highlight colour, or nil when the tint is off.
    let tint: Color?
    let showsOutline: Bool

    private static let cornerRadius: CGFloat = 6
    private static let tintOpacity = 0.12
    private static let outerLine = Color.black.opacity(0.22)
    private static let innerLinePlain = Color.white.opacity(0.32)
    private static let innerLineTintOpacity = 0.55
    /// Each line is one point wide and sits wholly on its side of the edge.
    private static let lineOffset: CGFloat = 0.5

    var body: some View {
        ZStack {
            if let tint {
                shape(outset: 0).fill(tint.opacity(Self.tintOpacity))
            }
            if showsOutline {
                // A soft dark line just outside the opening separates it from
                // the covered surround; a light line just inside defines the
                // opening. Together they read over light or dark pages.
                shape(outset: Self.lineOffset)
                    .stroke(Self.outerLine, lineWidth: 1)
                shape(outset: -Self.lineOffset)
                    .stroke(
                        tint?.opacity(Self.innerLineTintOpacity) ?? Self.innerLinePlain,
                        lineWidth: 1
                    )
            }
        }
    }

    private func shape(outset: CGFloat) -> SlitWindowShape {
        SlitWindowShape(layout: window, cornerRadius: Self.cornerRadius, outset: outset)
    }
}

/// How the blurred panel fades into the slit's opening.
///
/// A hard edge between blurred and sharp text flickers light and dark as the
/// slit crosses rows of text, so the blur fades out over a few points instead.
/// The fade is kept narrow and centred on the opening's edge: where the blur
/// is half faded the sharp page shows through it, and a wider fade would let
/// the lines above and below be read.
enum SlitFeather {
    private static let softnessPerBlurRadius: CGFloat = 0.2
    private static let softnessRange: ClosedRange<CGFloat> = 1...2

    /// Blur applied to the opening's edge in the mask, in points.
    static func softness(blurRadius: CGFloat) -> CGFloat {
        min(softnessRange.upperBound,
            max(softnessRange.lowerBound, blurRadius * softnessPerBlurRadius))
    }
}

/// The captured screen, blurred, covering the reading panel, with the slit's
/// opening faded out of it. Nothing is drawn inside the opening: the overlay
/// window is transparent there, so the live page shows through.
struct BlurredPanel: View {
    let image: NSImage
    let size: CGSize
    let blurRadius: CGFloat
    let panelRect: CGRect
    let panelCornerRadius: CGFloat
    let window: SlitWindowLayout

    private static let cornerRadius: CGFloat = 6

    var body: some View {
        Image(nsImage: image)
            .resizable()
            .frame(width: size.width, height: size.height)
            .blur(radius: blurRadius)
            .mask(
                ZStack {
                    MorphShape(rect: panelRect, cornerRadius: panelCornerRadius)
                        .fill(.white)
                    SlitWindowShape(layout: window, cornerRadius: Self.cornerRadius)
                        .fill(.black)
                        .blur(radius: SlitFeather.softness(blurRadius: blurRadius))
                        .blendMode(.destinationOut)
                }
                .frame(width: size.width, height: size.height)
                .compositingGroup()
            )
    }
}
