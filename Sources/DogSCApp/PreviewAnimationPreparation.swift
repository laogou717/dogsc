import Foundation
import RecorderCore

/// One animation sampling contract for the native display loop and its CPU
/// plan cache. The paused/export evaluators are deliberately not quantized.
enum PreviewAnimationCadence {
    static let framesPerSecond = 60

    static func sampleTime(_ time: TimeInterval) -> TimeInterval {
        let safe = time.isFinite ? max(time, 0) : 0
        return (safe * Double(framesPerSecond)).rounded() / Double(framesPerSecond)
    }
}

enum PreviewAnimationPreparation {
    struct Interval {
        let start: TimeInterval
        let end: TimeInterval
        let entryDuration: TimeInterval
        var isOpening = false
    }

    static func intervals(using evaluation: CanvasPlaybackEvaluationContext) -> [Interval] {
        var result: [Interval] = []
        let opening = evaluation.project.openingSequence
        if opening.isEnabled {
            result.append(Interval(start: 0, end: opening.duration,
                                   entryDuration: opening.duration, isOpening: true))
        }
        result += evaluation.zoomTrack.animations.map {
            Interval(start: $0.startTime, end: $0.effectEndTime,
                     entryDuration: min($0.effectEndTime - $0.startTime, 0.6))
        }
        result += evaluation.screenMotionTrack.clips.map {
            Interval(start: $0.timing.startTime, end: $0.timing.effectEndTime,
                     entryDuration: $0.timing.leadInDuration)
        }
        result += evaluation.cameraMotionTrack.clips.map {
            Interval(start: $0.timing.startTime, end: $0.timing.effectEndTime,
                     entryDuration: $0.timing.leadInDuration)
        }
        result += evaluation.project.timeline.mosaicClips.map {
            Interval(start: $0.timing.startTime, end: $0.timing.endTime,
                     entryDuration: $0.transitionInDuration)
        }
        result += evaluation.project.timeline.stickerClips.map {
            Interval(start: $0.timing.startTime, end: $0.timing.endTime,
                     entryDuration: $0.enterDuration)
        }
        return result
    }

    /// Sample the nearest real combined graphs, including opening phases in
    /// which staggered camera/stickers are visible. Evaluating the complete
    /// project at each timestamp naturally includes overlapping effects.
    static func prewarmTimes(
        around time: TimeInterval,
        using evaluation: CanvasPlaybackEvaluationContext
    ) -> [TimeInterval] {
        let now = min(max(time.isFinite ? time : 0, 0), evaluation.outputDuration)
        let horizon = min(now + 8, evaluation.outputDuration)
        var times: [TimeInterval] = []
        for interval in intervals(using: evaluation)
            .filter({ $0.end > now && $0.start <= horizon })
            .sorted(by: { $0.start < $1.start }) {
            let end = min(interval.end, evaluation.outputDuration)
            let remainingStart = max(now, interval.start)
            guard end > remainingStart else { continue }
            let offset = max(min(interval.entryDuration * 0.5,
                                 (end - interval.start) * 0.5), 1.0 / 60)
            times.append(min(max(now, interval.start + offset), end - 0.001))
            if interval.isOpening {
                times.append(min(max(now, interval.start + (end - interval.start) * 0.82),
                                 end - 0.001))
            }
        }
        return Array(Set(times.filter { $0 >= 0 && $0 <= horizon })).sorted().prefix(4).map { $0 }
    }
}
