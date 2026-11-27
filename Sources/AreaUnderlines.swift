import SwiftUI

/// Where the mark under one line sits, and its squiggly shape.
enum AreaUnderline {
    /// Space between the bottom of the text and the top of the wave.
    static let gap: CGFloat = 1.5
    static let thickness: CGFloat = 1.5
    /// How far the wave rises above and dips below its centre line.
    static let amplitude: CGFloat = 1.25
    /// Length of one full up-and-down of the wave.
    static let wavelength: CGFloat = 6

    /// The band the squiggle is drawn in: as wide as the text, just below it,
    /// and tall enough for the wave plus its stroke.
    static func rect(under line: CGRect) -> CGRect {
        CGRect(
            x: line.minX, y: line.maxY + gap,
            width: line.width, height: amplitude * 2 + thickness
        )
    }

    /// A wave across `band`, from its left edge to its right edge.
    ///
    /// The number of half-waves is rounded so the wave always ends exactly at
    /// the right edge, and is at least two so even a tiny line rises and falls.
    static func squiggle(in band: CGRect) -> Path {
        let halfWaves = max(2, Int((band.width / (wavelength / 2)).rounded()))
        let step = band.width / CGFloat(halfWaves)
        // A quadratic curve peaks halfway to its control point, so the control
        // sits at twice the amplitude.
        let reach = amplitude * 2

        return Path { path in
            path.move(to: CGPoint(x: band.minX, y: band.midY))
            for index in 0..<halfWaves {
                let startX = band.minX + CGFloat(index) * step
                let direction: CGFloat = index.isMultiple(of: 2) ? -1 : 1
                path.addQuadCurve(
                    to: CGPoint(x: startX + step, y: band.midY),
                    control: CGPoint(x: startX + step / 2, y: band.midY + direction * reach)
                )
            }
        }
    }
}

/// Underlines the lines an Option-drag would select, as the drag moves.
///
/// A thin squiggle under each line shows exactly which text would be taken
/// without boxing it in or tinting it: the dragged rectangle is only a
/// gesture, and what gets selected is the lines whose centre it covers.
/// Each squiggle draws itself from left to right as the drag reaches its line.
struct AreaUnderlines: View {
    /// The lines' frames in the overlay's coordinates.
    let lines: [CGRect]

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private enum Style {
        // Slit's accent colour reads on both white and dark pages.
        static let opacity = 0.9
        static let animation = Animation.easeOut(duration: 0.14)
        /// Long enough to see the pen move, short enough not to lag the drag.
        static let draw = Animation.easeOut(duration: 0.32)
    }

    var body: some View {
        ZStack {
            ForEach(lines.map(AreaUnderline.rect(under:)), id: \.key) { band in
                SquiggleShape()
                    .stroke(
                        SlitPalette.accent.opacity(Style.opacity),
                        style: StrokeStyle(
                            lineWidth: AreaUnderline.thickness,
                            lineCap: .round, lineJoin: .round
                        )
                    )
                    .frame(width: band.width, height: band.height)
                    .position(x: band.midX, y: band.midY)
                    .transition(appearance)
            }
        }
        // Lines draw in as the drag reaches them and fade out as it leaves them.
        .animation(Style.animation, value: lines)
        .accessibilityHidden(true)
    }

    private var appearance: AnyTransition {
        guard !reduceMotion else { return .opacity }
        return .asymmetric(
            insertion: .modifier(
                active: DrawReveal(fraction: 0),
                identity: DrawReveal(fraction: 1)
            ).animation(Style.draw),
            removal: .opacity
        )
    }
}

/// The squiggle filling whatever frame it is given.
private struct SquiggleShape: Shape {
    func path(in rect: CGRect) -> Path {
        AreaUnderline.squiggle(in: rect)
    }
}

/// Shows only the left `fraction` of its content, so animating the fraction
/// from 0 to 1 looks like the line being drawn from left to right.
private struct DrawReveal: ViewModifier {
    let fraction: CGFloat

    func body(content: Content) -> some View {
        content.mask(alignment: .leading) {
            Rectangle()
                // Wider than the band so the round line caps are never clipped.
                .padding(-AreaUnderline.thickness)
                .scaleEffect(x: fraction, anchor: .leading)
        }
    }
}

private extension CGRect {
    /// Identifies an underline by where it is, so one that stays put while
    /// the drag grows is kept rather than redrawn.
    var key: String { "\(minX)|\(minY)|\(width)" }
}
