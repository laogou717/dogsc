import RecorderCore
import SwiftUI

enum EditorOverlayTimingEditing {
    static func adjustedTiming(
        original: OverlayTiming,
        mode: EditorMotionTimelineEditMode,
        delta: TimeInterval,
        timelineDuration: TimeInterval,
        minimumLeadingStartTime: TimeInterval = 0
    ) -> OverlayTiming {
        guard delta.isFinite, timelineDuration.isFinite, timelineDuration > 0 else {
            return original
        }
        let minimumDuration = min(0.08, max(original.duration, 0.001))
        var timing = original
        switch mode {
        case .move:
            timing.startTime = min(
                max(original.startTime + delta, 0),
                max(timelineDuration - original.duration, 0)
            )
        case .leading:
            let end = min(max(original.endTime, minimumDuration), timelineDuration)
            let lowerBound = min(
                max(minimumLeadingStartTime, 0),
                end - minimumDuration
            )
            timing.startTime = min(
                max(original.startTime + delta, lowerBound),
                end - minimumDuration
            )
            timing.duration = end - timing.startTime
        case .trailing:
            let end = min(
                max(original.endTime + delta, original.startTime + minimumDuration),
                timelineDuration
            )
            timing.duration = end - original.startTime
        }
        return timing
    }

}

extension EditorTimelineView {
    var overlayTimelineClips: [TimelineOverlayClip] {
        let mosaics = displayedEffectTimeline.mosaicClips.map {
            TimelineOverlayClip(
                id: $0.id,
                timing: $0.timing,
                title: appLocalized($0.style == .spotlight ? "突出" : "柔化"),
                tint: .orange,
                kind: .mosaic,
                layerIndex: -1
            )
        }
        let orderedStickers = displayedEffectTimeline.stickerClips
            .sorted {
                $0.layerIndex == $1.layerIndex
                    ? $0.id.uuidString < $1.id.uuidString
                    : $0.layerIndex < $1.layerIndex
            }
        let stickers = orderedStickers.enumerated().map { rank, sticker in
            TimelineOverlayClip(
                id: sticker.id,
                timing: sticker.timing,
                title: orderedStickers.count > 1
                    ? String(format: appLocalized("贴图 · 层 %lld"), Int64(rank + 1))
                    : appLocalized("贴图"),
                tint: editorOverlayClip,
                kind: .sticker,
                layerIndex: sticker.layerIndex
            )
        }
        return (mosaics + stickers).sorted {
            if $0.timing.startTime != $1.timing.startTime {
                return $0.timing.startTime < $1.timing.startTime
            }
            if $0.layerIndex != $1.layerIndex {
                return $0.layerIndex < $1.layerIndex
            }
            return $0.id.uuidString < $1.id.uuidString
        }
    }

    /// Greedy interval packing gives every simultaneously visible overlay its
    /// own row while allowing non-overlapping clips to reuse space. No clip is
    /// hidden behind another merely because their authored times coincide.
    var overlayTimelineRows: [[TimelineOverlayClip]] {
        var rows: [[TimelineOverlayClip]] = []
        var rowEnds: [TimeInterval] = []
        for clip in overlayTimelineClips {
            if let row = rowEnds.firstIndex(where: {
                $0 <= clip.timing.startTime + 0.000_001
            }) {
                rows[row].append(clip)
                rowEnds[row] = clip.timing.endTime
            } else {
                rows.append([clip])
                rowEnds.append(clip.timing.endTime)
            }
        }
        return rows
    }

    func trimMosaicClip(
        id: UUID,
        edge: RecordingSegmentTrimEdge,
        atTime time: TimeInterval
    ) {
        var timeline = editorStore.project.timeline
        guard let index = timeline.mosaicClips.firstIndex(where: { $0.id == id }) else {
            return
        }
        var clip = timeline.mosaicClips[index]
        guard trimOverlayTiming(&clip.timing, edge: edge, atTime: time) else {
            return
        }
        timeline.mosaicClips[index] = clip
        replaceOverlayTimeline(timeline, actionName: "修剪打码")
    }

    func trimStickerClip(
        id: UUID,
        edge: RecordingSegmentTrimEdge,
        atTime time: TimeInterval
    ) {
        var timeline = editorStore.project.timeline
        guard let index = timeline.stickerClips.firstIndex(where: { $0.id == id }) else {
            return
        }
        var clip = timeline.stickerClips[index]
        guard trimOverlayTiming(&clip.timing, edge: edge, atTime: time) else {
            return
        }
        timeline.stickerClips[index] = clip
        replaceOverlayTimeline(timeline, actionName: "修剪贴图")
    }

    private func trimOverlayTiming(
        _ timing: inout OverlayTiming,
        edge: RecordingSegmentTrimEdge,
        atTime time: TimeInterval
    ) -> Bool {
        guard time > timing.startTime + 0.01,
              time < timing.endTime - 0.01 else { return false }
        switch edge {
        case .left:
            let end = timing.endTime
            timing.startTime = time
            timing.duration = end - time
        case .right:
            timing.duration = time - timing.startTime
        }
        return true
    }

    private func replaceOverlayTimeline(
        _ timeline: ProjectTimeline,
        actionName: String
    ) {
        do {
            try editorStore.replaceTimeline(with: timeline, actionName: actionName)
        } catch {
            onError(error.localizedDescription)
        }
    }

    func splitMosaicClip(id: UUID, atTime time: TimeInterval) {
        var timeline = editorStore.project.timeline
        guard let index = timeline.mosaicClips.firstIndex(where: { $0.id == id }) else {
            return
        }
        let original = timeline.mosaicClips[index]
        guard time > original.timing.startTime + 0.01,
              time < original.timing.endTime - 0.01 else { return }
        var left = original
        left.timing.duration = time - original.timing.startTime
        var right = original
        right.id = UUID()
        right.timing = OverlayTiming(
            startTime: time,
            duration: original.timing.endTime - time
        )
        timeline.mosaicClips.replaceSubrange(index...index, with: [left, right])
        do {
            try editorStore.replaceTimeline(with: timeline, actionName: "分割打码")
            editorStore.selection = .mosaic(right.id)
        } catch {
            onError(error.localizedDescription)
        }
    }

    func splitStickerClip(id: UUID, atTime time: TimeInterval) {
        var timeline = editorStore.project.timeline
        guard let index = timeline.stickerClips.firstIndex(where: { $0.id == id }) else {
            return
        }
        let original = timeline.stickerClips[index]
        guard time > original.timing.startTime + 0.01,
              time < original.timing.endTime - 0.01 else { return }
        var left = original
        left.timing.duration = time - original.timing.startTime
        var right = original
        right.id = UUID()
        right.timing = OverlayTiming(
            startTime: time,
            duration: original.timing.endTime - time
        )
        timeline.stickerClips.replaceSubrange(index...index, with: [left, right])
        do {
            try editorStore.replaceTimeline(with: timeline, actionName: "分割贴图")
            editorStore.selection = .sticker(right.id)
        } catch {
            onError(error.localizedDescription)
        }
    }

    func combinedOverlayTimeline(
        width: CGFloat,
        duration: TimeInterval
    ) -> some View {
        let rows = overlayTimelineRows
        return ZStack(alignment: .topLeading) {
            timelineLaneSurface(
                tint: editorOverlayClip,
                isFocused: focusedTimelineLane == .overlays
            )
            Color.clear
                .contentShape(Rectangle())
                .gesture(overlayTrackGesture(clips: [], timelineWidth: width, duration: duration))
            if rows.isEmpty {
                timelineEmptyTrackHint(
                    "单击或拖拽添加",
                    documentWidth: width
                )
                    .frame(height: overlayTimelineHeight)
            }
            VStack(spacing: 4) {
                ForEach(Array(rows.enumerated()), id: \.offset) { _, clips in
                    overlayClipRow(
                        clips: clips,
                        width: width,
                        duration: duration
                    )
                }
            }
            .padding(.vertical, 10)
            if let range = overlayCreateRange, range.upperBound - range.lowerBound > 0.01 {
                RoundedRectangle(cornerRadius: 7)
                    .fill(editorOverlayClip.opacity(0.18))
                    .overlay(RoundedRectangle(cornerRadius: 7)
                        .strokeBorder(editorOverlayClip.opacity(0.6), style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
                    .frame(width: max(CGFloat((range.upperBound - range.lowerBound) / duration) * width, 3), height: 30)
                    .offset(x: CGFloat(range.lowerBound / duration) * width, y: 10)
                    .allowsHitTesting(false)
            }
        }
        .frame(
            width: width,
            height: overlayTimelineHeight,
            alignment: .topLeading
        )
    }

    private func overlayClipRow(
        clips: [TimelineOverlayClip],
        width: CGFloat,
        duration: TimeInterval
    ) -> some View {
        ZStack(alignment: .topLeading) {
            // Match the zoom lane's layout contract: the lane itself owns the
            // complete 0...duration coordinate space.  Offset clip views are
            // only visual occupants of that space; their intrinsic widths must
            // never determine the row origin or its gesture coordinates.
            Color.clear
                .frame(width: width, height: 30)
                .allowsHitTesting(false)

            ForEach(clips) { clip in
                let x = CGFloat(clip.timing.startTime / max(duration, 0.001)) * width
                let clipWidth = max(
                    CGFloat(clip.timing.duration / max(duration, 0.001)) * width,
                    3
                )
                let selection = clip.kind.selection(id: clip.id)
                let isSelected = editorStore.selection == selection
                let isHovered = hoveredOverlaySelection == selection
                let emphasis = EditorTimelineClipEmphasis.resolve(
                    isEditing: overlayTimelineDrag?.id == clip.id
                        && overlayTimelineDrag?.kind == clip.kind,
                    isSelected: isSelected,
                    isHovered: isHovered
                )
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(
                        isSelected
                            ? EditorTheme.chrome(0.20)
                            : EditorTheme.chrome(isHovered ? 0.12 : 0.075)
                    )
                    .overlay {
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .fill(clip.tint.opacity(isSelected ? 0.34 : isHovered ? 0.24 : 0.18))
                    }
                    .overlay(alignment: .leading) {
                        if clipWidth >= 52 {
                            Text(clip.title)
                                .font(.appUI(size: 10, weight: .semibold))
                                .lineLimit(1)
                                .padding(.horizontal, 9)
                        }
                    }
                    .overlay {
                        if emphasis.showsHandles, clipWidth >= 22 {
                            HStack(spacing: 0) {
                                Capsule()
                                    .fill(EditorTheme.chrome(0.9))
                                    .frame(width: 3, height: 13)
                                Spacer(minLength: 0)
                                Capsule()
                                    .fill(EditorTheme.chrome(0.9))
                                    .frame(width: 3, height: 13)
                            }
                            .padding(.horizontal, 2)
                            .opacity(emphasis.handleOpacity)
                            .allowsHitTesting(false)
                        }
                    }
                    .editorTimelineClipChrome(cornerRadius: 7, emphasis: emphasis)
                    .contentShape(Rectangle())
                .frame(width: clipWidth, height: 30)
                .offset(x: x)
                .zIndex(emphasis == .editing ? 4 : isSelected ? 3 : isHovered ? 1 : 0)
                .onHover { hovering in
                    if hovering {
                        hoveredOverlaySelection = selection
                    } else if hoveredOverlaySelection == selection {
                        hoveredOverlaySelection = nil
                    }
                }
                .contextMenu { clipClipboardMenu(for: selection) }
                .help("拖动中部移动；拖动两端调整时长")
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(String(format: appLocalized("%@片段"), clip.title))
                .accessibilityValue(
                    String(
                        format: appLocalized("开始 %.2f 秒，时长 %.2f 秒"),
                        clip.timing.startTime,
                        clip.timing.duration
                    )
                )
                .accessibilityAddTraits(
                    isSelected ? [.isButton, .isSelected] : .isButton
                )
                .accessibilityAction {
                    activateTimelineSelection(selection)
                }
            }
        }
        .frame(width: width, height: 30, alignment: .leading)
        .contentShape(Rectangle())
        // The lane owns the gesture. A clip must never be both the moving
        // visual and the coordinate system that interprets that movement.
        .gesture(overlayTrackGesture(
            clips: clips,
            timelineWidth: width,
            duration: duration
        ))
    }

    func overlayTrackGesture(
        clips: [TimelineOverlayClip],
        timelineWidth: CGFloat,
        duration: TimeInterval
    ) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                if overlayTimelineDrag == nil, overlayCreateRange == nil {
                    beginOverlayTimelineDrag(
                        at: value.startLocation.x,
                        clips: clips,
                        timelineWidth: timelineWidth,
                        duration: duration
                    )
                }
                if gestureOwnership.activeIntent == .overlayCreate {
                    let start = overlayCreateStart ?? EditorTimelineMath.clampedTime(atX: Double(value.startLocation.x),
                        width: Double(timelineWidth), duration: duration)
                    let end = magneticTime(EditorTimelineMath.clampedTime(atX: Double(value.location.x),
                        width: Double(timelineWidth), duration: duration), width: timelineWidth, duration: duration)
                    overlayCreateRange = min(start, end)...max(start, end)
                    return
                }
                guard let drag = overlayTimelineDrag else { return }
                let intent = EditorTimelineGestureIntent.overlay(
                    drag.kind,
                    drag.id,
                    drag.mode
                )
                guard gestureOwnership.activeIntent == intent else { return }
                let rawDelta = TimeInterval(value.translation.width / max(timelineWidth, 1)) * duration
                let delta = magneticDelta(rawDelta, start: drag.original.startTime,
                    end: drag.original.endTime, mode: drag.mode, width: timelineWidth, duration: duration)
                let timing = adjustedOverlayTiming(
                    original: drag.original,
                    mode: drag.mode,
                    delta: delta,
                    timelineDuration: duration,
                    minimumLeadingStartTime: 0
                )
                timelineSnap.validate(edges: drag.mode == .move ? [timing.startTime, timing.endTime]
                    : [drag.mode == .leading ? timing.startTime : timing.endTime])
                updateOverlayTimingDraft(drag: drag, timing: timing)
            }
            .onEnded { value in
                if gestureOwnership.activeIntent == .overlayCreate, let range = overlayCreateRange {
                    overlayCreateRange = nil
                    overlayCreateStart = nil
                    endTimelineGesture(.overlayCreate)
                    let isDrawnRange = EditorTimelineRangeCreationPolicy.shouldCommit(
                        horizontalTranslation: value.translation.width)
                    if !isDrawnRange && emptyClickClearsSelection { return }
                    let length = isDrawnRange ? max(range.upperBound - range.lowerBound, 0.08) : 3
                    let start = min(range.lowerBound, max(duration - length, 0))
                    let clip = MosaicClip(timing: OverlayTiming(startTime: start,
                        duration: min(length, duration - start)))
                    playbackController.pause()
                    var timeline = editorStore.project.timeline
                    timeline.mosaicClips.append(clip)
                    do {
                        try withAnimation(SpringMotion.fluid) {
                            try editorStore.replaceTimeline(with: timeline, actionName: "添加柔化")
                        }
                        activateTimelineSelection(.mosaic(clip.id))
                    } catch { onError(error.localizedDescription) }
                    return
                }
                guard let drag = overlayTimelineDrag else { return }
                let intent = EditorTimelineGestureIntent.overlay(
                    drag.kind,
                    drag.id,
                    drag.mode
                )
                overlayTimelineDrag = nil
                guard gestureOwnership.activeIntent == intent else { return }
                if drag.mode == .move, abs(value.translation.width) < 3 {
                    editorStore.cancelInteraction()
                    activateTimelineSelection(drag.kind.selection(id: drag.id))
                } else {
                    commitOverlayTimelineDrag(drag)
                }
                endTimelineGesture(intent)
            }
    }

    func beginOverlayTimelineDrag(
        at x: CGFloat,
        clips: [TimelineOverlayClip],
        timelineWidth: CGFloat,
        duration: TimeInterval
    ) {
        cancelActiveTimelineGesture()
        let candidates = clips.filter { clip in
            let startX = CGFloat(
                clip.timing.startTime / max(duration, 0.001)
            ) * timelineWidth
            let clipWidth = max(
                CGFloat(clip.timing.duration / max(duration, 0.001))
                    * timelineWidth,
                3
            )
            return x >= startX && x <= startX + clipWidth
        }
        guard let clip = candidates.first(where: {
            editorStore.selection == $0.kind.selection(id: $0.id)
        }) ?? candidates.last else {
            prepareEmptyTimelineClick()
            guard beginTimelineGesture(.overlayCreate) else { return }
            let start = EditorTimelineMath.clampedTime(atX: Double(x),
                width: Double(timelineWidth), duration: duration)
            let snapped = magneticTime(start, width: timelineWidth, duration: duration)
            overlayCreateStart = snapped
            overlayCreateRange = snapped...snapped
            return
        }
        let startX = CGFloat(
            clip.timing.startTime / max(duration, 0.001)
        ) * timelineWidth
        let clipWidth = max(
            CGFloat(clip.timing.duration / max(duration, 0.001))
                * timelineWidth,
            3
        )
        let localX = x - startX
        let edgeWidth = min(max(clipWidth * 0.14, 5), 8)
        let mode: EditorMotionTimelineEditMode
        if clipWidth >= edgeWidth * 2 + 12, localX <= edgeWidth {
            mode = .leading
        } else if clipWidth >= edgeWidth * 2 + 12,
                  localX >= clipWidth - edgeWidth {
            mode = .trailing
        } else {
            mode = .move
        }
        let intent = EditorTimelineGestureIntent.overlay(clip.kind, clip.id, mode)
        guard beginTimelineGesture(intent),
              let timing = persistedOverlayTiming(kind: clip.kind, id: clip.id)
        else {
            endTimelineGesture(intent)
            return
        }
        playbackController.pause(revealingPlayhead: false)
        let selection = clip.kind.selection(id: clip.id)
        editorStore.beginInteraction(tool: .select, selection: selection)
        timelineInteractionID = editorStore.interaction?.id
        overlayTimelineDrag = EditorOverlayTimelineDrag(
            kind: clip.kind,
            id: clip.id,
            mode: mode,
            original: timing
        )
    }

    func persistedOverlayTiming(
        kind: EditorOverlayTimelineKind,
        id: UUID
    ) -> OverlayTiming? {
        switch kind {
        case .mosaic:
            return editorStore.project.timeline.mosaicClips
                .first(where: { $0.id == id })?.timing
        case .sticker:
            return editorStore.project.timeline.stickerClips
                .first(where: { $0.id == id })?.timing
        }
    }

    func adjustedOverlayTiming(
        original: OverlayTiming,
        mode: EditorMotionTimelineEditMode,
        delta: TimeInterval,
        timelineDuration: TimeInterval,
        minimumLeadingStartTime: TimeInterval = 0
    ) -> OverlayTiming {
        EditorOverlayTimingEditing.adjustedTiming(
            original: original,
            mode: mode,
            delta: delta,
            timelineDuration: timelineDuration,
            minimumLeadingStartTime: minimumLeadingStartTime
        )
    }

    func updateOverlayTimingDraft(
        drag: EditorOverlayTimelineDrag,
        timing: OverlayTiming
    ) {
        editorStore.updateInteraction { project in
            switch drag.kind {
            case .mosaic:
                guard let index = project.timeline.mosaicClips.firstIndex(where: {
                    $0.id == drag.id
                }) else { return }
                project.timeline.mosaicClips[index].timing = timing
            case .sticker:
                guard let index = project.timeline.stickerClips.firstIndex(where: {
                    $0.id == drag.id
                }) else { return }
                project.timeline.stickerClips[index].timing = timing
            }
        }
    }

    func commitOverlayTimelineDrag(_ drag: EditorOverlayTimelineDrag) {
        do {
            _ = try editorStore.commitInteraction(
                actionName: drag.mode == .move
                    ? drag.kind.moveActionName
                    : drag.kind.resizeActionName
            )
            // A move/resize is not an instruction to seek to this object.
        } catch {
            editorStore.cancelInteraction()
            onError(error.localizedDescription)
        }
    }
}

struct TimelineOverlayClip: Identifiable {
    let id: UUID
    let timing: OverlayTiming
    let title: String
    let tint: Color
    let kind: EditorOverlayTimelineKind
    let layerIndex: Int
}
