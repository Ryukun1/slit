import SwiftUI

/// The soft outline shown around the paragraph a ⌘+click would select.
///
/// It sits exactly where the reading panel will open, so the click feels like
/// the outline filling in rather than something new appearing.
struct HoverPreviewOutline: View {
    /// Outline frame in the overlay's coordinates, or nil to show nothing.
    let rect: CGRect?

    private enum Style {
        static let cornerRadius: CGFloat = 12
        static let fillOpacity = 0.10
        static let innerLineOpacity = 0.95
        static let innerLineWidth: CGFloat = 1.5
        static let outerLineOpacity = 0.22
        static let outerLineWidth: CGFloat = 1
        static let animation = Animation.easeOut(duration: 0.16)
    }

    var body: some View {
        ZStack {
            if let rect {
                RoundedRectangle(cornerRadius: Style.cornerRadius, style: .continuous)
                    .fill(SlitPalette.accent.opacity(Style.fillOpacity))
                    .overlay(
                        RoundedRectangle(cornerRadius: Style.cornerRadius, style: .continuous)
                            .strokeBorder(
                                // Slit's accent colour reads on both white and dark
                                // pages, where a plain white or black line
                                // disappears on one of them.
                                SlitPalette.accent.opacity(Style.innerLineOpacity),
                                lineWidth: Style.innerLineWidth
                            )
                    )
                    .overlay(
                        RoundedRectangle(
                            cornerRadius: Style.cornerRadius + Style.outerLineWidth,
                            style: .continuous
                        )
                        // A dark hairline outside keeps the edge crisp on mid-tone pages.
                        .strokeBorder(
                            Color.black.opacity(Style.outerLineOpacity),
                            lineWidth: Style.outerLineWidth
                        )
                        .padding(-Style.outerLineWidth)
                    )
                    .frame(width: rect.width, height: rect.height)
                    .position(x: rect.midX, y: rect.midY)
                    .transition(.opacity)
            }
        }
        // One view that moves: sliding between paragraphs glides the outline,
        // and it fades when there is nothing to select.
        .animation(Style.animation, value: rect)
        .accessibilityHidden(true)
    }
}
