import RecorderCore
import SwiftUI

extension EditorTimelineView {
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
        let mosaicClips = editorStore.previewProject.timeline.mosaicClips.map {
            TimelineOverlayClip(
                id: $0.id,
                timing: $0.timing,
                title: $0.style == .spotlight ? "突出" : "柔化",
                tint: .orange,
                kind: .mosaic
            )
        }
        let orderedStickers = editorStore.previewProject.timeline.stickerClips
            .sorted {
                $0.layerIndex == $1.layerIndex
                    ? $0.id.uuidString < $1.id.uuidString
                    : $0.layerIndex < $1.layerIndex
            }
        let stickerClips = orderedStickers.enumerated().map { rank, sticker in
            TimelineOverlayClip(
                id: sticker.id,
                timing: sticker.timing,
                title: orderedStickers.count > 1
                    ? "贴图 · 层 \(rank + 1)"
                    : "贴图",
                tint: editorOverlayClip,
                kind: .sticker
            )
        }
        return ZStack(alignment: .topLeading) {
            timelineLaneSurface(
                tint: editorOverlayClip,
                isFocused: focusedTimelineLane == .overlays
            )
            if mosaicClips.isEmpty && stickerClips.isEmpty {
                timelineEmptyTrackHint(
                    "从顶部“添加”加入柔化或贴图",
                    documentWidth: width
                )
                    .frame(height: overlayTimelineHeight)
            }
            VStack(spacing: 2) {
                overlayClipRow(
                    clips: mosaicClips,
                    width: width,
                    duration: duration
                )
                overlayClipRow(
                    clips: stickerClips,
                    width: width,
                    duration: duration
                )
            }
            // 19 + 2 + 19 + 1×2 = 42，严格落在单条叠加轨内，
            // 不向相邻进度条/运动轨的命中区溢出。
            .padding(.vertical, 1)
        }
        .frame(
            width: width,
            height: overlayTimelineHeight,
            alignment: .topLeading
        )
        .overlay(alignment: .bottom) { Divider().overlay(dividerColor) }
    }

    func progressOverlayTimeline(
        width: CGFloat,
        duration: TimeInterval
    ) -> some View {
        ZStack(alignment: .topLeading) {
            timelineLaneSurface(
                tint: editorProgressClip,
                isFocused: focusedTimelineLane == .progress
            )
            if editorStore.previewProject.timeline.progressOverlay != nil {
                Button {
                    editorStore.selection = .progress
                } label: {
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(Color(white: editorStore.selection == .progress ? 0.26 : 0.15))
                        .overlay {
                            RoundedRectangle(cornerRadius: 7, style: .continuous)
                                .fill(editorProgressClip.opacity(
                                    editorStore.selection == .progress ? 0.34 : 0.16
                                ))
                        }
                        .overlay {
                            if editorStore.selection == .progress {
                                RoundedRectangle(cornerRadius: 7, style: .continuous)
                                    .stroke(
                                        EditorTheme.platinumAccent.opacity(0.72),
                                        lineWidth: 1
                                    )
                            }
                        }
                        .padding(.vertical, 7)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("选择全片进度条")
            } else {
                timelineEmptyTrackHint(
                    "从顶部“添加”创建进度条",
                    documentWidth: width
                )
                    .frame(height: overlayTimelineHeight)
            }
        }
        .frame(
            width: width,
            height: overlayTimelineHeight,
            alignment: .topLeading
        )
        .overlay(alignment: .bottom) { Divider().overlay(dividerColor) }
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
                .frame(width: width, height: 19)
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
                    .fill(Color(white: isSelected ? 0.26 : isHovered ? 0.20 : 0.16))
                    .overlay {
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .fill(clip.tint.opacity(isSelected ? 0.34 : isHovered ? 0.24 : 0.18))
                    }
                    .overlay(alignment: .leading) {
                        if clipWidth >= 52 {
                            Text(clip.title)
                                .font(.system(size: 10, weight: .semibold))
                                .lineLimit(1)
                                .padding(.horizontal, 9)
                        }
                    }
                    .overlay {
                        if emphasis.showsHandles, clipWidth >= 22 {
                            HStack(spacing: 0) {
                                Capsule()
                                    .fill(Color.white.opacity(0.9))
                                    .frame(width: 3, height: 13)
                                Spacer(minLength: 0)
                                Capsule()
                                    .fill(Color.white.opacity(0.9))
                                    .frame(width: 3, height: 13)
                            }
                            .padding(.horizontal, 2)
                            .opacity(emphasis.handleOpacity)
                            .allowsHitTesting(false)
                        }
                    }
                    .editorTimelineClipChrome(cornerRadius: 7, emphasis: emphasis)
                    .contentShape(Rectangle())
                .frame(width: clipWidth, height: 19)
                .offset(x: x)
                .zIndex(emphasis == .editing ? 4 : isSelected ? 3 : isHovered ? 1 : 0)
                .onHover { hovering in
                    if hovering {
                        hoveredOverlaySelection = selection
                    } else if hoveredOverlaySelection == selection {
                        hoveredOverlaySelection = nil
                    }
                }
                .help("拖动中部移动；拖动两端调整时长")
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("\(clip.title)片段")
                .accessibilityValue(
                    String(
                        format: "开始 %.2f 秒，时长 %.2f 秒",
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
        .frame(width: width, height: 19, alignment: .leading)
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
                if overlayTimelineDrag == nil {
                    beginOverlayTimelineDrag(
                        at: value.startLocation.x,
                        clips: clips,
                        timelineWidth: timelineWidth,
                        duration: duration
                    )
                }
                guard let drag = overlayTimelineDrag else { return }
                let intent = EditorTimelineGestureIntent.overlay(
                    drag.kind,
                    drag.id,
                    drag.mode
                )
                guard gestureOwnership.activeIntent == intent else { return }
                let delta = TimeInterval(
                    value.translation.width / max(timelineWidth, 1)
                ) * duration
                let timing = adjustedOverlayTiming(
                    original: drag.original,
                    mode: drag.mode,
                    delta: delta,
                    timelineDuration: duration
                )
                updateOverlayTimingDraft(drag: drag, timing: timing)
            }
            .onEnded { value in
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
        }) ?? candidates.last else { return }
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
        playbackController.pause()
        let selection = clip.kind.selection(id: clip.id)
        editorStore.beginInteraction(tool: .select, selection: selection)
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
        timelineDuration: TimeInterval
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
            timing.startTime = min(
                max(original.startTime + delta, 0),
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
            activateTimelineSelection(drag.kind.selection(id: drag.id))
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
}
