import Foundation
import CoreGraphics
import AppKit
import Combine
import os

/// Monitors global keyboard and mouse events via CGEvent taps.
/// Runs the event tap on a background thread; dispatches state changes to MainActor.
final class EventMonitor {
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    /// A second tap, for left-button events only, that can keep an event from
    /// reaching the app under the pointer. Everything else stays on the
    /// listen-only tap, so keys and pointer moves are never held up by Slit.
    private var clickTap: CFMachPort?
    private var clickRunLoopSource: CFRunLoopSource?
    /// Which clicks Slit keeps. Read on the tap thread for every left-button
    /// event; its region is updated from the main thread as sessions open and
    /// close.
    private let clickCapture = OSAllocatedUnfairLock(initialState: ClickCapture())
    private var sessionObserver: AnyCancellable?
    private var tapThread: Thread?
    private let appState: AppState
    /// In-flight debug block detection, cancelled when the overlay is toggled off.
    @MainActor private var debugDetectionTask: Task<Void, Never>?
    /// Previous Shift state, for detecting the press edge of the toggle.
    @MainActor private var shiftWasDown = false
    /// Previous Command state, for reacting to its press/release edges.
    @MainActor private var commandWasDown = false
    /// Newest pointer location not yet handled on the main thread. The tap can
    /// deliver hundreds of moves a second and only the latest matters, so at
    /// most one main-queue hop is ever pending.
    private let pendingMouseLocation = OSAllocatedUnfairLock<CGPoint?>(initialState: nil)
    /// Debounced re-detection after scrolling.
    @MainActor private var debugRefreshTask: Task<Void, Never>?
    /// Outlines the paragraph under the pointer while ⌘ is held.
    @MainActor private lazy var hoverPreview = HoverPreview(state: appState)
    /// Outlines the lines an Option-drag would select while it is dragged.
    @MainActor private lazy var areaPreview = AreaPreview(state: appState)
    /// Set SLIT_TIMING=1 to trace scroll phase values.
    private static let logScrollPhases =
        ProcessInfo.processInfo.environment["SLIT_TIMING"] == "1"

    init(appState: AppState) {
        self.appState = appState
    }

    private static let log = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "com.alfonsomulet.slit",
        category: "events"
    )

    /// Safe to call more than once: a second call only re-enables the tap,
    /// which covers Accessibility being switched off and back on.
    func start() {
        if let eventTap {
            CGEvent.tapEnable(tap: eventTap, enable: true)
            if let clickTap { CGEvent.tapEnable(tap: clickTap, enable: true) }
            return
        }

        let refcon = Unmanaged.passUnretained(self).toOpaque()

        let clickMask: CGEventMask =
            (1 << CGEventType.leftMouseDown.rawValue) |
            (1 << CGEventType.leftMouseDragged.rawValue) |
            (1 << CGEventType.leftMouseUp.rawValue)
        let createdClickTap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: clickMask,
            callback: EventMonitor.eventCallback,
            userInfo: refcon
        )
        if createdClickTap == nil {
            Self.log.error("Could not create the click tap; clicks on the panel will also reach the page")
        }

        // Without the click tap, presses are still needed to drive the
        // session, so the listen-only tap watches them instead.
        let listenMask: CGEventMask =
            (1 << CGEventType.flagsChanged.rawValue) |
            (1 << CGEventType.mouseMoved.rawValue) |
            (1 << CGEventType.keyDown.rawValue) |
            (1 << CGEventType.scrollWheel.rawValue) |
            (createdClickTap == nil ? (1 << CGEventType.leftMouseDown.rawValue) : 0)

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: listenMask,
            callback: EventMonitor.eventCallback,
            userInfo: refcon
        ) else {
            Self.log.error("Could not create the event tap; Accessibility is probably not granted")
            // A tap that can hold events must never be left unattended: with
            // nothing reading from it, every click would wait on it.
            if let createdClickTap {
                CGEvent.tapEnable(tap: createdClickTap, enable: false)
                CFMachPortInvalidate(createdClickTap)
            }
            return
        }

        eventTap = tap
        runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        clickTap = createdClickTap
        clickRunLoopSource = createdClickTap.map {
            CFMachPortCreateRunLoopSource(kCFAllocatorDefault, $0, 0)
        }
        observeSession()

        let sources = [runLoopSource, clickRunLoopSource].compactMap { $0 }
        let taps = [tap, createdClickTap].compactMap { $0 }
        let thread = Thread {
            for source in sources {
                CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
            }
            for tap in taps {
                CGEvent.tapEnable(tap: tap, enable: true)
            }
            CFRunLoopRun()
        }
        thread.name = "EventMonitor"
        thread.qualityOfService = .userInteractive
        thread.start()
        tapThread = thread
    }

    func stop() {
        for tap in [eventTap, clickTap].compactMap({ $0 }) {
            CGEvent.tapEnable(tap: tap, enable: false)
        }
        tapThread?.cancel()
    }

    /// Keep the click tap's region in step with the session: the reading
    /// panel while a session is open, nothing otherwise.
    private func observeSession() {
        let clickCapture = clickCapture
        sessionObserver = MainActor.assumeIsolated {
            appState.$mode.combineLatest(appState.$overlayRegion)
                .sink { mode, textRegion in
                    let region = ClickCapture.region(
                        isReading: mode == .active, textRegion: textRegion
                    )
                    clickCapture.withLock { $0 = $0.withRegion(region) }
                }
        }
    }

    // MARK: - C callback

    private static let eventCallback: CGEventTapCallBack = {
        proxy, type, event, refcon in
        guard let refcon else { return Unmanaged.passUnretained(event) }
        let monitor = Unmanaged<EventMonitor>.fromOpaque(refcon).takeUnretainedValue()

        // Re-enable if the system disabled the tap
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            for tap in [monitor.eventTap, monitor.clickTap].compactMap({ $0 }) {
                CGEvent.tapEnable(tap: tap, enable: true)
            }
            return Unmanaged.passUnretained(event)
        }

        // Decide before reacting: the reaction may end the session, and the
        // decision must reflect the panel as it was when the click happened.
        let keptFromPage = monitor.keepsFromPage(type: type, event: event)
        monitor.handleEvent(type: type, event: event)
        return keptFromPage ? nil : Unmanaged.passUnretained(event)
    }

    /// Whether this event is a click on the reading panel that Slit acts on
    /// itself, and so must not also reach the page underneath.
    private func keepsFromPage(type: CGEventType, event: CGEvent) -> Bool {
        let phase: ClickCapture.Phase
        switch type {
        case .leftMouseDown: phase = .down
        case .leftMouseDragged: phase = .dragged
        case .leftMouseUp: phase = .up
        default: return false
        }
        let point = event.location
        let optionHeld = event.flags.contains(.maskAlternate)
        return clickCapture.withLock { capture in
            let result = capture.after(phase, at: point, optionHeld: optionHeld)
            capture = result.next
            return result.keepsEvent
        }
    }

    // MARK: - Event handling

    private func handleEvent(type: CGEventType, event: CGEvent) {
        switch type {
        case .flagsChanged:
            handleFlagsChanged(event: event)
        case .mouseMoved:
            handleMouseMoved(event: event)
        case .leftMouseDown:
            handleMouseDown(event: event)
        case .keyDown:
            handleKeyDown(event: event)
        case .scrollWheel:
            handleScroll(event: event)
        default:
            break
        }
    }

    /// Scrolling moves text under the debug overlay, leaving its boxes stale.
    ///
    /// Trackpads emit a burst of momentum events after the fingers lift, so a
    /// plain debounce would fire repeatedly as the scroll coasts. Instead, mark
    /// the overlay stale while anything is moving and only re-detect when the
    /// gesture truly finishes: momentum ended, or — for devices that send no
    /// momentum at all, like a mouse wheel — a short quiet period.
    private func handleScroll(event: CGEvent) {
        let point = event.location
        // 0=none 1=began 2=changed 4=ended 8=cancelled 128=mayBegin
        let scrollPhase = event.getIntegerValueField(.scrollWheelEventScrollPhase)
        // 0=none 1=begin 2=continue 3=end
        let momentumPhase = event.getIntegerValueField(.scrollWheelEventMomentumPhase)

        let momentumFinished = momentumPhase == 3
        let coasting = momentumPhase == 1 || momentumPhase == 2
        // A touch gesture that ended without any momentum (slow drag, or a
        // finger-down stop) still settles the content.
        let gestureEnded = scrollPhase == 4 || scrollPhase == 8

        if Self.logScrollPhases {
            print("[scroll] scrollPhase=\(scrollPhase) momentumPhase=\(momentumPhase)")
        }

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            if self.appState.mode == .selecting {
                self.hoverPreview.contentMoved(at: point)
            }
            self.areaPreview.contentMoved()
            guard self.appState.debugBlocksVisible else { return }

            if momentumFinished || (gestureEnded && !coasting) {
                // Settled — refresh promptly.
                self.scheduleDebugRefresh(at: point, state: self.appState, delayMs: 50)
            } else {
                // Still moving. Keep the overlay faded, and arm a fallback for
                // devices that never report a phase (classic mouse wheels).
                self.appState.debugStale = true
                self.scheduleDebugRefresh(at: point, state: self.appState, delayMs: 220)
            }
        }
    }

    private func handleFlagsChanged(event: CGEvent) {
        let commandHeld = event.flags.contains(.maskCommand)
        let optionHeld = event.flags.contains(.maskAlternate)
        let shiftHeld = event.flags.contains(.maskShift)
        let state = appState
        let mousePoint = event.location

        DispatchQueue.main.async {
            // --- Command: single-paragraph picker (click to choose) ---
            // React to the edge, not the level: flagsChanged also fires when a
            // *different* modifier changes while ⌘ is still down, and reading
            // that as a fresh press ended the session the click just started.
            let commandPressed = commandHeld && !self.commandWasDown
            let commandReleased = !commandHeld && self.commandWasDown
            self.commandWasDown = commandHeld

            if commandPressed {
                if state.mode == .idle {
                    state.beginSelecting()
                    // ⌘ goes down a beat before the click: use it to warm the
                    // capture path so detection starts from a hot cache.
                    ScreenCapture.prewarm()
                    self.hoverPreview.begin(at: mousePoint)
                } else if state.mode == .active {
                    state.deactivate()
                }
            } else if commandReleased {
                self.hoverPreview.cancel()
                if case .selecting = state.mode, state.optionAreaStart == nil {
                    state.deactivate()
                }
            }

            // --- Shift: debug selection preview (diagnostic only) ---
            // After the mode logic above, so it observes the settled mode
            // rather than racing it.
            self.updateDebugBlocks(enabled: shiftHeld, at: mousePoint, state: state)

            // --- Option: drag-area selector (only if enabled in settings) ---
            guard AppSettings.shared.dragSelectEnabled else { return }
            let canStartArea = state.mode == .active || state.mode == .selecting || state.mode == .idle
            if optionHeld {
                if canStartArea && state.optionAreaStart == nil {
                    if state.mode == .idle {
                        state.beginSelecting()
                    }
                    // A drag-area gesture replaces the single-paragraph preview.
                    self.hoverPreview.cancel()
                    state.optionAreaStart = mousePoint
                    state.optionAreaCurrent = mousePoint
                    self.areaPreview.begin(at: mousePoint)
                }
            } else {
                self.areaPreview.cancel()
                if let start = state.optionAreaStart {
                    let endPoint = state.optionAreaCurrent ?? mousePoint
                    let movedFar = abs(endPoint.y - start.y) > 8 || abs(endPoint.x - start.x) > 8
                    let wasActive = state.mode == .active
                    state.optionAreaStart = nil
                    state.optionAreaCurrent = nil

                    if movedFar {
                        Task {
                            if wasActive {
                                await self.detectAndAddArea(from: start, to: endPoint, state: state)
                            } else {
                                await self.detectAndActivateArea(from: start, to: endPoint, state: state)
                            }
                        }
                    } else if !wasActive {
                        state.deactivate()
                    }
                }
            }
        }
    }

    private func handleMouseMoved(event: CGEvent) {
        let location = event.location
        let hopAlreadyPending = pendingMouseLocation.withLock { pending -> Bool in
            defer { pending = location }
            return pending != nil
        }
        guard !hopAlreadyPending else { return }

        let state = appState
        let pendingMouseLocation = pendingMouseLocation

        DispatchQueue.main.async {
            let latest = pendingMouseLocation.withLock { pending -> CGPoint? in
                defer { pending = nil }
                return pending
            }
            guard let point = latest else { return }
            state.mousePosition = point

            if state.mode == .selecting {
                self.hoverPreview.pointerMoved(to: point)
            }

            // Debug preview follows the cursor — it shows what a click *here*
            // would select, which changes as the pointer moves.
            if state.debugBlocksVisible {
                state.updateDebugSelection(at: point)
            }

            // If a drag area is being defined, track it
            if state.optionAreaStart != nil {
                state.optionAreaCurrent = point
                self.areaPreview.pointerMoved(to: point)
            }

            if state.mode == .active {
                // Don't move the slit while dragging an area.
                // (updateActiveLine is a no-op in manual word-reveal mode, which
                // is click-driven — the cursor never moves the slit there.)
                if state.optionAreaStart == nil {
                    state.updateActiveLine(mouseY: point.y)
                }
            }
        }
    }

    /// Detect text in the area between two points and add it to the selection.
    @MainActor
    private func detectAndAddArea(from start: CGPoint, to end: CGPoint, state: AppState) async {
        let midPoint = CGPoint(x: (start.x + end.x) / 2, y: (start.y + end.y) / 2)
        let generation = state.detectionGeneration
        let blocks = await TextDetector.detectBlocks(near: midPoint)
        // The session may have ended, or restarted, while OCR ran.
        guard state.detectionGeneration == generation else { return }
        state.addAreaToSelection(lines: blocks.flatMap(\.lines), from: start, to: end)
    }

    /// Start a brand new selection from an Option-drag area (no prior selection).
    @MainActor
    private func detectAndActivateArea(from start: CGPoint, to end: CGPoint, state: AppState) async {
        let midPoint = CGPoint(x: (start.x + end.x) / 2, y: (start.y + end.y) / 2)
        state.beginDetecting(at: midPoint)
        let generation = state.detectionGeneration
        let blocks = await TextDetector.detectBlocks(near: midPoint)
        guard state.detectionGeneration == generation, state.mode == .detecting else { return }

        state.detectedBlocks = blocks
        state.activateArea(lines: blocks.flatMap(\.lines), from: start, to: end)
        if state.mode == .active {
            state.updateActiveLine(mouseY: end.y)
        }
    }

    private func handleMouseDown(event: CGEvent) {
        let point = event.location
        let optionHeld = event.flags.contains(.maskAlternate)
        let state = appState

        DispatchQueue.main.async {
            // The click decides; the preview has done its job.
            self.hoverPreview.cancel()

            // Click cancels any in-progress drag area gesture
            self.areaPreview.cancel()
            state.optionAreaStart = nil
            state.optionAreaCurrent = nil

            switch state.mode {
            case .selecting:
                state.beginDetecting(at: point)
                Task {
                    await self.detectAndActivate(at: point, state: state)
                }

            case .active:
                // Option + click anywhere → add another paragraph to the selection
                if optionHeld {
                    Task {
                        await self.detectAndAddToSelection(at: point, state: state)
                    }
                    return
                }

                // The same area whose clicks are kept from the page.
                let panel = ClickCapture.panelRegion(around: state.overlayRegion)
                if panel.contains(point) {
                    if AppSettings.shared.manualWordModeEnabled {
                        // Manual mode: each click reveals the next word; a click
                        // once the line is fully shown skips to the next line.
                        state.revealNextWordOrAdvance()
                    } else {
                        // Click inside the overlay → advance to next line
                        state.advanceToNextLine()
                    }
                } else {
                    // Click outside → deactivate
                    state.deactivate()
                }

            case .detecting, .idle:
                break
            }
        }
    }

    private func handleKeyDown(event: CGEvent) {
        let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
        let state = appState

        DispatchQueue.main.async {
            // A key pressed while ⌘ is held makes this a shortcut (⌘C, ⌘Tab),
            // not a selection: drop the preview for the rest of this press.
            if state.mode == .selecting {
                self.hoverPreview.cancel()
            }

            // Debug overlay owns the arrow keys while it is up, for tuning the
            // paragraph-break threshold live.
            if state.debugBlocksVisible {
                switch keyCode {
                case 124: // Right arrow — merge more (larger paragraphs)
                    self.adjustBreakSensitivity(by: 0.1, state: state)
                    return
                case 123: // Left arrow — split more (smaller paragraphs)
                    self.adjustBreakSensitivity(by: -0.1, state: state)
                    return
                case 53: // Escape dismisses the overlay
                    self.hideDebugOverlay(state)
                    return
                default:
                    break
                }
            }

            // Escape cancels a stuck/slow detection as well as an active session.
            if keyCode == 53, state.mode == .detecting {
                state.deactivate()
                return
            }

            guard state.mode == .active else { return }

            switch keyCode {
            case 125: // Down arrow
                state.advanceToNextLine()
            case 126: // Up arrow
                state.advanceToPreviousLine()
            case 53: // Escape
                state.deactivate()
            default:
                break
            }
        }
    }

    // MARK: - Debug paragraph outlines

    /// Tap Shift → toggle the debug overlay on; tap again to dismiss it.
    /// Diagnostic only: it never changes `mode`, so it can be used at any time
    /// without disturbing an active reading session.
    @MainActor
    private func updateDebugBlocks(
        enabled: Bool, at point: CGPoint, state: AppState
    ) {
        guard AppSettings.shared.debugOverlayEnabled else {
            if state.debugBlocksVisible {
                hideDebugOverlay(state)
            }
            shiftWasDown = false
            return
        }

        // Toggle on the press edge only. flagsChanged fires for both press and
        // release, so without this the overlay would flip twice per tap and
        // land back where it started.
        let pressed = enabled && !shiftWasDown
        shiftWasDown = enabled
        guard pressed else { return }

        if state.debugBlocksVisible {
            hideDebugOverlay(state)
            return
        }

        state.debugBlocksVisible = true
        state.debugBlocks = []
        runDebugDetection(at: point, state: state)
    }

    /// Detect and populate the debug overlay. Cancels any in-flight run.
    @MainActor
    private func runDebugDetection(at point: CGPoint, state: AppState) {
        debugDetectionTask?.cancel()
        debugDetectionTask = Task { @MainActor in
            let result = await TextDetector.detectEverything(near: point)
            guard !Task.isCancelled else { return }
            // May have been toggled back off while detection ran.
            if state.debugBlocksVisible {
                state.debugBlocks = result.blocks
                state.computeDebugLines(from: result.allLines, chromeBand: result.chromeBand)
                state.computeAllDebugSelections()
                state.updateDebugSelection(at: point)
            }
            debugDetectionTask = nil
        }
    }

    /// Re-detect after scrolling settles. Each new scroll event replaces the
    /// pending refresh, so a continuous scroll triggers one OCR pass at the end
    /// rather than one per tick.
    ///
    /// `delayMs` is short when the gesture has demonstrably ended, and longer
    /// when it is used as a quiet-period fallback for input devices that report
    /// no scroll phase.
    @MainActor
    private func scheduleDebugRefresh(
        at point: CGPoint, state: AppState, delayMs: Int
    ) {
        // Boxes no longer match the content the moment it moves.
        state.debugStale = true
        debugRefreshTask?.cancel()
        debugRefreshTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(delayMs))
            guard !Task.isCancelled, state.debugBlocksVisible else { return }
            state.debugStale = false
            runDebugDetection(at: point, state: state)
            debugRefreshTask = nil
        }
    }

    /// Nudge the paragraph-break threshold and re-cluster immediately, so the
    /// outlines re-split live as the value changes.
    @MainActor
    private func adjustBreakSensitivity(by delta: Double, state: AppState) {
        let settings = AppSettings.shared
        let updated = (settings.paragraphBreakSensitivity + delta)
            .clamped(to: 1.0...5.0)
        // Avoid a redundant re-detect when already at an end stop.
        guard updated != settings.paragraphBreakSensitivity else { return }
        settings.paragraphBreakSensitivity = updated

        // Re-cluster the lines we already have rather than re-running OCR —
        // only the grouping threshold changed, not what is on screen.
        state.recomputeDebugClustering(sensitivity: updated)
    }

    @MainActor
    private func hideDebugOverlay(_ state: AppState) {
        state.debugBlocksVisible = false
        state.debugBlocks = []
        state.debugAllSelections = []
        state.debugAllLines = []
        state.debugStale = false
        state.debugSelectionRect = nil
        state.debugSelectionLineCount = 0
        debugDetectionTask?.cancel()
        debugDetectionTask = nil
        debugRefreshTask?.cancel()
        debugRefreshTask = nil
    }

    @MainActor
    private func detectAndActivate(at point: CGPoint, state: AppState) async {
        let generation = state.detectionGeneration

        // Detect all text blocks on screen
        let blocks = await TextDetector.detectBlocks(near: point)

        // OCR takes long enough for the user to press Escape or click again.
        // A result that arrives after that must not open the overlay.
        guard state.detectionGeneration == generation, state.mode == .detecting else { return }
        state.detectedBlocks = blocks

        // Find the block closest to / containing the click point
        if let block = TextDetector.findBlock(at: point, from: blocks) {
            state.activate(block: block)
            state.updateActiveLine(mouseY: point.y)
        } else {
            Self.log.info("No text blocks detected near click point")
            // The usual reason nothing was found is that Slit may not look at
            // the screen at all. Say so, rather than silently doing nothing.
            Permissions.shared.refresh()
            if !Permissions.shared.screenRecording {
                PermissionsWindowController.shared.show()
            }
            // Must return to idle, not just clear isDetecting — `mode` drives the
            // loading indicator, and .detecting swallows clicks and the Escape
            // key, so leaving it set traps the user in a permanent spinner.
            state.deactivate()
        }
    }

    /// Option+click while active — detect a paragraph at the click point and
    /// add it to the existing selection.
    @MainActor
    private func detectAndAddToSelection(at point: CGPoint, state: AppState) async {
        let generation = state.detectionGeneration
        let blocks = await TextDetector.detectBlocks(near: point)
        guard state.detectionGeneration == generation else { return }
        if let block = TextDetector.findBlock(at: point, from: blocks) {
            state.addToSelection(block: block, from: blocks, near: point)
        }
    }
}
