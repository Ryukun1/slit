import Foundation
import Sparkle

/// Replaces Sparkle's own windows: every step of a check or install is turned
/// into an `UpdateFlow` event, and Settings → Updates shows the result.
///
/// Sparkle hands over callbacks it waits on (install or skip, cancel, OK).
/// They are kept here until the user answers in Settings. Messages that only
/// need an "OK" are acknowledged straight away, since the status stays on
/// screen in Settings.
@MainActor
final class UpdateUserDriver: NSObject, SPUUserDriver {
    /// Called with every new status.
    var onChange: (UpdateFlow) -> Void = { _ in }
    /// Asks the app to bring Settings → Updates forward.
    var onNeedsAttention: () -> Void = {}

    private(set) var flow = UpdateFlow() {
        didSet { onChange(flow) }
    }

    private var pendingChoice: ((SPUUserUpdateChoice) -> Void)?
    private var pendingCancel: (() -> Void)?

    // MARK: - Answers from Settings

    func install() {
        flow = flow.applying(.userChoseInstall)
        answer(.install)
    }

    func skipThisVersion() { answer(.skip) }

    func later() { answer(.dismiss) }

    func cancel() {
        let cancel = pendingCancel
        pendingCancel = nil
        cancel?()
    }

    private func answer(_ choice: SPUUserUpdateChoice) {
        let reply = pendingChoice
        pendingChoice = nil
        reply?(choice)
    }

    var canAnswer: Bool { pendingChoice != nil }
    var canCancel: Bool { pendingCancel != nil }

    // MARK: - SPUUserDriver

    func show(_ request: SPUUpdatePermissionRequest,
              reply: @escaping (SUUpdatePermissionResponse) -> Void) {
        // Info.plist already sets SUEnableAutomaticChecks, so this should not
        // happen; if it does, stay offline unless the user opts in.
        reply(SUUpdatePermissionResponse(automaticUpdateChecks: false, sendSystemProfile: false))
    }

    func showUserInitiatedUpdateCheck(cancellation: @escaping () -> Void) {
        pendingCancel = cancellation
        flow = flow.applying(.checkStarted)
    }

    func showUpdateFound(with appcastItem: SUAppcastItem, state: SPUUserUpdateState,
                         reply: @escaping (SPUUserUpdateChoice) -> Void) {
        pendingCancel = nil
        pendingChoice = reply
        flow = flow.applying(.updateFound(
            version: appcastItem.displayVersionString, stage: Self.stage(state.stage)
        ))
        if state.userInitiated { onNeedsAttention() }
    }

    func showUpdateReleaseNotes(with downloadData: SPUDownloadData) {}

    func showUpdateReleaseNotesFailedToDownloadWithError(_ error: Error) {}

    func showUpdateNotFoundWithError(_ error: Error, acknowledgement: @escaping () -> Void) {
        pendingCancel = nil
        flow = flow.applying(.noUpdate)
        acknowledgement()
    }

    func showUpdaterError(_ error: Error, acknowledgement: @escaping () -> Void) {
        pendingCancel = nil
        pendingChoice = nil
        flow = flow.applying(.failed(Self.describe(error)))
        acknowledgement()
    }

    func showDownloadInitiated(cancellation: @escaping () -> Void) {
        pendingCancel = cancellation
        flow = flow.applying(.downloadStarted)
    }

    func showDownloadDidReceiveExpectedContentLength(_ expectedContentLength: UInt64) {
        flow = flow.applying(.expectedLength(expectedContentLength))
    }

    func showDownloadDidReceiveData(ofLength length: UInt64) {
        flow = flow.applying(.received(length))
    }

    func showDownloadDidStartExtractingUpdate() {
        pendingCancel = nil
        flow = flow.applying(.extractionStarted)
    }

    func showExtractionReceivedProgress(_ progress: Double) {
        flow = flow.applying(.extraction(progress))
    }

    func showReady(toInstallAndRelaunch reply: @escaping (SPUUserUpdateChoice) -> Void) {
        flow = flow.applying(.readyToInstall)
        if flow.installRequested {
            reply(.install)
        } else {
            pendingChoice = reply
        }
    }

    func showInstallingUpdate(withApplicationTerminated applicationTerminated: Bool,
                              retryTerminatingApplication: @escaping () -> Void) {
        flow = flow.applying(.installing)
    }

    func showUpdateInstalledAndRelaunched(_ relaunched: Bool, acknowledgement: @escaping () -> Void) {
        acknowledgement()
    }

    func showUpdateInFocus() {
        onNeedsAttention()
    }

    func dismissUpdateInstallation() {
        pendingChoice = nil
        pendingCancel = nil
        flow = flow.applying(.sessionEnded)
    }

    // MARK: - Helpers

    private static func stage(_ stage: SPUUserUpdateStage) -> UpdateFlow.Stage {
        switch stage {
        case .downloaded: return .downloaded
        case .installing: return .installing
        default: return .notDownloaded
        }
    }

    /// A short reason the user can act on.
    private static func describe(_ error: Error) -> String {
        let nsError = error as NSError
        if nsError.domain == NSURLErrorDomain {
            return "Check your internet connection. Some networks block GitHub downloads; "
                + "try another one, or download Slit from its GitHub page."
        }
        return nsError.localizedDescription
    }
}
