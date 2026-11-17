import CoreGraphics

/// Geometry of the slit's opening animation.
enum SlitOpening {
    /// How far the reading panel extends beyond the text it frames. The hover
    /// preview uses the same margin so its outline is where the panel opens.
    static let panelMargin = CGSize(width: 16, height: 12)

    /// Where the slit starts when a session opens: a small square centred on
    /// the loading bubble, so it grows out of the same point as the dimmed
    /// panel and travels to its line, instead of appearing on the line while
    /// the panel is still expanding from the click.
    ///
    /// - Parameters:
    ///   - bubble: the loading bubble's rect, in view coordinates.
    ///   - targetHeight: height of the slit once fully open.
    static func seedRect(bubble: CGRect, targetHeight: CGFloat) -> CGRect {
        let side = min(bubble.width, bubble.height, targetHeight)
        return CGRect(
            x: bubble.midX - side / 2,
            y: bubble.midY - side / 2,
            width: side,
            height: side
        )
    }
}

// MARK: - Panel fade-in

extension SlitOpening {
    /// How long the panel takes to reach its full strength. Short next to
    /// the growth: the panel has to be clearly visible while it is still
    /// small, or it would seem to fade in in place instead of enlarging from
    /// the click.
    static let panelFadeInDuration: Double = 0.15

    /// The spring that enlarges the panel from the click point until it fits
    /// the selected area: slow enough to follow, with barely any bounce.
    static let panelGrowResponse: Double = 0.55
    static let panelGrowDamping: Double = 0.88

    /// How visible the panel is on its first frame. It starts transparent
    /// and fades in quickly at the click point, so it does not snap on.
    static func panelStartOpacity(style _: OverlayStyle) -> Double { 0 }

    /// Whether the loading bubble is on screen. It stays after detection has
    /// ended until the panel starts to open: blur mode captures the screen in
    /// between, and the bubble must not vanish during that wait.
    static func showsLoadingBubble(
        isDetecting: Bool, isActive: Bool, panelIsOpening: Bool
    ) -> Bool {
        isDetecting || (isActive && !panelIsOpening)
    }
}
