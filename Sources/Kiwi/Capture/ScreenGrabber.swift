import AppKit
import ScreenCaptureKit

/// Thin wrapper around ScreenCaptureKit's one-shot screenshot API.
@MainActor
enum ScreenGrabber {
    static var hasPermission: Bool { CGPreflightScreenCaptureAccess() }

    /// Triggers the system prompt the first time; afterwards it is a no-op.
    @discardableResult
    static func requestPermission() -> Bool { CGRequestScreenCaptureAccess() }

    private static func shareableContent() async throws -> SCShareableContent {
        try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
    }

    /// Display list fetched while the user is still dragging a selection, so
    /// the capture itself starts the moment the mouse is released.
    private static var warm: (content: SCShareableContent, date: Date)?

    static func prewarm() {
        Task { @MainActor in
            if let content = try? await shareableContent() {
                warm = (content, Date())
            }
        }
    }

    private static func recentContent() async throws -> SCShareableContent {
        if let warm, Date().timeIntervalSince(warm.date) < 20 {
            return warm.content
        }
        return try await shareableContent()
    }

    /// Captures a display, or a part of it.
    /// - Parameter rect: Area in the display's own point space, origin at its top-left. Nil captures everything.
    static func captureDisplay(
        _ displayID: CGDirectDisplayID,
        rect: CGRect?,
        showCursor: Bool
    ) async throws -> (image: CGImage, scale: CGFloat) {
        // Area captures reuse the prewarmed list; full-screen captures fetch a fresh one.
        var content = try await (rect == nil ? shareableContent() : recentContent())
        if !content.displays.contains(where: { $0.displayID == displayID }) {
            content = try await shareableContent()
        }
        warm = nil
        guard let display = content.displays.first(where: { $0.displayID == displayID }) else {
            throw KiwiError("That display is no longer available.")
        }

        let setup = try regionSetup(display: display, content: content, rect: rect, showCursor: showCursor)
        let image = try await SCScreenshotManager.captureImage(
            contentFilter: setup.filter, configuration: setup.configuration
        )
        return (image, setup.scale)
    }

    /// Filter and configuration for capturing part of a display without Kiwi's own windows.
    static func regionSetup(
        display: SCDisplay,
        content: SCShareableContent,
        rect: CGRect?,
        showCursor: Bool
    ) throws -> (filter: SCContentFilter, configuration: SCStreamConfiguration, scale: CGFloat, area: CGRect) {
        // Leave Kiwi's own windows (overlay, preview, toast, borders) out of the picture.
        let ownPID = ProcessInfo.processInfo.processIdentifier
        let kiwi = content.applications.filter { $0.processID == ownPID }
        let filter = SCContentFilter(display: display, excludingApplications: kiwi, exceptingWindows: [])
        let scale = CGFloat(filter.pointPixelScale)

        let full = CGRect(x: 0, y: 0, width: CGFloat(display.width), height: CGFloat(display.height))
        let area = (rect ?? full).intersection(full)
        guard area.width >= 1, area.height >= 1 else {
            throw KiwiError("The selected area is empty.")
        }

        let configuration = SCStreamConfiguration()
        configuration.sourceRect = area
        configuration.width = Int((area.width * scale).rounded())
        configuration.height = Int((area.height * scale).rounded())
        configuration.showsCursor = showCursor
        configuration.captureResolution = .best
        configuration.scalesToFit = false
        return (filter, configuration, scale, area)
    }

    /// Fresh display lookup for long-running sessions (scrolling capture, recording).
    static func locateDisplay(_ displayID: CGDirectDisplayID) async throws -> (display: SCDisplay, content: SCShareableContent) {
        let content = try await shareableContent()
        guard let display = content.displays.first(where: { $0.displayID == displayID }) else {
            throw KiwiError("That display is no longer available.")
        }
        return (display, content)
    }

    /// Prepares repeated captures of the same region.
    static func makeRegionGrabber(_ displayID: CGDirectDisplayID, rect: CGRect) async throws -> RegionGrabber {
        let found = try await locateDisplay(displayID)
        let setup = try regionSetup(display: found.display, content: found.content, rect: rect, showCursor: false)
        return RegionGrabber(filter: setup.filter, configuration: setup.configuration, scale: setup.scale)
    }

    /// Captures a single window with a transparent background and no shadow.
    static func captureWindow(_ windowID: CGWindowID) async throws -> (image: CGImage, scale: CGFloat) {
        let content = try await shareableContent()
        guard let window = content.windows.first(where: { $0.windowID == windowID }) else {
            throw KiwiError("That window is no longer available.")
        }

        let filter = SCContentFilter(desktopIndependentWindow: window)
        let scale = CGFloat(filter.pointPixelScale)
        let size = filter.contentRect.size

        let configuration = SCStreamConfiguration()
        configuration.width = Int((size.width * scale).rounded())
        configuration.height = Int((size.height * scale).rounded())
        configuration.showsCursor = false
        configuration.ignoreShadowsSingleWindow = true
        configuration.captureResolution = .best

        let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
        return (image, scale)
    }
}

/// Captures the same region again and again with one prepared filter.
@MainActor
final class RegionGrabber {
    let scale: CGFloat
    private let filter: SCContentFilter
    private let configuration: SCStreamConfiguration

    init(filter: SCContentFilter, configuration: SCStreamConfiguration, scale: CGFloat) {
        self.filter = filter
        self.configuration = configuration
        self.scale = scale
    }

    func grab() async throws -> CGImage {
        try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
    }
}
