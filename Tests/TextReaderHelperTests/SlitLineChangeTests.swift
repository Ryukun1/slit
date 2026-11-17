import CoreGraphics
import SwiftUI
import Testing
@testable import TextReaderHelper

/// Moving on to the next line: the line just finished stays exactly as it
/// is, and the opening for the new line drops down from under it at the
/// width of its first word.
struct SlitLineChangeTests {
    private let firstLine = CGRect(x: 96, y: 97, width: 408, height: 25)
    private let finished = CGRect(x: 96, y: 127, width: 408, height: 25)
    private let firstWord = CGRect(x: 96, y: 157, width: 60, height: 25)

    /// The second line fully revealed, before the click that moves on.
    private var before: SlitWindowLayout {
        SlitWindowLayout(
            upper: firstLine, lower: finished, line: 1,
            arrival: SlitWindow.Arrival(line: 1, lower: finished, finished: firstLine)
        )
    }

    /// The first word of the third line, once the move is over.
    private var after: SlitWindowLayout {
        SlitWindowLayout(
            upper: firstLine.union(finished), lower: firstWord, line: 2,
            arrival: SlitWindow.Arrival(line: 2, lower: firstWord, finished: finished)
        )
    }

    /// What SwiftUI draws part-way through an animation: the new layout with
    /// its animated values interpolated from the old one.
    private func frame(
        from start: SlitWindowLayout, to end: SlitWindowLayout, at progress: Double
    ) -> SlitWindowLayout {
        var change = end.animatableData - start.animatableData
        change.scale(by: progress)
        var frame = end
        frame.animatableData = start.animatableData + change
        return frame
    }

    private func outline(_ layout: SlitWindowLayout) -> Path {
        SlitWindow.outline(layout, cornerRadius: 6)
    }

    private let steps = 20

    @Test("The finished line stays open from start to end the whole way through")
    func finishedLineStaysOpen() {
        for step in 0...steps {
            let path = outline(frame(from: before, to: after, at: Double(step) / Double(steps)))

            for x in stride(from: CGFloat(100), through: 500, by: 20) {
                #expect(path.contains(CGPoint(x: x, y: finished.midY)), "covered at x \(x), step \(step)")
            }
        }
    }

    @Test("The new line opens downwards at the width of its first word")
    func opensAsADropDown() {
        for step in 1...steps {
            let progress = CGFloat(step) / CGFloat(steps)
            let path = outline(frame(from: before, to: after, at: Double(progress)))

            // The bottom edge travels from the finished line to the new one.
            let bottom = finished.maxY + (firstWord.maxY - finished.maxY) * progress
            #expect(abs(path.boundingRect.maxY - bottom) < 0.01, "step \(step)")
            // Just above that edge it is already as wide as the first word...
            #expect(path.contains(CGPoint(x: firstWord.maxX - 8, y: bottom - 0.6)), "step \(step)")
            // ...and never wider: the rest of the new line stays covered.
            for x in stride(from: firstWord.maxX + 4, through: 500, by: 24) {
                #expect(!path.contains(CGPoint(x: x, y: bottom - 0.6)), "shown at x \(x), step \(step)")
                #expect(!path.contains(CGPoint(x: x, y: firstWord.midY)), "shown at x \(x), step \(step)")
            }
        }
    }

    @Test("The move starts from the opening as it was and ends at the new one")
    func startsAndEndsWhereItShould() {
        let start = outline(frame(from: before, to: after, at: 0))
        let end = outline(frame(from: before, to: after, at: 1))

        #expect(start.boundingRect == firstLine.union(finished))
        #expect(end.boundingRect == firstLine.union(firstWord))
        #expect(end.contains(CGPoint(x: firstWord.midX, y: firstWord.midY)))
        #expect(!end.contains(CGPoint(x: 400, y: firstWord.midY)))
    }

    @Test("Lines closer together than their padding still stay open")
    func overlappingRowsStayOpen() {
        let tight = CGRect(x: 96, y: 149, width: 60, height: 25)
        let end = SlitWindowLayout(
            upper: firstLine.union(finished), lower: tight, line: 2,
            arrival: SlitWindow.Arrival(line: 2, lower: tight, finished: finished)
        )

        for step in 0...steps {
            let path = outline(frame(from: before, to: end, at: Double(step) / Double(steps)))
            #expect(path.contains(CGPoint(x: 480, y: finished.maxY - 1)), "step \(step)")
        }
    }

    @Test("At rest the opening is just its two parts")
    func restingLayoutUsesBothRects() {
        #expect(SlitWindow.parts(of: after) == [after.upper, after.lower])
        #expect(SlitWindow.parts(of: before) == [before.upper, before.lower])
    }

    @Test("Moving back up a line slides the opening as before")
    func movingUpSlides() {
        let midway = frame(from: after, to: before, at: 0.5)

        #expect(SlitWindow.parts(of: midway) == [midway.upper, midway.lower])
    }

    @Test("With no finished line left open, the opening slides to the new line")
    func slidesWhenThePreviousLineCloses() {
        // Visible lines set to one: the line just read closes as you move on.
        let start = SlitWindowLayout(upper: .null, lower: finished, line: 1, arrival: nil)
        let end = SlitWindowLayout(
            upper: .null, lower: firstWord, line: 2,
            arrival: SlitWindow.Arrival(line: 2, lower: firstWord, finished: .null)
        )
        let midway = frame(from: start, to: end, at: 0.5)

        #expect(SlitWindow.parts(of: midway) == [midway.upper, midway.lower])
    }

    @Test("Revealing the last word only moves the right edge")
    func lastWordGlidesRight() {
        let almost = CGRect(x: 96, y: 127, width: 330, height: 25)
        let start = SlitWindowLayout(
            upper: firstLine, lower: almost, line: 1,
            arrival: SlitWindow.Arrival(line: 1, lower: almost, finished: firstLine)
        )

        for step in 0...steps {
            let progress = CGFloat(step) / CGFloat(steps)
            let path = outline(frame(from: start, to: before, at: Double(progress)))
            let edge = almost.maxX + (finished.maxX - almost.maxX) * progress

            #expect(path.boundingRect == firstLine.union(finished))
            // Covered right of the moving edge, all the way down the line.
            if edge + 3 < finished.maxX {
                #expect(!path.contains(CGPoint(x: edge + 3, y: finished.minY + 4)), "step \(step)")
                #expect(!path.contains(CGPoint(x: edge + 3, y: finished.maxY - 4)), "step \(step)")
            }
            #expect(path.contains(CGPoint(x: edge - 8, y: finished.midY)), "step \(step)")
        }
    }
}

/// The outline around any stack of rects that share a left edge.
struct SlitStackOutlineTests {
    @Test("Three stacked parts make one staircase")
    func threeParts() {
        let corners = SlitWindow.corners(of: [
            CGRect(x: 10, y: 0, width: 300, height: 20),
            CGRect(x: 10, y: 20, width: 200, height: 20),
            CGRect(x: 10, y: 40, width: 50, height: 10),
        ])

        #expect(corners == [
            CGPoint(x: 10, y: 0), CGPoint(x: 310, y: 0), CGPoint(x: 310, y: 20),
            CGPoint(x: 210, y: 20), CGPoint(x: 210, y: 40),
            CGPoint(x: 60, y: 40), CGPoint(x: 60, y: 50), CGPoint(x: 10, y: 50),
        ])
    }

    @Test("A gap between parts is as wide as the part above it")
    func gapIsFilled() {
        let corners = SlitWindow.corners(of: [
            CGRect(x: 10, y: 0, width: 300, height: 20),
            CGRect(x: 10, y: 24, width: 50, height: 10),
        ])

        #expect(corners == [
            CGPoint(x: 10, y: 0), CGPoint(x: 310, y: 0), CGPoint(x: 310, y: 24),
            CGPoint(x: 60, y: 24), CGPoint(x: 60, y: 34), CGPoint(x: 10, y: 34),
        ])
    }

    @Test("Parts that are missing or have no size are left out")
    func emptyPartsAreIgnored() {
        let only = CGRect(x: 10, y: 0, width: 300, height: 20)
        let corners = SlitWindow.corners(of: [
            .null, only, CGRect(x: 10, y: 20, width: 80, height: 0),
        ])

        #expect(corners.count == 4)
        #expect(SlitWindow.corners(of: []).isEmpty)
    }
}
