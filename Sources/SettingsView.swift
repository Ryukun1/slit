import SwiftUI

/// Settings UI styled to match the Slit landing page:
/// dark warm-black background, bold Helvetica, thin rules, one sticky title
/// strip, and grouped sections with segmented toggles + minimal sliders.
struct SettingsView: View {
    @ObservedObject var settings = AppSettings.shared
    @ObservedObject private var updater = Updater.shared

    // Palette — mirrors the CSS variables on slit.app
    private static let bg = Color(red: 0xE / 255.0, green: 0xE / 255.0, blue: 0x10 / 255.0)
    private static let bgSoft = Color(red: 0x15 / 255.0, green: 0x15 / 255.0, blue: 0x18 / 255.0)
    private static let ink = Color(red: 0xF2 / 255.0, green: 0xEE / 255.0, blue: 0xE6 / 255.0)
    private static let inkSoft = Color(red: 0x8A / 255.0, green: 0x86 / 255.0, blue: 0x80 / 255.0)
    private static let rule = Color(red: 0x23 / 255.0, green: 0x23 / 255.0, blue: 0x27 / 255.0)
    private static let accent = Color(red: 0xC9 / 255.0, green: 0xA9 / 255.0, blue: 0x73 / 255.0)

    var body: some View {
        ZStack(alignment: .top) {
            Self.bg.ignoresSafeArea()

            ScrollViewReader { scroller in
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 0) {
                    header
                        .padding(.horizontal, 40)
                        .padding(.top, 28)
                        .padding(.bottom, 40)

                    LazyVStack(alignment: .leading, spacing: 44) {
                        overlaySection
                        readingSection
                        selectionSection
                        fontsSection
                        shortcutsSection
                        updatesSection
                            .id(Self.updatesAnchor)
                        aboutSection
                    }
                    .padding(.horizontal, 40)
                    .padding(.bottom, 48)
                }
            }
            .scrollContentBackground(.hidden)
            // "Check for Updates…" opens Settings here, at the Updates section.
            .onAppear { scrollToUpdatesIfAsked(scroller) }
            .onChange(of: updater.focusRequest) { _, _ in scrollToUpdatesIfAsked(scroller) }
            }
        }
        .frame(width: 640, height: 680)
        .background(Self.bg)
        .preferredColorScheme(.dark)
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 14) {
            LogoView(size: 44)
                .shadow(color: .black.opacity(0.35), radius: 10, y: 4)
            VStack(alignment: .leading, spacing: 2) {
                Text("Slit")
                    .font(.system(size: 22, weight: .bold))
                    .foregroundStyle(Self.ink)
                Text("Reading focus")
                    .font(.system(size: 10, weight: .bold))
                    .tracking(1.2)
                    .textCase(.uppercase)
                    .foregroundStyle(Self.inkSoft)
            }
            Spacer()
            Text("Settings")
                .font(.system(size: 11, weight: .bold))
                .tracking(1.2)
                .textCase(.uppercase)
                .foregroundStyle(Self.inkSoft)
        }
        .padding(.bottom, 24)
        .overlay(
            Rectangle()
                .fill(Self.rule)
                .frame(height: 1),
            alignment: .bottom
        )
    }

    // MARK: - Sections

    private var overlaySection: some View {
        section(title: "Overlay") {
            row("Mode", trailing: {
                SegmentedToggle(
                    options: [("Dim", OverlayStyle.dim), ("Blur", OverlayStyle.blur)],
                    selection: $settings.overlayStyle
                )
                .frame(width: 160)
            })

            switch settings.overlayStyle {
            case .dim:
                SlitSlider(label: "Dim amount",
                           value: $settings.dimOpacity,
                           range: 0.1...1.0, step: 0.05,
                           display: "\(Int(settings.dimOpacity * 100))%")
            case .blur:
                SlitSlider(label: "Blur radius",
                           value: $settings.blurRadius,
                           range: 2...20, step: 1,
                           display: "\(Int(settings.blurRadius)) px")
            }

            toggleRow("Slit outline", binding: $settings.slitOutlineEnabled)

            toggleRow("Highlight tint", binding: $settings.highlightColorEnabled)

            if settings.highlightColorEnabled {
                highlightSwatches
                    .padding(.leading, Self.childIndent)
            }
        }
    }

    private var readingSection: some View {
        section(title: "Reading") {
            // The rolling-window height. With word-by-word keeping all read
            // text visible there is no window to size, so say so instead of
            // showing a slider that does nothing.
            if keepsAllReadText {
                unavailableRow("Visible lines", reason: "Not used while read text stays visible")
            } else {
                SlitSlider(label: "Visible lines",
                           value: Binding(
                            get: { Double(settings.visibleLines) },
                            set: { settings.visibleLines = Int($0) }
                           ),
                           range: 1...5, step: 1,
                           display: visibleLinesLabel)
            }

            toggleRow("Word-by-word reveal", binding: Binding(
                get: { settings.manualWordModeEnabled },
                set: { settings.setWordByWord($0) }
            ))

            if settings.manualWordModeEnabled {
                Group {
                    captionRow(wordModeCaption)
                    toggleRow("Keep read text visible", binding: $settings.keepReadTextVisible)
                }
                .padding(.leading, Self.childIndent)
            }

            // Shown but unavailable rather than hidden, so it is clear where
            // the option went and why.
            if settings.manualWordModeEnabled {
                unavailableRow("Auto-advance", reason: Self.wordModeConflict)
            } else {
                toggleRow("Auto-advance", binding: Binding(
                    get: { settings.autoAdvanceEnabled },
                    set: { settings.setAutoAdvance($0) }
                ))

                if settings.autoAdvanceEnabled {
                    SlitSlider(label: "Speed",
                               value: $settings.autoAdvanceSeconds,
                               range: 0.5...10.0, step: 0.5,
                               display: String(format: "%.1f s", settings.autoAdvanceSeconds))
                        .padding(.leading, Self.childIndent)
                }
            }
        }
    }

    private var selectionSection: some View {
        section(title: "Selection") {
            toggleRow("Drag to select area", binding: $settings.dragSelectEnabled)

            toggleRow("Preview paragraph while holding ⌘", binding: $settings.hoverPreviewEnabled)

            SlitSlider(label: "Paragraph size",
                       value: $settings.paragraphBreakSensitivity,
                       range: 1.0...5.0, step: 0.1,
                       display: String(format: "%.1f×", settings.paragraphBreakSensitivity))

            toggleRow("Debug: ⇧ toggles paragraph outlines", binding: $settings.debugOverlayEnabled)
        }
    }

    private var fontsSection: some View {
        section(title: "Font") {
            toggleRow("OpenDyslexic", binding: $settings.dyslexicFontEnabled)

            if settings.dyslexicFontEnabled {
                toggleRow("Full page", binding: $settings.dyslexicFullPageMode)
                    .padding(.leading, Self.childIndent)
            }
        }
    }

    private var shortcutsSection: some View {
        section(title: "Shortcuts") {
            shortcutRow("Enter selection", keys: ["hold", "⌘"])
            shortcutRow("Select paragraph", keys: ["⌘", "click"])
            if settings.dragSelectEnabled {
                shortcutRow("Draw region", keys: ["⌥", "drag"])
            }
            shortcutRow("Next / previous line", keys: ["↑", "↓"])
            if settings.manualWordModeEnabled {
                shortcutRow("Reveal next word", keys: ["click"])
                shortcutRow("Skip line (at line end)", keys: ["click"])
            } else {
                shortcutRow("Advance", keys: ["click"])
            }
            shortcutRow("Dismiss", keys: ["esc"])
        }
    }

    private static let updatesAnchor = "updates"

    private func scrollToUpdatesIfAsked(_ scroller: ScrollViewProxy) {
        guard updater.takeFocusRequest() else { return }
        withAnimation(.easeInOut(duration: 0.3)) {
            scroller.scrollTo(Self.updatesAnchor, anchor: .top)
        }
    }

    @ViewBuilder
    private var updatesSection: some View {
        section(title: "Updates") {
            if updater.isAvailable {
                updateStatusRow
                toggleRow("Check for updates automatically", binding: $updater.automaticallyChecks)
            } else {
                unavailableRow("Check for updates", reason: "Only in the packaged app")
            }
        }
    }

    /// Version, what the updater is doing, and the buttons that apply now.
    private var updateStatusRow: some View {
        VStack(alignment: .leading, spacing: 0) {
            Self.rule.frame(height: 1)
            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Version \(Updater.currentVersion)")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Self.ink)
                    if !updater.status.message.isEmpty {
                        Text(updater.status.message)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(updateMessageColor)
                            .fixedSize(horizontal: false, vertical: true)
                            .transition(.opacity)
                    }
                }
                Spacer(minLength: 12)
                updateButtons
            }
            .padding(.vertical, 14)

            if let progress = updater.status.progress {
                ProgressView(value: progress)
                    .progressViewStyle(.linear)
                    .tint(Self.accent)
                    .padding(.bottom, 14)
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: updater.status)
    }

    @ViewBuilder
    private var updateButtons: some View {
        HStack(spacing: 8) {
            switch updater.status {
            case .available, .readyToInstall:
                if updater.awaitingChoice {
                    pillButton("Skip This Version", prominent: false) { updater.skipThisVersion() }
                    pillButton("Later", prominent: false) { updater.later() }
                    pillButton(installTitle, prominent: true) { updater.install() }
                } else {
                    pillButton("Check Now", prominent: false) { updater.checkForUpdates() }
                }
            case .checking, .downloading:
                if updater.canCancel {
                    pillButton("Cancel", prominent: false) { updater.cancel() }
                }
            case .preparing, .installing:
                ProgressView().controlSize(.small)
            case .idle, .upToDate, .failed:
                pillButton("Check Now", prominent: false) { updater.checkForUpdates() }
            }
        }
    }

    private var installTitle: String {
        if case .readyToInstall = updater.status { return "Restart to Update" }
        return "Install Update"
    }

    private var updateMessageColor: Color {
        switch updater.status {
        case .failed: return Color(nsColor: .systemRed)
        case .available, .readyToInstall: return Self.accent
        default: return Self.inkSoft
        }
    }

    private func pillButton(_ title: String, prominent: Bool, action: @escaping () -> Void) -> some View {
        Button(title, action: action)
            .buttonStyle(.plain)
            .font(.system(size: 12, weight: .bold))
            .foregroundStyle(prominent ? Self.bg : Self.ink)
            .padding(.horizontal, 12)
            .frame(height: 26)
            .background(RoundedRectangle(cornerRadius: 6).fill(prominent ? Self.accent : Self.bgSoft))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(prominent ? .clear : Self.rule, lineWidth: 1))
            .fixedSize()
    }

    private var aboutSection: some View {
        section(title: "About") {
            VStack(alignment: .leading, spacing: 4) {
                Text("Slit")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(Self.ink)
                Text("Version \(Updater.currentVersion)  ·  macOS reading focus tool")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Self.inkSoft)
            }
            .padding(.vertical, 14)
        }
    }

    // MARK: - Highlight swatches

    private static let highlightPresets: [(name: String, color: Color)] = [
        ("White",  Color(red: 1.0, green: 1.0, blue: 1.0)),
        ("Amber",  Color(red: 1.0, green: 0.85, blue: 0.3)),
        ("Peach",  Color(red: 1.0, green: 0.55, blue: 0.3)),
        ("Red",    Color(red: 1.0, green: 0.4, blue: 0.4)),
        ("Pink",   Color(red: 1.0, green: 0.45, blue: 0.75)),
        ("Purple", Color(red: 0.7, green: 0.45, blue: 1.0)),
        ("Blue",   Color(red: 0.4, green: 0.6, blue: 1.0)),
        ("Cyan",   Color(red: 0.3, green: 0.85, blue: 0.95)),
        ("Green",  Color(red: 0.4, green: 0.85, blue: 0.55)),
    ]

    private var highlightSwatches: some View {
        HStack(spacing: 10) {
            ForEach(Self.highlightPresets.indices, id: \.self) { i in
                let preset = Self.highlightPresets[i]
                let selected = colorsApproxEqual(preset.color, settings.highlightColor)
                Button {
                    settings.setHighlightColor(preset.color)
                } label: {
                    Circle()
                        .fill(preset.color)
                        .frame(width: 22, height: 22)
                        .overlay(
                            Circle()
                                .strokeBorder(
                                    selected ? Self.accent : Self.rule,
                                    lineWidth: selected ? 2 : 1
                                )
                        )
                }
                .buttonStyle(.plain)
                .help(preset.name)
            }
            Spacer()
        }
        .padding(.vertical, 14)
        .overlay(alignment: .top) { Self.rule.frame(height: 1) }
    }

    // MARK: - Section + row builders

    @ViewBuilder
    private func section<Content: View>(title: String, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title)
                .font(.system(size: 11, weight: .bold))
                .tracking(1.2)
                .textCase(.uppercase)
                .foregroundStyle(Self.inkSoft)
                .padding(.bottom, 14)
            VStack(alignment: .leading, spacing: 0) {
                content()
            }
        }
    }

    @ViewBuilder
    private func row<Trailing: View>(_ title: String,
                                     @ViewBuilder trailing: () -> Trailing) -> some View {
        VStack(spacing: 0) {
            Self.rule.frame(height: 1)
            HStack(alignment: .center) {
                Text(title)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Self.ink)
                Spacer()
                trailing()
            }
            .padding(.vertical, 14)
        }
    }

    /// A small muted caption line, used to explain a setting's behavior.
    private func captionRow(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(Self.inkSoft)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 10)
    }

    /// A setting that cannot be used with the current choices: its name,
    /// dimmed, with the reason in place of its control.
    private func unavailableRow(_ title: String, reason: String) -> some View {
        VStack(spacing: 0) {
            Self.rule.frame(height: 1)
            HStack(alignment: .center) {
                Text(title)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Self.inkSoft.opacity(0.7))
                Spacer()
                Text(reason)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Self.inkSoft)
                    .multilineTextAlignment(.trailing)
            }
            .padding(.vertical, 14)
        }
        .accessibilityElement(children: .combine)
    }

    /// Row with a boolean On/Off toggle — clicking anywhere flips the value.
    private func toggleRow(_ title: String, binding: Binding<Bool>) -> some View {
        VStack(spacing: 0) {
            Self.rule.frame(height: 1)
            HStack(alignment: .center) {
                Text(title)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Self.ink)
                Spacer()
                SegmentedToggle(
                    options: [("Off", false), ("On", true)],
                    selection: binding
                )
                .frame(width: 120)
                .allowsHitTesting(false)
            }
            .padding(.vertical, 14)
            .contentShape(Rectangle())
            .onTapGesture {
                withAnimation(.easeInOut(duration: 0.18)) {
                    binding.wrappedValue.toggle()
                }
            }
        }
    }

    private func shortcutRow(_ label: String, keys: [String]) -> some View {
        VStack(spacing: 0) {
            Self.rule.frame(height: 1)
            HStack {
                Text(label)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Self.ink)
                Spacer()
                HStack(spacing: 4) {
                    ForEach(keys.indices, id: \.self) { i in
                        Text(keys[i])
                            .font(.system(size: 12, weight: .bold))
                            .foregroundStyle(Self.ink)
                            .padding(.horizontal, 8)
                            .frame(height: 24)
                            .background(
                                RoundedRectangle(cornerRadius: 6)
                                    .fill(Self.bgSoft)
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 6)
                                    .strokeBorder(Self.rule, lineWidth: 1)
                            )
                    }
                }
            }
            .padding(.vertical, 12)
        }
    }

    // MARK: - Helpers

    private func colorsApproxEqual(_ a: Color, _ b: Color) -> Bool {
        let an = NSColor(a).usingColorSpace(.sRGB)
        let bn = NSColor(b).usingColorSpace(.sRGB)
        guard let an, let bn else { return false }
        return abs(an.redComponent - bn.redComponent) < 0.04
            && abs(an.greenComponent - bn.greenComponent) < 0.04
            && abs(an.blueComponent - bn.blueComponent) < 0.04
    }

    /// How far an option is inset under the setting it depends on.
    private static let childIndent: CGFloat = 20

    private static let wordModeConflict = "Not available with word-by-word reveal"

    /// Word-by-word with every read line kept open: no rolling window.
    private var keepsAllReadText: Bool {
        settings.manualWordModeEnabled && settings.keepReadTextVisible
    }

    private var wordModeCaption: String {
        settings.keepReadTextVisible
            ? "Click to reveal each word. Everything you have read stays visible."
            : "Click to reveal each word; completed lines stack up to your Visible lines, "
                + "then scroll. Move the cursor up to re-read."
    }

    private var visibleLinesLabel: String {
        let n = settings.visibleLines
        return n == 1 ? "1 line" : "\(n) lines"
    }
}

// MARK: - Segmented toggle matching the web page

private struct SegmentedToggle<Value: Hashable>: View {
    let options: [(String, Value)]
    @Binding var selection: Value

    private static var bg: Color { Color(red: 0xE/255.0, green: 0xE/255.0, blue: 0x10/255.0) }
    private static var bgSoft: Color { Color(red: 0x15/255.0, green: 0x15/255.0, blue: 0x18/255.0) }
    private static var ink: Color { Color(red: 0xF2/255.0, green: 0xEE/255.0, blue: 0xE6/255.0) }
    private static var inkSoft: Color { Color(red: 0x8A/255.0, green: 0x86/255.0, blue: 0x80/255.0) }
    private static var rule: Color { Color(red: 0x23/255.0, green: 0x23/255.0, blue: 0x27/255.0) }

    var body: some View {
        HStack(spacing: 2) {
            ForEach(options.indices, id: \.self) { i in
                let opt = options[i]
                let on = opt.1 == selection
                Button {
                    withAnimation(.easeInOut(duration: 0.18)) {
                        selection = opt.1
                    }
                } label: {
                    Text(opt.0)
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(on ? Self.bg : Self.inkSoft)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 7)
                        .background(
                            RoundedRectangle(cornerRadius: 6)
                                .fill(on ? Self.ink : Color.clear)
                        )
                }
                .buttonStyle(.plain)
            }
        }
        .padding(2)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Self.bg)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(Self.rule, lineWidth: 1)
        )
    }
}

// MARK: - Slider that matches the web page

private struct SlitSlider: View {
    let label: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let step: Double
    let display: String

    private static var ink: Color { Color(red: 0xF2/255.0, green: 0xEE/255.0, blue: 0xE6/255.0) }
    private static var inkSoft: Color { Color(red: 0x8A/255.0, green: 0x86/255.0, blue: 0x80/255.0) }
    private static var rule: Color { Color(red: 0x23/255.0, green: 0x23/255.0, blue: 0x27/255.0) }

    var body: some View {
        VStack(spacing: 0) {
            Self.rule.frame(height: 1)
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text(label)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Self.ink)
                    Spacer()
                    Text(display)
                        .font(.system(size: 12, weight: .bold))
                        .monospacedDigit()
                        .foregroundStyle(Self.inkSoft)
                }
                Slider(value: $value, in: range, step: step)
                    .tint(Color(red: 0xC9/255.0, green: 0xA9/255.0, blue: 0x73/255.0))
                    .controlSize(.small)
            }
            .padding(.vertical, 14)
        }
    }
}
