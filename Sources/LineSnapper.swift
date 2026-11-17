import Foundation

/// Finds the nearest text line to a given mouse Y position.
enum LineSnapper {
    /// How much closer (as a share of line height) another line must be before
    /// the slit leaves the current one.
    private static let hysteresisShare: CGFloat = 0.2

    /// Returns the index of the line whose vertical center is closest to `mouseY`.
    /// Returns `nil` if `lines` is empty or the mouse is too far from any line.
    ///
    /// Pass `current` to add hysteresis: the current line is kept until the
    /// pointer is clearly closer to another one, so resting the pointer on the
    /// boundary between two lines no longer flickers the slit between them.
    static func nearestLineIndex(
        mouseY: CGFloat, lines: [TextLine], current: Int? = nil
    ) -> Int? {
        guard !lines.isEmpty else { return nil }

        var bestIndex = 0
        var bestDistance = CGFloat.greatestFiniteMagnitude

        for (index, line) in lines.enumerated() {
            let lineCenter = line.rect.midY
            let distance = abs(mouseY - lineCenter)
            if distance < bestDistance {
                bestDistance = distance
                bestIndex = index
            }
        }

        // Only snap if within 2x the average line height
        let avgHeight = lines.map(\.rect.height).reduce(0, +) / CGFloat(lines.count)
        let threshold = avgHeight * 2.0
        if bestDistance > threshold {
            return nil
        }

        if let current, current != bestIndex, lines.indices.contains(current) {
            let currentDistance = abs(mouseY - lines[current].rect.midY)
            let margin = lines[current].rect.height * hysteresisShare
            if currentDistance - bestDistance < margin { return current }
        }

        return bestIndex
    }
}
