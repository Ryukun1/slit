import CoreGraphics
import Testing
@testable import TextReaderHelper

/// While a reading session is open, clicks on the reading panel belong to
/// Slit: they reveal words or move on a line, and must not reach the page
/// underneath, where they would select text.
struct ClickCaptureTests {
    private let panel = CGRect(x: 100, y: 100, width: 400, height: 200)
    private let inside = CGPoint(x: 300, y: 200)
    private let outside = CGPoint(x: 700, y: 200)

    private var session: ClickCapture { ClickCapture().withRegion(panel) }

    @Test("A click on the panel is kept, press and release")
    func clickOnPanelIsKept() {
        let press = session.after(.down, at: inside, optionHeld: false)
        let release = press.next.after(.up, at: inside, optionHeld: false)

        #expect(press.keepsEvent)
        #expect(release.keepsEvent)
    }

    @Test("Moving while the button is down is kept too, so no text gets selected")
    func dragAfterKeptClickIsKept() {
        let press = session.after(.down, at: inside, optionHeld: false)
        let drag = press.next.after(.dragged, at: outside, optionHeld: false)
        let release = drag.next.after(.up, at: outside, optionHeld: false)

        #expect(drag.keepsEvent)
        #expect(release.keepsEvent)
    }

    @Test("A click outside the panel reaches the page untouched")
    func clickOutsidePasses() {
        let press = session.after(.down, at: outside, optionHeld: false)
        let drag = press.next.after(.dragged, at: inside, optionHeld: false)
        let release = drag.next.after(.up, at: inside, optionHeld: false)

        #expect(!press.keepsEvent)
        #expect(!drag.keepsEvent)
        #expect(!release.keepsEvent)
    }

    @Test("Option-click, which adds a paragraph, is left alone")
    func optionClickPasses() {
        #expect(!session.after(.down, at: inside, optionHeld: true).keepsEvent)
    }

    @Test("With no session open nothing is kept")
    func nothingKeptWithoutSession() {
        let idle = ClickCapture()

        #expect(!idle.after(.down, at: inside, optionHeld: false).keepsEvent)
        #expect(!idle.after(.up, at: inside, optionHeld: false).keepsEvent)
    }

    @Test("A release is kept if its press was, even when the session ended in between")
    func releaseFollowsItsPress() {
        let press = session.after(.down, at: inside, optionHeld: false)
        let ended = press.next.withRegion(nil)

        #expect(ended.after(.up, at: inside, optionHeld: false).keepsEvent)
    }

    @Test("After a kept click, the next click outside passes again")
    func keptClickDoesNotLinger() {
        let press = session.after(.down, at: inside, optionHeld: false)
        let release = press.next.after(.up, at: inside, optionHeld: false)

        #expect(!release.next.after(.dragged, at: inside, optionHeld: false).keepsEvent)
        #expect(!release.next.after(.down, at: outside, optionHeld: false).keepsEvent)
    }

    @Test("The panel is the text plus its margin, and only while reading")
    func regionFollowsSession() {
        let text = CGRect(x: 120, y: 116, width: 360, height: 168)

        #expect(ClickCapture.region(isReading: true, textRegion: text) == panel)
        #expect(ClickCapture.region(isReading: false, textRegion: text) == nil)
    }
}
