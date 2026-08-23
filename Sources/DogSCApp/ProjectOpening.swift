import Foundation
import RecorderCore

/// A fully resolved project payload. Loading happens before AppModel publishes
/// any of these values, so the editor cannot observe mixed project/media state.
struct ProjectOpenSnapshot: Sendable {
    let normalizedURL: URL
    let session: RecordingSession
    let project: RecorderProject
    let recordingURL: URL?
    let cameraRecordingURL: URL?
    let microphoneRecordingURL: URL?
    let pointerEvents: [PointerEventRecord]
    let wasInterrupted: Bool
    let warnings: [String]

    var isSaved: Bool {
        !ProjectStore.isWorkingProject(normalizedURL)
    }

    static func load(at packageURL: URL) throws -> ProjectOpenSnapshot {
        try Task.checkCancellation()
        let normalizedURL = packageURL.lastPathComponent == "project.json"
            ? packageURL.deletingLastPathComponent()
            : packageURL
        let wasInterrupted = ProjectStore.isRecoverableProject(at: normalizedURL)
        let loaded = try ProjectStore.loadProject(at: normalizedURL)
        var project = loaded.project
        try Task.checkCancellation()
        if case let .bundledImage(relativePath) = project.canvas.backgroundSource,
           BundledWallpaperLibrary.resolve(relativePath: relativePath) == nil {
            project.canvas.backgroundSource = .defaultBundledImage
        }

        let recordingURL = ProjectStore.resolve(
            relativePath: project.media?.screen.relativePath,
            session: loaded.session
        )
        // The automatically generated timestamp proxy did not restore real
        // lip sync and must not silently remain the project's source. Migrate
        // projects that autosaved that temporary path back to the untouched
        // camera recording before exposing the manual alignment workflow.
        if var camera = project.media?.camera,
           camera.relativePath.hasSuffix("-timestamp-repaired.mov") {
            let originalRelativePath = String(
                camera.relativePath.dropLast("-timestamp-repaired.mov".count)
            ) + ".mov"
            if ProjectStore.resolve(
                relativePath: originalRelativePath,
                session: loaded.session
            ) != nil {
                camera.relativePath = originalRelativePath
                camera.sourceTimeScale = nil
                camera.sourceEndTime = nil
                project.media?.camera = camera
            }
        }
        let cameraRecordingURL = ProjectStore.resolve(
            relativePath: project.media?.camera?.relativePath,
            session: loaded.session
        )
        let microphoneRecordingURL = ProjectStore.resolve(
            relativePath: project.media?.microphone?.relativePath,
            session: loaded.session
        )

        var warnings: [String] = []
        if project.media == nil {
            warnings.append("项目没有主录屏素材引用。")
        } else if recordingURL == nil {
            warnings.append("项目引用的主录屏素材不存在或路径无效。")
        }
        if project.media?.camera != nil, cameraRecordingURL == nil {
            warnings.append("项目引用的摄像头素材不存在或路径无效。")
        }
        if project.media?.microphone != nil, microphoneRecordingURL == nil {
            warnings.append("项目引用的麦克风素材不存在或路径无效。")
        }

        let pointerEvents: [PointerEventRecord]
        do {
            pointerEvents = try ProjectStore.loadPointerEvents(
                project: project,
                session: loaded.session
            )
        } catch {
            pointerEvents = []
            warnings.append("鼠标事件轨损坏：\(error.localizedDescription)")
        }

        try Task.checkCancellation()
        // Legacy repair can compare a complete automatic zoom track against
        // hundreds of thousands of pointer events. It belongs to the immutable
        // background snapshot, not the AppKit main-actor publication step.
        let originalMotion = project.motion
        let originalAutomaticTrack = project.zoomAnimations
        let regroupedAutomaticTrack = AutoZoomPlanner.repairingLegacyAutomaticAnimations(
            originalAutomaticTrack,
            for: pointerEvents,
            easing: originalMotion.defaultZoomEasing,
            transitionDuration: originalMotion.defaultZoomTransitionDuration
        )
        let upgradedMotion = LegacyMotionDefaultsUpgrade.upgraded(originalMotion)
        project.motion = upgradedMotion
        if regroupedAutomaticTrack != originalAutomaticTrack,
           upgradedMotion.defaultZoomEasing != originalMotion.defaultZoomEasing {
            project.zoomAnimations = regroupedAutomaticTrack.map { clip in
                var upgraded = clip
                if upgraded.origin == .automatic,
                   upgraded.easing == originalMotion.defaultZoomEasing {
                    upgraded.easing = upgradedMotion.defaultZoomEasing
                }
                return upgraded
            }
        } else {
            project.zoomAnimations = regroupedAutomaticTrack
        }
        project.timeline = ProjectTimelineEditing.repairingPersistedRippleTransitions(
            project.timeline,
            defaultTransitionDuration: project.motion.defaultZoomTransitionDuration
        )
        try Task.checkCancellation()

        return ProjectOpenSnapshot(
            normalizedURL: normalizedURL,
            session: loaded.session,
            project: project,
            recordingURL: recordingURL,
            cameraRecordingURL: cameraRecordingURL,
            microphoneRecordingURL: microphoneRecordingURL,
            pointerEvents: pointerEvents,
            wasInterrupted: wasInterrupted,
            warnings: warnings
        )
    }
}
