import Foundation
import RecorderCore

extension SharedPreviewEngine {
    /// Prepare exact upcoming clip starts, rather than polling arbitrary future
    /// times which can miss a short graphic. At most three future resources
    /// share the editor's existing lookahead allowance with the active clips.
    func prewarmMotions(at time: TimeInterval) {
        guard time < lastMotionWarmTime || time - lastMotionWarmTime >= 0.25,
              let provider = playbackFrameProvider else { return }
        lastMotionWarmTime = time
        var scenes: [(FrameScene, UUID?)] = []
        for start in motionStarts where start.time >= time && start.time <= time + 2 {
            let tick = EditorPlaybackRenderTick(mediaGeneration: renderTick?.mediaGeneration ?? 0,
                discontinuityID: renderTick?.discontinuityID ?? 0, outputTime: start.time,
                itemTime: .zero, cameraIsAvailable: false, isPlaying: true)
            scenes.append((provider(tick).semanticScene, start.segmentID))
            if scenes.count == 3 { break }
        }
        warmedAnimationIDs.removeAll(keepingCapacity: true)
        warmedMainIDs.removeAll(keepingCapacity: true)
        let active = Set(semanticScene?.animations.map(\.id) ?? [])
        for (scene, segmentID) in scenes {
            if scene.insertedMotion != nil, let segmentID,
               warmedAnimationIDs.count + warmedMainIDs.count < 3 { warmedMainIDs.insert(segmentID) }
            for animation in scene.animations where !active.contains(animation.id)
                && warmedAnimationIDs.count + warmedMainIDs.count < 3 {
                warmedAnimationIDs.insert(animation.id)
            }
        }
        for (scene, segmentID) in scenes {
            for animation in scene.animations where warmedAnimationIDs.contains(animation.id) {
                _ = animationResource(animation, in: scene)
            }
            if let segmentID, warmedMainIDs.contains(segmentID) {
                _ = insertedMotionResource(for: scene, segmentID: segmentID)
            }
        }
    }
}
