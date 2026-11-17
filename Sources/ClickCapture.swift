import CoreGraphics

/// Decides which mouse events Slit keeps for itself.
///
/// While a reading session is open, a click on the reading panel reveals the
/// next word or moves on a line. If the click also reached the page beneath,
/// it would start a text selection there, and quick clicks would select whole
/// words and paragraphs. So a press on the panel is kept, together with any
/// movement while the button is down and the release that ends it.
///
/// A value type with no shared state: each event produces the next value.
struct ClickCapture: Equatable {
    enum Phase {
        case down, dragged, up
    }

    /// How far beyond the text the reading panel reaches.
    static let panelMargin = CGSize(width: 20, height: 16)

    /// Screen area whose clicks are kept; nil when no session is open.
    private let region: CGRect?
    /// The button went down on the panel and has not come up yet.
    private let isHoldingClick: Bool

    init() {
        self.init(region: nil, isHoldingClick: false)
    }

    private init(region: CGRect?, isHoldingClick: Bool) {
        self.region = region
        self.isHoldingClick = isHoldingClick
    }

    /// The panel for a session's text region, or nil when not reading.
    static func region(isReading: Bool, textRegion: CGRect) -> CGRect? {
        isReading ? panelRegion(around: textRegion) : nil
    }

    static func panelRegion(around textRegion: CGRect) -> CGRect {
        textRegion.insetBy(dx: -panelMargin.width, dy: -panelMargin.height)
    }

    func withRegion(_ region: CGRect?) -> ClickCapture {
        ClickCapture(region: region, isHoldingClick: isHoldingClick)
    }

    /// Whether Slit keeps this event from the page, and the state after it.
    func after(
        _ phase: Phase, at point: CGPoint, optionHeld: Bool
    ) -> (keepsEvent: Bool, next: ClickCapture) {
        switch phase {
        case .down:
            // Option-click adds a paragraph to the selection; leave it be.
            let keeps = !optionHeld && (region?.contains(point) ?? false)
            return (keeps, ClickCapture(region: region, isHoldingClick: keeps))
        case .dragged:
            return (isHoldingClick, self)
        case .up:
            // The release belongs with its press, wherever it lands and
            // whether or not the session is still open.
            return (isHoldingClick, ClickCapture(region: region, isHoldingClick: false))
        }
    }
}
