import CoreGraphics
import Testing
@testable import TextReaderHelper

/// Remembers the reading settings these tests change, and puts them back.
@MainActor
private struct SavedReadingSettings {
    private let settings = AppSettings.shared
    private let wordByWord = AppSettings.shared.manualWordModeEnabled
    private let autoAdvance = AppSettings.shared.autoAdvanceEnabled
    private let dyslexic = AppSettings.shared.dyslexicFontEnabled
    private let keepRead = AppSettings.shared.keepReadTextVisible
    private let visibleLines = AppSettings.shared.visibleLines

    func restore() {
        settings.manualWordModeEnabled = wordByWord
        settings.autoAdvanceEnabled = autoAdvance
        settings.dyslexicFontEnabled = dyslexic
        settings.keepReadTextVisible = keepRead
        settings.visibleLines = visibleLines
    }
}

/// Settings that cannot work together are never on together.
@MainActor
@Suite(.serialized)
struct SettingsRulesTests {
    private let settings = AppSettings.shared

    @Test("Word-by-word turns off auto-advance, which it cannot be combined with")
    func wordByWordIsExclusive() {
        let saved = SavedReadingSettings()
        defer { saved.restore() }
        settings.autoAdvanceEnabled = true

        settings.setWordByWord(true)

        #expect(settings.manualWordModeEnabled)
        #expect(!settings.autoAdvanceEnabled)
    }

    @Test("Auto-advance turns word-by-word off")
    func autoAdvanceTurnsWordByWordOff() {
        let saved = SavedReadingSettings()
        defer { saved.restore() }

        settings.setWordByWord(true)
        settings.setAutoAdvance(true)

        #expect(!settings.manualWordModeEnabled)
        #expect(settings.autoAdvanceEnabled)
    }

    @Test("Word-by-word and OpenDyslexic can be on together, in either order")
    func wordByWordWorksWithOpenDyslexic() {
        let saved = SavedReadingSettings()
        defer { saved.restore() }

        settings.dyslexicFontEnabled = true
        settings.setWordByWord(true)
        #expect(settings.manualWordModeEnabled)
        #expect(settings.dyslexicFontEnabled)

        settings.dyslexicFontEnabled = false
        settings.dyslexicFontEnabled = true
        settings.resolveConflicts()
        #expect(settings.manualWordModeEnabled)
        #expect(settings.dyslexicFontEnabled)
    }

    @Test("Turning word-by-word off leaves the others alone")
    func turningOffChangesNothingElse() {
        let saved = SavedReadingSettings()
        defer { saved.restore() }
        settings.setWordByWord(true)

        settings.setWordByWord(false)

        #expect(!settings.manualWordModeEnabled)
        #expect(!settings.autoAdvanceEnabled)
        #expect(!settings.dyslexicFontEnabled)
    }

    @Test("A conflicting combination saved by an older version is repaired")
    func savedConflictsAreResolved() {
        let saved = SavedReadingSettings()
        defer { saved.restore() }
        settings.manualWordModeEnabled = true
        settings.autoAdvanceEnabled = true

        settings.resolveConflicts()

        #expect(settings.manualWordModeEnabled)
        #expect(!settings.autoAdvanceEnabled)
    }
}

/// Word-by-word: how much of the text already read stays uncovered.
@MainActor
@Suite(.serialized)
struct KeepReadTextTests {
    private let state = AppState()
    private let settings = AppSettings.shared

    private func makeBlock(lines: Int = 5) -> TextBlock {
        TextBlock(lines: (0..<lines).map { index in
            TextLine(
                text: "one two",
                rect: CGRect(x: 100, y: 300 + CGFloat(index) * 30, width: 400, height: 20)
            )
        })
    }

    /// Click through whole lines: two words each, then one click to move on.
    private func readLines(_ count: Int) {
        for _ in 0..<count {
            state.revealNextWordOrAdvance()
            state.revealNextWordOrAdvance()
        }
    }

    private func start(keepRead: Bool, visibleLines: Int) {
        settings.setWordByWord(true)
        settings.keepReadTextVisible = keepRead
        settings.visibleLines = visibleLines
        state.scrollPage = { _, _ in }
        state.activate(block: makeBlock())
    }

    @Test("By default the window rolls, keeping only the visible lines")
    func windowRollsByDefault() {
        let saved = SavedReadingSettings()
        defer { saved.restore() }
        start(keepRead: false, visibleLines: 2)

        readLines(3)

        #expect(state.activeLineIndex == 3)
        #expect(state.windowTopIndex == 2)
    }

    @Test("Keeping read text visible leaves everything open from the first line")
    func keepsEverythingRead() {
        let saved = SavedReadingSettings()
        defer { saved.restore() }
        start(keepRead: true, visibleLines: 1)

        readLines(4)

        #expect(state.activeLineIndex == 4)
        #expect(state.windowTopIndex == 0)
    }
}
