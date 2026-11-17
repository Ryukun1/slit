import AppKit
import CoreGraphics
import Foundation
import ScreenCaptureKit

/// Screen capture via ScreenCaptureKit.
///
/// `CGWindowListCreateImage` was deprecated in macOS 14 and obsoleted in macOS 15;
/// on macOS 15+ it returns nil at runtime regardless of Screen Recording
/// permission, so every capture path in the app goes through here instead.
///
/// Slit's own windows are always excluded — otherwise the dim overlay would be
/// captured on top of the content we are trying to read.
enum ScreenCapture {

    /// Capture `region` (global screen coordinates, origin top-left).
    ///
    /// - Parameter scale: pixel density multiplier. Defaults to the display's
    ///   native backing scale so captures stay sharp on Retina screens; pass a
    ///   smaller value only when the result is not displayed to the user.
    /// - Returns: the captured image, or nil if capture failed for any reason.
    /// Set `SLIT_TIMING=1` in the environment to log capture timings.
    private static let logTimings =
        ProcessInfo.processInfo.environment["SLIT_TIMING"] == "1"

    static func region(_ region: CGRect, scale: CGFloat? = nil) async -> CGImage? {
        guard region.width > 1, region.height > 1 else { return nil }

        let started = Date()
        defer {
            if logTimings {
                let ms = Date().timeIntervalSince(started) * 1000
                print(String(format: "[timing] capture %.0fx%.0f took %.0fms",
                             region.width, region.height, ms))
            }
        }

        do {
            let contentStart = Date()
            let content = try await shareableContent()
            if logTimings {
                let ms = Date().timeIntervalSince(contentStart) * 1000
                print(String(format: "[timing]   shareableContent %.0fms", ms))
            }

            guard let display = display(containing: region, in: content.displays)
                    ?? content.displays.first else {
                print("ScreenCapture: no display available")
                return nil
            }

            let filter = SCContentFilter(
                display: display,
                excludingWindows: ownWindows(in: content)
            )

            let scale = scale ?? backingScale(for: display)

            // sourceRect is display-local, origin top-left.
            let local = CGRect(
                x: region.origin.x - display.frame.origin.x,
                y: region.origin.y - display.frame.origin.y,
                width: region.width,
                height: region.height
            ).intersection(CGRect(origin: .zero, size: display.frame.size))

            guard !local.isNull, local.width > 1, local.height > 1 else {
                print("ScreenCapture: region outside display bounds")
                return nil
            }

            let config = SCStreamConfiguration()
            config.sourceRect = local
            config.width = Int(local.width * scale)
            config.height = Int(local.height * scale)
            config.captureResolution = .best
            config.showsCursor = false
            config.ignoreGlobalClipDisplay = true

            return try await SCScreenshotManager.captureImage(
                contentFilter: filter, configuration: config
            )
        } catch {
            print("ScreenCapture failed: \(error.localizedDescription)")
            return nil
        }
    }

    // MARK: - Shareable content cache

    /// `SCShareableContent` enumerates every window on the system, which costs
    /// tens of milliseconds. Capture sites often fire in bursts (one per text
    /// line), so a short-lived cache keeps a burst to a single enumeration
    /// while staying fresh enough to track window changes between gestures.
    private actor ContentCache {
        private var cached: SCShareableContent?
        private var fetchedAt: Date?
        private var inFlight: Task<SCShareableContent, Error>?

        private static let ttl: TimeInterval = 1.0

        func content() async throws -> SCShareableContent {
            if let cached, let fetchedAt,
               Date().timeIntervalSince(fetchedAt) < Self.ttl {
                return cached
            }

            // Coalesce concurrent misses into one enumeration.
            if let inFlight { return try await inFlight.value }

            let task = Task {
                try await SCShareableContent.excludingDesktopWindows(
                    false, onScreenWindowsOnly: true
                )
            }
            inFlight = task
            defer { inFlight = nil }

            let result = try await task.value
            cached = result
            fetchedAt = Date()
            return result
        }

        func invalidate() {
            cached = nil
            fetchedAt = nil
        }
    }

    private static let cache = ContentCache()

    private static func shareableContent() async throws -> SCShareableContent {
        try await cache.content()
    }

    /// Start enumerating shareable content now, so the capture that follows a
    /// click finds it cached instead of paying for it. Call when a selection
    /// gesture begins (⌘ goes down a beat before the click lands).
    static func prewarm() {
        Task.detached(priority: .userInitiated) {
            _ = try? await shareableContent()
        }
    }

    /// Drop the cached window list — call when a capture must reflect the
    /// screen exactly as it is right now.
    static func invalidateCache() async {
        await cache.invalidate()
    }

    // MARK: - Helpers

    private static func display(
        containing region: CGRect, in displays: [SCDisplay]
    ) -> SCDisplay? {
        let mid = CGPoint(x: region.midX, y: region.midY)
        return displays.first { $0.frame.contains(mid) }
    }

    /// Native backing scale for a display (2 on Retina, 1 otherwise).
    private static func backingScale(for display: SCDisplay) -> CGFloat {
        let screen = NSScreen.screens.first {
            ($0.deviceDescription[.init("NSScreenNumber")] as? CGDirectDisplayID)
                == display.displayID
        }
        return screen?.backingScaleFactor ?? 2
    }

    private static func ownWindows(in content: SCShareableContent) -> [SCWindow] {
        let ownPID = ProcessInfo.processInfo.processIdentifier
        return content.windows.filter {
            $0.owningApplication?.processID == ownPID
        }
    }
}
