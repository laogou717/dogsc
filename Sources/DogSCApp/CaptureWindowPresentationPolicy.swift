import AppKit
import RecorderCore

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

/// Geometry for selection cards that belong to the recorder bar. The full-screen
/// selector remains one level below the recorder controls, while the card is
/// centred on the complete recorder bar and attached above/below it. Anchoring
/// to the individual source button made Display and Device cards visibly drift
/// left because those buttons live at the bar's leading edge.
enum CaptureSelectionCardPlacement {
    static let edgeInset: CGFloat = 16
    static let attachmentGap: CGFloat = 12

    static func globalCenter(
        anchorFrame: CGRect?,
        cardSize: CGSize,
        visibleFrame: CGRect
    ) -> CGPoint {
        let safeFrame = visibleFrame.insetBy(dx: edgeInset, dy: edgeInset)
        guard let anchorFrame, !anchorFrame.isNull, !anchorFrame.isEmpty else {
            return CGPoint(x: visibleFrame.midX, y: visibleFrame.midY)
        }

        let halfWidth = cardSize.width / 2
        let halfHeight = cardSize.height / 2
        let minCenterX = safeFrame.minX + halfWidth
        let maxCenterX = safeFrame.maxX - halfWidth
        let centerX = clamp(
            anchorFrame.midX,
            lower: minCenterX,
            upper: maxCenterX
        )

        let belowY = anchorFrame.minY - attachmentGap - halfHeight
        let aboveY = anchorFrame.maxY + attachmentGap + halfHeight
        let minCenterY = safeFrame.minY + halfHeight
        let maxCenterY = safeFrame.maxY - halfHeight

        let centerY: CGFloat
        if belowY >= minCenterY {
            centerY = belowY
        } else if aboveY <= maxCenterY {
            centerY = aboveY
        } else {
            centerY = clamp(
                belowY,
                lower: minCenterY,
                upper: maxCenterY
            )
        }
        return CGPoint(x: centerX, y: centerY)
    }

    static func localCenter(
        anchorFrame: CGRect?,
        cardSize: CGSize,
        screenFrame: CGRect,
        visibleFrame: CGRect
    ) -> CGPoint {
        let global = globalCenter(
            anchorFrame: anchorFrame,
            cardSize: cardSize,
            visibleFrame: visibleFrame
        )
        return CGPoint(
            x: global.x - screenFrame.minX,
            y: screenFrame.maxY - global.y
        )
    }

    private static func clamp(
        _ value: CGFloat,
        lower: CGFloat,
        upper: CGFloat
    ) -> CGFloat {
        guard lower <= upper else { return (lower + upper) / 2 }
        return min(max(value, lower), upper)
    }
}

enum RecorderCaptureSourceAccessibilityID {
    static let display = "recorder.capture-source.display"
    static let window = "recorder.capture-source.window"
    static let area = "recorder.capture-source.area"
    static let device = "recorder.capture-source.device"

    static func value(for source: CaptureSource) -> String {
        switch source {
        case .display: display
        case .window: window
        case .area: area
        case .device: device
        }
    }
}

@MainActor
enum RecorderCaptureSourceAnchorResolver {
    static var recorderWindow: NSWindow? {
        NSApplication.shared.windows.first {
            $0.identifier == recorderMainWindowIdentifier
        }
    }

    static var recorderFrame: CGRect? {
        guard let frame = recorderWindow?.frame,
              !frame.isNull,
              !frame.isEmpty else { return nil }
        return frame
    }

    static func screenFrame(for source: CaptureSource) -> CGRect? {
        guard let window = recorderWindow,
              let contentView = window.contentView,
              let sourceView = descendant(
                  in: contentView,
                  identifier: NSUserInterfaceItemIdentifier(
                      RecorderCaptureSourceAccessibilityID.value(for: source)
                  )
              ) else { return nil }
        let windowRect = sourceView.convert(sourceView.bounds, to: nil as NSView?)
        return window.convertToScreen(windowRect)
    }

    private static func descendant(
        in view: NSView,
        identifier: NSUserInterfaceItemIdentifier
    ) -> NSView? {
        if view.identifier == identifier { return view }
        for subview in view.subviews {
            if let match = descendant(in: subview, identifier: identifier) {
                return match
            }
        }
        return nil
    }
}

let cameraPreviewWindowIdentifier = NSUserInterfaceItemIdentifier(
    "cn.laogou.dogsc.camera-preview"
)
