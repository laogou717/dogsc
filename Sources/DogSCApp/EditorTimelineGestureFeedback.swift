import RecorderCore
import SwiftUI

enum EditorTimelineGestureFeedbackTone {
    case primary
    case zoom
    case screenMotion
    case cameraMotion
    case overlay

    var color: Color {
        switch self {
        case .primary: return EditorTheme.amberAccent
        case .zoom: return editorZoomClip
        case .screenMotion: return Color(red: 0.85, green: 0.58, blue: 0.24)
        case .cameraMotion: return Color(red: 0.43, green: 0.67, blue: 0.47)
        case .overlay: return editorOverlayClip
        }
    }
}

struct EditorTimelineGestureFeedbackDescriptor {
    let icon: String
    let title: String
    let value: String
    let status: String?
    let guideTimes: [TimeInterval]
    let focusTime: TimeInterval
    let tone: EditorTimelineGestureFeedbackTone
}

private struct EditorTimelineGestureFeedbackHUD: View {
    let descriptor: EditorTimelineGestureFeedbackDescriptor
    let documentWidth: CGFloat
    let documentHeight: CGFloat
    let duration: TimeInterval
    let visibleRange: ClosedRange<CGFloat>

    private var accent: Color { descriptor.tone.color }

    var body: some View {
        let safeDuration = max(duration, 0.001)
        let bubbleWidth: CGFloat = descriptor.status == nil ? 224 : 276
        let measuredVisibleWidth = visibleRange.upperBound - visibleRange.lowerBound
        let visibleWidth = measuredVisibleWidth > 2
            ? measuredVisibleWidth
            : min(max(documentWidth, 1), 1_200)
        let visibleStart = measuredVisibleWidth > 2 ? visibleRange.lowerBound : 0
        let visibleEnd = min(visibleStart + visibleWidth, documentWidth)
        let focusX = CGFloat(descriptor.focusTime / safeDuration) * documentWidth
        let half = min(bubbleWidth / 2, max(visibleWidth / 2 - 5, 0))
        let bubbleCenterX = min(
            max(focusX, visibleStart + half + 5),
            max(visibleEnd - half - 5, visibleStart + half + 5)
        )
        let guides = deduplicatedGuideTimes(descriptor.guideTimes)

        ZStack(alignment: .topLeading) {
            ForEach(Array(guides.enumerated()), id: \.offset) { index, time in
                let x = CGFloat(time / safeDuration) * documentWidth
                Rectangle()
                    .fill(
                        LinearGradient(
                            colors: [
                                accent.opacity(index == guides.count - 1 ? 0.94 : 0.62),
                                accent.opacity(0.12),
                            ],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                    .frame(width: index == guides.count - 1 ? 1.5 : 1, height: documentHeight)
                    .offset(x: x - 0.5)
            }

            HStack(spacing: 9) {
                Image(systemName: descriptor.icon)
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(Color.black.opacity(0.76))
                    .frame(width: 24, height: 24)
                    .background(accent, in: Circle())

                VStack(alignment: .leading, spacing: 2) {
                    Text(descriptor.title)
                        .font(.system(size: 10.5, weight: .semibold))
                        .foregroundStyle(Color.white.opacity(0.96))
                    Text(descriptor.value)
                        .font(.system(size: 9.5, weight: .medium, design: .monospaced))
                        .foregroundStyle(Color.white.opacity(0.66))
                        .lineLimit(1)
                }

                Spacer(minLength: 2)

                if let status = descriptor.status {
                    Text(status)
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(accent.opacity(0.98))
                        .padding(.horizontal, 7)
                        .frame(height: 22)
                        .background(accent.opacity(0.10), in: Capsule(style: .continuous))
                        .overlay {
                            Capsule(style: .continuous)
                                .stroke(accent.opacity(0.30), lineWidth: 0.75)
                        }
                }
            }
            .padding(.horizontal, 9)
            .frame(width: min(bubbleWidth, max(visibleWidth - 10, 80)), height: 40)
            .background(
                LinearGradient(
                    colors: [Color(white: 0.14), Color(white: 0.075)],
                    startPoint: .top,
                    endPoint: .bottom
                ),
                in: RoundedRectangle(cornerRadius: 12, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(accent.opacity(0.34), lineWidth: 0.8)
            }
            .shadow(color: Color.black.opacity(0.48), radius: 10, y: 4)
            .position(x: bubbleCenterX, y: 23)
        }
        .frame(width: documentWidth, height: documentHeight, alignment: .topLeading)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private func deduplicatedGuideTimes(_ values: [TimeInterval]) -> [TimeInterval] {
        values.reduce(into: []) { result, value in
            let clamped = min(max(value, 0), max(duration, 0))
            guard !result.contains(where: { abs($0 - clamped) < 0.000_5 }) else { return }
            result.append(clamped)
        }
    }
}

extension EditorTimelineView {
    @ViewBuilder
    func timelineGestureFeedbackOverlay(
        width: CGFloat,
        duration: TimeInterval
    ) -> some View {
        if let descriptor = timelineGestureFeedbackDescriptor(duration: duration) {
            EditorTimelineGestureFeedbackHUD(
                descriptor: descriptor,
                documentWidth: width,
                documentHeight: timelineCanvasHeight,
                duration: duration,
                visibleRange: clampedTimelineVisibleDocumentRange(width: width)
            )
            .transition(.opacity.combined(with: .scale(scale: 0.97, anchor: .top)))
            .zIndex(40)
        }
    }

    func timelineGestureFeedbackDescriptor(
        duration: TimeInterval
    ) -> EditorTimelineGestureFeedbackDescriptor? {
        if let primaryTrimDraft,
           let segment = primaryDisplaySegments.first(where: {
               $0.id == primaryTrimDraft.segmentID
           }) {
            let focus = primaryTrimDraft.edge == .left
                ? segment.outputStart : segment.outputEnd
            let status: String?
            if segment.outputDuration <= minimumPrimarySegmentDuration + 0.000_1 {
                status = "最短 1 帧"
            } else if abs(primaryTrimDraft.proposedOutputTime
                        - primaryTrimDraft.minimumOutputTime) < 0.000_5
                        || abs(primaryTrimDraft.proposedOutputTime
                            - primaryTrimDraft.maximumOutputTime) < 0.000_5 {
                status = "素材边界"
            } else {
                status = nil
            }
            return feedbackDescriptor(
                icon: primaryTrimDraft.edge == .left
                    ? "arrow.right.to.line" : "arrow.left.to.line",
                title: primaryTrimDraft.edge == .left ? "调整片段起点" : "调整片段终点",
                start: segment.outputStart,
                end: segment.outputEnd,
                focus: focus,
                status: status,
                tone: .primary
            )
        }

        if let primaryRetimeDraft {
            let outputDuration = primaryRetimeDraft.original.sourceDuration
                / max(primaryRetimeDraft.proposedRate, 0.000_1)
            let end = primaryRetimeDraft.original.outputStart + outputDuration
            let status: String?
            if primaryRetimeDraft.proposedRate >= 20 - 0.000_1 {
                status = "速度上限"
            } else if primaryRetimeDraft.proposedRate <= 1 + 0.000_1 {
                status = "正常速度"
            } else {
                status = nil
            }
            return EditorTimelineGestureFeedbackDescriptor(
                icon: "gauge.with.dots.needle.67percent",
                title: "片段变速",
                value: "\(timelinePlaybackRateText(primaryRetimeDraft.proposedRate))  ·  成片 \(timelineTimestamp(outputDuration))",
                status: status,
                guideTimes: [end],
                focusTime: end,
                tone: .primary
            )
        }

        if let draggedPrimarySegmentID,
           let pointerX = primarySegmentDragDocumentX,
           let placement = primaryReorderPlacement(
               draggedID: draggedPrimarySegmentID,
               pointerX: pointerX
           ) {
            return EditorTimelineGestureFeedbackDescriptor(
                icon: "arrow.left.arrow.right",
                title: "调整片段顺序",
                value: "第 \(placement.oldIndex + 1) 位  →  第 \(placement.destination + 1) 位",
                status: placement.oldIndex == placement.destination
                    ? "保持当前位置" : "松手放置",
                guideTimes: [placement.insertionTime],
                focusTime: placement.insertionTime,
                tone: .primary
            )
        }

        switch zoomTrackDrag {
        case .create:
            guard let manualZoomDragStart, let manualZoomDragEnd else { break }
            return feedbackDescriptor(
                icon: "plus.magnifyingglass",
                title: "创建缩放区间",
                start: min(manualZoomDragStart, manualZoomDragEnd),
                end: max(manualZoomDragStart, manualZoomDragEnd),
                focus: manualZoomDragEnd,
                status: abs(manualZoomDragEnd - manualZoomDragStart) < 0.000_5
                    ? "拖动建立区间" : nil,
                tone: .zoom
            )
        case let .move(id), let .resize(id, _):
            guard let clip = editorStore.previewProject.zoomAnimations.first(where: {
                $0.id == id
            }) else { break }
            let isLeading: Bool? = {
                if case let .resize(_, leading) = zoomTrackDrag { return leading }
                return nil
            }()
            let focus = isLeading == true ? clip.startTime : clip.endTime
            let anchors = editorStore.previewProject.zoomAnimations
                .filter { $0.id != id }
                .flatMap { [$0.startTime, $0.endTime] }
            let resolved = timelineFeedbackStatus(
                start: clip.startTime,
                end: clip.endTime,
                preferredFocus: isLeading == true ? clip.startTime : clip.endTime,
                minimumDuration: 0.16,
                duration: duration,
                anchors: anchors,
                considersBothEdges: isLeading == nil
            )
            return feedbackDescriptor(
                icon: isLeading == nil ? "arrow.left.arrow.right" : "arrow.left.and.right",
                title: isLeading == nil
                    ? "移动缩放动画"
                    : (isLeading == true ? "调整缩放起点" : "调整缩放终点"),
                start: clip.startTime,
                end: clip.endTime,
                focus: resolved.focus ?? focus,
                status: resolved.status,
                tone: .zoom
            )
        case nil:
            break
        }

        switch motionTrackDrag {
        case .create:
            guard let motionCreateDrag else { break }
            return feedbackDescriptor(
                icon: "plus",
                title: motionCreateDrag.track == .screen
                    ? "创建屏幕 3D" : "创建摄像运动",
                start: min(motionCreateDrag.start, motionCreateDrag.end),
                end: max(motionCreateDrag.start, motionCreateDrag.end),
                focus: motionCreateDrag.end,
                status: abs(motionCreateDrag.end - motionCreateDrag.start) < 0.000_5
                    ? "拖动建立区间" : nil,
                tone: motionCreateDrag.track == .screen ? .screenMotion : .cameraMotion
            )
        case let .move(id), let .resize(id, _):
            guard let origin = motionGestureOrigin,
                  origin.clip.id == id,
                  let timing = previewMotionTiming(track: origin.clip.track, id: id)
            else { break }
            let isLeading: Bool? = {
                if case let .resize(_, leading) = motionTrackDrag { return leading }
                return nil
            }()
            let anchors = motionFeedbackAnchors(
                track: origin.clip.track,
                excluding: id
            )
            let resolved = timelineFeedbackStatus(
                start: timing.startTime,
                end: timing.endTime,
                preferredFocus: isLeading == true ? timing.startTime : timing.endTime,
                minimumDuration: EditorMotionTimelinePresentation.minimumDuration,
                duration: duration,
                anchors: anchors,
                considersBothEdges: isLeading == nil
            )
            return feedbackDescriptor(
                icon: isLeading == nil ? "arrow.left.arrow.right" : "arrow.left.and.right",
                title: isLeading == nil
                    ? "移动\(origin.clip.track == .screen ? "屏幕 3D" : "摄像运动")"
                    : (isLeading == true ? "调整动画起点" : "调整动画终点"),
                start: timing.startTime,
                end: timing.endTime,
                focus: resolved.focus ?? (isLeading == true ? timing.startTime : timing.endTime),
                status: resolved.status,
                tone: origin.clip.track == .screen ? .screenMotion : .cameraMotion
            )
        case nil:
            break
        }

        if let overlayTimelineDrag,
           let timing = persistedOverlayPreviewTiming(
               kind: overlayTimelineDrag.kind,
               id: overlayTimelineDrag.id
           ) {
            let focus = overlayTimelineDrag.mode == .leading
                ? timing.startTime : timing.endTime
            let resolved = timelineFeedbackStatus(
                start: timing.startTime,
                end: timing.endTime,
                preferredFocus: focus,
                minimumDuration: 0.08,
                duration: duration,
                anchors: [],
                considersBothEdges: overlayTimelineDrag.mode == .move
            )
            let noun = overlayTimelineDrag.kind == .mosaic ? "柔化" : "贴图"
            let title: String = switch overlayTimelineDrag.mode {
            case .move: "移动\(noun)"
            case .leading: "调整\(noun)起点"
            case .trailing: "调整\(noun)终点"
            }
            return feedbackDescriptor(
                icon: overlayTimelineDrag.mode == .move
                    ? "arrow.left.arrow.right" : "arrow.left.and.right",
                title: title,
                start: timing.startTime,
                end: timing.endTime,
                focus: resolved.focus ?? focus,
                status: resolved.status,
                tone: .overlay
            )
        }

        return nil
    }

    private func feedbackDescriptor(
        icon: String,
        title: String,
        start: TimeInterval,
        end: TimeInterval,
        focus: TimeInterval,
        status: String?,
        tone: EditorTimelineGestureFeedbackTone
    ) -> EditorTimelineGestureFeedbackDescriptor {
        EditorTimelineGestureFeedbackDescriptor(
            icon: icon,
            title: title,
            value: "\(timelineTimestamp(start)) – \(timelineTimestamp(end))  ·  \(timelineTimestamp(max(end - start, 0)))",
            status: status,
            guideTimes: [start, end],
            focusTime: focus,
            tone: tone
        )
    }

    private func timelineFeedbackStatus(
        start: TimeInterval,
        end: TimeInterval,
        preferredFocus: TimeInterval,
        minimumDuration: TimeInterval,
        duration: TimeInterval,
        anchors: [TimeInterval],
        considersBothEdges: Bool
    ) -> (status: String?, focus: TimeInterval?) {
        let tolerance = ZoomInterpolator.adjacencyTolerance + 0.000_1
        if end - start <= minimumDuration + 0.000_1 {
            return ("最短时长", preferredFocus)
        }
        let candidates = considersBothEdges ? [start, end] : [preferredFocus]
        for value in candidates {
            if abs(value) <= tolerance { return ("片头边界", value) }
            if abs(value - duration) <= tolerance { return ("片尾边界", value) }
            if anchors.contains(where: { abs($0 - value) <= tolerance }) {
                return ("已吸附", value)
            }
        }
        return (nil, nil)
    }

    private func previewMotionTiming(
        track: EditorMotionTimelineTrack,
        id: UUID
    ) -> TransitionTiming? {
        switch track {
        case .screen:
            return editorStore.previewProject.timeline.screenMotionClips
                .first(where: { $0.id == id })?.timing
        case .camera:
            return editorStore.previewProject.timeline.cameraMotionClips
                .first(where: { $0.id == id })?.timing
        }
    }

    private func motionFeedbackAnchors(
        track: EditorMotionTimelineTrack,
        excluding id: UUID
    ) -> [TimeInterval] {
        let timings: [TransitionTiming]
        switch track {
        case .screen:
            timings = editorStore.previewProject.timeline.screenMotionClips
                .filter { $0.id != id }.map(\.timing)
        case .camera:
            timings = editorStore.previewProject.timeline.cameraMotionClips
                .filter { $0.id != id }.map(\.timing)
        }
        return timings.flatMap { [$0.startTime, $0.endTime, $0.effectEndTime] }
    }

    private func persistedOverlayPreviewTiming(
        kind: EditorOverlayTimelineKind,
        id: UUID
    ) -> OverlayTiming? {
        switch kind {
        case .mosaic:
            return editorStore.previewProject.timeline.mosaicClips
                .first(where: { $0.id == id })?.timing
        case .sticker:
            return editorStore.previewProject.timeline.stickerClips
                .first(where: { $0.id == id })?.timing
        }
    }

    private func primaryReorderPlacement(
        draggedID: UUID,
        pointerX: CGFloat
    ) -> (oldIndex: Int, destination: Int, insertionTime: TimeInterval)? {
        guard let map = timelineMap,
              let oldIndex = map.segments.firstIndex(where: { $0.id == draggedID })
        else { return nil }
        let clampedX = min(max(pointerX, 0), max(timelineContentWidth, 1))
        guard let targetIndex = map.segments.indices.min(by: { lhs, rhs in
            let lhsCenter = CGFloat(
                (map.segments[lhs].outputStart + map.segments[lhs].outputDuration / 2)
                    / max(timelineDuration, 0.001)
            ) * timelineContentWidth
            let rhsCenter = CGFloat(
                (map.segments[rhs].outputStart + map.segments[rhs].outputDuration / 2)
                    / max(timelineDuration, 0.001)
            ) * timelineContentWidth
            return abs(lhsCenter - clampedX) < abs(rhsCenter - clampedX)
        }) else { return nil }
        let target = map.segments[targetIndex]
        let targetCenter = CGFloat(
            (target.outputStart + target.outputDuration / 2)
                / max(timelineDuration, 0.001)
        ) * timelineContentWidth
        var destination = targetIndex + (clampedX >= targetCenter ? 1 : 0)
        if oldIndex < destination { destination -= 1 }
        destination = min(max(destination, 0), map.segments.count - 1)
        var reordered = map.segments
        let moved = reordered.remove(at: oldIndex)
        reordered.insert(moved, at: destination)
        let insertionTime = reordered.prefix(destination).reduce(0) {
            $0 + $1.outputDuration
        }
        return (oldIndex, destination, insertionTime)
    }
}
