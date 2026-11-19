import Foundation
import RecorderCore

struct EditorCameraSyncCurveSample: Equatable {
    let startsSubpath: Bool
    let outputTime: TimeInterval
    let offset: TimeInterval
}

/// Synchronous, non-observable memoization for full-document timeline values.
/// Native viewport movement and hover chrome can rebuild the SwiftUI body, but
/// they must not remap/sort every offscreen clip or publish another state
/// change from inside that body evaluation.
@MainActor
final class EditorTimelineDerivedPresentationCache {
    // MARK: Added-material lanes (EDT-061)

    struct OverlayKey: Equatable {
        let mosaics: [MosaicClip]
        let stickers: [StickerClip]
        let animations: [AnimationClip]
        let animationAssets: [MediaAsset]
        let audio: [AudioClip]
        let subtitles: [SubtitleCue]
        let videos: [VideoClip]
    }
    private var overlayKey: OverlayKey?
    /// Bumps whenever the overlay clip list is rebuilt.
    private(set) var overlayGeneration: UInt64 = 0
    private var cachedOverlayClips: [TimelineOverlayClip] = []
    private var cachedLaneRows: [TimelineLane: [[TimelineOverlayClip]]] = [:]

    private var overlayRevision: UInt64?

    /// `revision` identifies the source timeline (nil when it cannot, e.g.
    /// during a reorder preview); when unchanged the deep key comparison of
    /// every subtitle is skipped entirely.
    func overlayClips(revision: UInt64?, key: () -> OverlayKey,
                      build: () -> [TimelineOverlayClip]) -> [TimelineOverlayClip] {
        if let revision, let overlayRevision, overlayRevision == revision { return cachedOverlayClips }
        overlayRevision = revision
        return overlayClips(key: key(), build: build)
    }

    func overlayClips(key: OverlayKey, build: () -> [TimelineOverlayClip]) -> [TimelineOverlayClip] {
        if overlayKey == key { return cachedOverlayClips }
        overlayKey = key
        overlayGeneration &+= 1
        cachedOverlayClips = build()
        cachedLaneRows = [:]
        cachedLaneSummary = nil
        return cachedOverlayClips
    }

    /// Per-group counts and occupied layer/audio rows. Every clip view reads
    /// `trackScale`, which sums lane heights; deriving these from the full
    /// clip list on each read made one timeline body O(clips²).
    struct LaneSummary {
        let counts: [TimelinePostLane: Int]
        let visualLayers: [Int]
        let audioLanes: [Int]
    }
    private var cachedLaneSummary: LaneSummary?

    /// Hidden post-lane groups, parsed once per stored string.
    private var hiddenLanesRaw: String?
    private var hiddenLanes: Set<String> = []

    func hiddenPostLanes(_ raw: String) -> Set<String> {
        if raw == hiddenLanesRaw { return hiddenLanes }
        hiddenLanesRaw = raw
        hiddenLanes = Set(raw.split(separator: ",").map(String.init))
        return hiddenLanes
    }

    /// Natural track height for one combination of visible lanes; every clip
    /// view reads `trackScale`, so this must not re-walk the lanes each time.
    struct NaturalHeightKey: Equatable {
        let tracks: Int
        let hidden: String
        let cameraSync: Bool
        let primary: CGFloat
        let motion: CGFloat
        let overlays: UInt64
    }
    private var naturalHeightKey: NaturalHeightKey?
    private var naturalHeight: CGFloat = 0

    func naturalTracksHeight(key: NaturalHeightKey, compute: () -> CGFloat) -> CGFloat {
        if naturalHeightKey == key { return naturalHeight }
        naturalHeightKey = key
        naturalHeight = compute()
        return naturalHeight
    }

    func laneSummary(for clips: [TimelineOverlayClip]) -> LaneSummary {
        if let cachedLaneSummary { return cachedLaneSummary }
        var counts: [TimelinePostLane: Int] = [:]
        var layers = Set<Int>()
        var audio = Set<Int>()
        for clip in clips {
            switch clip.kind {
            case .subtitle: counts[.subtitles, default: 0] += 1
            case .video, .sticker, .animation: counts[.layers, default: 0] += 1
            case .mosaic: counts[.effects, default: 0] += 1
            case .audio:
                counts[.audio, default: 0] += 1
                audio.insert(clip.audioLane)
            }
            if TimelineLane.layer(clip.layer).contains(clip) { layers.insert(clip.layer) }
        }
        let summary = LaneSummary(counts: counts, visualLayers: layers.sorted(by: >), audioLanes: audio.sorted())
        cachedLaneSummary = summary
        return summary
    }

    /// Rows of one lane for the current clips (cleared when clips change).
    func laneRows(_ lane: TimelineLane, build: () -> [[TimelineOverlayClip]]) -> [[TimelineOverlayClip]] {
        if let rows = cachedLaneRows[lane] { return rows }
        let rows = build()
        cachedLaneRows[lane] = rows
        return rows
    }

    private struct RecordingMarkerInput: Equatable {
        let markers: [RecordingMarker]
        let map: TimelineMap
    }
    private var markerInput: RecordingMarkerInput?
    private var mappedMarkers: [EditorRecordingMarker] = []

    func recordingMarkers(_ markers: [RecordingMarker], map: TimelineMap) -> [EditorRecordingMarker] {
        let input = RecordingMarkerInput(markers: markers, map: map)
        guard markerInput != input else { return mappedMarkers }
        markerInput = input
        var mapped: [EditorRecordingMarker] = []
        for marker in markers {
            for position in map.outputPositions(forSourceTime: marker.sourceTime, sourceID: marker.resolvedSourceID) {
                mapped.append(EditorRecordingMarker(marker: marker, outputTime: position.time, segmentID: position.segmentID))
            }
        }
        mappedMarkers = mapped.sorted { $0.outputTime == $1.outputTime ? $0.marker.number < $1.marker.number : $0.outputTime < $1.outputTime }
        return mappedMarkers
    }

    private struct WaveformPlanInput: Equatable {
        let sequence: SourceSequence
        let sources: [UUID: RecordingSourceMedia]
    }
    private var waveformPlanInput: WaveformPlanInput?
    private var waveformPlan: ProjectTimelineMediaPlan?

    /// Pure media-time math over the existing PCM data. A ripple draft must
    /// move every following audio slice with the same displayed segment map.
    func waveformPlan(segments: [ResolvedRecordingSegment], sources: [UUID: RecordingSourceMedia]) -> ProjectTimelineMediaPlan? {
        // Keep `media`: an inserted clip (black, an opening, a video) has no
        // recording sound. Dropping it made its file time read as recording
        // time (a waveform under black) or collide with the recording's own
        // range, which failed the whole plan and blanked every waveform.
        let sequence = SourceSequence.edited(segments.map {
            RecordingSegment(id: $0.id, sourceStart: $0.sourceStart,
                             sourceDuration: $0.sourceDuration, playbackRate: $0.playbackRate, media: $0.media, sourceID: $0.sourceID, sceneStyle: $0.sceneStyle)
        })
        let input = WaveformPlanInput(sequence: sequence, sources: sources)
        if input != waveformPlanInput {
            waveformPlanInput = input
            waveformPlan = try? ProjectTimelineMediaPlan(sourceSequence: sequence, sources: sources)
        }
        return waveformPlan
    }

    private struct TimelineMapInput: Equatable {
        let sourceSequence: SourceSequence
        let sourceDurations: [UUID: TimeInterval]
    }

    private struct ZoomInput: Equatable {
        let animations: [ZoomAnimationClip]
        let duration: TimeInterval
    }

    private struct ScreenMotionInput: Equatable {
        let clips: [ScreenMotionClip]
        let duration: TimeInterval
    }

    private struct CameraMotionInput: Equatable {
        let clips: [CameraMotionClip]
        let duration: TimeInterval
    }

    private struct CameraSyncPathInput: Equatable {
        let map: TimelineMap
        let sourceID: UUID?
        let anchors: [MediaSyncAnchor]
    }

    private var zoomInput: ZoomInput?
    private var zoomSegments: [TimelineZoomSegment] = []
    private var zoomSegmentIndicesByID: [UUID: Int] = [:]
    private var screenMotionInput: ScreenMotionInput?
    private var screenMotionClips: [EditorMotionTimelineClip] = []
    private var screenMotionClipIndicesByID: [UUID: Int] = [:]
    private var cameraMotionInput: CameraMotionInput?
    private var cameraMotionClips: [EditorMotionTimelineClip] = []
    private var cameraMotionClipIndicesByID: [UUID: Int] = [:]
    private var primaryJunctionMap: TimelineMap?
    private var primaryJunctions: [EditorTimelineSegmentJunction] = []
    private var primaryLeadingGap: EditorTimelineLeadingGap?
    private var primaryTrailingGap: EditorTimelineTrailingGap?
    private var syncAnchorsInput: [MediaSyncAnchor]?
    private var syncCurve = MediaSyncAnchorCurve([])
    private var syncDisplayRange: TimeInterval = 0.118
    private var syncPathInput: CameraSyncPathInput?
    private var syncPathSamples: [EditorCameraSyncCurveSample] = []

    private var timelineMapInput: TimelineMapInput?
    private var resolvedTimelineMap: TimelineMap?

    func timelineMap(
        sourceSequence: SourceSequence,
        sourceDurations: [UUID: TimeInterval]
    ) -> TimelineMap? {
        let nextInput = TimelineMapInput(
            sourceSequence: sourceSequence,
            sourceDurations: sourceDurations
        )
        guard timelineMapInput != nextInput else { return resolvedTimelineMap }
        timelineMapInput = nextInput
        resolvedTimelineMap = try? TimelineMap(
            sourceSequence: sourceSequence,
            sourceDurations: sourceDurations
        )
        return resolvedTimelineMap
    }

    func zoomSegments(
        animations: [ZoomAnimationClip],
        duration: TimeInterval
    ) -> [TimelineZoomSegment] {
        let nextInput = ZoomInput(animations: animations, duration: duration)
        if zoomInput != nextInput {
            zoomInput = nextInput
            zoomSegments = EditorTimelineMath.zoomSegments(
                from: animations,
                duration: duration
            )
            zoomSegmentIndicesByID = Dictionary(
                uniqueKeysWithValues: zoomSegments.indices.map {
                    (zoomSegments[$0].id, $0)
                }
            )
        }
        return zoomSegments
    }

    func zoomSegmentIndex(for id: UUID?) -> Int? {
        id.flatMap { zoomSegmentIndicesByID[$0] }
    }

    func screenMotionClips(
        clips: [ScreenMotionClip],
        duration: TimeInterval
    ) -> [EditorMotionTimelineClip] {
        let nextInput = ScreenMotionInput(clips: clips, duration: duration)
        if screenMotionInput != nextInput {
            screenMotionInput = nextInput
            screenMotionClips = clips
                .map {
                    EditorMotionTimelineClip(
                        id: $0.id,
                        timing: $0.timing,
                        track: .screen,
                        groupID: $0.groupID
                    )
                }
                .filter { $0.timing.endTime > 0 && $0.timing.startTime < duration }
                .sorted(by: Self.motionOrder)
            screenMotionClipIndicesByID = Dictionary(
                uniqueKeysWithValues: screenMotionClips.indices.map {
                    (screenMotionClips[$0].id, $0)
                }
            )
        }
        return screenMotionClips
    }

    func screenMotionClipIndex(for id: UUID?) -> Int? {
        id.flatMap { screenMotionClipIndicesByID[$0] }
    }

    func cameraMotionClips(
        clips: [CameraMotionClip],
        duration: TimeInterval
    ) -> [EditorMotionTimelineClip] {
        let nextInput = CameraMotionInput(clips: clips, duration: duration)
        if cameraMotionInput != nextInput {
            cameraMotionInput = nextInput
            cameraMotionClips = clips
                .map {
                    EditorMotionTimelineClip(
                        id: $0.id,
                        timing: $0.timing,
                        track: .camera,
                        groupID: $0.groupID
                    )
                }
                .filter { $0.timing.endTime > 0 && $0.timing.startTime < duration }
                .sorted(by: Self.motionOrder)
            cameraMotionClipIndicesByID = Dictionary(
                uniqueKeysWithValues: cameraMotionClips.indices.map {
                    (cameraMotionClips[$0].id, $0)
                }
            )
        }
        return cameraMotionClips
    }

    func cameraMotionClipIndex(for id: UUID?) -> Int? {
        id.flatMap { cameraMotionClipIndicesByID[$0] }
    }

    func segmentJunctions(for map: TimelineMap) -> [EditorTimelineSegmentJunction] {
        preparePrimaryJunctions(for: map)
        return primaryJunctions
    }

    func leadingGap(for map: TimelineMap) -> EditorTimelineLeadingGap? {
        preparePrimaryJunctions(for: map)
        return primaryLeadingGap
    }

    func trailingGap(for map: TimelineMap) -> EditorTimelineTrailingGap? {
        preparePrimaryJunctions(for: map)
        return primaryTrailingGap
    }

    func cameraSyncCurve(for anchors: [MediaSyncAnchor]) -> MediaSyncAnchorCurve {
        prepareCameraSyncPresentation(for: anchors)
        return syncCurve
    }

    func cameraSyncDisplayRange(for anchors: [MediaSyncAnchor]) -> TimeInterval {
        prepareCameraSyncPresentation(for: anchors)
        return syncDisplayRange
    }

    func cameraSyncPathSamples(
        map: TimelineMap,
        sourceID: UUID?,
        anchors: [MediaSyncAnchor]
    ) -> [EditorCameraSyncCurveSample] {
        let nextInput = CameraSyncPathInput(map: map, sourceID: sourceID, anchors: anchors)
        guard syncPathInput != nextInput else { return syncPathSamples }
        syncPathInput = nextInput

        let curve = cameraSyncCurve(for: anchors)
        var samples: [EditorCameraSyncCurveSample] = []
        samples.reserveCapacity(map.segments.count * 2 + curve.anchors.count)
        for segment in map.segments where segment.media == nil && segment.sourceID == sourceID {
            samples.append(EditorCameraSyncCurveSample(
                startsSubpath: true,
                outputTime: segment.outputStart,
                offset: curve.offset(atSourceTime: segment.sourceStart)
            ))

            var anchorIndex = Self.firstAnchorIndex(
                after: segment.sourceStart,
                in: curve.anchors
            )
            while anchorIndex < curve.anchors.count {
                let anchor = curve.anchors[anchorIndex]
                guard anchor.sourceTime < segment.sourceEnd else { break }
                samples.append(EditorCameraSyncCurveSample(
                    startsSubpath: false,
                    outputTime: segment.outputStart
                        + (anchor.sourceTime - segment.sourceStart) / segment.playbackRate,
                    offset: curve.offset(atSourceTime: anchor.sourceTime)
                ))
                anchorIndex += 1
            }

            samples.append(EditorCameraSyncCurveSample(
                startsSubpath: false,
                outputTime: segment.outputEnd,
                offset: curve.offset(atSourceTime: segment.sourceEnd)
            ))
        }
        syncPathSamples = samples
        return samples
    }

    private func preparePrimaryJunctions(for map: TimelineMap) {
        guard primaryJunctionMap != map else { return }
        primaryJunctionMap = map
        primaryJunctions = EditorPrimaryTimelinePresentation.segmentJunctions(from: map)
        primaryLeadingGap = EditorPrimaryTimelinePresentation.leadingGap(from: map)
        primaryTrailingGap = EditorPrimaryTimelinePresentation.trailingGap(from: map)
    }

    private func prepareCameraSyncPresentation(for anchors: [MediaSyncAnchor]) {
        guard syncAnchorsInput != anchors else { return }
        syncAnchorsInput = anchors
        syncCurve = MediaSyncAnchorCurve(anchors)
        syncDisplayRange = max(anchors.lazy.map { abs($0.offset) }.max() ?? 0, 0.100) * 1.18
    }

    private static func firstAnchorIndex(
        after sourceTime: TimeInterval,
        in anchors: [MediaSyncAnchor]
    ) -> Int {
        var lower = 0
        var upper = anchors.count
        while lower < upper {
            let middle = lower + (upper - lower) / 2
            if anchors[middle].sourceTime <= sourceTime {
                lower = middle + 1
            } else {
                upper = middle
            }
        }
        return lower
    }

    private static func motionOrder(
        _ lhs: EditorMotionTimelineClip,
        _ rhs: EditorMotionTimelineClip
    ) -> Bool {
        lhs.timing.startTime == rhs.timing.startTime
            ? lhs.id.uuidString < rhs.id.uuidString
            : lhs.timing.startTime < rhs.timing.startTime
    }
}
