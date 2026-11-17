import CoreGraphics
import SwiftUI
import Testing
@testable import TextReaderHelper

/// The opening is one shape: the lines already read, plus the current line as
/// far as it has been revealed. Where the current line stops short, the
/// corner between the two is rounded and everything beyond stays covered.
struct SlitWindowTests {
    private let read = CGRect(x: 100, y: 100, width: 400, height: 50)
    /// The current line, half revealed, with a gap below the read lines.
    private let current = CGRect(x: 104, y: 158, width: 200, height: 25)

    private func outline(upper: CGRect, lower: CGRect) -> Path {
        SlitWindow.outline(upper: upper, lower: lower, cornerRadius: 6)
    }

    @Test("With nothing read yet the opening is just the current line")
    func loneLineIsItsOwnRect() {
        let path = outline(upper: .null, lower: current)

        #expect(path.boundingRect == current)
        #expect(path.contains(CGPoint(x: current.midX, y: current.midY)))
    }

    @Test("A zero-height read block counts as nothing read")
    func emptyUpperIsIgnored() {
        let empty = CGRect(x: 100, y: current.minY, width: 400, height: 0)

        #expect(outline(upper: empty, lower: current).boundingRect == current)
    }

    @Test("Read lines and the current line form one joined opening")
    func partsAreJoined() {
        let path = outline(upper: read, lower: current)

        // The strip between the two lines is open too: no covered band.
        #expect(path.contains(CGPoint(x: 200, y: 154)))
        #expect(path.contains(CGPoint(x: read.midX, y: read.midY)))
        #expect(path.contains(CGPoint(x: current.midX, y: current.midY)))
    }

    @Test("Text beyond the revealed words stays covered")
    func unrevealedPartStaysCovered() {
        let path = outline(upper: read, lower: current)

        // Right of where the current line has been revealed to.
        #expect(!path.contains(CGPoint(x: 400, y: current.midY)))
        // Directly above that spot the read lines are open.
        #expect(path.contains(CGPoint(x: 400, y: read.midY)))
    }

    @Test("Both parts share one straight left edge")
    func leftEdgeIsAligned() {
        let path = outline(upper: read, lower: current)

        #expect(path.boundingRect.minX == read.minX)
        // Just inside the shared edge, on the current line.
        #expect(path.contains(CGPoint(x: read.minX + 2, y: current.midY)))
    }

    @Test("Every corner is rounded, including the one between the two parts")
    func innerCornerIsRounded() {
        let path = outline(upper: read, lower: current)
        let corner = CGPoint(x: current.maxX, y: current.minY)

        // The rounding opens up the corner itself...
        #expect(path.contains(CGPoint(x: corner.x + 0.5, y: corner.y + 0.5)))
        // ...and nothing more: a little further in, the text is still covered.
        #expect(!path.contains(CGPoint(x: corner.x + 5, y: corner.y + 5)))
        // An outer corner is cut by its rounding.
        #expect(!path.contains(CGPoint(x: read.maxX - 0.5, y: read.minY + 0.5)))
    }

    @Test("A small step between the two parts still curves without overlapping")
    func smallStepStaysInsideItsEdges() {
        let nearlyFull = CGRect(x: 100, y: 158, width: 396, height: 25)
        let path = outline(upper: read, lower: nearlyFull)

        #expect(path.boundingRect == read.union(nearlyFull))
        #expect(path.contains(CGPoint(x: 490, y: nearlyFull.midY)))
    }

    @Test("A fully revealed line makes a plain rectangle")
    func equalWidthsMakeOneRect() {
        let full = CGRect(x: 100, y: 158, width: 400, height: 25)
        let path = outline(upper: read, lower: full)

        #expect(path.boundingRect == read.union(full))
        #expect(path.contains(CGPoint(x: 495, y: 170)))
    }

    @Test("A current line longer than the read lines steps outwards instead")
    func longerCurrentLine() {
        let long = CGRect(x: 100, y: 158, width: 520, height: 25)
        let path = outline(upper: read, lower: long)

        #expect(path.contains(CGPoint(x: 600, y: long.midY)))
        #expect(!path.contains(CGPoint(x: 600, y: read.midY)))
    }

    @Test("Growing the outline moves every edge outwards")
    func outsetGrowsShape() {
        let grown = SlitWindow.outline(upper: read, lower: current, cornerRadius: 6, outset: 1)

        #expect(grown.boundingRect == read.union(current).insetBy(dx: -1, dy: -1))
    }

    // MARK: Moving on to the next line

    @Test("While the opening moves down to the next line, the line just read stays open")
    func finishedLineStaysOpenDuringTheMove() {
        // Part-way through the move: the current-line part has left the read
        // block's last line but still overlaps it, and is already narrower.
        let moving = CGRect(x: 100, y: 140, width: 250, height: 25)
        let path = outline(upper: read, lower: moving)

        // The end of the line just read, beside and below the moving part.
        #expect(path.contains(CGPoint(x: 450, y: 145)))
        #expect(path.contains(CGPoint(x: 200, y: 160)))
        // Below the read block, beyond the moving part, is still covered.
        #expect(!path.contains(CGPoint(x: 450, y: 160)))
    }

    @Test("Every moment of the move to the next line leaves the finished line open")
    func lineChangeNeverCoversTheFinishedLine() {
        // Two lines open at full width; the second has just been finished.
        let block = CGRect(x: 96, y: 97, width: 408, height: 55)
        let finished = CGRect(x: 96, y: 127, width: 408, height: 24)
        let firstWordOfNext = CGRect(x: 96, y: 154, width: 60, height: 25)

        for step in 0...20 {
            let progress = CGFloat(step) / 20
            let moving = CGRect(
                x: finished.minX + (firstWordOfNext.minX - finished.minX) * progress,
                y: finished.minY + (firstWordOfNext.minY - finished.minY) * progress,
                width: finished.width + (firstWordOfNext.width - finished.width) * progress,
                height: finished.height + (firstWordOfNext.height - finished.height) * progress
            )
            let path = outline(upper: block, lower: moving)

            // Along the middle of the finished line, start to end.
            for x in stride(from: CGFloat(100), through: 500, by: 20) {
                #expect(path.contains(CGPoint(x: x, y: 139)), "covered at x \(x), step \(step)")
            }
            // The rest of the next line stays covered throughout.
            #expect(!path.contains(CGPoint(x: 450, y: 170)), "next line shown at step \(step)")
        }
    }

    @Test("A current line that lies within the read block adds nothing to it")
    func lineInsideTheBlockAddsNothing() {
        let inside = CGRect(x: 100, y: 127, width: 396, height: 22)

        #expect(outline(upper: read, lower: inside).boundingRect == read)
    }

    @Test("A fully revealed first line and its own full-width block are one rectangle")
    func sameLineTwiceIsOneRect() {
        let line = CGRect(x: 100, y: 100, width: 400, height: 25)
        let revealed = CGRect(x: 100, y: 100, width: 400, height: 24)

        #expect(outline(upper: line, lower: revealed).boundingRect == line)
    }
}

/// Which lines are open at full width in word-by-word mode.
struct FullWidthLinesTests {
    @Test("Lines already read are open, the line being revealed is not")
    func readLinesOnly() {
        #expect(SlitWindow.fullWidthLines(windowTop: 0, leading: 2) == 0...1)
    }

    @Test("A finished current line is still the current line")
    func finishedLineIsNotYetRead() {
        // Revealing the last word only widens the current line's own opening.
        // It joins the read lines when the next click moves on.
        #expect(SlitWindow.fullWidthLines(windowTop: 0, leading: 2) == 0...1)
        #expect(SlitWindow.fullWidthLines(windowTop: 2, leading: 2) == nil)
    }

    @Test("On the first line, part revealed, nothing is open at full width")
    func nothingReadYet() {
        #expect(SlitWindow.fullWidthLines(windowTop: 0, leading: 0) == nil)
    }

    @Test("A rolling window starts where it has scrolled to")
    func rollingWindow() {
        #expect(SlitWindow.fullWidthLines(windowTop: 3, leading: 4) == 3...3)
        #expect(SlitWindow.fullWidthLines(windowTop: 9, leading: 4) == nil)
    }
}
