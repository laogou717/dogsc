import Foundation

/// Cheap validation gates for immutable playback-track construction. Authored
/// editor arrays normally stay in deterministic start-time order and drag
/// constraints prevent clips from crossing neighbours. Reusing that input
/// avoids sorting and allocating another full array for every interaction
/// draft; malformed/legacy input still takes the original repair path.
enum TimelineTrackOrdering {
    static func zoomAnimationsNeedRepair(_ animations: [ZoomAnimationClip]) -> Bool {
        for (index, animation) in animations.enumerated() {
            guard animation.duration > 0.001 else { return true }
            if index > animations.startIndex,
               zoomPrecedes(animation, animations[index - 1]) {
                return true
            }
        }
        return false
    }

    static func screenMotionClipsNeedRepair(_ clips: [ScreenMotionClip]) -> Bool {
        motionClipsNeedRepair(clips) { ($0.id, $0.timing.startTime) }
    }

    static func cameraMotionClipsNeedRepair(_ clips: [CameraMotionClip]) -> Bool {
        motionClipsNeedRepair(clips) { ($0.id, $0.timing.startTime) }
    }

    private static func motionClipsNeedRepair<Element>(
        _ clips: [Element],
        identity: (Element) -> (id: UUID, startTime: TimeInterval)
    ) -> Bool {
        guard clips.count > 1 else { return false }
        for index in clips.indices.dropFirst() {
            let current = identity(clips[index])
            let previous = identity(clips[index - 1])
            if current.startTime < previous.startTime
                || (
                    current.startTime == previous.startTime
                        && current.id.uuidString < previous.id.uuidString
                ) {
                return true
            }
        }
        return false
    }

    private static func zoomPrecedes(
        _ lhs: ZoomAnimationClip,
        _ rhs: ZoomAnimationClip
    ) -> Bool {
        lhs.startTime == rhs.startTime
            ? lhs.id.uuidString < rhs.id.uuidString
            : lhs.startTime < rhs.startTime
    }
}
