import Foundation
import RecorderCore

struct PrimarySegmentTrimDraft: Equatable {
    let segmentID: UUID
    let edge: RecordingSegmentTrimEdge
    let original: ResolvedRecordingSegment
    /// Stable restoration limits captured once when the pointer gesture starts.
    /// They do not change while the draft moves, so the hot path must not scan
    /// the entire project again for every mouse event.
    let minimumOutputTime: TimeInterval
    let maximumOutputTime: TimeInterval
    var proposedOutputTime: TimeInterval

    init(
        segmentID: UUID,
        edge: RecordingSegmentTrimEdge,
        original: ResolvedRecordingSegment,
        minimumOutputTime: TimeInterval? = nil,
        maximumOutputTime: TimeInterval? = nil,
        proposedOutputTime: TimeInterval
    ) {
        self.segmentID = segmentID
        self.edge = edge
        self.original = original
        self.minimumOutputTime = minimumOutputTime ?? original.outputStart
        self.maximumOutputTime = maximumOutputTime ?? original.outputEnd
        self.proposedOutputTime = proposedOutputTime
    }
}

struct EditorTimelineSegmentJunction: Equatable, Identifiable {
    let previousSegmentID: UUID
    let nextSegmentID: UUID
    let outputTime: TimeInterval
    let removedSourceStart: TimeInterval
    let removedDuration: TimeInterval

    /// A junction survives layout/ripple changes as long as its right-hand
    /// retained segment survives.
    var id: UUID { nextSegmentID }

    var hasRemovedSourceGap: Bool {
        removedDuration > 1.0 / 120_000.0
    }
}

struct EditorTimelineLeadingGap: Equatable, Identifiable {
    let nextSegmentID: UUID
    let removedDuration: TimeInterval

    var id: UUID { nextSegmentID }
    var outputTime: TimeInterval { 0 }
}

struct EditorTimelineTrailingGap: Equatable, Identifiable {
    let previousSegmentID: UUID
    let outputTime: TimeInterval
    let removedDuration: TimeInterval

    var id: UUID { previousSegmentID }
}

/// Pure presentation decisions for the primary-recording lane. Keeping this
/// separate from SwiftUI makes ripple layout, trim previews, and pointer-clock
/// conversion testable without launching an editor window.
enum EditorPrimaryTimelinePresentation {
    static func leadingGap(from map: TimelineMap) -> EditorTimelineLeadingGap? {
        guard let first = map.segments.first,
              map.segments.allSatisfy({
                  $0.id == first.id || $0.sourceStart >= first.sourceStart
              }),
              first.sourceStart > 1.0 / 120_000.0 else { return nil }
        return EditorTimelineLeadingGap(
            nextSegmentID: first.id,
            removedDuration: first.sourceStart
        )
    }

    static func trailingGap(from map: TimelineMap) -> EditorTimelineTrailingGap? {
        guard let last = map.segments.last,
              map.segments.allSatisfy({
                  $0.id == last.id || $0.sourceEnd <= last.sourceEnd
              }) else { return nil }
        let removedDuration = map.fullSourceDuration - last.sourceEnd
        guard removedDuration > 1.0 / 120_000.0 else { return nil }
        return EditorTimelineTrailingGap(
            previousSegmentID: last.id,
            outputTime: map.outputDuration,
            removedDuration: removedDuration
        )
    }

    static func segmentJunctions(from map: TimelineMap) -> [EditorTimelineSegmentJunction] {
        guard map.segments.count > 1 else { return [] }
        return zip(map.segments, map.segments.dropFirst()).compactMap { previous, next in
            // A reversed/reordered seam is a real edit boundary but cannot be
            // merged or filled with a forward source interval.
            guard next.sourceStart >= previous.sourceEnd - 1.0 / 120_000.0 else {
                return nil
            }
            return EditorTimelineSegmentJunction(
                previousSegmentID: previous.id,
                nextSegmentID: next.id,
                outputTime: previous.outputEnd,
                removedSourceStart: previous.sourceEnd,
                removedDuration: max(next.sourceStart - previous.sourceEnd, 0)
            )
        }
    }

    static func timelineMap(
        fullSourceDuration: TimeInterval,
        project: RecorderProject
    ) throws -> TimelineMap {
        try TimelineMap(
            sourceSequence: project.timeline.sourceSequence,
            fullSourceDuration: fullSourceDuration
        )
    }

    static func displaySegments(
        from map: TimelineMap,
        trimDraft: PrimarySegmentTrimDraft?
    ) -> [ResolvedRecordingSegment] {
        guard let trimDraft,
              map.segments.contains(where: { $0.id == trimDraft.segmentID })
        else { return map.segments }

        var outputStart: TimeInterval = 0
        return map.segments.map { segment in
            var sourceStart = segment.sourceStart
            var sourceDuration = segment.sourceDuration
            if segment.id == trimDraft.segmentID {
                switch trimDraft.edge {
                case .left:
                    let removedDuration = trimDraft.proposedOutputTime - segment.outputStart
                    sourceStart += removedDuration
                    sourceDuration -= removedDuration
                    // Ripple trim keeps the authored edit point contiguous:
                    // the trimmed clip starts where the preceding clip ends,
                    // and every following clip shifts by the removed/inserted
                    // duration. The hover guide still follows the pointer, so
                    // the draft can match the exact post-commit geometry
                    // without jumping left on mouse-up.
                case .right:
                    sourceDuration = trimDraft.proposedOutputTime - segment.outputStart
                }
            }
            let displayed = ResolvedRecordingSegment(
                id: segment.id,
                sourceStart: sourceStart,
                sourceDuration: max(sourceDuration, 0),
                outputStart: outputStart
            )
            outputStart += displayed.sourceDuration
            return displayed
        }
    }

    /// Capture the source material available immediately before and after one
    /// authored segment. This is intentionally paid once at gesture start;
    /// subsequent pointer updates reuse the limits stored in the draft.
    static func trimDraftOrigin(
        segmentID: UUID,
        edge: RecordingSegmentTrimEdge,
        map: TimelineMap,
        fullSourceDuration: TimeInterval
    ) -> PrimarySegmentTrimDraft? {
        guard let segment = map.segments.first(where: { $0.id == segmentID }) else {
            return nil
        }
        let epsilon = 0.000_001
        var previousSourceEnd: TimeInterval = 0
        var nextSourceStart = fullSourceDuration
        for candidate in map.segments where candidate.id != segmentID {
            if candidate.sourceEnd <= segment.sourceStart + epsilon {
                previousSourceEnd = max(previousSourceEnd, candidate.sourceEnd)
            }
            if candidate.sourceStart >= segment.sourceEnd - epsilon {
                nextSourceStart = min(nextSourceStart, candidate.sourceStart)
            }
        }
        let minimumOutputTime = segment.outputStart
            - max(segment.sourceStart - previousSourceEnd, 0)
        let maximumOutputTime = segment.outputEnd
            + max(nextSourceStart - segment.sourceEnd, 0)
        return PrimarySegmentTrimDraft(
            segmentID: segmentID,
            edge: edge,
            original: segment,
            minimumOutputTime: minimumOutputTime,
            maximumOutputTime: maximumOutputTime,
            proposedOutputTime: edge == .left ? segment.outputStart : segment.outputEnd
        )
    }

    /// Mapped click events are ordered by output time. During a ripple-trim
    /// preview the displayed segments remain one continuous output interval,
    /// so a pair of binary boundaries exactly replaces the former nested
    /// event-by-segment scan.
    static func pointerClicks(
        _ clicks: [PointerEventRecord],
        beforeOutputEnd outputEnd: TimeInterval
    ) -> [PointerEventRecord] {
        guard outputEnd.isFinite, outputEnd > 0, !clicks.isEmpty else { return [] }

        func firstIndex(atOrAfter time: TimeInterval) -> Int {
            var lower = clicks.startIndex
            var upper = clicks.endIndex
            while lower < upper {
                let middle = lower + (upper - lower) / 2
                if clicks[middle].time < time {
                    lower = middle + 1
                } else {
                    upper = middle
                }
            }
            return lower
        }

        let lower = firstIndex(atOrAfter: 0)
        let upper = firstIndex(atOrAfter: outputEnd)
        if lower == clicks.startIndex, upper == clicks.endIndex { return clicks }
        return Array(clicks[lower..<upper])
    }

    /// Segment output starts form an ordered boundary index. Preserve the
    /// existing rule (the first segment boundary inside 7 pt wins; playback is
    /// the fallback) without allocating and scanning every endpoint.
    static func snappedCutX(
        pointerX: CGFloat,
        width: CGFloat,
        duration: TimeInterval,
        segments: [ResolvedRecordingSegment],
        playbackTime: TimeInterval,
        tolerance: CGFloat = 7
    ) -> CGFloat {
        guard pointerX.isFinite,
              width.isFinite, width > 0,
              duration.isFinite, duration > 0 else { return pointerX }
        let safeTolerance = max(tolerance.isFinite ? tolerance : 0, 0)
        let lowerTime = duration * Double((pointerX - safeTolerance) / width)
        let upperX = pointerX + safeTolerance

        var lower = segments.startIndex
        var upper = segments.endIndex
        while lower < upper {
            let middle = lower + (upper - lower) / 2
            if segments[middle].outputStart < lowerTime {
                lower = middle + 1
            } else {
                upper = middle
            }
        }
        if lower < segments.endIndex {
            let boundaryX = width * CGFloat(segments[lower].outputStart / duration)
            if boundaryX <= upperX { return boundaryX }
        } else if let finalEnd = segments.last?.outputEnd {
            let boundaryX = width * CGFloat(finalEnd / duration)
            if boundaryX >= pointerX - safeTolerance,
               boundaryX <= upperX {
                return boundaryX
            }
        }

        let playbackX = width * CGFloat(playbackTime / duration)
        if playbackX.isFinite, abs(playbackX - pointerX) <= safeTolerance {
            return playbackX
        }
        return pointerX
    }

    static func trimOutputTime(
        for segment: ResolvedRecordingSegment,
        edge: RecordingSegmentTrimEdge,
        translation: CGFloat,
        laneWidth: CGFloat,
        outputDuration: TimeInterval,
        minimumSegmentDuration: TimeInterval,
        minimumOutputTime: TimeInterval? = nil,
        maximumOutputTime: TimeInterval? = nil
    ) -> TimeInterval {
        guard laneWidth.isFinite, laneWidth > 0,
              outputDuration.isFinite, outputDuration > 0 else {
            return edge == .left ? segment.outputStart : segment.outputEnd
        }
        let delta = TimeInterval(translation / laneWidth) * outputDuration
        let retainedDuration = min(
            max(minimumSegmentDuration, 0.000_001),
            segment.sourceDuration
        )
        switch edge {
        case .left:
            let lower = min(minimumOutputTime ?? segment.outputStart, segment.outputStart)
            return min(
                max(segment.outputStart + delta, lower),
                segment.outputEnd - retainedDuration
            )
        case .right:
            let upper = max(maximumOutputTime ?? segment.outputEnd, segment.outputEnd)
            return max(
                min(segment.outputEnd + delta, upper),
                segment.outputStart + retainedDuration
            )
        }
    }

    /// Keep pointer-drag preview on the already-installed composition. The
    /// leading edge shows the first retained frame; the trailing edge shows
    /// the final retained frame. Restoring material outside the current media
    /// plan stays on its nearest existing boundary until the one final commit
    /// installs the expanded plan.
    static func trimPreviewTime(
        for draft: PrimarySegmentTrimDraft,
        frameDuration: TimeInterval
    ) -> TimeInterval {
        let original = draft.original
        let frame = max(
            frameDuration.isFinite ? frameDuration : 0,
            1.0 / 120_000.0
        )
        let lastVisibleFrame = max(
            original.outputEnd - frame,
            original.outputStart
        )
        switch draft.edge {
        case .left:
            return min(
                max(draft.proposedOutputTime, original.outputStart),
                lastVisibleFrame
            )
        case .right:
            return min(
                max(draft.proposedOutputTime - frame, original.outputStart),
                lastVisibleFrame
            )
        }
    }

    /// Resolve a trim directly from the pointer's absolute position in the
    /// timeline document. Unlike a handle-local translation, this coordinate
    /// does not move when the segment being trimmed changes its own frame.
    static func trimOutputTime(
        for segment: ResolvedRecordingSegment,
        edge: RecordingSegmentTrimEdge,
        pointerX: CGFloat,
        laneWidth: CGFloat,
        outputDuration: TimeInterval,
        minimumSegmentDuration: TimeInterval,
        minimumOutputTime: TimeInterval? = nil,
        maximumOutputTime: TimeInterval? = nil
    ) -> TimeInterval {
        guard laneWidth.isFinite, laneWidth > 0,
              pointerX.isFinite,
              outputDuration.isFinite, outputDuration > 0 else {
            return edge == .left ? segment.outputStart : segment.outputEnd
        }
        let pointerTime = TimeInterval(pointerX / laneWidth) * outputDuration
        let retainedDuration = min(
            max(minimumSegmentDuration, 0.000_001),
            segment.sourceDuration
        )
        switch edge {
        case .left:
            let lower = min(minimumOutputTime ?? segment.outputStart, segment.outputStart)
            return min(
                max(pointerTime, lower),
                segment.outputEnd - retainedDuration
            )
        case .right:
            let upper = max(maximumOutputTime ?? segment.outputEnd, segment.outputEnd)
            return max(
                min(pointerTime, upper),
                segment.outputStart + retainedDuration
            )
        }
    }

    static func mappedPointerClicks(
        sourceEvents: [PointerEventRecord],
        map: TimelineMap
    ) -> [PointerEventRecord] {
        map.mapPointerEventSegments(sourceEvents)
            .flatMap(\.events)
            .filter { $0.kind == .leftClick || $0.kind == .rightClick }
    }
}

/// Immutable time anchor used while SwiftUI changes the document width. A
/// burst of wheel events may arrive before NSScrollView has laid out even the
/// first new width, so the semantic time under the pointer—not a stale pixel
/// offset—must survive across the whole burst.
struct EditorTimelineZoomAnchor: Equatable {
    let contentFraction: CGFloat
    let viewportX: CGFloat
    let targetContentWidth: CGFloat

    init(
        pointerViewportX: CGFloat,
        contentOffsetX: CGFloat,
        contentWidth: CGFloat,
        targetContentWidth: CGFloat
    ) {
        let safeWidth = max(contentWidth, 1)
        contentFraction = min(
            max((contentOffsetX + pointerViewportX) / safeWidth, 0),
            1
        )
        viewportX = max(pointerViewportX, 0)
        self.targetContentWidth = max(targetContentWidth, 1)
    }

    private init(
        contentFraction: CGFloat,
        viewportX: CGFloat,
        targetContentWidth: CGFloat
    ) {
        self.contentFraction = contentFraction
        self.viewportX = viewportX
        self.targetContentWidth = max(targetContentWidth, 1)
    }

    func retargeting(contentWidth: CGFloat) -> EditorTimelineZoomAnchor {
        EditorTimelineZoomAnchor(
            contentFraction: contentFraction,
            viewportX: viewportX,
            targetContentWidth: contentWidth
        )
    }

    func scrollOffset(viewportWidth: CGFloat) -> CGFloat {
        let maximumOffset = max(targetContentWidth - max(viewportWidth, 0), 0)
        return min(
            max(contentFraction * targetContentWidth - viewportX, 0),
            maximumOffset
        )
    }
}

/// A trackpad can deliver several wheel/magnify events inside one display
/// frame. Applying every event immediately makes SwiftUI rebuild the complete
/// timeline and resizes NSScrollView several times before any of those frames
/// can be shown. Keep the exact accumulated zoom target, but publish at most
/// once per display frame.
final class EditorTimelineZoomInputCoalescer {
    typealias Apply = (_ targetZoom: Double, _ pointerViewportX: CGFloat?) -> Void

    private var pendingTargetZoom: Double?
    private var latestPointerViewportX: CGFloat?
    private var flushTask: Task<Void, Never>?

    static func targetZoom(from currentZoom: Double, deltaY: CGFloat) -> Double {
        min(max(currentZoom * pow(1.12, Double(deltaY)), 1), 120)
    }

    func enqueue(
        currentZoom: Double,
        deltaY: CGFloat,
        pointerViewportX: CGFloat?,
        apply: @escaping Apply
    ) {
        let baseZoom = pendingTargetZoom ?? currentZoom
        pendingTargetZoom = Self.targetZoom(from: baseZoom, deltaY: deltaY)
        latestPointerViewportX = pointerViewportX
        guard flushTask == nil else { return }

        flushTask = Task { @MainActor [weak self] in
            do {
                // One 60 Hz display interval. The editor may itself run on a
                // 120 Hz panel, but its timeline contents do not need two full
                // layout passes per video frame.
                try await Task.sleep(for: .milliseconds(16))
            } catch {
                return
            }
            guard let self, !Task.isCancelled else { return }
            let targetZoom = self.pendingTargetZoom
            let pointerViewportX = self.latestPointerViewportX
            self.pendingTargetZoom = nil
            self.latestPointerViewportX = nil
            self.flushTask = nil
            if let targetZoom {
                apply(targetZoom, pointerViewportX)
            }
        }
    }

    func cancel() {
        flushTask?.cancel()
        flushTask = nil
        pendingTargetZoom = nil
        latestPointerViewportX = nil
    }
}

enum EditorMotionTimelineTrack: Equatable {
    case screen
    case camera
}

enum EditorMotionTimelineEditMode: Equatable {
    case move
    case leading
    case trailing
}

struct EditorMotionTimelineClip: Equatable, Identifiable {
    let id: UUID
    let timing: TransitionTiming
    let track: EditorMotionTimelineTrack
    /// 跨轨道配对 ID（组合布局预设成对插入）；拖动/缩放时同组片段跟随。
    var groupID: UUID? = nil
}

struct EditorMotionTimelineBounds: Equatable {
    let previousEnd: TimeInterval
    let previousClear: TimeInterval
    let nextStart: TimeInterval
}

struct EditorMotionTimelineGestureOrigin: Equatable {
    let clip: EditorMotionTimelineClip
    let mode: EditorMotionTimelineEditMode
    let bounds: EditorMotionTimelineBounds
    /// 拖动开始时同组配对片段的持久态快照；联动跟随必须从这里计算，
    /// 否则每一帧都会在伙伴已移动的位置上再次叠加总位移（越拖越乱）。
    var partnerOrigins: [EditorMotionPartnerOrigin] = []
}

struct EditorMotionPartnerOrigin: Equatable {
    let id: UUID
    let timing: TransitionTiming
}

/// Selection-only timeline policy. Segment identity is derived from the
/// persisted source sequence, so it never depends on an asynchronously rebuilt
/// media plan.
enum EditorTimelineSelectionPresentation {
    static func primarySegmentID(from selection: EditorSelection?) -> UUID? {
        guard case let .primarySegment(id) = selection else { return nil }
        return id
    }

    static func primarySegmentIDs(in sourceSequence: SourceSequence) -> [UUID] {
        switch sourceSequence {
        case .fullRecording:
            return [TimelineMap.fullRecordingSegmentID]
        case let .edited(segments):
            return segments.map(\.id)
        }
    }

    static func reconcilingPrimarySelection(
        _ selection: EditorSelection?,
        sourceSequence: SourceSequence
    ) -> EditorSelection? {
        guard let id = primarySegmentID(from: selection) else { return selection }
        return primarySegmentIDs(in: sourceSequence).contains(id) ? selection : .screen
    }
}

enum EditorTimelineDeleteTarget: Equatable {
    case primarySegment(UUID)
    case screenMotion(UUID)
    case cameraMotion(UUID)
    case zoom(UUID)

    init?(selection: EditorSelection?) {
        switch selection {
        case let .primarySegment(id): self = .primarySegment(id)
        case let .screenMotion(id): self = .screenMotion(id)
        case let .cameraMotion(id): self = .cameraMotion(id)
        case let .zoom(id): self = .zoom(id)
        default: return nil
        }
    }
}

/// `S` follows the same precise selection model as deletion. A selected
/// authored effect is split at the playhead; selections that do not represent
/// a timed effect fall back to splitting the primary recording lane.
enum EditorTimelineSplitTarget: Equatable {
    case zoom(UUID)
    case screenMotion(UUID)
    case cameraMotion(UUID)

    init?(selection: EditorSelection?) {
        switch selection {
        case let .zoom(id): self = .zoom(id)
        case let .screenMotion(id): self = .screenMotion(id)
        case let .cameraMotion(id): self = .cameraMotion(id)
        default: return nil
        }
    }
}

/// Locks one mouse-down to one semantic target until mouse-up. It deliberately
/// owns no project or playback state; local hit zones still perform the edit.
enum EditorTimelineGestureIntent: Equatable {
    case scrub
    case primaryTrim(UUID, RecordingSegmentTrimEdge)
    case zoomCreate
    case zoomMove(UUID)
    case zoomResize(UUID, leading: Bool)
    case motionCreate(EditorMotionTimelineTrack)
    case motion(EditorMotionTimelineTrack, UUID, EditorMotionTimelineEditMode)

    var seeksDuringDrag: Bool {
        switch self {
        case .scrub, .primaryTrim:
            return true
        default:
            return false
        }
    }
}

struct EditorTimelineGestureOwnership: Equatable {
    private(set) var activeIntent: EditorTimelineGestureIntent?

    mutating func begin(_ intent: EditorTimelineGestureIntent) -> Bool {
        if let activeIntent { return activeIntent == intent }
        activeIntent = intent
        return true
    }

    mutating func end(_ intent: EditorTimelineGestureIntent) {
        guard activeIntent == intent else { return }
        activeIntent = nil
    }

    mutating func cancel() {
        activeIntent = nil
    }
}
