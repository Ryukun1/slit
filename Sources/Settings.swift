import Foundation
import SwiftUI

/// How non-highlighted text lines are obscured.
enum OverlayStyle: String, CaseIterable, Identifiable {
    case dim = "dim"
    case blur = "blur"

    var id: String { rawValue }

    var label: String {
        switch self {
        case .dim: "Dim"
        case .blur: "Blur"
        }
    }

    var icon: String {
        switch self {
        case .dim: "circle.lefthalf.filled"
        case .blur: "aqi.medium"
        }
    }
}

/// Persisted app settings backed by UserDefaults.
@MainActor
final class AppSettings: ObservableObject {
    static let shared = AppSettings()

    @AppStorage("overlayStyle") var overlayStyle: OverlayStyle = .dim
    @AppStorage("dimOpacity") var dimOpacity: Double = 0.45
    @AppStorage("blurRadius") var blurRadius: Double = 8.0
    @AppStorage("visibleLines") var visibleLines: Int = 1
    @AppStorage("highlightColorR") var highlightColorR: Double = 1.0
    @AppStorage("highlightColorG") var highlightColorG: Double = 1.0
    @AppStorage("highlightColorB") var highlightColorB: Double = 1.0
    @AppStorage("highlightColorEnabled") var highlightColorEnabled: Bool = false
    /// Thin lines around the slit's opening. Off leaves the opening unframed.
    @AppStorage("slitOutlineEnabled") var slitOutlineEnabled: Bool = true

    // Auto-advance
    @AppStorage("autoAdvanceEnabled") var autoAdvanceEnabled: Bool = false
    @AppStorage("autoAdvanceSeconds") var autoAdvanceSeconds: Double = 3.0

    // OpenDyslexic
    @AppStorage("dyslexicFontEnabled") var dyslexicFontEnabled: Bool = false
    @AppStorage("dyslexicFullPageMode") var dyslexicFullPageMode: Bool = false

    // Drag-area selection (Option + drag)
    @AppStorage("dragSelectEnabled") var dragSelectEnabled: Bool = true

    /// While ⌘ is held, outline the paragraph a click would select.
    @AppStorage("hoverPreviewEnabled") var hoverPreviewEnabled: Bool = true

    /// Debug: tapping Shift toggles red outlines around every paragraph a
    /// ⌘+click would select. Diagnostic aid for tuning paragraph detection —
    /// off by default so it never interferes with normal reading.
    @AppStorage("debugOverlayEnabled") var debugOverlayEnabled: Bool = false

    /// How much bigger than the normal line gap a vertical gap must be before
    /// it counts as a paragraph break. Lower splits text into more, smaller
    /// paragraphs; higher merges them into larger blocks.
    @AppStorage("paragraphBreakSensitivity") var paragraphBreakSensitivity: Double = 1.8

    /// Manual word-reveal mode. When on, the slit no longer follows the cursor
    /// up and down. Instead it starts at the top line and reveals that line word
    /// by word as the cursor moves right; clicking skips to the next line and
    /// resets the reveal.
    @AppStorage("manualWordModeEnabled") var manualWordModeEnabled: Bool = false

    /// Word-by-word only: text stays uncovered once read, from the first line
    /// down to the current word, instead of rolling off after `visibleLines`.
    @AppStorage("keepReadTextVisible") var keepReadTextVisible: Bool = false

    // MARK: - Settings that cannot be combined

    // Word-by-word moves on clicks; auto-advance moves the slit on a timer.
    // The two cannot be on together. (OpenDyslexic can: the reveal follows
    // the redrawn text's own word positions.)

    func setWordByWord(_ on: Bool) {
        manualWordModeEnabled = on
        if on { autoAdvanceEnabled = false }
    }

    func setAutoAdvance(_ on: Bool) {
        autoAdvanceEnabled = on
        if on { manualWordModeEnabled = false }
    }

    /// Repair a combination saved before these rules existed.
    func resolveConflicts() {
        if manualWordModeEnabled { setWordByWord(true) }
    }

    var highlightColor: Color {
        Color(red: highlightColorR, green: highlightColorG, blue: highlightColorB)
    }

    func setHighlightColor(_ color: Color) {
        if let components = NSColor(color).usingColorSpace(.sRGB) {
            highlightColorR = components.redComponent
            highlightColorG = components.greenComponent
            highlightColorB = components.blueComponent
        }
    }

    private init() {}
}

// Make OverlayStyle work with @AppStorage
extension OverlayStyle: RawRepresentable {}
