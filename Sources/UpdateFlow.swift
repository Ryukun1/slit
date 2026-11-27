import Foundation

/// Where an update check or install has got to, as shown in Settings → Updates.
enum UpdateStatus: Equatable {
    case idle
    case checking
    case upToDate
    case available(version: String)
    /// `fraction` is nil while the download's size is unknown.
    case downloading(fraction: Double?)
    /// Unpacking and verifying the downloaded update.
    case preparing(fraction: Double)
    case readyToInstall(version: String)
    case installing
    case failed(message: String)

    var message: String {
        switch self {
        case .idle: return ""
        case .checking: return "Checking for updates…"
        case .upToDate: return "You're up to date."
        case .available(let version): return "Slit \(version) is available."
        case .downloading(let fraction?): return "Downloading… \(Int((fraction * 100).rounded()))%"
        case .downloading(nil): return "Downloading…"
        case .preparing: return "Preparing the update…"
        case .readyToInstall(let version): return "Slit \(version) is ready to install."
        case .installing: return "Installing and restarting…"
        case .failed(let message): return "Couldn't update. \(message)"
        }
    }

    /// The progress bar's value, or nil when there is no work to show.
    var progress: Double? {
        switch self {
        case .downloading(let fraction): return fraction ?? 0
        case .preparing(let fraction): return fraction
        default: return nil
        }
    }

    var menuTitle: String {
        switch self {
        case .available(let version), .readyToInstall(let version): return "Update to Slit \(version)…"
        default: return "Check for Updates…"
        }
    }

    /// Sparkle is in the middle of something the user can only cancel.
    var isWorking: Bool {
        switch self {
        case .checking, .downloading, .preparing, .installing: return true
        default: return false
        }
    }
}

/// Turns what Sparkle reports into the status Slit shows. Pure, so the whole
/// check → download → install sequence can be tested without a network.
struct UpdateFlow: Equatable {
    /// How far Sparkle got with an update it found.
    enum Stage: Equatable {
        case notDownloaded, downloaded, installing
    }

    enum Event: Equatable {
        case checkStarted
        case noUpdate
        case updateFound(version: String, stage: Stage)
        case userChoseInstall
        case downloadStarted
        case expectedLength(UInt64)
        case received(UInt64)
        case extractionStarted
        case extraction(Double)
        case readyToInstall
        case installing
        case failed(String)
        /// Sparkle closed the session: finished, skipped, postponed or cancelled.
        case sessionEnded
    }

    private(set) var status: UpdateStatus = .idle
    /// The user pressed Install, so the update installs as soon as it's ready.
    private(set) var installRequested = false
    private var version: String?
    private var expectedLength: UInt64?
    private var receivedLength: UInt64 = 0

    func applying(_ event: Event) -> UpdateFlow {
        var next = self
        switch event {
        case .checkStarted:
            next = UpdateFlow()
            next.status = .checking
        case .noUpdate:
            next.status = .upToDate
        case .updateFound(let version, let stage):
            next.version = version
            next.status = stage == .notDownloaded
                ? .available(version: version) : .readyToInstall(version: version)
        case .userChoseInstall:
            next.installRequested = true
        case .downloadStarted:
            next.expectedLength = nil
            next.receivedLength = 0
            next.status = .downloading(fraction: nil)
        case .expectedLength(let length):
            next.expectedLength = length > 0 ? length : nil
            next.status = .downloading(fraction: next.downloadFraction)
        case .received(let length):
            next.receivedLength += length
            next.status = .downloading(fraction: next.downloadFraction)
        case .extractionStarted:
            next.status = .preparing(fraction: 0)
        case .extraction(let fraction):
            next.status = .preparing(fraction: min(max(fraction, 0), 1))
        case .readyToInstall:
            next.status = installRequested
                ? .installing : .readyToInstall(version: version ?? "")
        case .installing:
            next.status = .installing
        case .failed(let message):
            next.status = .failed(message: message)
        case .sessionEnded:
            // Keep a final answer on screen; anything half-done is over.
            switch status {
            case .upToDate, .failed: next.installRequested = false
            default: next = UpdateFlow()
            }
        }
        return next
    }

    private var downloadFraction: Double? {
        guard let expectedLength else { return nil }
        return min(Double(receivedLength) / Double(expectedLength), 1)
    }
}
