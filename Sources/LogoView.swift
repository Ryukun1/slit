import SwiftUI

/// The Slit logo mark — matches the SVG used on the marketing site.
/// A rounded charcoal square with 4 dimmed text bars and a translucent
/// grey slit centered on the second bar.
struct LogoView: View {
    /// Overall size in points. Internal geometry scales from a 64pt canvas.
    var size: CGFloat = 64

    // Palette — matches the web page.
    private static let frame = Color(red: 0x0E / 255.0, green: 0x0E / 255.0, blue: 0x10 / 255.0)
    private static let border = Color(red: 0x2A / 255.0, green: 0x2A / 255.0, blue: 0x2F / 255.0)
    private static let bar = Color(red: 0x2A / 255.0, green: 0x2A / 255.0, blue: 0x2F / 255.0)
    private static let slit = Color(red: 0x8A / 255.0, green: 0x86 / 255.0, blue: 0x80 / 255.0)

    var body: some View {
        let s = size / 64.0

        ZStack {
            // Rounded frame
            RoundedRectangle(cornerRadius: 16 * s, style: .continuous)
                .fill(Self.frame)
                .overlay(
                    RoundedRectangle(cornerRadius: 16 * s, style: .continuous)
                        .strokeBorder(Self.border, lineWidth: 1)
                )

            // 4 uneven text bars: widths 34, 48, 40, 28 at y 16/26/38/48
            GeometryReader { _ in
                Group {
                    bar(x: 10, y: 16, w: 34, scale: s)
                    bar(x: 10, y: 26, w: 48, scale: s)
                    bar(x: 10, y: 38, w: 40, scale: s)
                    bar(x: 10, y: 48, w: 28, scale: s)
                }
            }

            // Slit — translucent grey + grey border, pill-shaped over bar 2
            RoundedRectangle(cornerRadius: 5 * s, style: .continuous)
                .fill(Self.slit.opacity(0.35))
                .overlay(
                    RoundedRectangle(cornerRadius: 5 * s, style: .continuous)
                        .strokeBorder(Self.slit, lineWidth: 1.2)
                )
                .frame(width: 52 * s, height: 10 * s)
                .position(x: 32 * s, y: 28 * s)
        }
        .frame(width: size, height: size)
    }

    private func bar(x: CGFloat, y: CGFloat, w: CGFloat, scale: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: 2 * scale, style: .continuous)
            .fill(Self.bar)
            .frame(width: w * scale, height: 4 * scale)
            .position(x: (x + w / 2) * scale, y: (y + 2) * scale)
    }
}
