import SwiftUI

/// The slit's opening at one moment.
///
/// `upper`, `lower` and `line` are animated together. `arrival` is not: it
/// says where a move to another line ends, so the frames in between can be
/// drawn as a drop-down instead of a slide (`SlitWindow.parts(of:)`).
struct SlitWindowLayout: Equatable, Animatable {
    /// The block of lines already read; null or empty when none.
    var upper: CGRect = .null
    /// The current line's revealed part.
    var lower: CGRect = .zero
    /// Index of the current line. Part-way through a move it lies between
    /// the line being left and the line being moved to.
    var line: CGFloat = 0
    /// The destination of a move to another line; nil when it never applies
    /// (outside word-by-word mode).
    var arrival: SlitWindow.Arrival?

    typealias AnimatableData = AnimatablePair<
        AnimatablePair<CGRect.AnimatableData, CGRect.AnimatableData>, CGFloat
    >

    var animatableData: AnimatableData {
        get {
            AnimatablePair(
                AnimatablePair(Self.animatable(upper), lower.animatableData), line
            )
        }
        set {
            upper.animatableData = newValue.first.first
            lower.animatableData = newValue.first.second
            line = newValue.second
        }
    }

    /// A null rect has infinite coordinates, which cannot be interpolated.
    private static func animatable(_ rect: CGRect) -> CGRect.AnimatableData {
        (rect.isNull || rect.isInfinite ? CGRect.zero : rect).animatableData
    }
}
