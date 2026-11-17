import Foundation

/// Splits a line of text into "reveal words" for the manual word-reveal slit.
///
/// A reveal word is a whitespace-delimited token, except that **standalone or
/// trailing punctuation is attached to the preceding word**. So OCR output like
/// `"world ."` or `"hello , there"` reveals as `["world ."]` and
/// `["hello ,", "there"]` rather than treating the punctuation as its own click.
///
/// This is the single source of truth for word segmentation: both the click
/// counter (`AppState`) and the slit geometry (`DimOverlayView`) use it, so the
/// number of clicks and the revealed width can never disagree.
enum WordSegmenter {
    /// Characters that, when appearing as their own token, glue onto the word
    /// before them instead of counting as a separate reveal step.
    private static let attachablePunctuation = CharacterSet(charactersIn: ".,;:!?…)»”’\"'-—–")

    /// A segmented word: the substring and its character range within the
    /// original line (so callers can map it to Vision per-character boxes).
    struct Word: Equatable {
        let text: String
        /// Range within the source string (used to look up OCR geometry).
        let range: Range<String.Index>
    }

    /// Segment `line` into reveal words. Punctuation-only tokens merge into the
    /// previous word's range so they reveal together.
    static func words(in line: String) -> [Word] {
        var result: [Word] = []
        var index = line.startIndex

        while index < line.endIndex {
            // Skip whitespace
            while index < line.endIndex, line[index].isWhitespace {
                index = line.index(after: index)
            }
            guard index < line.endIndex else { break }

            // Consume a run of non-whitespace = one raw token
            let tokenStart = index
            while index < line.endIndex, !line[index].isWhitespace {
                index = line.index(after: index)
            }
            let tokenRange = tokenStart..<index
            let token = String(line[tokenRange])

            // If the token is entirely attachable punctuation and we have a
            // previous word, extend that word's range to swallow this token.
            if isPunctuationOnly(token), let last = result.last {
                let mergedRange = last.range.lowerBound..<tokenRange.upperBound
                result[result.count - 1] = Word(text: String(line[mergedRange]), range: mergedRange)
            } else {
                result.append(Word(text: token, range: tokenRange))
            }
        }

        return result
    }

    /// Number of reveal words on the line (at least 1 for non-empty text).
    static func count(in line: String) -> Int {
        max(1, words(in: line).count)
    }

    /// True if every character in `token` is attachable punctuation.
    private static func isPunctuationOnly(_ token: String) -> Bool {
        guard !token.isEmpty else { return false }
        return token.unicodeScalars.allSatisfy { attachablePunctuation.contains($0) }
    }
}
