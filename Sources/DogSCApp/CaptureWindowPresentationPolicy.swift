import AppKit

enum CaptureWindowPresentationRole: Equatable {
    case selectionOverlay
    case recordingGuideOverlay
    case recorderPanel(phase: AppPhase, selectionActive: Bool)
}

/// The only owner of capture-window level arithmetic. Selection and recording
/// guides share one overlay band; the interactive recorder bar stays above it
/// for selection, preparation and recording.
enum CaptureWindowLevelPolicy {
    private static let overlayLevel = NSWindow.Level(
        rawValue: NSWindow.Level.floating.rawValue + 1
    )
    private static let activeRecorderLevel = NSWindow.Level(
        rawValue: NSWindow.Level.floating.rawValue + 2
    )

    static func level(for role: CaptureWindowPresentationRole) -> NSWindow.Level {
        switch role {
        case .selectionOverlay, .recordingGuideOverlay:
            overlayLevel
        case let .recorderPanel(phase, selectionActive):
            switch phase {
            case .setup where selectionActive:
                activeRecorderLevel
            case .preparing, .recording:
                activeRecorderLevel
            case .setup, .finishing, .editor:
                .floating
            }
        }
    }
}

enum CaptureOverlayScreenPolicy {
    static func keyScreenIndex(
        pointer: CGPoint,
        screenFrames: [CGRect]
    ) -> Int? {
        screenFrames.firstIndex(where: { $0.contains(pointer) })
            ?? screenFrames.indices.first
    }

    static func largestIntersectionIndex(
        targetFrame: CGRect,
        screenFrames: [CGRect]
    ) -> Int? {
        var bestIndex: Int?
        var bestArea: CGFloat = 0
        for index in screenFrames.indices {
            let intersection = targetFrame.intersection(screenFrames[index])
            guard !intersection.isNull, !intersection.isEmpty else { continue }
            let area = intersection.width * intersection.height
            if area > bestArea {
                bestArea = area
                bestIndex = index
            }
        }
        return bestIndex
    }
}

let cameraPreviewWindowIdentifier = NSUserInterfaceItemIdentifier(
    "cn.laogou.dogsc.camera-preview"
)
