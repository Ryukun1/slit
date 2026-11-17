import AppKit
import ApplicationServices
import Combine
import CoreGraphics
import os

/// A macOS permission Slit depends on.
enum PermissionKind: String, CaseIterable, Identifiable {
    case screenRecording
    case accessibility

    var id: String { rawValue }

    var title: String {
        switch self {
        case .screenRecording: "Screen Recording"
        case .accessibility: "Accessibility"
        }
    }

    /// Why Slit asks for it, in plain words.
    var reason: String {
        switch self {
        case .screenRecording:
            "Slit finds the lines of text by looking at what is on your screen. "
                + "It happens on your Mac; nothing is saved or sent anywhere."
        case .accessibility:
            "Lets Slit notice ⌘+click, the arrow keys and Esc while another app "
                + "is in front, scroll the page when you reach its edge, and keep "
                + "clicks on the reading panel from selecting the text underneath."
        }
    }

    /// What stops working if it is not granted.
    var withoutIt: String {
        switch self {
        case .screenRecording: "Without it, Slit cannot find any text."
        case .accessibility: "Without it, Slit cannot be started or controlled."
        }
    }

    var symbolName: String {
        switch self {
        case .screenRecording: "record.circle"
        case .accessibility: "accessibility"
        }
    }

    /// macOS applies a new Screen Recording grant only to a freshly started
    /// process. Accessibility takes effect straight away.
    var appliesAfterRelaunch: Bool { self == .screenRecording }

    fileprivate var settingsURL: URL? {
        let anchor = self == .screenRecording ? "Privacy_ScreenCapture" : "Privacy_Accessibility"
        return URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)")
    }

    /// Service name understood by `tccutil reset`.
    fileprivate var tccService: String {
        self == .screenRecording ? "ScreenCapture" : "Accessibility"
    }
}

/// Kept outside the main-actor class so background work can log too.
private enum PermissionsLog {
    static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "com.alfonsomulet.slit",
        category: "permissions"
    )
}

/// Live state of Slit's permissions, and the actions that change it.
///
/// The app never has to be told a permission was granted: this polls the two
/// side-effect-free system checks (quickly while a permission window or guide
/// is on screen, slowly otherwise, not at all once everything is granted) and
/// publishes the result.
@MainActor
final class Permissions: ObservableObject {
    static let shared = Permissions()

    @Published private(set) var accessibility: Bool
    @Published private(set) var screenRecording: Bool
    /// True once Screen Recording has been granted during this run, which
    /// only a relaunch can put into effect.
    @Published private(set) var needsRelaunch = false

    private enum Polling {
        /// While a permission window or guide card is visible.
        static let watched: TimeInterval = 1
        /// Something is missing but nobody is looking at it.
        static let idle: TimeInterval = 5
        /// Lets the system register the app in its list before the pane loads.
        static let settingsDelay: Duration = .milliseconds(400)
    }

    private enum Reset {
        static let tool = "/usr/bin/tccutil"
        /// A stuck `tccutil` must not leave the card waiting forever.
        static let timeout: TimeInterval = 5
        static let pollInterval: TimeInterval = 0.05
    }

    private var timer: Timer?
    private var timerInterval: TimeInterval?
    private var watcherCount = 0
    private var activationObserver: NSObjectProtocol?

    private init() {
        accessibility = AXIsProcessTrusted()
        screenRecording = CGPreflightScreenCaptureAccess()
        activationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        reschedulePolling()
    }

    var allGranted: Bool { accessibility && screenRecording }

    func isGranted(_ kind: PermissionKind) -> Bool {
        switch kind {
        case .accessibility: accessibility
        case .screenRecording: screenRecording
        }
    }

    func publisher(for kind: PermissionKind) -> AnyPublisher<Bool, Never> {
        switch kind {
        case .accessibility: $accessibility.eraseToAnyPublisher()
        case .screenRecording: $screenRecording.eraseToAnyPublisher()
        }
    }

    /// Re-read both permissions. Cheap and prompt-free, so safe to call often.
    func refresh() {
        let trusted = AXIsProcessTrusted()
        let canCapture = CGPreflightScreenCaptureAccess()
        if trusted != accessibility { accessibility = trusted }
        if canCapture != screenRecording {
            if canCapture { needsRelaunch = true }
            screenRecording = canCapture
        }
        reschedulePolling()
    }

    /// Call while permission UI is on screen so a grant shows up within a
    /// second. Balance every call with `endWatching()`.
    func beginWatching() {
        watcherCount += 1
        refresh()
    }

    func endWatching() {
        watcherCount = max(0, watcherCount - 1)
        reschedulePolling()
    }

    // MARK: - Actions

    /// Ask macOS for `kind` and keep the person company on the trip to System
    /// Settings with the floating guide.
    func request(_ kind: PermissionKind) {
        refresh()
        guard !isGranted(kind) else { return }

        // These show the system prompt the first time only; on every later
        // call they are silent. They also add Slit to the list in Settings.
        switch kind {
        case .accessibility:
            let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true]
            _ = AXIsProcessTrustedWithOptions(options as CFDictionary)
        case .screenRecording:
            _ = CGRequestScreenCaptureAccess()
        }

        PermissionGuidePanel.shared.show(for: kind)

        // Open the right list ourselves, so asking a second time still leads
        // somewhere even though the system prompt will not appear again.
        Task {
            try? await Task.sleep(for: Polling.settingsDelay)
            guard !isGranted(kind) else { return }
            openSettings(for: kind)
        }
    }

    func openSettings(for kind: PermissionKind) {
        guard let url = kind.settingsURL else { return }
        NSWorkspace.shared.open(url)
    }

    /// Remove Slit's entry for `kind` and ask again.
    ///
    /// macOS ties an entry to the app's code signature. A copy signed
    /// differently — a new build, an update — finds its switch already on in
    /// Settings yet the permission not honoured, and nothing short of removing
    /// the entry makes the system ask afresh. `tccutil reset` does that for
    /// this app's own entry without needing a password.
    func startOver(_ kind: PermissionKind) {
        guard let bundleID = Bundle.main.bundleIdentifier else {
            PermissionsLog.logger.error("No bundle identifier; cannot reset \(kind.rawValue)")
            request(kind)
            return
        }
        let service = kind.tccService
        Task {
            await Task.detached(priority: .userInitiated) {
                Self.resetEntry(service: service, bundleID: bundleID)
            }.value
            refresh()
            request(kind)
        }
    }

    /// Runs `tccutil reset <service> <bundleID>` and waits for it, bounded.
    private nonisolated static func resetEntry(service: String, bundleID: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: Reset.tool)
        process.arguments = ["reset", service, bundleID]
        do {
            try process.run()
        } catch {
            PermissionsLog.logger.error(
                "tccutil reset \(service) did not start: \(error.localizedDescription)"
            )
            return
        }
        let deadline = Date().addingTimeInterval(Reset.timeout)
        while process.isRunning, Date() < deadline {
            Thread.sleep(forTimeInterval: Reset.pollInterval)
        }
        guard !process.isRunning else {
            process.terminate()
            PermissionsLog.logger.error("tccutil reset \(service) timed out")
            return
        }
        if process.terminationStatus != 0 {
            PermissionsLog.logger.error(
                "tccutil reset \(service) exited with \(process.terminationStatus)"
            )
        }
    }

    /// Quit and start a fresh copy, which is what puts a Screen Recording
    /// grant into effect.
    func relaunch() {
        let bundleURL = Bundle.main.bundleURL
        guard bundleURL.pathExtension == "app" else {
            // Not running from an app bundle (e.g. `swift run`): nothing to reopen.
            PermissionsLog.logger.notice("Not an app bundle; quitting without relaunch")
            NSApp.terminate(nil)
            return
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: bundleURL, configuration: configuration) { _, error in
            if let error {
                PermissionsLog.logger.error("Relaunch failed: \(error.localizedDescription)")
            }
            DispatchQueue.main.async { NSApp.terminate(nil) }
        }
    }

    // MARK: - Polling

    private func reschedulePolling() {
        let wanted: TimeInterval? = allGranted
            ? nil
            : (watcherCount > 0 ? Polling.watched : Polling.idle)
        guard wanted != timerInterval else { return }

        timer?.invalidate()
        timer = nil
        timerInterval = wanted
        guard let wanted else { return }

        let newTimer = Timer(timeInterval: wanted, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        newTimer.tolerance = wanted * 0.3
        RunLoop.main.add(newTimer, forMode: .common)
        timer = newTimer
    }
}
