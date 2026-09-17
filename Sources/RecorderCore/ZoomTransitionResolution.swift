import Foundation

public extension ZoomAnimationClip {
    var requestedEnterDuration: TimeInterval { preferredEnterDuration ?? enterDuration }

    func requestedExitDuration(defaultTransition: TimeInterval = 0.7) -> TimeInterval {
        preferredExitDuration ?? (exitDuration > 0.000_1 ? exitDuration : max(defaultTransition, 0))
    }

    mutating func preserveTransitionIntent(defaultTransition: TimeInterval = 0.7) {
        if preferredEnterDuration == nil { preferredEnterDuration = enterDuration }
        if preferredExitDuration == nil {
            preferredExitDuration = requestedExitDuration(defaultTransition: defaultTransition)
        }
    }
}

/// Shared by the inspector, preview and export. Project-authored ranges remain
/// intact when the output tail is trimmed, so restoring media does not destroy
/// hidden animation content. Only the evaluated windows are fitted to the end.
public enum ZoomTransitionResolution {
    public static func resolve(
        _ animations: [ZoomAnimationClip],
        outputDuration: TimeInterval
    ) -> [ZoomAnimationClip] {
        guard outputDuration.isFinite, outputDuration > 0 else { return [] }
        let ordered = animations.filter { $0.startTime < outputDuration && $0.duration > 0.001 }
            .sorted { $0.startTime == $1.startTime ? $0.id.uuidString < $1.id.uuidString : $0.startTime < $1.startTime }
        return ordered.enumerated().map { index, authored in
            var clip = authored
            let next = ordered.indices.contains(index + 1) ? ordered[index + 1] : nil
            let requestedEnter = max(clip.requestedEnterDuration, 0)
            let requestedExit = max(clip.requestedExitDuration(), 0)
            if let next {
                let gap = max(next.startTime - clip.endTime, 0)
                clip.exitDuration = gap <= ZoomInterpolator.adjacencyTolerance
                    ? 0 : min(requestedExit, gap)
            } else {
                let available = max(outputDuration - clip.startTime, 0)
                // A short final zoom reserves a real entrance and return. For
                // a longer zoom only its final hold is shortened, never the
                // requested transition stored in the project.
                let exit = min(requestedExit, max(available - min(requestedEnter, available * 0.5), 0))
                clip.endTime = min(clip.endTime, outputDuration - exit)
                if clip.endTime < authored.endTime - 0.000_001 {
                    clip.exitProgressOffset = 0
                }
                clip.exitDuration = min(requestedExit, max(outputDuration - clip.endTime, 0))
            }
            clip.enterDuration = min(requestedEnter, clip.duration)
            return clip
        }
    }
}
