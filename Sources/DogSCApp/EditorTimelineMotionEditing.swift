import AppKit
import RecorderCore
import SwiftUI
import UniformTypeIdentifiers

extension EditorTimelineView {
var screenMotionTimelineClips: [EditorMotionTimelineClip] {
        derivedPresentationCache.screenMotionClips(
            clips: editorStore.previewProject.timeline.screenMotionClips,
            duration: timelineDuration
        )
    }

    var cameraMotionTimelineClips: [EditorMotionTimelineClip] {
        derivedPresentationCache.cameraMotionClips(
            clips: editorStore.previewProject.timeline.cameraMotionClips,
            duration: timelineDuration
        )
    }

    func motionTimeline(
        track: EditorMotionTimelineTrack,
        clips: [EditorMotionTimelineClip],
        width: CGFloat,
        duration: TimeInterval
    ) -> some View {
        let visibleTimeRange = EditorTimelineViewportPresentation.bufferedTimeRange(
            documentWidth: width,
            duration: duration,
            visibleRange: clampedTimelineVisibleDocumentRange(width: width)
        )
        let visibleClipIndices = EditorTimelineViewportPresentation.visibleIntervalIndices(
            in: clips,
            timeRange: visibleTimeRange,
            startTime: { $0.timing.startTime },
            endTime: { $0.timing.endTime },
            retainingIndices: motionRetainedClipIndices(for: track)
        )
        return ZStack(alignment: .leading) {
            timelineLaneSurface(
                tint: motionTrackColor(track),
                isFocused: focusedTimelineLane == (track == .screen ? .screenMotion : .cameraMotion)
            )

            if clips.isEmpty {
                timelineEmptyTrackHint(
                    track == .screen
                        ? "拖动空白处添加屏幕 3D"
                        : "拖动空白处添加摄像运动",
                    documentWidth: width
                )
            }

            ForEach(visibleClipIndices, id: \.self) { index in
                let clip = clips[index]
                let visibleStart = min(max(clip.timing.startTime, 0), duration)
                let visibleEnd = min(max(clip.timing.endTime, visibleStart), duration)
                let startX = CGFloat(visibleStart / max(duration, 0.001)) * width
                let clipWidth = max(
                    CGFloat((visibleEnd - visibleStart) / max(duration, 0.001)) * width,
                    7
                )
                let selected = isMotionClipSelected(clip)
                let hovered = hoveredMotionClip?.id == clip.id
                    && hoveredMotionClip?.track == clip.track
                let emphasis = EditorTimelineClipEmphasis.resolve(
                    isEditing: isMotionClipEditing(clip),
                    isSelected: selected,
                    isHovered: hovered
                )
                // 片段全部保留圆角；首尾相接处在交界处画一条分割线，
                // 既能看出是两段，又不会像两个圆角叠在一起那样脏。
                let touchesPrevious = index > 0
                    && clips[index - 1].timing.endTime
                        >= clip.timing.startTime - ZoomInterpolator.adjacencyTolerance

                if touchesPrevious {
                    Rectangle()
                        .fill(Color.black.opacity(0.55))
                        .frame(width: 1.5, height: 24)
                        .offset(x: startX - 0.75)
                        .allowsHitTesting(false)
                }

                ZStack {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [
                                    motionTrackColor(track).opacity(0.72),
                                    motionTrackColor(track).opacity(0.96),
                                ],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                        )
                        .overlay {
                            if clipWidth > 72 {
                                HStack(spacing: 5) {
                                    Image(systemName: track == .screen ? "move.3d" : "video.badge.ellipsis")
                                    Text("过渡 \(index + 1)")
                                    if clipWidth > 116 {
                                        Text(timelineTimestamp(clip.timing.duration))
                                            .foregroundStyle(.white.opacity(0.7))
                                    }
                                }
                                .font(.system(size: 10, weight: .semibold))
                                .lineLimit(1)
                                .padding(.horizontal, 9)
                            }
                        }
                        .editorTimelineClipChrome(cornerRadius: 6, emphasis: emphasis)

                    if emphasis.showsHandles {
                        HStack(spacing: 0) {
                            motionResizeHandle(leading: true)
                            Spacer(minLength: 0)
                            motionResizeHandle(leading: false)
                        }
                        .padding(.horizontal, 0.5)
                        .opacity(emphasis.handleOpacity)
                        .allowsHitTesting(false)
                    }
                }
                .frame(width: clipWidth, height: 36)
                .offset(x: startX)
                .zIndex(emphasis == .editing ? 4 : selected ? 3 : hovered ? 1 : 0)
                .contentShape(Rectangle())
                .contextMenu {
                    Button(role: .destructive) {
                        removeMotionClip(clip)
                    } label: {
                        Label("删除动画", systemImage: "trash")
                    }
                }
                .onHover { hovering in
                    if hovering {
                        hoveredMotionClip = clip
                    } else if hoveredMotionClip?.id == clip.id,
                              hoveredMotionClip?.track == clip.track {
                        hoveredMotionClip = nil
                    }
                }
                .accessibilityElement(children: .ignore)
                .help("单击选中；拖动移动过渡；拖两端调整时长；右键可删除")
                .accessibilityLabel(track == .screen ? "屏幕 3D \(index + 1)" : "摄像运动 \(index + 1)")
                .accessibilityValue(
                    "\(timelineTimestamp(clip.timing.startTime)) 至 \(timelineTimestamp(clip.timing.endTime))"
                )
                .accessibilityAddTraits(
                    selected ? [.isButton, .isSelected] : .isButton
                )
                .accessibilityAction {
                    activateTimelineSelection(
                        clip.track == .screen
                            ? .screenMotion(clip.id)
                            : .cameraMotion(clip.id)
                    )
                }
                .accessibilityIdentifier(
                    "editor.timeline.motion.\(track == .screen ? "screen" : "camera").\(clip.id.uuidString)"
                )
            }

            // 悬浮空白处显示创建起点；需要水平拖动形成区间，单击不会写入动画。
            if let indicatorX = motionCreateIndicatorX(
                track: track,
                clips: clips,
                width: width,
                duration: duration
            ) {
                Image(systemName: "plus")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 16, height: 16)
                    .background(Circle().fill(motionTrackColor(track)))
                    .offset(x: indicatorX - 8)
                    .allowsHitTesting(false)
            }

            if let drag = motionCreateDrag, drag.track == track {
                let start = min(drag.start, drag.end)
                let end = max(drag.start, drag.end)
                let startX = CGFloat(start / max(duration, 0.001)) * width
                let rangeWidth = max(CGFloat((end - start) / max(duration, 0.001)) * width, 4)
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(motionTrackColor(track).opacity(0.42))
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(.white.opacity(0.8), style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
                    )
                    .frame(width: rangeWidth, height: 36)
                    .offset(x: startX)
                    .allowsHitTesting(false)
            }
        }
        .frame(width: width, height: motionTimelineHeight, alignment: .leading)
        .overlay(alignment: .bottom) { Divider().overlay(dividerColor) }
        .contentShape(Rectangle())
        // 与缩放轨同一单手势分发模型：按下按命中区域（手柄/片段/空白）分发为
        // 调整、移动或创建。
        .gesture(motionTrackGesture(track: track, width: width, duration: duration))
        .onContinuousHover(coordinateSpace: .local) { phase in
            switch phase {
            case let .active(location):
                motionTrackHover[track] = location
            case .ended:
                motionTrackHover[track] = nil
            }
        }
    }

    private func motionRetainedClipIndices(
        for track: EditorMotionTimelineTrack
    ) -> [Int] {
        let selectedID = track == .screen
            ? selectedScreenMotionID : selectedCameraMotionID
        let gestureID = motionGestureOrigin?.clip.track == track
            ? motionGestureOrigin?.clip.id : nil
        switch track {
        case .screen:
            return [
                derivedPresentationCache.screenMotionClipIndex(for: selectedID),
                derivedPresentationCache.screenMotionClipIndex(for: gestureID),
            ].compactMap { $0 }
        case .camera:
            return [
                derivedPresentationCache.cameraMotionClipIndex(for: selectedID),
                derivedPresentationCache.cameraMotionClipIndex(for: gestureID),
            ].compactMap { $0 }
        }
    }

    func motionResizeHandle(leading: Bool) -> some View {
        Capsule(style: .continuous)
            .fill(Color.white.opacity(0.94))
            .frame(width: 3, height: 26)
            .accessibilityLabel(leading ? "调整动画开始" : "调整动画结束")
    }

    func motionTrackColor(_ track: EditorMotionTimelineTrack) -> Color {
        switch track {
        case .screen: return Color(red: 0.85, green: 0.58, blue: 0.24)
        case .camera: return Color(red: 0.43, green: 0.67, blue: 0.47)
        }
    }

    func isMotionClipSelected(_ clip: EditorMotionTimelineClip) -> Bool {
        switch clip.track {
        case .screen: return selectedScreenMotionID == clip.id
        case .camera: return selectedCameraMotionID == clip.id
        }
    }

    enum MotionTrackDrag: Equatable {
        case create
        case move(UUID)
        case resize(UUID, leading: Bool)
    }

    func isMotionClipEditing(_ clip: EditorMotionTimelineClip) -> Bool {
        switch motionTrackDrag {
        case let .move(id), let .resize(id, _):
            return id == clip.id && motionGestureOrigin?.clip.track == clip.track
        case .create, nil:
            return false
        }
    }

    struct MotionCreateDragState: Equatable {
        let track: EditorMotionTimelineTrack
        var start: TimeInterval
        var end: TimeInterval
    }

    func motionTrackGesture(
        track: EditorMotionTimelineTrack,
        width: CGFloat,
        duration: TimeInterval
    ) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                if motionTrackDrag == nil {
                    beginMotionTrackDrag(
                        at: value.startLocation,
                        track: track,
                        width: width,
                        duration: duration
                    )
                }
                switch motionTrackDrag {
                case .create:
                    guard gestureOwnership.activeIntent == .motionCreate(track),
                          var drag = motionCreateDrag else { return }
                    drag.end = EditorTimelineMath.clampedTime(
                        atX: Double(value.location.x),
                        width: Double(width),
                        duration: duration
                    )
                    motionCreateDrag = drag
                    if EditorTimelineRangeCreationPolicy.shouldCommit(
                        horizontalTranslation: value.translation.width
                    ) {
                        playbackController.pause()
                    }
                case let .move(id):
                    let intent = EditorTimelineGestureIntent.motion(
                        track, id, EditorMotionTimelineEditMode.move
                    )
                    guard gestureOwnership.activeIntent == intent,
                          let origin = motionGestureOrigin else { return }
                    let delta = TimeInterval(value.translation.width / max(width, 1)) * duration
                    let timing = EditorMotionTimelinePresentation.adjustedTiming(
                        original: origin.clip.timing,
                        mode: .move,
                        delta: delta,
                        bounds: origin.bounds,
                        timelineDuration: duration
                    )
                    updateMotionTimingDraft(
                        clip: origin.clip,
                        timing: timing,
                        partnerOrigins: origin.partnerOrigins,
                        timelineDuration: duration
                    )
                case let .resize(id, leading):
                    let mode: EditorMotionTimelineEditMode = leading ? .leading : .trailing
                    let intent = EditorTimelineGestureIntent.motion(track, id, mode)
                    guard gestureOwnership.activeIntent == intent,
                          let origin = motionGestureOrigin else { return }
                    let delta = TimeInterval(value.translation.width / max(width, 1)) * duration
                    let timing = EditorMotionTimelinePresentation.adjustedTiming(
                        original: origin.clip.timing,
                        mode: mode,
                        delta: delta,
                        bounds: origin.bounds,
                        timelineDuration: duration
                    )
                    updateMotionTimingDraft(
                        clip: origin.clip,
                        timing: timing,
                        partnerOrigins: origin.partnerOrigins,
                        timelineDuration: duration
                    )
                case nil:
                    break
                }
            }
            .onEnded { value in
                let drag = motionTrackDrag
                let create = motionCreateDrag
                let origin = motionGestureOrigin
                motionTrackDrag = nil
                motionCreateDrag = nil
                motionGestureOrigin = nil
                switch drag {
                case .create:
                    guard gestureOwnership.activeIntent == .motionCreate(track),
                          let create else { return }
                    guard EditorTimelineRangeCreationPolicy.shouldCommit(
                        horizontalTranslation: value.translation.width
                    ) else {
                        clearTimelineSelection()
                        endTimelineGesture(.motionCreate(track))
                        return
                    }
                    createManualMotionClip(drag: create, duration: duration)
                    endTimelineGesture(.motionCreate(track))
                case let .move(id):
                    let intent = EditorTimelineGestureIntent.motion(
                        track, id, EditorMotionTimelineEditMode.move
                    )
                    guard gestureOwnership.activeIntent == intent else { return }
                    if abs(value.translation.width) < 3 {
                        editorStore.cancelInteraction()
                        if let origin {
                            activateTimelineSelection(
                                track == .screen
                                    ? .screenMotion(origin.clip.id)
                                    : .cameraMotion(origin.clip.id)
                            )
                        }
                    } else {
                        commitMotionGesture(origin: origin)
                    }
                    endTimelineGesture(intent)
                case let .resize(id, leading):
                    let mode: EditorMotionTimelineEditMode = leading ? .leading : .trailing
                    let intent = EditorTimelineGestureIntent.motion(track, id, mode)
                    guard gestureOwnership.activeIntent == intent else { return }
                    commitMotionGesture(origin: origin)
                    endTimelineGesture(intent)
                case nil:
                    break
                }
            }
    }

    func beginMotionTrackDrag(
        at point: CGPoint,
        track: EditorMotionTimelineTrack,
        width: CGFloat,
        duration: TimeInterval
    ) {
        // Keep the motion lanes on the same complete-session boundary as the
        // zoom lane. Clearing only gestureOwnership can leave an abandoned
        // EditorStore preview transaction swallowing this new drag.
        cancelActiveTimelineGesture()
        let clips = track == .screen ? screenMotionTimelineClips : cameraMotionTimelineClips
        let zone = EditorTimelineMath.motionHitZone(
            x: Double(point.x),
            y: Double(point.y),
            items: clips,
            id: { $0.id },
            timing: { $0.timing },
            width: Double(width),
            duration: duration,
            selectedID: track == .screen ? selectedScreenMotionID : selectedCameraMotionID,
            hoveredID: hoveredMotionClip?.track == track ? hoveredMotionClip?.id : nil,
            itemsAreOrdered: true
        )
        // Alt+单击快捷裁剪：切分运动片段（与主片段同一快捷逻辑），不进入拖拽。
        if NSEvent.modifierFlags.contains(.option) {
            switch zone {
            case let .move(id), let .resize(id, _):
                let time = EditorTimelineMath.clampedTime(
                    atX: Double(point.x),
                    width: Double(width),
                    duration: duration
                )
                splitMotionClip(track: track, id: id, atTime: time)
            case .empty:
                break
            }
            return
        }
        switch zone {
        case .empty:
            let intent = EditorTimelineGestureIntent.motionCreate(track)
            guard beginTimelineGesture(intent) else { return }
            let start = EditorTimelineMath.clampedTime(
                atX: Double(point.x),
                width: Double(width),
                duration: duration
            )
            motionCreateDrag = MotionCreateDragState(track: track, start: start, end: start)
            motionTrackDrag = .create
        case let .move(id):
            let intent = EditorTimelineGestureIntent.motion(
                track, id, EditorMotionTimelineEditMode.move
            )
            guard beginTimelineGesture(intent) else { return }
            guard let clip = clips.first(where: { $0.id == id }) else {
                endTimelineGesture(intent)
                return
            }
            playbackController.pause()
            beginMotionGestureIfNeeded(
                clip: clip,
                mode: .move,
                duration: duration
            )
            guard motionGestureOrigin != nil else {
                endTimelineGesture(intent)
                return
            }
            motionTrackDrag = .move(id)
        case let .resize(id, leading):
            let mode: EditorMotionTimelineEditMode = leading ? .leading : .trailing
            let intent = EditorTimelineGestureIntent.motion(track, id, mode)
            guard beginTimelineGesture(intent) else { return }
            guard let clip = clips.first(where: { $0.id == id }) else {
                endTimelineGesture(intent)
                return
            }
            playbackController.pause()
            beginMotionGestureIfNeeded(clip: clip, mode: mode, duration: duration)
            guard motionGestureOrigin != nil else {
                endTimelineGesture(intent)
                return
            }
            motionTrackDrag = .resize(id, leading: leading)
        }
    }

    /// 悬浮在空白处且该处有空隙时，返回"+"指示的 x 位置（画布内容坐标）。
    func motionCreateIndicatorX(
        track: EditorMotionTimelineTrack,
        clips: [EditorMotionTimelineClip],
        width: CGFloat,
        duration: TimeInterval
    ) -> CGFloat? {
        guard let location = motionTrackHover[track],
              motionCreateDrag == nil else { return nil }
        let zone = EditorTimelineMath.motionHitZone(
            x: Double(location.x),
            y: Double(location.y),
            items: clips,
            id: { $0.id },
            timing: { $0.timing },
            width: Double(width),
            duration: duration,
            selectedID: track == .screen ? selectedScreenMotionID : selectedCameraMotionID,
            hoveredID: hoveredMotionClip?.track == track ? hoveredMotionClip?.id : nil,
            itemsAreOrdered: true
        )
        guard zone == .empty else { return nil }
        let time = EditorTimelineMath.clampedTime(
            atX: Double(location.x),
            width: Double(width),
            duration: duration
        )
        guard EditorTimelineMath.fitMotionTiming(
            start: time,
            end: time,
            among: clips,
            timing: { $0.timing },
            duration: duration,
            returnDuration: editorStore.project.motion.defaultZoomTransitionDuration,
            itemsAreOrdered: true
        ) != nil else { return nil }
        return location.x
    }

    func createManualMotionClip(
        drag: MotionCreateDragState,
        duration: TimeInterval
    ) {
        let track = drag.track
        guard let timing = EditorTimelineMath.fitMotionTiming(
            start: drag.start,
            end: drag.end,
            among: track == .screen ? screenMotionTimelineClips : cameraMotionTimelineClips,
            timing: { $0.timing },
            duration: duration,
            easing: editorStore.project.motion.defaultZoomEasing,
            returnDuration: editorStore.project.motion.defaultZoomTransitionDuration,
            leadInDuration: editorStore.project.motion.defaultZoomTransitionDuration,
            itemsAreOrdered: true
        ) else { return }
        do {
            switch track {
            case .screen:
                let clip = ScreenMotionClip(
                    timing: timing,
                    target: ScreenMotionState(
                        position: NormalizedPoint(x: 0.5, y: 0.5),
                        scale: 1.2
                    )
                )
                try editorStore.insertScreenMotion(clip, actionName: "添加屏幕 3D")
                activateTimelineSelection(.screenMotion(clip.id))
            case .camera:
                let base = editorStore.project.camera
                let clip = CameraMotionClip(
                    timing: timing,
                    target: CameraMotionState(
                        layout: .shape(base.shape),
                        position: base.position,
                        size: min(base.size * 1.25, 1),
                        roundness: base.roundness,
                        opacity: 1
                    )
                )
                try editorStore.insertCameraMotion(clip, actionName: "添加摄像运动")
                activateTimelineSelection(.cameraMotion(clip.id))
            }
        } catch {
            onError(error.localizedDescription)
        }
    }

    func beginMotionGestureIfNeeded(
        clip: EditorMotionTimelineClip,
        mode: EditorMotionTimelineEditMode,
        duration: TimeInterval
    ) {
        if let motionGestureOrigin,
           motionGestureOrigin.clip.id == clip.id,
           motionGestureOrigin.clip.track == clip.track,
           motionGestureOrigin.mode == mode {
            return
        }

        editorStore.cancelInteraction()
        guard let persistedClip = persistedMotionClip(track: clip.track, id: clip.id),
              let bounds = motionBounds(for: persistedClip, duration: duration) else { return }
        selectMotionClip(persistedClip)
        let selection: EditorSelection
        let tool: EditorTool
        switch clip.track {
        case .screen:
            selection = .screenMotion(clip.id)
            tool = .editScreenMotion
        case .camera:
            selection = .cameraMotion(clip.id)
            tool = .editCameraMotion
        }
        editorStore.beginInteraction(tool: tool, selection: selection)
        var partnerOrigins: [EditorMotionPartnerOrigin] = []
        if let groupID = clip.groupID {
            partnerOrigins =
                editorStore.project.timeline.screenMotionClips
                .filter { $0.groupID == groupID && $0.id != clip.id }
                .map { EditorMotionPartnerOrigin(id: $0.id, timing: $0.timing) }
                + editorStore.project.timeline.cameraMotionClips
                .filter { $0.groupID == groupID && $0.id != clip.id }
                .map { EditorMotionPartnerOrigin(id: $0.id, timing: $0.timing) }
        }
        motionGestureOrigin = EditorMotionTimelineGestureOrigin(
            clip: persistedClip,
            mode: mode,
            bounds: bounds,
            partnerOrigins: partnerOrigins
        )
    }

    func persistedMotionClip(
        track: EditorMotionTimelineTrack,
        id: UUID
    ) -> EditorMotionTimelineClip? {
        switch track {
        case .screen:
            return editorStore.project.timeline.screenMotionClips
                .first(where: { $0.id == id })
                .map { EditorMotionTimelineClip(id: $0.id, timing: $0.timing, track: .screen, groupID: $0.groupID) }
        case .camera:
            return editorStore.project.timeline.cameraMotionClips
                .first(where: { $0.id == id })
                .map { EditorMotionTimelineClip(id: $0.id, timing: $0.timing, track: .camera, groupID: $0.groupID) }
        }
    }

    func motionBounds(
        for clip: EditorMotionTimelineClip,
        duration: TimeInterval
    ) -> EditorMotionTimelineBounds? {
        let clips = clip.track == .screen
            ? screenMotionTimelineClips
            : cameraMotionTimelineClips
        return EditorMotionTimelinePresentation.bounds(
            for: clip.id,
            items: clips,
            id: { $0.id },
            timing: { $0.timing },
            timelineDuration: duration,
            itemsAreOrdered: true
        )
    }

    func updateMotionTimingDraft(
        clip: EditorMotionTimelineClip,
        timing: TransitionTiming,
        partnerOrigins: [EditorMotionPartnerOrigin],
        timelineDuration: TimeInterval
    ) {
        editorStore.updateInteraction { project in
            switch clip.track {
            case .screen:
                guard let index = project.timeline.screenMotionClips.firstIndex(where: {
                    $0.id == clip.id
                }) else { return }
                project.timeline.screenMotionClips[index].timing = timing
                // 相接关系被这次拖动改变时，同步修复结尾片段的回落时长：
                // 不再相接（成为结尾）且没有回落时长的片段补上默认回落。
                for patch in EditorTimelineMath.motionReturnNormalizations(
                    afterEditing: clip.id,
                    among: project.timeline.screenMotionClips,
                    id: { $0.id },
                    timing: { $0.timing },
                    defaultReturn: project.motion.defaultZoomTransitionDuration
                ) {
                    guard let patchIndex = project.timeline.screenMotionClips.firstIndex(where: {
                        $0.id == patch.id
                    }) else { continue }
                    project.timeline.screenMotionClips[patchIndex].timing = patch.timing
                }
                EditorTimelineAuthoredOrder.normalize(&project.timeline.screenMotionClips)
            case .camera:
                guard let index = project.timeline.cameraMotionClips.firstIndex(where: {
                    $0.id == clip.id
                }) else { return }
                project.timeline.cameraMotionClips[index].timing = timing
                for patch in EditorTimelineMath.motionReturnNormalizations(
                    afterEditing: clip.id,
                    among: project.timeline.cameraMotionClips,
                    id: { $0.id },
                    timing: { $0.timing },
                    defaultReturn: project.motion.defaultZoomTransitionDuration
                ) {
                    guard let patchIndex = project.timeline.cameraMotionClips.firstIndex(where: {
                        $0.id == patch.id
                    }) else { continue }
                    project.timeline.cameraMotionClips[patchIndex].timing = patch.timing
                }
                EditorTimelineAuthoredOrder.normalize(&project.timeline.cameraMotionClips)
            }
            if let groupID = clip.groupID {
                syncLinkedMotionPartners(
                    groupID: groupID,
                    sourceClipID: clip.id,
                    partnerOrigins: partnerOrigins,
                    deltaStart: timing.startTime - clip.timing.startTime,
                    deltaEnd: timing.endTime - clip.timing.endTime,
                    timelineDuration: timelineDuration,
                    in: &project
                )
            }
        }
    }

    /// 组合预设配对片段跟随：一侧被拖动/缩放时，其他轨道的同组片段按相同的
    /// 起点/终点位移跟随（先整体平移再修正终点）。每个伙伴都从拖动开始时的
    /// 快照原点计算（与被拖片段一致），不会在已跟随的位置上重复叠加；
    /// 受各自轨道邻接边界约束，与被拖片段同属一次交互，提交后一次撤销。
    func syncLinkedMotionPartners(
        groupID: UUID,
        sourceClipID: UUID,
        partnerOrigins: [EditorMotionPartnerOrigin],
        deltaStart: TimeInterval,
        deltaEnd: TimeInterval,
        timelineDuration: TimeInterval,
        in project: inout RecorderProject
    ) {
        guard deltaStart.isFinite, deltaEnd.isFinite,
              deltaStart != 0 || deltaEnd != 0 else { return }

        func adjustedPartnerTiming(
            origin: TransitionTiming,
            bounds: EditorMotionTimelineBounds
        ) -> TransitionTiming? {
            var timing = origin
            if deltaStart != 0 {
                timing = EditorMotionTimelinePresentation.adjustedTiming(
                    original: timing,
                    mode: .move,
                    delta: deltaStart,
                    bounds: bounds,
                    timelineDuration: timelineDuration
                )
            }
            let remaining = (origin.endTime + deltaEnd) - timing.endTime
            if abs(remaining) > 0.000_001 {
                timing = EditorMotionTimelinePresentation.adjustedTiming(
                    original: timing,
                    mode: .trailing,
                    delta: remaining,
                    bounds: bounds,
                    timelineDuration: timelineDuration
                )
            }
            return timing == origin ? nil : timing
        }

        let defaultReturn = project.motion.defaultZoomTransitionDuration
        let originTimingByID = Dictionary(
            uniqueKeysWithValues: partnerOrigins.map { ($0.id, $0.timing) }
        )
        for partner in partnerOrigins where partner.id != sourceClipID {
            if project.timeline.screenMotionClips.contains(where: { $0.id == partner.id }) {
                // 边界按拖动开始时的持久布局计算（伙伴条目替换回快照原点）
                guard let bounds = EditorMotionTimelinePresentation.bounds(
                    for: partner.id,
                    items: project.timeline.screenMotionClips,
                    id: { $0.id },
                    timing: { originTimingByID[$0.id] ?? $0.timing },
                    timelineDuration: timelineDuration,
                    itemsAreOrdered: true
                ), let newTiming = adjustedPartnerTiming(
                    origin: partner.timing,
                    bounds: bounds
                ), let index = project.timeline.screenMotionClips.firstIndex(where: {
                    $0.id == partner.id
                }) else { continue }
                project.timeline.screenMotionClips[index].timing = newTiming
                for patch in EditorTimelineMath.motionReturnNormalizations(
                    afterEditing: partner.id,
                    among: project.timeline.screenMotionClips,
                    id: { $0.id },
                    timing: { $0.timing },
                    defaultReturn: defaultReturn
                ) {
                    guard let patchIndex = project.timeline.screenMotionClips.firstIndex(where: {
                        $0.id == patch.id
                    }) else { continue }
                    project.timeline.screenMotionClips[patchIndex].timing = patch.timing
                }
                EditorTimelineAuthoredOrder.normalize(&project.timeline.screenMotionClips)
            } else if project.timeline.cameraMotionClips.contains(where: { $0.id == partner.id }) {
                guard let bounds = EditorMotionTimelinePresentation.bounds(
                    for: partner.id,
                    items: project.timeline.cameraMotionClips,
                    id: { $0.id },
                    timing: { originTimingByID[$0.id] ?? $0.timing },
                    timelineDuration: timelineDuration,
                    itemsAreOrdered: true
                ), let newTiming = adjustedPartnerTiming(
                    origin: partner.timing,
                    bounds: bounds
                ), let index = project.timeline.cameraMotionClips.firstIndex(where: {
                    $0.id == partner.id
                }) else { continue }
                project.timeline.cameraMotionClips[index].timing = newTiming
                for patch in EditorTimelineMath.motionReturnNormalizations(
                    afterEditing: partner.id,
                    among: project.timeline.cameraMotionClips,
                    id: { $0.id },
                    timing: { $0.timing },
                    defaultReturn: defaultReturn
                ) {
                    guard let patchIndex = project.timeline.cameraMotionClips.firstIndex(where: {
                        $0.id == patch.id
                    }) else { continue }
                    project.timeline.cameraMotionClips[patchIndex].timing = patch.timing
                }
                EditorTimelineAuthoredOrder.normalize(&project.timeline.cameraMotionClips)
            }
        }
    }

    func commitMotionGesture(origin: EditorMotionTimelineGestureOrigin?) {
        guard let origin else { return }
        let actionName: String
        switch (origin.clip.track, origin.mode) {
        case (.screen, .move): actionName = "移动屏幕 3D"
        case (.screen, _): actionName = "调整屏幕 3D 时长"
        case (.camera, .move): actionName = "移动摄像运动"
        case (.camera, _): actionName = "调整摄像运动时长"
        }
        do {
            _ = try editorStore.commitInteraction(actionName: actionName)
            activateTimelineSelection(
                origin.clip.track == .screen
                    ? .screenMotion(origin.clip.id)
                    : .cameraMotion(origin.clip.id)
            )
        } catch {
            editorStore.cancelInteraction()
            onError(error.localizedDescription)
        }
    }

    func selectMotionClip(_ clip: EditorMotionTimelineClip) {
        primaryTrimDraft = nil
        primaryRetimeDraft = nil
        switch clip.track {
        case .screen:
            editorStore.selection = .screenMotion(clip.id)
        case .camera:
            editorStore.selection = .cameraMotion(clip.id)
        }
    }

    /// Alt+单击切分运动片段：左段保留到切点（目标烘焙为切点处状态），
    /// 右段从切点继续到原目标，播放效果与原片段一致；一次撤销。
    func splitMotionClip(
        track: EditorMotionTimelineTrack,
        id: UUID,
        atTime time: TimeInterval
    ) {
        var timeline = editorStore.project.timeline
        switch track {
        case .screen:
            guard let index = timeline.screenMotionClips.firstIndex(where: { $0.id == id })
            else { return }
            let clip = timeline.screenMotionClips[index]
            guard let pieces = Self.splitMotionTiming(
                of: clip.timing,
                at: time,
                defaultLeadIn: editorStore.project.motion.defaultZoomTransitionDuration
            ) else { return }
            let baked = ScreenMotionTrack(timeline.screenMotionClips).sample(
                at: pieces.splitTime,
                base: ScreenMotionState(
                    position: editorStore.project.canvas.contentPosition,
                    scale: editorStore.project.canvas.contentScale
                ),
                motion: editorStore.project.motion
            )
            let left = ScreenMotionClip(timing: pieces.left, target: baked, groupID: clip.groupID)
            let right = ScreenMotionClip(timing: pieces.right, target: clip.target, groupID: clip.groupID)
            timeline.screenMotionClips.remove(at: index)
            timeline.screenMotionClips.append(contentsOf: [left, right])
            timeline.screenMotionClips.sort { $0.timing.startTime < $1.timing.startTime }
            do {
                try editorStore.replaceTimeline(with: timeline, actionName: "分割屏幕 3D")
                editorStore.selection = .screenMotion(right.id)
            } catch {
                onError(error.localizedDescription)
            }
        case .camera:
            guard let index = timeline.cameraMotionClips.firstIndex(where: { $0.id == id })
            else { return }
            let clip = timeline.cameraMotionClips[index]
            guard let pieces = Self.splitMotionTiming(
                of: clip.timing,
                at: time,
                defaultLeadIn: editorStore.project.motion.defaultZoomTransitionDuration
            ) else { return }
            let sourceSize = mediaSession.sourceDisplaySize
            let cameraSize = mediaSession.cameraDisplaySize
            let canvasAspect = max(Double(sourceSize.width) / max(Double(sourceSize.height), 1), 0.01)
            let cameraAspect = cameraSize.map {
                max(Double($0.width) / max(Double($0.height), 1), 0.01)
            } ?? (4.0 / 3.0)
            let project = editorStore.project
            let baked = CameraMotionTrack(timeline.cameraMotionClips).sample(
                at: pieces.splitTime,
                base: CameraMotionState(
                    layout: .shape(project.camera.shape),
                    position: project.camera.position,
                    size: project.camera.size,
                    roundness: project.camera.roundness,
                    opacity: project.camera.isHidden ? 0 : 1
                ),
                cameraAspectRatio: cameraAspect,
                canvasAspectRatio: canvasAspect,
                motion: project.motion
            )
            let leftTarget = CameraMotionState(
                layout: clip.target.layout,
                position: NormalizedPoint(
                    x: min(max(baked.position.x, 0), 1),
                    y: min(max(baked.position.y, 0), 1)
                ),
                size: baked.size,
                roundness: clip.target.roundness,
                opacity: baked.opacity
            )
            let left = CameraMotionClip(timing: pieces.left, target: leftTarget, groupID: clip.groupID)
            let right = CameraMotionClip(timing: pieces.right, target: clip.target, groupID: clip.groupID)
            timeline.cameraMotionClips.remove(at: index)
            timeline.cameraMotionClips.append(contentsOf: [left, right])
            timeline.cameraMotionClips.sort { $0.timing.startTime < $1.timing.startTime }
            do {
                try editorStore.replaceTimeline(with: timeline, actionName: "分割摄像运动")
                editorStore.selection = .cameraMotion(right.id)
            } catch {
                onError(error.localizedDescription)
            }
        }
    }

    /// 切分时间学：左段 [start, t]（进入过渡按长度截断、无回落——与右段相接），
    /// 右段 [t, end]（回落保持原值）。右段 leadIn：过渡期切开时保留剩余过渡
    /// （曲线连续）；保持期切开时给默认过渡时长——此时右段与原状态一致，
    /// 长 leadIn 无害，而用户一旦改右段目标，就能自然过渡而不是瞬间跳变。
    static func splitMotionTiming(
        of timing: TransitionTiming,
        at time: TimeInterval,
        defaultLeadIn: TimeInterval = 0.7
    ) -> (left: TransitionTiming, right: TransitionTiming, splitTime: TimeInterval)? {
        guard time.isFinite,
              time >= timing.startTime,
              time <= timing.endTime else { return nil }
        let t = min(max(time, timing.startTime + 0.05), timing.endTime - 0.05)
        guard t > timing.startTime + 0.000_1, t < timing.endTime - 0.000_1 else { return nil }
        var left = timing
        left.duration = t - timing.startTime
        left.leadInDuration = min(timing.leadInDuration, left.duration)
        left.returnDuration = 0
        let leadInEnd = timing.startTime + min(timing.leadInDuration, timing.duration)
        var right = timing
        right.startTime = t
        right.duration = timing.endTime - t
        // 过渡期切开：保留剩余过渡（曲线与原片段一致）；保持期切开：给默认
        // 过渡时长——未改目标是空过渡，改了目标则自然过渡而非瞬间跳变。
        let remainingLeadIn = leadInEnd - t
        right.leadInDuration = min(
            remainingLeadIn > 0.000_1 ? remainingLeadIn : defaultLeadIn,
            right.duration
        )
        return (left, right, t)
    }

    func removeMotionClip(_ clip: EditorMotionTimelineClip) {
        editorStore.cancelInteraction()
        motionGestureOrigin = nil
        do {
            switch clip.track {
            case .screen:
                try editorStore.removeScreenMotion(id: clip.id, actionName: "删除屏幕 3D")
                editorStore.selection = .screenMotionTrack
            case .camera:
                try editorStore.removeCameraMotion(id: clip.id, actionName: "删除摄像运动")
                editorStore.selection = .camera
            }
        } catch {
            onError(error.localizedDescription)
        }
        if hoveredMotionClip?.id == clip.id,
           hoveredMotionClip?.track == clip.track {
            hoveredMotionClip = nil
        }
    }

    func trimMotionClip(
        track: EditorMotionTimelineTrack,
        id: UUID,
        edge: RecordingSegmentTrimEdge,
        at time: TimeInterval
    ) {
        guard let clip = persistedMotionClip(track: track, id: id) else { return }
        guard time > clip.timing.startTime + 0.01, time < clip.timing.endTime - 0.01 else { return }
        var project = editorStore.project
        let defaultReturn = project.motion.defaultZoomTransitionDuration
        var newTiming = clip.timing
        switch edge {
        case .left:
            let newStart = time
            let remainingDuration = clip.timing.endTime - newStart
            guard remainingDuration >= EditorMotionTimelinePresentation.minimumDuration else { return }
            newTiming.startTime = newStart
            newTiming.duration = remainingDuration
            newTiming.leadInDuration = min(clip.timing.leadInDuration, remainingDuration)
            newTiming.returnDuration = min(clip.timing.returnDuration, remainingDuration)
        case .right:
            let newEnd = time
            let remainingDuration = newEnd - clip.timing.startTime
            guard remainingDuration >= EditorMotionTimelinePresentation.minimumDuration else { return }
            newTiming.duration = remainingDuration
            newTiming.leadInDuration = min(clip.timing.leadInDuration, remainingDuration)
            newTiming.returnDuration = min(clip.timing.returnDuration, remainingDuration)
        }

        switch track {
        case .screen:
            guard let index = project.timeline.screenMotionClips.firstIndex(where: { $0.id == id }) else { return }
            project.timeline.screenMotionClips[index].timing = newTiming
            for patch in EditorTimelineMath.motionReturnNormalizations(
                afterEditing: id,
                among: project.timeline.screenMotionClips,
                id: { $0.id },
                timing: { $0.timing },
                defaultReturn: defaultReturn
            ) {
                guard let patchIndex = project.timeline.screenMotionClips.firstIndex(where: { $0.id == patch.id }) else { continue }
                project.timeline.screenMotionClips[patchIndex].timing = patch.timing
            }
            EditorTimelineAuthoredOrder.normalize(&project.timeline.screenMotionClips)
        case .camera:
            guard let index = project.timeline.cameraMotionClips.firstIndex(where: { $0.id == id }) else { return }
            project.timeline.cameraMotionClips[index].timing = newTiming
            for patch in EditorTimelineMath.motionReturnNormalizations(
                afterEditing: id,
                among: project.timeline.cameraMotionClips,
                id: { $0.id },
                timing: { $0.timing },
                defaultReturn: defaultReturn
            ) {
                guard let patchIndex = project.timeline.cameraMotionClips.firstIndex(where: { $0.id == patch.id }) else { continue }
                project.timeline.cameraMotionClips[patchIndex].timing = patch.timing
            }
            EditorTimelineAuthoredOrder.normalize(&project.timeline.cameraMotionClips)
        }

        let actionName = "\(edge == .left ? "Q" : "W") 修剪\(track == .screen ? "屏幕" : "摄像头")动画"
        do {
            try editorStore.replaceProject(with: project, actionName: actionName)
            seekTimeline(to: edge == .left ? newTiming.startTime : newTiming.endTime)
        } catch {
            onError(error.localizedDescription)
        }
    }
}
