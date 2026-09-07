import AppKit
import Foundation
import RecorderCore

/// A local NSEvent monitor outlives the SwiftUI value that installed it.
/// Reading the skimming preference through that captured value freezes the
/// switch at its launch state, so keep the live value in a stable reference.
@MainActor
final class EditorTimelineHoverPreviewGate {
    var isEnabled = true
}

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

struct PrimarySegmentRetimeDraft: Equatable {
    let segmentID: UUID
    let original: ResolvedRecordingSegment
    var proposedRate: Double
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
        trimDraft: PrimarySegmentTrimDraft?,
        retimeDraft: PrimarySegmentRetimeDraft?
    ) -> [ResolvedRecordingSegment] {
        let hasTrimDraft = trimDraft.map { draft in
            map.segments.contains(where: { $0.id == draft.segmentID })
        } ?? false
        let hasRetimeDraft = retimeDraft.map { draft in
            map.segments.contains(where: { $0.id == draft.segmentID })
        } ?? false
        guard hasTrimDraft || hasRetimeDraft else { return map.segments }

        var outputStart: TimeInterval = 0
        return map.segments.map { segment in
            var sourceStart = segment.sourceStart
            var sourceDuration = segment.sourceDuration
            var playbackRate = segment.playbackRate
            if let trimDraft, segment.id == trimDraft.segmentID {
                switch trimDraft.edge {
                case .left:
                    let removedOutputDuration = trimDraft.proposedOutputTime
                        - segment.outputStart
                    let removedSourceDuration = removedOutputDuration
                        * segment.playbackRate
                    sourceStart += removedSourceDuration
                    sourceDuration -= removedSourceDuration
                    // Ripple trim keeps the authored edit point contiguous:
                    // the trimmed clip starts where the preceding clip ends,
                    // and every following clip shifts by the removed/inserted
                    // duration. The hover guide still follows the pointer, so
                    // the draft can match the exact post-commit geometry
                    // without jumping left on mouse-up.
                case .right:
                    sourceDuration = (trimDraft.proposedOutputTime - segment.outputStart)
                        * segment.playbackRate
                }
            }
            if let retimeDraft, segment.id == retimeDraft.segmentID {
                playbackRate = min(
                    max(
                        retimeDraft.proposedRate,
                        RecordingSegment.minimumPlaybackRate
                    ),
                    RecordingSegment.maximumPlaybackRate
                )
            }
            let displayed = ResolvedRecordingSegment(
                id: segment.id,
                sourceStart: sourceStart,
                sourceDuration: max(sourceDuration, 0),
                playbackRate: playbackRate,
                outputStart: outputStart
            )
            outputStart += displayed.outputDuration
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
            - max(segment.sourceStart - previousSourceEnd, 0) / segment.playbackRate
        let maximumOutputTime = segment.outputEnd
            + max(nextSourceStart - segment.sourceEnd, 0) / segment.playbackRate
        return PrimarySegmentTrimDraft(
            segmentID: segmentID,
            edge: edge,
            original: segment,
            minimumOutputTime: minimumOutputTime,
            maximumOutputTime: maximumOutputTime,
            proposedOutputTime: edge == .left ? segment.outputStart : segment.outputEnd
        )
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
            segment.outputDuration
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
            segment.outputDuration
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
enum EditorTimelineZoomPolicy {
    static let minimum = 1.0
    /// A fixed 480× ceiling still compressed a 30-minute, 60 fps recording to
    /// roughly seven points per frame on a laptop viewport. The timeline is
    /// viewport-virtualized, so the document may safely become wide enough for
    /// frame-accurate edge work without materializing the complete waveform.
    static let maximum = 4_096.0

    static func clamped(_ value: Double) -> Double {
        min(max(value.isFinite ? value : minimum, minimum), maximum)
    }
}

@MainActor
final class EditorTimelineZoomInputCoalescer {
    typealias Apply = @MainActor (_ targetZoom: Double, _ pointerViewportX: CGFloat?) -> Void

    private var pendingTargetZoom: Double?
    private var latestPointerViewportX: CGFloat?
    private var pendingApply: Apply?
    private var flushTask: Task<Void, Never>?

    static func targetZoom(from currentZoom: Double, deltaY: CGFloat) -> Double {
        // A wheel notch previously changed scale by only 12%, while trackpad
        // deltas are usually fractions of one notch. The resulting gesture
        // needed several long swipes even in the common 1×–8× range.
        EditorTimelineZoomPolicy.clamped(
            currentZoom * pow(1.24, Double(deltaY))
        )
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
        pendingApply = apply
        scheduleFlush()
    }

    /// Slider drags provide an absolute target rather than a wheel delta, but
    /// they can still emit several changes before one display frame. Share the
    /// same publication gate so every zoom input has one rendering cadence.
    func enqueue(
        targetZoom: Double,
        pointerViewportX: CGFloat?,
        apply: @escaping Apply
    ) {
        pendingTargetZoom = EditorTimelineZoomPolicy.clamped(targetZoom)
        latestPointerViewportX = pointerViewportX
        pendingApply = apply
        scheduleFlush()
    }

    private func scheduleFlush() {
        guard flushTask == nil else { return }

        flushTask = Task { @MainActor [weak self] in
            do {
                // Editing cadence follows the active display, not the media's
                // frame rate. A 120 Hz panel must not inherit a 60 Hz UI cap.
                let screen = NSApp.keyWindow?.screen ?? NSApp.mainWindow?.screen ?? NSScreen.main
                let rate = max(screen?.maximumFramesPerSecond ?? 60, 1)
                try await Task.sleep(for: .nanoseconds(Int64(1_000_000_000 / rate)))
            } catch {
                return
            }
            guard let self, !Task.isCancelled else { return }
            self.flush()
        }
    }

    /// Mouse-up must not leave the last fraction of a drag waiting behind the
    /// display gate. Applying it synchronously also keeps the slider thumb and
    /// the final document scale identical when the interaction ends.
    func flush() {
        flushTask?.cancel()
        flushTask = nil
        let targetZoom = pendingTargetZoom
        let pointerViewportX = latestPointerViewportX
        let apply = pendingApply
        pendingTargetZoom = nil
        latestPointerViewportX = nil
        pendingApply = nil
        if let targetZoom, let apply {
            apply(targetZoom, pointerViewportX)
        }
    }

    func cancel() {
        flushTask?.cancel()
        flushTask = nil
        pendingTargetZoom = nil
        latestPointerViewportX = nil
        pendingApply = nil
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

enum EditorOverlayTimelineKind: Equatable {
    case mosaic
    case sticker

    func selection(id: UUID) -> EditorSelection {
        switch self {
        case .mosaic: return .mosaic(id)
        case .sticker: return .sticker(id)
        }
    }

    var moveActionName: String {
        switch self {
        case .mosaic: return "移动打码"
        case .sticker: return "移动贴图"
        }
    }

    var resizeActionName: String {
        switch self {
        case .mosaic: return "调整打码时长"
        case .sticker: return "调整贴图时长"
        }
    }
}

struct EditorOverlayTimelineDrag: Equatable {
    let kind: EditorOverlayTimelineKind
    let id: UUID
    let mode: EditorMotionTimelineEditMode
    let original: OverlayTiming
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
        // A removed timeline segment has lost its own editing context. Fall
        // back to the neutral canvas instead of activating screen transforms;
        // temporal selection must never imply spatial manipulation.
        return primarySegmentIDs(in: sourceSequence).contains(id) ? selection : .canvas
    }
}

enum EditorTimelineDeleteTarget: Equatable {
    case primarySegment(UUID)
    case screenMotion(UUID)
    case cameraMotion(UUID)
    case zoom(UUID)
    case mosaic(UUID)
    case sticker(UUID)

    init?(selection: EditorSelection?) {
        switch selection {
        case let .primarySegment(id): self = .primarySegment(id)
        case let .screenMotion(id): self = .screenMotion(id)
        case let .cameraMotion(id): self = .cameraMotion(id)
        case let .zoom(id): self = .zoom(id)
        case let .mosaic(id): self = .mosaic(id)
        case let .sticker(id): self = .sticker(id)
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
    case mosaic(UUID)
    case sticker(UUID)

    init?(selection: EditorSelection?) {
        switch selection {
        case let .zoom(id): self = .zoom(id)
        case let .screenMotion(id): self = .screenMotion(id)
        case let .cameraMotion(id): self = .cameraMotion(id)
        case let .mosaic(id): self = .mosaic(id)
        case let .sticker(id): self = .sticker(id)
        default: return nil
        }
    }
}

/// A temporal selection must remain inspectable on the monitor. Selecting a
/// clip while the playhead is already inside it preserves the user's frame;
/// selecting one elsewhere reveals the first useful authored state instead of
/// leaving a selected inspector attached to an invisible object.
enum EditorTimelineSelectionReveal {
    static func time(
        for selection: EditorSelection,
        in project: RecorderProject,
        currentTime: TimeInterval,
        outputDuration: TimeInterval? = nil
    ) -> TimeInterval? {
        let interval: (start: TimeInterval, end: TimeInterval, preferred: TimeInterval)?
        switch selection {
        case let .zoom(id):
            let visibleZooms = outputDuration.map {
                ZoomTransitionResolution.resolve(project.zoomAnimations, outputDuration: $0)
            } ?? project.zoomAnimations
            interval = visibleZooms.first(where: { $0.id == id }).map {
                (
                    start: $0.startTime,
                    end: $0.endTime,
                    preferred: $0.startTime + min($0.enterDuration, $0.endTime - $0.startTime)
                )
            }
        case let .screenMotion(id):
            interval = project.timeline.screenMotionClips.first(where: { $0.id == id }).map {
                (start: $0.timing.startTime,
                 end: $0.timing.endTime,
                 preferred: $0.timing.leadInEndTime)
            }
        case let .cameraMotion(id):
            interval = project.timeline.cameraMotionClips.first(where: { $0.id == id }).map {
                (start: $0.timing.startTime,
                 end: $0.timing.endTime,
                 preferred: $0.timing.leadInEndTime)
            }
        case let .mosaic(id):
            interval = project.timeline.mosaicClips.first(where: { $0.id == id }).map {
                (start: $0.timing.startTime,
                 end: $0.timing.endTime,
                 preferred: $0.timing.startTime)
            }
        case let .sticker(id):
            interval = project.timeline.stickerClips.first(where: { $0.id == id }).map {
                (start: $0.timing.startTime,
                 end: $0.timing.endTime,
                 preferred: $0.timing.startTime)
            }
        default:
            interval = nil
        }
        guard let interval else { return nil }
        let start = max(interval.start, 0)
        let end = max(interval.end, start)
        if currentTime >= start, currentTime < end { return nil }
        guard end > start else { return start }
        return min(max(interval.preferred, start), end - 0.001)
    }
}

/// Locks one mouse-down to one semantic target until mouse-up. It deliberately
/// owns no project or playback state; local hit zones still perform the edit.
enum EditorTimelineGestureIntent: Equatable {
    case scrub
    case primaryTrim(UUID, RecordingSegmentTrimEdge)
    case primaryRetime(UUID)
    case zoomCreate
    case zoomMove(UUID)
    case zoomResize(UUID, leading: Bool)
    case motionCreate(EditorMotionTimelineTrack)
    case motion(EditorMotionTimelineTrack, UUID, EditorMotionTimelineEditMode)
    case overlayCreate
    case overlay(EditorOverlayTimelineKind, UUID, EditorMotionTimelineEditMode)

    var seeksDuringDrag: Bool {
        switch self {
        case .scrub, .primaryTrim, .primaryRetime:
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
