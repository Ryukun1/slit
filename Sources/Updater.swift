import AppKit
import Combine
import OSLog
import Sparkle

/// Where updates come from and how they are verified, as `build_app.sh` writes
/// them into Info.plist.
///
/// Missing or unusable values mean the app was not packaged for release
/// (`swift run`, the test runner), and Slit then never contacts the network.
struct UpdateConfiguration: Equatable {
    let feedURL: URL
    /// Base64 EdDSA public key; every update must be signed by its private half.
    let publicKey: String

    init?(info: [String: Any]?) {
        guard
            let info,
            let feed = info["SUFeedURL"] as? String,
            let url = URL(string: feed),
            url.scheme == "https",
            url.host != nil,
            let key = info["SUPublicEDKey"] as? String,
            Data(base64Encoded: key)?.count == Self.publicKeyLength
        else { return nil }
        feedURL = url
        publicKey = key
    }

    /// An Ed25519 public key is 32 bytes.
    private static let publicKeyLength = 32
}

/// Slit's "Check for Updates…": finds a newer release, downloads it, checks its
/// signature, replaces the app and relaunches it, using Sparkle.
///
/// Everything is shown in Settings → Updates rather than in Sparkle's own
/// windows (see `UpdateUserDriver`). Slit only goes online when the user asks,
/// unless they turn on automatic checks in Settings (off by default).
@MainActor
final class Updater: NSObject, ObservableObject, NSMenuItemValidation {
    static let shared = Updater()

    /// Mirrors Sparkle's own setting so Settings redraws when it changes.
    @Published var automaticallyChecks: Bool {
        didSet { updater?.automaticallyChecksForUpdates = automaticallyChecks }
    }

    @Published private(set) var status: UpdateStatus = .idle
    /// Whether Install / Skip / Later can be answered right now.
    @Published private(set) var awaitingChoice = false
    /// Whether the current check or download can be cancelled.
    @Published private(set) var canCancel = false
    /// Bumped to ask Settings to scroll to the Updates section.
    @Published private(set) var focusRequest = 0

    /// Opens Settings; set by the app delegate.
    var showSettings: () -> Void = {}

    private let driver: UpdateUserDriver
    private let updater: SPUUpdater?

    /// False in builds that were not packaged for release.
    var isAvailable: Bool { updater != nil }

    private init(bundle: Bundle = .main) {
        let driver = UpdateUserDriver()
        self.driver = driver
        guard UpdateConfiguration(info: bundle.infoDictionary) != nil else {
            updater = nil
            automaticallyChecks = false
            super.init()
            return
        }
        let updater = SPUUpdater(
            hostBundle: bundle, applicationBundle: bundle, userDriver: driver, delegate: nil
        )
        self.updater = updater
        automaticallyChecks = updater.automaticallyChecksForUpdates
        super.init()

        driver.onChange = { [weak self] flow in self?.refresh(from: flow) }
        driver.onNeedsAttention = { [weak self] in self?.bringForward() }
        do {
            try updater.start()
        } catch {
            status = .failed(message: error.localizedDescription)
            Self.log.error("Updater failed to start: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: - Actions

    /// Opens Settings at the Updates section and checks there.
    func checkForUpdates() {
        bringForward()
        guard let updater, !status.isWorking else { return }
        updater.checkForUpdates()
    }

    func install() { driver.install() }
    func skipThisVersion() { driver.skipThisVersion() }
    func later() { driver.later() }
    func cancel() { driver.cancel() }

    // MARK: - Menu

    /// "Check for Updates…", or "Update to Slit 1.2…" once one is waiting.
    func makeMenuItem() -> NSMenuItem {
        let item = NSMenuItem(
            title: status.menuTitle, action: #selector(menuItemChosen(_:)), keyEquivalent: ""
        )
        item.target = self
        item.image = NSImage(
            systemSymbolName: "arrow.triangle.2.circlepath",
            accessibilityDescription: "Check for Updates"
        )
        return item
    }

    @objc private func menuItemChosen(_ sender: Any?) {
        switch status {
        case .available, .readyToInstall: bringForward()
        default: checkForUpdates()
        }
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        guard menuItem.action == #selector(menuItemChosen(_:)) else { return true }
        menuItem.title = status.menuTitle
        return isAvailable
    }

    // MARK: - Helpers

    private static let log = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "com.alfonsomulet.slit", category: "updates"
    )

    private func refresh(from flow: UpdateFlow) {
        status = flow.status
        awaitingChoice = driver.canAnswer
        canCancel = driver.canCancel
    }

    private var pendingFocus = false

    /// True once after something asked for the Updates section; Settings
    /// calls this when it appears or when `focusRequest` changes.
    func takeFocusRequest() -> Bool {
        defer { pendingFocus = false }
        return pendingFocus
    }

    private func bringForward() {
        pendingFocus = true
        showSettings()
        focusRequest += 1
    }

    /// The version shown to the user, e.g. "1.1".
    static var currentVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—"
    }
}
