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

struct CrossDisplayWindowRestoreState: Equatable {
    private(set) var generation: UInt64 = 0

    mutating func begin() -> UInt64 {
        generation &+= 1
        return generation
    }

    mutating func invalidate() {
        generation &+= 1
    }

    func shouldOrderFront(
        generation requestedGeneration: UInt64,
        isVisible: Bool,
        purposeIsActive: Bool
    ) -> Bool {
        generation == requestedGeneration && isVisible && purposeIsActive
    }
}

let cameraPreviewWindowIdentifier = NSUserInterfaceItemIdentifier(
    "cn.laogou.dogsc.camera-preview"
)

enum CrossDisplayWindowPurpose: Equatable {
    case recorderPanel(phase: AppPhase)
    case cameraPreview

    @MainActor
    func isActive(for window: NSWindow) -> Bool {
        switch self {
        case let .recorderPanel(phase):
            guard window.identifier == recorderMainWindowIdentifier,
                  let panel = window as? RecorderPanel else { return false }
            return panel.presentedPhase == phase
        case .cameraPreview:
            return window.identifier == cameraPreviewWindowIdentifier
        }
    }
}

/// Owns only the one-run-loop restoration after an AppKit drag. It restores
/// collection behavior for the newest drag, but never resurrects a hidden or
/// semantically obsolete window.
@MainActor
final class CrossDisplayWindowDragRestorer {
    private var state = CrossDisplayWindowRestoreState()

    func performDrag(
        window: NSWindow,
        event: NSEvent,
        purpose: CrossDisplayWindowPurpose
    ) {
        let originalBehavior = window.collectionBehavior
        var dragBehavior = originalBehavior
        dragBehavior.remove(.canJoinAllSpaces)
        window.collectionBehavior = dragBehavior
        let generation = state.begin()
        window.performDrag(with: event)

        RunLoop.main.perform { [self, weak window] in
            MainActor.assumeIsolated {
                guard let window, state.generation == generation else { return }
                window.collectionBehavior = originalBehavior
                window.contentView?.needsDisplay = true
                guard state.shouldOrderFront(
                    generation: generation,
                    isVisible: window.isVisible,
                    purposeIsActive: purpose.isActive(for: window)
                ) else { return }
                window.orderFrontRegardless()
            }
        }
    }
}
