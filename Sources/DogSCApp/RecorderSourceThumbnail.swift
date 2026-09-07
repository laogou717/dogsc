import AppKit
import ScreenCaptureKit

/// Small, transient previews of the actual chosen source. No disk cache and
/// no capture loop: each selection requests one frame, excluding our overlays.
@MainActor
enum RecorderSourceThumbnail {
    static func image(displayID: UInt32? = nil, windowID: UInt32? = nil) async -> NSImage? {
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            try Task.checkCancellation()
            let filter: SCContentFilter
            let size: CGSize
            if let windowID, let window = content.windows.first(where: { $0.windowID == windowID }) {
                filter = SCContentFilter(desktopIndependentWindow: window)
                size = window.frame.size
            } else if let displayID, let display = content.displays.first(where: { $0.displayID == displayID }) {
                let ownApps = content.applications.filter { $0.processID == getpid() }
                filter = SCContentFilter(display: display, excludingApplications: ownApps, exceptingWindows: [])
                size = display.frame.size
            } else { return nil }
            let config = SCStreamConfiguration()
            config.width = 256
            config.height = max(2, Int(256 * size.height / max(size.width, 1)))
            config.showsCursor = false
            config.scalesToFit = true
            let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
            try Task.checkCancellation()
            return NSImage(cgImage: image, size: CGSize(width: image.width, height: image.height))
        } catch { return nil }
    }
}
