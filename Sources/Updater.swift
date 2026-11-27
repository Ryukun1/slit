import AppKit
import Combine
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
/// Slit only goes online when the user asks, unless they turn on automatic
/// checks in Settings (off by default).
@MainActor
final class Updater: ObservableObject {
    static let shared = Updater()

    /// Mirrors Sparkle's own setting so Settings redraws when it changes.
    @Published var automaticallyChecks: Bool {
        didSet { controller?.updater.automaticallyChecksForUpdates = automaticallyChecks }
    }

    private let controller: SPUStandardUpdaterController?

    /// False in builds that were not packaged for release.
    var isAvailable: Bool { controller != nil }

    private init(bundle: Bundle = .main) {
        guard UpdateConfiguration(info: bundle.infoDictionary) != nil else {
            controller = nil
            automaticallyChecks = false
            return
        }
        let controller = SPUStandardUpdaterController(
            startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil
        )
        self.controller = controller
        automaticallyChecks = controller.updater.automaticallyChecksForUpdates
    }

    func checkForUpdates() {
        controller?.checkForUpdates(nil)
    }

    /// A menu item wired straight to Sparkle, which also greys it out while a
    /// check is already running.
    func makeMenuItem(title: String = "Check for Updates…") -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.image = NSImage(
            systemSymbolName: "arrow.triangle.2.circlepath",
            accessibilityDescription: "Check for Updates"
        )
        if let controller {
            item.target = controller
            item.action = #selector(SPUStandardUpdaterController.checkForUpdates(_:))
        }
        return item
    }

    /// The version shown to the user, e.g. "1.1".
    static var currentVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—"
    }
}
