import CoreGraphics
import Testing
@testable import TextReaderHelper

/// A new reading session opens the slit on the first line of the selection,
/// and keeps it there until the pointer is deliberately moved.
@MainActor
@Suite(.serialized)
struct ActivationStartTests {
    private enum Fixture {
        static let lineHeight: CGFloat = 20
        static let lineSpacing: CGFloat = 30
        static let top: CGFloat = 100
        static let lineCount = 6
    }

    private let state = AppState()

    init() {
        // Both are alternative reading modes with their own start rules.
        AppSettings.shared.manualWordModeEnabled = false
        AppSettings.shared.autoAdvanceEnabled = false
        // Never send real scroll events to the Mac running the tests.
        state.scrollPage = { _, _ in }
    }

    private func makeLines() -> [TextLine] {
        (0..<Fixture.lineCount).map { index in
            TextLine(
                text: "Line \(index)",
                rect: CGRect(
                    x: 50, y: Fixture.top + CGFloat(index) * Fixture.lineSpacing,
                    width: 400, height: Fixture.lineHeight
                )
            )
        }
    }

    private func centerY(ofLine index: Int) -> CGFloat {
        Fixture.top + CGFloat(index) * Fixture.lineSpacing + Fixture.lineHeight / 2
    }

    @Test("Activating a paragraph opens the slit on its first line")
    func activationStartsOnFirstLine() {
        state.activate(block: TextBlock(lines: makeLines()))

        #expect(state.mode == .active)
        #expect(state.activeLineIndex == 0)
    }

    @Test("Lines given out of order still start at the topmost one")
    func activationStartsOnTopmostLine() {
        let lines = makeLines()
        state.activate(block: TextBlock(lines: lines.reversed()))

        #expect(state.activeLineIndex == 0)
        #expect(state.detectedLines.first?.text == lines.first?.text)
    }

    @Test("Reactivating the same paragraph starts over at the first line")
    func reactivationStartsOnFirstLine() {
        let block = TextBlock(lines: makeLines())
        state.activate(block: block)
        state.advanceToNextLine()
        state.advanceToNextLine()
        #expect(state.activeLineIndex == 2)
        state.deactivate()

        state.activate(block: block)

        #expect(state.activeLineIndex == 0)
    }

    @Test("A dragged area opens the slit on its first line")
    func areaActivationStartsOnFirstLine() {
        let lines = makeLines()
        state.activateArea(
            lines: lines,
            from: CGPoint(x: 0, y: Fixture.top - 10),
            to: CGPoint(x: 600, y: centerY(ofLine: Fixture.lineCount - 1) + 40)
        )

        #expect(state.mode == .active)
        #expect(state.activeLineIndex == 0)
    }

    @Test("The pointer resting where it clicked does not pull the slit away")
    func restingPointerKeepsFirstLine() {
        state.activate(block: TextBlock(lines: makeLines()))
        let clickY = centerY(ofLine: 4)

        state.updateActiveLine(mouseY: clickY)
        state.updateActiveLine(mouseY: clickY + 3)
        state.updateActiveLine(mouseY: clickY - 4)

        #expect(state.activeLineIndex == 0)
    }

    @Test("Moving the pointer a line's height makes the slit follow it again")
    func deliberateMoveResumesFollowing() {
        state.activate(block: TextBlock(lines: makeLines()))
        let clickY = centerY(ofLine: 3)
        state.updateActiveLine(mouseY: clickY)

        state.updateActiveLine(mouseY: centerY(ofLine: 4))
        #expect(state.activeLineIndex == 4)

        // Once following has resumed, small moves track normally.
        state.updateActiveLine(mouseY: centerY(ofLine: 5))
        #expect(state.activeLineIndex == 5)
    }

    @Test("The arrow keys step from the first line")
    func keyboardStepsFromFirstLine() {
        state.activate(block: TextBlock(lines: makeLines()))

        state.advanceToNextLine()

        #expect(state.activeLineIndex == 1)
    }
}
