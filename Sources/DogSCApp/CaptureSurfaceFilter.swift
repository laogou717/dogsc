import AppKit
import RecorderCore
import ScreenCaptureKit

/// One policy for initial capture, visibility controls and editor appearance.
/// The exception API includes windows of excluded apps and excludes windows of
/// other apps: editor exceptions and Finder desktop exclusions can coexist.
@MainActor
struct CaptureSurfaceFilter {
    let filter: SCContentFilter
    let editorWindowIDs: Set<UInt32>

    init(content: SCShareableContent, display: SCDisplay, configuration: CaptureConfiguration) {
        var excludedApplications = content.applications.filter { $0.processID == getpid() }
        if configuration.hidesDock {
            excludedApplications.append(contentsOf: content.applications.filter {
                $0.bundleIdentifier == "com.apple.dock"
            })
        }

        let editorWindows = content.windows.filter {
            $0.owningApplication?.processID == getpid()
                && CaptureEditorWindows.shared.includes($0.windowID)
        }
        editorWindowIDs = Set(editorWindows.map(\.windowID))
        var exceptingWindows = editorWindows
        if configuration.hidesDesktopFiles {
            let desktopIDs = Self.finderDesktopWindowIDs()
            exceptingWindows.append(contentsOf: content.windows.filter {
                desktopIDs.contains($0.windowID)
            })
        }

        filter = SCContentFilter(
            display: display,
            excludingApplications: excludedApplications,
            exceptingWindows: exceptingWindows
        )
    }

    private static func finderDesktopWindowIDs() -> Set<CGWindowID> {
        guard let descriptions = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly], kCGNullWindowID
        ) as? [[String: Any]] else { return [] }
        return Set(descriptions.compactMap { description in
            let ownerPID = (description[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value ?? 0
            let bundleIdentifier = NSRunningApplication(processIdentifier: ownerPID)?.bundleIdentifier
            let layer = (description[kCGWindowLayer as String] as? NSNumber)?.intValue ?? 0
            guard bundleIdentifier == "com.apple.finder", layer < 0,
                  let number = description[kCGWindowNumber as String] as? NSNumber else { return nil }
            return CGWindowID(number.uint32Value)
        })
    }
}
