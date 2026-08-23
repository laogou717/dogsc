import Foundation
import RecorderCore

/// Immutable result of the CPU-heavy pointer work performed after all capture
/// tracks have stopped. Keeping this outside AppModel makes it safe to execute
/// on a detached user-initiated task without publishing half-finished editor
/// state through MainActor.
struct RecordingPointerFinalizationResult: Equatable, Sendable {
    let events: [PointerEventRecord]
    let automaticZoomAnimations: [ZoomAnimationClip]
}

enum RecordingPointerFinalization {
    nonisolated static func prepare(
        events: [PointerEventRecord],
        startOffset: TimeInterval,
        sourceStartTime: TimeInterval,
        createsAutomaticZooms: Bool,
        easing: ZoomEasingPreset,
        transitionDuration: TimeInterval
    ) throws -> RecordingPointerFinalizationResult {
        try Task.checkCancellation()
        let aligned = PointerTimelineAlignment.align(
            events,
            startOffset: startOffset,
            sourceStartTime: sourceStartTime
        )
        try Task.checkCancellation()
        let animations = AutoZoomPlanner.makeAnimations(
            for: createsAutomaticZooms ? aligned : [],
            easing: easing,
            transitionDuration: transitionDuration
        )
        try Task.checkCancellation()
        return RecordingPointerFinalizationResult(
            events: aligned,
            automaticZoomAnimations: animations
        )
    }

    nonisolated static func persist(
        _ events: [PointerEventRecord],
        session: RecordingSession
    ) throws {
        try Task.checkCancellation()
        try ProjectStore.savePointerEvents(events, session: session)
        try Task.checkCancellation()
    }
}
