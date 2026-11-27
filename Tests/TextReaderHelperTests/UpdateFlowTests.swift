import Foundation
import Testing
@testable import TextReaderHelper

/// What Settings → Updates shows as Sparkle works through a check and install.
struct UpdateFlowTests {
    private func run(_ events: [UpdateFlow.Event], from flow: UpdateFlow = UpdateFlow()) -> UpdateFlow {
        events.reduce(flow) { $0.applying($1) }
    }

    @Test("Starts idle")
    func startsIdle() {
        #expect(UpdateFlow().status == .idle)
    }

    @Test("A check with nothing new ends up to date, and stays that way after Sparkle closes the session")
    func upToDate() {
        let flow = run([.checkStarted, .noUpdate, .sessionEnded])

        #expect(flow.status == .upToDate)
    }

    @Test("A new version is offered until the user chooses")
    func updateFound() {
        let flow = run([.checkStarted, .updateFound(version: "1.2", stage: .notDownloaded)])

        #expect(flow.status == .available(version: "1.2"))
        #expect(flow.installRequested == false)
    }

    @Test("Download progress is shown as a fraction of the expected size")
    func downloadProgress() {
        let flow = run([
            .updateFound(version: "1.2", stage: .notDownloaded), .userChoseInstall,
            .downloadStarted, .expectedLength(1000), .received(250), .received(250),
        ])

        #expect(flow.status == .downloading(fraction: 0.5))
    }

    @Test("Without a known size the download shows no percentage")
    func unknownSize() {
        let flow = run([.downloadStarted, .received(4000)])

        #expect(flow.status == .downloading(fraction: nil))
    }

    @Test("Progress never goes past 100%")
    func progressCapped() {
        let flow = run([.downloadStarted, .expectedLength(100), .received(150)])

        #expect(flow.status == .downloading(fraction: 1))
    }

    @Test("After choosing Install, Slit installs as soon as the update is ready, without asking again")
    func installAfterChoosing() {
        let flow = run([
            .updateFound(version: "1.2", stage: .notDownloaded), .userChoseInstall,
            .downloadStarted, .extractionStarted, .extraction(0.5), .readyToInstall,
        ])

        #expect(flow.installRequested)
        #expect(flow.status == .installing)
    }

    @Test("An update downloaded in the background waits for the user")
    func readyWithoutAsking() {
        let flow = run([.updateFound(version: "1.2", stage: .downloaded), .readyToInstall])

        #expect(flow.status == .readyToInstall(version: "1.2"))
        #expect(flow.installRequested == false)
    }

    @Test("Extraction progress is shown")
    func extraction() {
        let flow = run([.downloadStarted, .extractionStarted, .extraction(0.25)])

        #expect(flow.status == .preparing(fraction: 0.25))
    }

    @Test("Errors are shown and survive the end of the session")
    func failure() {
        let flow = run([.checkStarted, .failed("The network connection was lost."), .sessionEnded])

        #expect(flow.status == .failed(message: "The network connection was lost."))
    }

    @Test("Closing the session mid-way (skip, later, cancel) goes back to idle")
    func dismissed() {
        for events: [UpdateFlow.Event] in [
            [.checkStarted, .sessionEnded],
            [.updateFound(version: "1.2", stage: .notDownloaded), .sessionEnded],
            [.downloadStarted, .received(5), .sessionEnded],
        ] {
            let flow = run(events)
            #expect(flow.status == .idle)
            #expect(flow.installRequested == false)
        }
    }

    @Test("A new check clears the last result and any earlier download")
    func newCheckResets() {
        let flow = run([
            .downloadStarted, .expectedLength(10), .received(10), .failed("x"), .sessionEnded,
            .checkStarted, .downloadStarted, .received(1),
        ])

        #expect(flow.status == .downloading(fraction: nil))
    }

    @Test("Each status says what is happening in words")
    func messages() {
        #expect(UpdateStatus.checking.message == "Checking for updates…")
        #expect(UpdateStatus.upToDate.message == "You're up to date.")
        #expect(UpdateStatus.available(version: "1.2").message == "Slit 1.2 is available.")
        #expect(UpdateStatus.downloading(fraction: 0.42).message == "Downloading… 42%")
        #expect(UpdateStatus.downloading(fraction: nil).message == "Downloading…")
        #expect(UpdateStatus.readyToInstall(version: "1.2").message == "Slit 1.2 is ready to install.")
        #expect(UpdateStatus.failed(message: "Offline.").message == "Couldn't update. Offline.")
    }

    @Test("Only work in progress shows a progress bar")
    func progressBar() {
        #expect(UpdateStatus.downloading(fraction: 0.3).progress == 0.3)
        #expect(UpdateStatus.preparing(fraction: 0.8).progress == 0.8)
        #expect(UpdateStatus.idle.progress == nil)
        #expect(UpdateStatus.available(version: "1.2").progress == nil)
    }

    @Test("The menu item offers the waiting update by name")
    func menuTitle() {
        #expect(UpdateStatus.idle.menuTitle == "Check for Updates…")
        #expect(UpdateStatus.available(version: "1.2").menuTitle == "Update to Slit 1.2…")
        #expect(UpdateStatus.readyToInstall(version: "1.2").menuTitle == "Update to Slit 1.2…")
    }
}
