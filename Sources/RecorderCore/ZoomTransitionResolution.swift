import Foundation

public extension ZoomAnimationClip {
    var requestedEnterDuration: TimeInterval { preferredEnterDuration ?? enterDuration }

    func requestedExitDuration(defaultTransition: TimeInterval = 0.7) -> TimeInterval {
        let requested = preferredExitDuration ?? (exitDuration > 0.000_1 ? exitDuration : max(defaultTransition, 0))
        // Repair only legacy automatic sub-frame returns. New explicit fast
        // transitions and manual animation durations remain exact.
        if transitionIntentVersion == 0, origin == .automatic,
           requested > 0, requested < 1.0 / 30.0 {
            return max(defaultTransition, 0)
        }
        return requested
    }

    mutating func preserveTransitionIntent(defaultTransition: TimeInterval = 0.7) {
        let exit = requestedExitDuration(defaultTransition: defaultTransition)
        if preferredEnterDuration == nil { preferredEnterDuration = enterDuration }
        preferredExitDuration = exit
        transitionIntentVersion = 1
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
        let sorted = animations.filter { $0.startTime < outputDuration && $0.duration > 0.001 }
            .sorted { $0.startTime == $1.startTime ? $0.id.uuidString < $1.id.uuidString : $0.startTime < $1.startTime }
        // An isolated automatic entrance reduced by a cut to less than two
        // 60 Hz frames must not squeeze a full push-in into that fragment.
        // Keep the authored data, but omit its flash from the evaluated track.
        let ordered = sorted.enumerated().compactMap { index, clip -> ZoomAnimationClip? in
            let continues = index > 0 && abs(sorted[index - 1].endTime - clip.startTime) <= ZoomInterpolator.adjacencyTolerance
            if clip.origin == .automatic, !continues, clip.enterProgressOffset == 0,
               clip.duration < min(clip.requestedEnterDuration, 1.0 / 30.0) { return nil }
            return clip
        }
        return ordered.enumerated().map { index, authored in
            var clip = authored
            let next = ordered.indices.contains(index + 1) ? ordered[index + 1] : nil
            let requestedEnter = max(clip.requestedEnterDuration, 0)
            let requestedExit = max(clip.requestedExitDuration(), 0)
            if let next {
                let gap = max(next.startTime - clip.endTime, 0)
                if clip.origin == .automatic, next.origin == .automatic,
                   gap > 0, gap < 1.0 / 60.0, requestedExit > gap {
                    clip.endTime = next.startTime
                    clip.exitDuration = 0
                } else {
                    clip.exitDuration = gap <= ZoomInterpolator.adjacencyTolerance
                    ? 0 : min(requestedExit, gap)
                }
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
