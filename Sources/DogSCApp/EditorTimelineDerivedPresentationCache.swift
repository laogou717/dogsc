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
    private var primarySegmentIndicesByID: [UUID: Int] = [:]
    private var primaryJunctions: [EditorTimelineSegmentJunction] = []
    private var primaryLeadingGap: EditorTimelineLeadingGap?
    private var primaryTrailingGap: EditorTimelineTrailingGap?
    private var syncAnchorsInput: [MediaSyncAnchor]?
    private var syncCurve = MediaSyncAnchorCurve([])
    private var syncDisplayRange: TimeInterval = 0.118
    private var syncPathInput: CameraSyncPathInput?
    private var syncPathSamples: [EditorCameraSyncCurveSample] = []
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

    func primarySegmentIndex(for id: UUID?, in map: TimelineMap) -> Int? {
        preparePrimaryJunctions(for: map)
        return id.flatMap { primarySegmentIndicesByID[$0] }
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
        anchors: [MediaSyncAnchor]
    ) -> [EditorCameraSyncCurveSample] {
        let nextInput = CameraSyncPathInput(map: map, anchors: anchors)
        guard syncPathInput != nextInput else { return syncPathSamples }
        syncPathInput = nextInput

        let curve = cameraSyncCurve(for: anchors)
        var samples: [EditorCameraSyncCurveSample] = []
        samples.reserveCapacity(map.segments.count * 2 + curve.anchors.count)
        for segment in map.segments {
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
                        + anchor.sourceTime - segment.sourceStart,
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
        primarySegmentIndicesByID = Dictionary(
            uniqueKeysWithValues: map.segments.indices.map {
                (map.segments[$0].id, $0)
            }
        )
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
