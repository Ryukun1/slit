import CoreGraphics
import Testing
@testable import TextReaderHelper

/// Blur mode fades the blur out around the opening instead of cutting it hard.
struct SlitFeatherTests {
    @Test("A stronger blur gets a softer edge, within limits",
          arguments: [(2.0, 1.0), (8.0, 1.6), (10.0, 2.0), (20.0, 2.0)])
    func softnessFollowsBlurRadius(blurRadius: Double, expected: Double) {
        let softness = Double(SlitFeather.softness(blurRadius: CGFloat(blurRadius)))

        #expect(abs(softness - expected) < 0.0001)
    }

    @Test("The fade stays narrow, so neighbouring lines do not show through")
    func fadeStaysNarrow() {
        for blurRadius in stride(from: 2.0, through: 20.0, by: 1.0) {
            #expect(SlitFeather.softness(blurRadius: CGFloat(blurRadius)) <= 2)
        }
    }
}
