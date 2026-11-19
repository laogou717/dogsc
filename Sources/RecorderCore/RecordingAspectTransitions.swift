import Foundation

/// The canvas stays fixed while a recording card settles to the next source's
/// own aspect in 240 ms, only between compatible mockups. The source pixels
/// still use contain fitting. This
/// value is shared by live preview and export, with no wall-clock animation.
public struct RecordingAspectTransitions: Equatable, Sendable {
    public static let duration: TimeInterval = 0.240

    private struct Transition: Equatable, Sendable {
        let start: TimeInterval
        let from: Double
        let to: Double
        func value(at time: TimeInterval) -> Double {
            let x = min(max((time - start) / RecordingAspectTransitions.duration, 0), 1)
            let eased = x * x * (3 - 2 * x)
            return from + (to - from) * eased
        }
    }

    private struct Span: Equatable, Sendable {
        let start: TimeInterval
        let end: TimeInterval
        let sourceID: UUID
        let cropAspect: Double
        let transition: Transition
    }
    private var spans: [Span] = []

    /// `crops` is keyed by recording, `segmentCrops` by occurrence: a clip that
    /// opted out of following its recording is framed by the latter, so the
    /// aspect this table morphs to has to come from the same authority the
    /// renderer samples with. Pass `project.segmentCrops`.
    public init(primary: TimelineMediaPlan, sourceAspectRatios: [UUID: Double], crops: [UUID: NormalizedCrop],
                frameStyles: [UUID: ScreenFrameStyle] = [:],
                segmentStyles: [UUID: SegmentSceneStyle] = [:],
                segmentCrops: [UUID: NormalizedCrop] = [:]) {
        var previousSourceID: UUID?
        var previousFrame: ScreenFrameStyle = .none
        var previousAspect: Double?
        var transition: Transition?
        for slice in primary.slices {
            guard slice.media == nil, let aspect = sourceAspectRatios[slice.sourceID],
                  aspect.isFinite, aspect > 0 else {
                previousSourceID = nil
                transition = nil
                continue
            }
            let scene = segmentStyles[slice.segmentID]
            let frame = scene?.canvas.screenFrame ?? frameStyles[slice.sourceID] ?? .none
            let crop = (segmentCrops[slice.segmentID] ?? crops[slice.sourceID] ?? .full).clamped()
            let croppedAspect = aspect * crop.width / crop.height
            if previousSourceID == nil {
                transition = Transition(start: slice.outputStart, from: croppedAspect, to: croppedAspect)
            } else if previousSourceID != slice.sourceID || previousFrame != frame || previousAspect != croppedAspect {
                // A short intervening clip can end before its morph finishes.
                // Start the next morph at that presented value, not its target.
                let compatible = Self.canTransition(
                    from: previousFrame, to: frame)
                transition = Transition(start: slice.outputStart,
                    from: compatible ? (transition?.value(at: slice.outputStart) ?? croppedAspect) : croppedAspect,
                    to: croppedAspect)
            }
            if let transition {
                spans.append(Span(start: slice.outputStart, end: slice.outputEnd, sourceID: slice.sourceID,
                    cropAspect: crop.width / crop.height, transition: transition))
            }
            previousSourceID = slice.sourceID
            previousFrame = frame
            previousAspect = croppedAspect
        }
    }

    private static func canTransition(from previous: ScreenFrameStyle, to next: ScreenFrameStyle) -> Bool {
        guard previous != .none, next != .none else { return false }
        return (previous.isDeviceFrame && next.isDeviceFrame)
            || (previous.isWindowFrame && next.isWindowFrame)
            || (previous.isBrowserFrame && next.isBrowserFrame)
    }

    /// Returns the uncropped aspect consumed by the scene evaluator. The
    /// evaluator applies this source's crop once, just as it does at rest.
    public func sourceAspectRatio(atOutputTime time: TimeInterval, sourceID: UUID?) -> Double? {
        guard time.isFinite, let sourceID else { return nil }
        var lower = 0, upper = spans.count
        while lower < upper {
            let middle = (lower + upper) / 2
            if spans[middle].start <= time { lower = middle + 1 } else { upper = middle }
        }
        guard lower > 0 else { return nil }
        let span = spans[lower - 1]
        guard span.sourceID == sourceID, time < span.end else { return nil }
        return span.transition.value(at: time) / span.cropAspect
    }
}
