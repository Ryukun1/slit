import SwiftUI

/// Where the mark under one line sits.
enum AreaUnderline {
    /// Space between the bottom of the text and the underline.
    static let gap: CGFloat = 2
    static let thickness: CGFloat = 1.5

    /// The underline for a line of text: as wide as the text, just below it.
    static func rect(under line: CGRect) -> CGRect {
        CGRect(x: line.minX, y: line.maxY + gap, width: line.width, height: thickness)
    }
}

/// Underlines the lines an Option-drag would select, as the drag moves.
///
/// A thin stroke under each line shows exactly which text would be taken
/// without boxing it in or tinting it: the dragged rectangle is only a
/// gesture, and what gets selected is the lines whose centre it covers.
struct AreaUnderlines: View {
    /// The lines' frames in the overlay's coordinates.
    let lines: [CGRect]

    private enum Style {
        // Slit's accent colour reads on both white and dark pages.
        static let opacity = 0.9
        static let animation = Animation.easeOut(duration: 0.14)
    }

    var body: some View {
        ZStack {
            ForEach(lines.map(AreaUnderline.rect(under:)), id: \.key) { underline in
                Capsule()
                    .fill(SlitPalette.accent.opacity(Style.opacity))
                    .frame(width: underline.width, height: underline.height)
                    .position(x: underline.midX, y: underline.midY)
                    .transition(.opacity)
            }
        }
        // Lines fade in as the drag reaches them and out as it leaves them.
        .animation(Style.animation, value: lines)
        .accessibilityHidden(true)
    }
}

private extension CGRect {
    /// Identifies an underline by where it is, so one that stays put while
    /// the drag grows is kept rather than redrawn.
    var key: String { "\(minX)|\(minY)|\(width)" }
}
