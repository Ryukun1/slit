import SwiftUI

/// Geometry of the slit's opening.
///
/// The opening is one shape, not a rectangle per line. In word-by-word mode it
/// is the lines already read (`upper`) joined to the current line as far as it
/// has been revealed (`lower`): an L with every corner rounded, including the
/// one between the two parts, and everything beyond the revealed words still
/// covered. With nothing read, or outside word-by-word mode, it is simply
/// `lower` as a rounded rectangle.
enum SlitWindow {
    /// Below this size a rect is treated as absent. Animation interpolates
    /// rects through near-zero sizes, which must not produce slivers.
    private static let minimumExtent: CGFloat = 0.5

    /// - Parameters:
    ///   - upper: the block of lines already read; null or empty when none.
    ///   - lower: the current line's revealed part.
    ///   - cornerRadius: rounding of every corner.
    ///   - outset: grows (or, if negative, shrinks) the whole shape, for
    ///     drawing a line just outside or inside the opening.
    static func outline(
        upper: CGRect,
        lower: CGRect,
        cornerRadius: CGFloat,
        outset: CGFloat = 0
    ) -> Path {
        outline(corners: corners(upper: upper, lower: lower), cornerRadius: cornerRadius, outset: outset)
    }

    /// The opening for a layout, including the moments while it is moving
    /// down to the next line.
    static func outline(
        _ layout: SlitWindowLayout, cornerRadius: CGFloat, outset: CGFloat = 0
    ) -> Path {
        let vertices: [CGPoint]
        if dropProgress(of: layout) == nil {
            vertices = corners(upper: layout.upper, lower: layout.lower)
        } else {
            vertices = corners(of: parts(of: layout))
        }
        return outline(corners: vertices, cornerRadius: cornerRadius, outset: outset)
    }

    private static func outline(
        corners vertices: [CGPoint], cornerRadius: CGFloat, outset: CGFloat
    ) -> Path {
        guard vertices.count >= 4 else { return Path() }
        let grown = outset == 0 ? vertices : offset(vertices, by: outset)
        // Growing the shape widens its outer curves and tightens the inner
        // ones, so a line drawn around the opening stays parallel to its edge.
        return roundedPolygon(
            grown,
            outerRadius: max(0, cornerRadius + outset),
            innerRadius: max(0, cornerRadius - outset)
        )
    }

    /// Corner points of the opening, clockwise from the top-left.
    ///
    /// The shape is everything in the read block and everything in the
    /// current line's part, plus the strip between them. With no current
    /// line there is no opening, and a read block that starts below the
    /// current line is ignored.
    static func corners(upper: CGRect, lower: CGRect) -> [CGPoint] {
        guard isPresent(lower) else { return [] }
        guard isPresent(upper), upper.minY < lower.minY + minimumExtent else {
            return rectCorners(lower)
        }
        return corners(of: [upper, lower])
    }

    /// Corner points around a stack of rects, clockwise from the top-left:
    /// one straight left edge, and a right edge that steps in or out from
    /// one rect to the next. Rects may overlap; a gap between two of them is
    /// open as wide as the rect above it, so no covered band is left.
    static func corners(of rects: [CGRect]) -> [CGPoint] {
        let present = rects.filter(isPresent)
        guard let left = present.map(\.minX).min() else { return [] }

        // Horizontal bands between every top and bottom edge. Edges closer
        // together than `minimumExtent` count as one, so no slivers.
        let edges = present.flatMap { [$0.minY, $0.maxY] }.sorted()
            .reduce(into: [CGFloat]()) { kept, edge in
                if let last = kept.last, edge - last < minimumExtent { return }
                kept.append(edge)
            }
        let bands = zip(edges, edges.dropFirst()).reduce(into: [Band]()) { bands, edge in
            let middle = (edge.0 + edge.1) / 2
            let widest = present.filter { $0.minY <= middle && middle <= $0.maxY }.map(\.maxX).max()
            guard let right = widest ?? bands.last?.right else { return }
            if let last = bands.last, abs(last.right - right) < minimumExtent {
                bands[bands.count - 1] = Band(top: last.top, bottom: edge.1, right: max(last.right, right))
            } else {
                bands.append(Band(top: edge.0, bottom: edge.1, right: right))
            }
        }
        guard let first = bands.first, let last = bands.last else { return [] }

        return [CGPoint(x: left, y: first.top)]
            + bands.flatMap { [CGPoint(x: $0.right, y: $0.top), CGPoint(x: $0.right, y: $0.bottom)] }
            + [CGPoint(x: left, y: last.bottom)]
    }

    /// One horizontal slice of the opening, open from the left edge to `right`.
    private struct Band {
        let top: CGFloat
        let bottom: CGFloat
        let right: CGFloat
    }

    // MARK: Moving down to the next line

    /// Where a move to another line ends. These values are not animated:
    /// they describe the destination from the first frame of the move.
    struct Arrival: Equatable {
        /// Index of the line the opening is moving to (or resting on).
        let line: Int
        /// The current line's opening once it has arrived.
        let lower: CGRect
        /// The line above, just finished, at full width; null when it does
        /// not stay open.
        let finished: CGRect
    }

    /// How far a move down to the next line has got, from 0 to 1, or nil
    /// when the opening is at rest, moving up, or the line just read closes.
    ///
    /// Sliding the current line's rect down while it narrows would sweep a
    /// wide opening across the new line. Instead the finished line stays as
    /// it is and the new line's opening drops down from under it.
    static func dropProgress(of layout: SlitWindowLayout) -> CGFloat? {
        guard let arrival = layout.arrival,
              isPresent(arrival.finished), isPresent(arrival.lower) else { return nil }
        let remaining = CGFloat(arrival.line) - layout.line
        guard remaining > settledTolerance, remaining <= 1 else { return nil }
        return 1 - remaining
    }

    /// The rects that make up the opening at this moment.
    static func parts(of layout: SlitWindowLayout) -> [CGRect] {
        guard let progress = dropProgress(of: layout), let arrival = layout.arrival else {
            return [layout.upper, layout.lower]
        }
        let finished = arrival.finished
        // The seam between the two lines travels from the finished line's
        // bottom to the new line's top, closing any gap between them.
        let seam = finished.maxY + (arrival.lower.minY - finished.maxY) * progress
        let kept = CGRect(
            x: finished.minX, y: finished.minY,
            width: finished.width, height: max(finished.maxY, seam) - finished.minY
        )
        let dropping = CGRect(
            x: arrival.lower.minX, y: seam,
            width: arrival.lower.width, height: arrival.lower.height * progress
        )
        return [layout.upper, kept, dropping]
    }

    /// A line position this close to the destination counts as arrived.
    private static let settledTolerance: CGFloat = 0.0005

    /// Word-by-word: the lines open at full width, or nil when there are none.
    ///
    /// These are the lines already read, from where the rolling window
    /// starts. The current line is never one of them, even with every word
    /// shown: revealing its last word only widens its own opening.
    static func fullWidthLines(windowTop: Int, leading: Int) -> ClosedRange<Int>? {
        let top = max(0, min(windowTop, leading))
        let last = leading - 1
        return top <= last ? top...last : nil
    }

    private static func isPresent(_ rect: CGRect) -> Bool {
        !rect.isNull && !rect.isInfinite
            && rect.width >= minimumExtent && rect.height >= minimumExtent
    }

    private static func rectCorners(_ rect: CGRect) -> [CGPoint] {
        [
            CGPoint(x: rect.minX, y: rect.minY),
            CGPoint(x: rect.maxX, y: rect.minY),
            CGPoint(x: rect.maxX, y: rect.maxY),
            CGPoint(x: rect.minX, y: rect.maxY),
        ]
    }

    /// Whether the path turns right at `corner` (an outer corner, for points
    /// listed clockwise with y growing downwards).
    private static func isOuterCorner(_ previous: CGPoint, _ corner: CGPoint, _ next: CGPoint) -> Bool {
        let incoming = CGVector(dx: corner.x - previous.x, dy: corner.y - previous.y)
        let outgoing = CGVector(dx: next.x - corner.x, dy: next.y - corner.y)
        return incoming.dx * outgoing.dy - incoming.dy * outgoing.dx > 0
    }

    /// Move every edge of an axis-aligned polygon outwards by `distance`.
    private static func offset(_ vertices: [CGPoint], by distance: CGFloat) -> [CGPoint] {
        let count = vertices.count
        return vertices.indices.map { index in
            let previous = vertices[(index + count - 1) % count]
            let corner = vertices[index]
            let next = vertices[(index + 1) % count]
            // Outward normal of a clockwise edge (y down) is its direction
            // rotated a quarter turn to the left.
            let incoming = unitNormal(from: previous, to: corner)
            let outgoing = unitNormal(from: corner, to: next)
            return CGPoint(
                x: corner.x + (incoming.dx + outgoing.dx) * distance,
                y: corner.y + (incoming.dy + outgoing.dy) * distance
            )
        }
    }

    private static func unitNormal(from start: CGPoint, to end: CGPoint) -> CGVector {
        let dx = end.x - start.x
        let dy = end.y - start.y
        let length = max(hypot(dx, dy), .leastNonzeroMagnitude)
        return CGVector(dx: dy / length, dy: -dx / length)
    }

    private static func roundedPolygon(
        _ vertices: [CGPoint], outerRadius: CGFloat, innerRadius: CGFloat
    ) -> Path {
        let count = vertices.count
        var path = Path()
        path.move(to: midpoint(vertices[count - 1], vertices[0]))
        for index in vertices.indices {
            let previous = vertices[(index + count - 1) % count]
            let corner = vertices[index]
            let next = vertices[(index + 1) % count]
            let wanted = isOuterCorner(previous, corner, next) ? outerRadius : innerRadius
            // A radius can use at most half of each edge it sits on.
            let available = min(distance(previous, corner), distance(corner, next)) / 2
            let radius = min(wanted, available)
            if radius < minimumExtent {
                path.addLine(to: corner)
            } else {
                path.addArc(
                    tangent1End: corner, tangent2End: midpoint(corner, next), radius: radius
                )
            }
            path.addLine(to: midpoint(corner, next))
        }
        path.closeSubpath()
        return path
    }

    private static func midpoint(_ a: CGPoint, _ b: CGPoint) -> CGPoint {
        CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2)
    }

    private static func distance(_ a: CGPoint, _ b: CGPoint) -> CGFloat {
        hypot(b.x - a.x, b.y - a.y)
    }
}

/// The opening as a drawable shape, for its tint and outline. Animates with
/// the same layout as the cutout in `AnimatedDimShape`, so they move together.
struct SlitWindowShape: Shape {
    var layout: SlitWindowLayout
    var cornerRadius: CGFloat = 6
    var outset: CGFloat = 0

    var animatableData: SlitWindowLayout.AnimatableData {
        get { layout.animatableData }
        set { layout.animatableData = newValue }
    }

    func path(in _: CGRect) -> Path {
        SlitWindow.outline(layout, cornerRadius: cornerRadius, outset: outset)
    }
}
