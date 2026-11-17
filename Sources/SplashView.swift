import SwiftUI

/// Brief launch splash — logo mark + wordmark, dark rounded card matching the
/// marketing site aesthetic. Fades in then out automatically (timing handled
/// by the AppDelegate).
struct SplashView: View {
    private static let bg = Color(red: 0x0E / 255.0, green: 0x0E / 255.0, blue: 0x10 / 255.0)
    private static let ink = Color(red: 0xF2 / 255.0, green: 0xEE / 255.0, blue: 0xE6 / 255.0)
    private static let inkSoft = Color(red: 0x8A / 255.0, green: 0x86 / 255.0, blue: 0x80 / 255.0)
    private static let rule = Color(red: 0x23 / 255.0, green: 0x23 / 255.0, blue: 0x27 / 255.0)

    var body: some View {
        VStack(spacing: 20) {
            LogoView(size: 96)
                .shadow(color: .black.opacity(0.35), radius: 20, y: 8)

            VStack(spacing: 4) {
                Text("Slit")
                    .font(.system(size: 22, weight: .bold))
                    .foregroundStyle(Self.ink)
                Text("Reading focus")
                    .font(.system(size: 11, weight: .bold))
                    .tracking(1.2)
                    .textCase(.uppercase)
                    .foregroundStyle(Self.inkSoft)
            }
        }
        .frame(width: 220, height: 240)
        .background(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(Self.bg)
                .overlay(
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .strokeBorder(Self.rule, lineWidth: 1)
                )
        )
    }
}
