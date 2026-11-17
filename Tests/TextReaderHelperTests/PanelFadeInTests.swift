import Testing
@testable import TextReaderHelper

/// The reading panel fades in as it grows, in dim and in blur mode, instead
/// of being at full strength from its first frame.
struct PanelFadeInTests {
    @Test("The panel starts transparent in every style", arguments: OverlayStyle.allCases)
    func startsTransparent(style: OverlayStyle) {
        #expect(SlitOpening.panelStartOpacity(style: style) == 0)
    }

    @Test("The panel is fully visible while it is still small, so its growth is seen")
    func visibleBeforeItHasGrown() {
        // If the fade took as long as the growth, the panel would only show
        // up once it was nearly full size and would seem to fade in in place.
        #expect(SlitOpening.panelFadeInDuration <= 0.18)
        #expect(SlitOpening.panelFadeInDuration >= 0.1)
        #expect(SlitOpening.panelFadeInDuration <= SlitOpening.panelGrowResponse * 0.35)
    }

    @Test("The growth is slow enough to follow from the click to the full area")
    func growthCanBeFollowed() {
        #expect(SlitOpening.panelGrowResponse >= 0.5)
        #expect(SlitOpening.panelGrowResponse <= 0.65)
        // Barely any bounce: it enlarges until it fits and stops there.
        #expect(SlitOpening.panelGrowDamping >= 0.85)
    }

    @Test("The loading bubble stays until the panel starts to open")
    func bubbleStaysUntilThePanelOpens() {
        // Blur mode captures the screen between detection ending and the
        // panel opening; the bubble must not vanish during that wait.
        #expect(SlitOpening.showsLoadingBubble(isDetecting: true, isActive: false, panelIsOpening: false))
        #expect(SlitOpening.showsLoadingBubble(isDetecting: false, isActive: true, panelIsOpening: false))
        #expect(!SlitOpening.showsLoadingBubble(isDetecting: false, isActive: true, panelIsOpening: true))
        #expect(!SlitOpening.showsLoadingBubble(isDetecting: false, isActive: false, panelIsOpening: false))
    }
}
