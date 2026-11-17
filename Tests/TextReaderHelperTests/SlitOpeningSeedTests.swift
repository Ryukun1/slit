import CoreGraphics
import Testing
@testable import TextReaderHelper

/// The slit opening and the dimmed panel both grow out of the loading bubble
/// at the click point, so they read as one motion.
struct SlitOpeningSeedTests {
    private let bubble = CGRect(x: 482, y: 300, width: 36, height: 36)

    @Test("The opening starts centred on the loading bubble")
    func seedIsCentredOnBubble() {
        let seed = SlitOpening.seedRect(bubble: bubble, targetHeight: 24)

        #expect(seed.midX == bubble.midX)
        #expect(seed.midY == bubble.midY)
    }

    @Test("The opening starts inside the bubble, whatever the line height",
          arguments: [8, 24, 36, 90] as [CGFloat])
    func seedFitsInsideBubble(targetHeight: CGFloat) {
        let seed = SlitOpening.seedRect(bubble: bubble, targetHeight: targetHeight)

        #expect(bubble.contains(seed))
        #expect(seed.width == seed.height)
        #expect(seed.height == min(bubble.height, targetHeight))
    }
}
