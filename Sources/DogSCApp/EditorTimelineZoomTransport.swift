import AppKit
import RecorderCore
import SwiftUI
import UniformTypeIdentifiers

extension EditorTimelineView {
func zoomTimeline(width: CGFloat, duration: TimeInterval) -> some View {
        let segments = timelineZoomSegments
        let visibleTimeRange = EditorTimelineViewportPresentation.bufferedTimeRange(
            documentWidth: width,
            duration: duration,
            visibleRange: clampedTimelineVisibleDocumentRange(width: width)
        )
        let visibleSegmentIndices = EditorTimelineViewportPresentation.visibleIntervalIndices(
            in: segments,
            timeRange: visibleTimeRange,
            startTime: \.startTime,
            endTime: \.endTime,
            retainingIndices: [
                derivedPresentationCache.zoomSegmentIndex(for: selectedZoomID),
                derivedPresentationCache.zoomSegmentIndex(for: zoomGestureOrigin?.id),
            ].compactMap { $0 }
        )
        return ZStack(alignment: .leading) {
            editorZoomClip.opacity(0.07)
            if isZoomTrackHovered,
               hoveredZoomID == nil,
               manualZoomDragStart == nil {
                Text(
                    "拖动空白处添加缩放动画"
                )
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.secondary)
                    .padding(.leading, 10)
                    .allowsHitTesting(false)
            }
            ForEach(visibleSegmentIndices, id: \.self) { index in
                let segment = segments[index]
                let startX = CGFloat(segment.startTime / max(duration, 0.001)) * width
                let segmentWidth = max(
                    CGFloat((segment.endTime - segment.startTime) / max(duration, 0.001)) * width,
                    14
                )
                let accessibilityValue =
                    "\(timelineTimestamp(segment.startTime)) 至 "
                    + "\(timelineTimestamp(segment.endTime))，"
                    + "\(String(format: "%.1f", segment.scale)) 倍，"
                    + (segment.origin == .manual ? "手动" : "自动")
                let accessibilityTraits: AccessibilityTraits = selectedZoomID == segment.id
                    ? [.isButton, .isSelected] : .isButton
                ZStack {
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [
                                    editorZoomClip,
                                    Color(red: 0.30, green: 0.38, blue: 0.54),
                                ],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                        )
                        .overlay {
                            if segmentWidth > 86 {
                                Text(
                                    "保持 \(String(format: "%.1f", segment.scale))× · "
                                        + (segment.origin == .manual ? "手动" : "自动")
                                )
                                .font(.caption2.weight(.semibold))
                                .lineLimit(1)
                            }
                        }
                        .overlay(
                            RoundedRectangle(cornerRadius: 7)
                                .stroke(
                                    selectedZoomID == segment.id
                                        ? .white : .clear,
                                    lineWidth: 1.5
                                )
                        )

                    if selectedZoomID == segment.id || hoveredZoomID == segment.id {
                        HStack {
                            zoomResizeHandle(edge: .leading)
                            Spacer(minLength: 0)
                            zoomResizeHandle(edge: .trailing)
                        }
                        .padding(.horizontal, 2)
                        .allowsHitTesting(false)
                    }
                }
                .frame(width: segmentWidth, height: 42)
                .offset(x: startX)
                .contentShape(Rectangle())
                .contextMenu {
                    Button(role: .destructive) {
                        removeZoomAnimation(id: segment.id)
                    } label: {
                        Label("删除缩放动画", systemImage: "trash")
                    }
                }
                .onHover { hovering in
                    hoveredZoomID = hovering ? segment.id : (hoveredZoomID == segment.id ? nil : hoveredZoomID)
                }
                .accessibilityElement(children: .ignore)
                .help("单击选中；拖动移动；拖两端调整保持时间；右键可删除")
                .accessibilityLabel("缩放动画 \(index + 1)")
                .accessibilityValue(accessibilityValue)
                .accessibilityAddTraits(accessibilityTraits)
                .accessibilityAction {
                    beginSelectingZoom(segment)
                }
                .accessibilityIdentifier(
                    "editor.timeline.zoom.\(segment.id.uuidString)"
                )
            }

            // 悬浮空白处显示创建起点；需要水平拖动形成区间，单击只定位，
            // 不会意外写入一个默认片段。
            if let indicatorX = zoomCreateIndicatorX(width: width, duration: duration) {
                Image(systemName: "plus")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.black.opacity(0.78))
                    .frame(width: 18, height: 18)
                    .background(Circle().fill(editorAccent))
                    .offset(x: indicatorX - 9)
                    .allowsHitTesting(false)
            }

            if let dragStart = manualZoomDragStart,
               let dragEnd = manualZoomDragEnd {
                let start = min(dragStart, dragEnd)
                let end = max(dragStart, dragEnd)
                let startX = CGFloat(start / max(duration, 0.001)) * width
                let rangeWidth = max(CGFloat((end - start) / max(duration, 0.001)) * width, 4)
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(editorAccent.opacity(0.42))
                    .overlay(
                        RoundedRectangle(cornerRadius: 7)
                            .stroke(.white.opacity(0.8), style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
                    )
                    .frame(width: rangeWidth, height: 42)
                    .offset(x: startX)
                    .allowsHitTesting(false)
            }
        }
        .frame(width: width, height: 56, alignment: .leading)
        .overlay(alignment: .bottom) { Divider().overlay(dividerColor) }
        .contentShape(Rectangle())
        // 整条轨道只挂这一个手势：按下时按命中区域（手柄/片段/空白）分发为
        // 调整、移动或创建。此前背景创建手势与片段手势作为兄弟手势相互竞争，
        // 按下永远先落在创建手势上，导致片段选不中、拖不动、手柄失效。
        .gesture(zoomTrackGesture(width: width, duration: duration))
        .onHover { isZoomTrackHovered = $0 }
        .onContinuousHover(coordinateSpace: .local) { phase in
            switch phase {
            case let .active(location):
                hoveredZoomTrackLocation = location
            case .ended:
                hoveredZoomTrackLocation = nil
            }
        }
    }

    /// 悬浮在空白处且该处有空隙时，返回"+"指示的 x 位置（画布内容坐标）。
    func zoomCreateIndicatorX(width: CGFloat, duration: TimeInterval) -> CGFloat? {
        guard let location = hoveredZoomTrackLocation,
              manualZoomDragStart == nil else { return nil }
        let zone = EditorTimelineMath.zoomHitZone(
            x: Double(location.x),
            y: Double(location.y),
            segments: timelineZoomSegments,
            width: Double(width),
            duration: duration,
            selectedID: selectedZoomID,
            hoveredID: hoveredZoomID,
            segmentsAreOrdered: true
        )
        guard zone == .empty else { return nil }
        let time = EditorTimelineMath.clampedTime(
            atX: Double(location.x),
            width: Double(width),
            duration: duration
        )
        guard EditorTimelineMath.fitZoomAnimation(
            start: time,
            end: time,
            among: editorStore.project.zoomAnimations,
            duration: duration,
            transitionDuration: editorStore.project.motion.defaultZoomTransitionDuration
        ) != nil else { return nil }
        return location.x
    }

    enum ZoomTrackDrag: Equatable {
        case create
        case move(UUID)
        case resize(UUID, leading: Bool)
    }

    func zoomResizeHandle(edge: ZoomResizeEdge) -> some View {
        Capsule()
            .fill(.white.opacity(0.92))
            .frame(width: 4, height: 30)
            .frame(width: 10, height: 42)
            .accessibilityLabel(edge == .leading ? "调整动画开始" : "调整动画结束")
    }

    func zoomTrackGesture(width: CGFloat, duration: TimeInterval) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                if zoomTrackDrag == nil {
                    beginZoomTrackDrag(at: value.startLocation, width: width, duration: duration)
                }
                switch zoomTrackDrag {
                case .create:
                    guard gestureOwnership.activeIntent == .zoomCreate else { return }
                    manualZoomDragEnd = EditorTimelineMath.clampedTime(
                        atX: Double(value.location.x),
                        width: Double(width),
                        duration: duration
                    )
                    if EditorTimelineRangeCreationPolicy.shouldCommit(
                        horizontalTranslation: value.translation.width
                    ) {
                        playbackController.pause()
                    }
                case let .move(id):
                    guard gestureOwnership.activeIntent == .zoomMove(id),
                          let origin = zoomGestureOrigin else { return }
                    let delta = TimeInterval(value.translation.width / max(width, 1)) * duration
                    let moved = EditorTimelineMath.moving(
                        animation: origin,
                        to: origin.startTime + delta,
                        among: editorStore.previewProject.zoomAnimations,
                        duration: duration,
                        defaultExit: editorStore.project.motion.defaultZoomTransitionDuration
                    )
                    previewZoomAnimation(moved)
                case let .resize(id, leading):
                    guard gestureOwnership.activeIntent == .zoomResize(id, leading: leading),
                          let origin = zoomGestureOrigin else { return }
                    let delta = TimeInterval(value.translation.width / max(width, 1)) * duration
                    let resized: ZoomAnimationClip
                    if leading {
                        resized = EditorTimelineMath.resizing(
                            animation: origin,
                            proposedStart: origin.startTime + delta,
                            among: editorStore.previewProject.zoomAnimations,
                            duration: duration,
                            defaultExit: editorStore.project.motion.defaultZoomTransitionDuration
                        )
                    } else {
                        resized = EditorTimelineMath.resizing(
                            animation: origin,
                            proposedEnd: origin.endTime + delta,
                            among: editorStore.previewProject.zoomAnimations,
                            duration: duration,
                            defaultExit: editorStore.project.motion.defaultZoomTransitionDuration
                        )
                    }
                    previewZoomAnimation(resized)
                case nil:
                    break
                }
            }
            .onEnded { value in
                let drag = zoomTrackDrag
                let origin = zoomGestureOrigin
                let createStart = manualZoomDragStart
                let createEnd = manualZoomDragEnd
                zoomTrackDrag = nil
                zoomGestureOrigin = nil
                manualZoomDragStart = nil
                manualZoomDragEnd = nil
                switch drag {
                case .create:
                    guard gestureOwnership.activeIntent == .zoomCreate else { return }
                    guard EditorTimelineRangeCreationPolicy.shouldCommit(
                        horizontalTranslation: value.translation.width
                    ) else {
                        clearTimelineSelection()
                        endTimelineGesture(.zoomCreate)
                        return
                    }
                    let start = createStart ?? EditorTimelineMath.clampedTime(
                        atX: Double(value.startLocation.x),
                        width: Double(width),
                        duration: duration
                    )
                    createZoomRange(start: start, end: createEnd ?? start, duration: duration)
                    endTimelineGesture(.zoomCreate)
                case let .move(id):
                    let intent = EditorTimelineGestureIntent.zoomMove(id)
                    guard gestureOwnership.activeIntent == intent else { return }
                    if let origin,
                       NSEvent.modifierFlags.contains(.option),
                       abs(value.translation.width) < 5 {
                        editorStore.cancelInteraction()
                        let clipWidth = max(
                            CGFloat((origin.endTime - origin.startTime) / max(duration, 0.001)) * width,
                            1
                        )
                        let startX = CGFloat(origin.startTime / max(duration, 0.001)) * width
                        let fraction = min(max((value.location.x - startX) / clipWidth, 0), 1)
                        let splitTime = origin.startTime
                            + TimeInterval(fraction) * (origin.endTime - origin.startTime)
                        splitZoomAnimation(id: origin.id, at: splitTime)
                    } else if abs(value.translation.width) < 3 {
                        editorStore.cancelInteraction()
                    } else {
                        commitZoomInteraction()
                    }
                    endTimelineGesture(intent)
                case let .resize(id, leading):
                    let intent = EditorTimelineGestureIntent.zoomResize(id, leading: leading)
                    guard gestureOwnership.activeIntent == intent else { return }
                    commitZoomInteraction()
                    endTimelineGesture(intent)
                case nil:
                    break
                }
            }
    }

    /// 按下手只发生一次：根据起点命中区域决定这次拖动是创建、移动还是调整。
    /// 任何上一次按下遗留的状态都在这里被判定为过期（新的按下证明旧的按下
    /// 已经结束，即使它的 onEnded 因手势取消而丢失）。
    func beginZoomTrackDrag(at point: CGPoint, width: CGFloat, duration: TimeInterval) {
        // EDT-020: the semantic owner is only one part of a drag session.
        // A removed SwiftUI clip can also leave its Store preview transaction
        // and another lane's local draft alive.  Starting from that partial
        // state makes the new clip look selected while updateInteraction is
        // still targeting the previous edit.  A new physical press is a safe
        // boundary, so retire the complete previous session before hit testing.
        cancelActiveTimelineGesture()
        let zone = EditorTimelineMath.zoomHitZone(
            x: Double(point.x),
            y: Double(point.y),
            segments: timelineZoomSegments,
            width: Double(width),
            duration: duration,
            selectedID: selectedZoomID,
            hoveredID: hoveredZoomID,
            segmentsAreOrdered: true
        )
        switch zone {
        case .empty:
            guard beginTimelineGesture(.zoomCreate) else { return }
            let start = EditorTimelineMath.clampedTime(
                atX: Double(point.x),
                width: Double(width),
                duration: duration
            )
            manualZoomDragStart = start
            manualZoomDragEnd = start
            zoomTrackDrag = .create
        case let .move(id):
            let intent = EditorTimelineGestureIntent.zoomMove(id)
            guard beginTimelineGesture(intent) else { return }
            guard let segment = timelineZoomSegments.first(where: { $0.id == id }),
                  let clip = zoomAnimation(id: id) else {
                endTimelineGesture(intent)
                return
            }
            playbackController.pause()
            beginSelectingZoom(segment)
            zoomGestureOrigin = clip
            editorStore.beginInteraction(tool: .editZoom, selection: .zoom(id))
            zoomTrackDrag = .move(id)
        case let .resize(id, leading):
            let intent = EditorTimelineGestureIntent.zoomResize(id, leading: leading)
            guard beginTimelineGesture(intent) else { return }
            guard let segment = timelineZoomSegments.first(where: { $0.id == id }),
                  let clip = zoomAnimation(id: id) else {
                endTimelineGesture(intent)
                return
            }
            playbackController.pause()
            beginSelectingZoom(segment)
            zoomGestureOrigin = clip
            editorStore.beginInteraction(tool: .editZoom, selection: .zoom(id))
            zoomTrackDrag = .resize(id, leading: leading)
        }
    }

    var timelineZoomSegments: [TimelineZoomSegment] {
        derivedPresentationCache.zoomSegments(
            animations: editorStore.previewProject.zoomAnimations,
            duration: timelineDuration
        )
    }

    func zoomAnimation(id: UUID) -> ZoomAnimationClip? {
        editorStore.project.zoomAnimations.first(where: { $0.id == id })
    }

    func previewZoomAnimation(_ animation: ZoomAnimationClip) {
        editorStore.updateInteraction { project in
            guard let index = project.zoomAnimations.firstIndex(where: { $0.id == animation.id }) else {
                return
            }
            project.zoomAnimations[index] = animation
            // 相接关系被这次拖动改变时，同步修复结尾片段的退出时长：
            // 不再相接（成为结尾）且没有退出时长的片段补上默认过渡。
            for patch in EditorTimelineMath.exitNormalizations(
                afterEditing: animation.id,
                among: project.zoomAnimations,
                defaultExit: project.motion.defaultZoomTransitionDuration
            ) {
                guard let patchIndex = project.zoomAnimations.firstIndex(where: {
                    $0.id == patch.id
                }) else { continue }
                project.zoomAnimations[patchIndex] = patch
            }
            EditorTimelineAuthoredOrder.normalize(&project.timeline.zoomClips)
        }
    }

    func commitZoomInteraction() {
        do {
            _ = try editorStore.commitInteraction(actionName: "调整缩放")
        } catch {
            editorStore.cancelInteraction()
            onError(error.localizedDescription)
        }
    }

    func beginSelectingZoom(_ segment: TimelineZoomSegment) {
        primaryTrimDraft = nil
        primaryRetimeDraft = nil
        selectedZoomID = segment.id
    }

    func removeZoomAnimation(id: UUID) {
        guard zoomAnimation(id: id) != nil else { return }
        editorStore.cancelInteraction()
        do {
            try editorStore.removeZoom(id: id, actionName: "删除缩放动画")
        } catch {
            onError(error.localizedDescription)
            return
        }
        if selectedZoomID == id {
            selectedZoomID = nil
        }
        if hoveredZoomID == id {
            hoveredZoomID = nil
        }
    }

    func installDeleteKeyMonitor() {
        guard deleteKeyMonitor == nil else { return }
        deleteKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard event.window?.identifier?.rawValue
                    == "cn.laogou.dogsc.editor-window",
                  !event.isARepeat else { return event }

            if let textView = event.window?.firstResponder as? NSTextView,
               textView.isEditable {
                return event
            }

            let editingModifiers = event.modifierFlags.intersection([
                .command, .control, .option,
            ])
            let hasEditingModifier = !editingModifiers.isEmpty

            switch event.keyCode {
            case 12 where !hasEditingModifier: // Q
                Task { @MainActor in rippleDeleteBeforePlayhead() }
                return nil
            case 13 where !hasEditingModifier: // W
                Task { @MainActor in rippleDeleteAfterPlayhead() }
                return nil
            case 2 where !hasEditingModifier: // D
                return removeCurrentTimelineSelection() ? nil : event
            case 1 where !hasEditingModifier: // S
                Task { @MainActor in splitCurrentTimelineSelectionAtPlayhead() }
                return nil
            case 51, 117: // Delete / forward delete
                return removeCurrentTimelineSelection() ? nil : event
            default:
                return event
            }
        }
    }

    /// Both `D` and the physical delete keys remove the current precise
    /// timeline selection. Keeping one router prevents one shortcut from
    /// silently falling back to the primary video lane.
    var canRemoveCurrentTimelineSelection: Bool {
        selectedCameraSyncAnchorID != nil
            || EditorTimelineDeleteTarget(selection: editorStore.selection) != nil
    }

    var currentTimelineDeleteHelp: String {
        "\(currentTimelineDeleteAccessibilityLabel)（D 或 Delete）"
    }

    var currentTimelineDeleteAccessibilityLabel: String {
        if selectedCameraSyncAnchorID != nil { return "删除选中的摄像头同步点" }
        switch EditorTimelineDeleteTarget(selection: editorStore.selection) {
        case .primarySegment: return "删除选中的主片段"
        case .zoom: return "删除选中的缩放动画"
        case .screenMotion: return "删除选中的屏幕 3D"
        case .cameraMotion: return "删除选中的摄像运动"
        case .mosaic: return "删除选中的打码"
        case .sticker: return "删除选中的贴图"
        case .progress: return "删除进度条"
        case nil: return "删除当前时间线选中项"
        }
    }

    @discardableResult
    func removeCurrentTimelineSelection() -> Bool {
        if let selectedCameraSyncAnchorID {
            Task { @MainActor in
                removeCameraSyncAnchor(id: selectedCameraSyncAnchorID)
            }
            return true
        }
        guard let target = EditorTimelineDeleteTarget(selection: editorStore.selection) else {
            return false
        }
        Task { @MainActor in removeTimelineTarget(target) }
        return true
    }

    /// Current effective edit time for split (S) and ripple trim (Q/W).
    /// When skimming (hover preview) is enabled, the editor is paused, and the pointer
    /// is hovering over the timeline, the hover position takes precedence ("cut what you see").
    /// Otherwise (during playback or when hover is inactive/disabled), it defaults to the playhead time.
    var isSkimmingActive: Bool {
        isHoverPreviewEnabled && !playbackController.isPlaying && hoveredTimelineContentX != nil
    }

    var effectiveTimelineEditTime: TimeInterval {
        snappedTimelineTime(playbackTime)
    }

    /// Split the selected authored effect when one is selected. Otherwise `S`
    /// retains its established behaviour on the primary recording lane.
    var canSplitCurrentTimelineSelectionAtPlayhead: Bool {
        let time = effectiveTimelineEditTime
        switch EditorTimelineSplitTarget(selection: editorStore.selection) {
        case let .zoom(id):
            guard let animation = editorStore.project.zoomAnimations.first(where: {
                $0.id == id
            }) else { return false }
            return EditorTimelineMath.split(animation: animation, at: time) != nil
        case let .screenMotion(id):
            guard let clip = editorStore.project.timeline.screenMotionClips.first(where: {
                $0.id == id
            }) else { return false }
            return Self.splitMotionTiming(of: clip.timing, at: time) != nil
        case let .cameraMotion(id):
            guard let clip = editorStore.project.timeline.cameraMotionClips.first(where: {
                $0.id == id
            }) else { return false }
            return Self.splitMotionTiming(of: clip.timing, at: time) != nil
        case let .mosaic(id):
            guard let clip = editorStore.project.timeline.mosaicClips.first(
                where: { $0.id == id }
            ) else { return false }
            return time > clip.timing.startTime + 0.01
                && time < clip.timing.endTime - 0.01
        case let .sticker(id):
            guard let clip = editorStore.project.timeline.stickerClips.first(
                where: { $0.id == id }
            ) else { return false }
            return time > clip.timing.startTime + 0.01
                && time < clip.timing.endTime - 0.01
        case nil:
            return primarySplitCandidate != nil
        }
    }

    var currentTimelineSplitHelp: String {
        switch EditorTimelineSplitTarget(selection: editorStore.selection) {
        case .zoom:
            return "在播放头处分割选中的缩放动画（S）"
        case .screenMotion:
            return "在播放头处分割选中的屏幕 3D（S）"
        case .cameraMotion:
            return "在播放头处分割选中的摄像运动（S）"
        case .mosaic:
            return "在播放头处分割选中的打码（S）"
        case .sticker:
            return "在播放头处分割选中的贴图（S）"
        case nil:
            return "在播放头处分割主片段（S）；按住 ⌥ 点击片段可直接切开"
        }
    }

    var currentTimelineSplitAccessibilityLabel: String {
        switch EditorTimelineSplitTarget(selection: editorStore.selection) {
        case .zoom: return "分割选中的缩放动画"
        case .screenMotion: return "分割选中的屏幕 3D"
        case .cameraMotion: return "分割选中的摄像运动"
        case .mosaic: return "分割选中的打码"
        case .sticker: return "分割选中的贴图"
        case nil: return "在播放头处分割主片段"
        }
    }

    func splitCurrentTimelineSelectionAtPlayhead() {
        let time = effectiveTimelineEditTime
        switch EditorTimelineSplitTarget(selection: editorStore.selection) {
        case let .zoom(id):
            splitZoomAnimation(id: id, at: time)
        case let .screenMotion(id):
            splitMotionClip(track: .screen, id: id, atTime: time)
        case let .cameraMotion(id):
            splitMotionClip(track: .camera, id: id, atTime: time)
        case let .mosaic(id):
            splitMosaicClip(id: id, atTime: time)
        case let .sticker(id):
            splitStickerClip(id: id, atTime: time)
        case nil:
            splitPrimarySegmentAtPlayhead()
        }
    }

    func trimZoomAnimation(
        id: UUID,
        edge: RecordingSegmentTrimEdge,
        at time: TimeInterval
    ) {
        guard let clip = editorStore.project.zoomAnimations.first(where: { $0.id == id }) else { return }
        guard time > clip.startTime + 0.01, time < clip.endTime - 0.01 else { return }
        let duration = timelineDuration
        let resized: ZoomAnimationClip
        switch edge {
        case .left:
            resized = EditorTimelineMath.resizing(
                animation: clip,
                proposedStart: time,
                among: editorStore.project.zoomAnimations,
                duration: duration,
                defaultExit: editorStore.project.motion.defaultZoomTransitionDuration
            )
            guard resized.startTime != clip.startTime else { return }
        case .right:
            resized = EditorTimelineMath.resizing(
                animation: clip,
                proposedEnd: time,
                among: editorStore.project.zoomAnimations,
                duration: duration,
                defaultExit: editorStore.project.motion.defaultZoomTransitionDuration
            )
            guard resized.endTime != clip.endTime else { return }
        }
        do {
            try editorStore.replaceZoom(
                resized,
                actionName: edge == .left ? "Q 修剪缩放开始" : "W 修剪缩放结束"
            )
            seekTimeline(to: edge == .left ? resized.startTime : resized.endTime)
        } catch {
            onError(error.localizedDescription)
        }
    }

    /// Q: remove the current segment material before the edit point and ripple
    /// everything after it left. When a timed effect (zoom or motion) is selected,
    /// trim its leading edge to the edit point instead of affecting the primary clip.
    func rippleDeleteBeforePlayhead() {
        let editTime = effectiveTimelineEditTime
        switch EditorTimelineSplitTarget(selection: editorStore.selection) {
        case let .zoom(id):
            trimZoomAnimation(id: id, edge: .left, at: editTime)
        case let .screenMotion(id):
            trimMotionClip(track: .screen, id: id, edge: .left, at: editTime)
        case let .cameraMotion(id):
            trimMotionClip(track: .camera, id: id, edge: .left, at: editTime)
        case let .mosaic(id):
            trimMosaicClip(id: id, edge: .left, atTime: editTime)
        case let .sticker(id):
            trimStickerClip(id: id, edge: .left, atTime: editTime)
        case nil:
            guard let segment = timelineMap?.segment(atOutputTime: editTime),
                  editTime > segment.outputStart + timelineFrameDuration / 2,
                  segment.outputEnd - editTime >= minimumPrimarySegmentDuration else { return }
            do {
                try editorStore.trimPrimarySegment(
                    id: segment.id,
                    edge: .left,
                    toOutputTime: editTime,
                    fullSourceDuration: fullSourceDuration,
                    actionName: "Q 波纹删除"
                )
                primaryTrimDraft = nil
                primaryRetimeDraft = nil
                selectPrimarySegment(segment.id)
                seekTimeline(to: segment.outputStart)
            } catch {
                onError(error.localizedDescription)
            }
        }
    }

    /// W: remove material from the edit point to the current segment's next edit
    /// and ripple the following segment to the same frame boundary. When a timed
    /// effect is selected, trim its trailing edge to the edit point instead.
    func rippleDeleteAfterPlayhead() {
        let editTime = effectiveTimelineEditTime
        switch EditorTimelineSplitTarget(selection: editorStore.selection) {
        case let .zoom(id):
            trimZoomAnimation(id: id, edge: .right, at: editTime)
        case let .screenMotion(id):
            trimMotionClip(track: .screen, id: id, edge: .right, at: editTime)
        case let .cameraMotion(id):
            trimMotionClip(track: .camera, id: id, edge: .right, at: editTime)
        case let .mosaic(id):
            trimMosaicClip(id: id, edge: .right, atTime: editTime)
        case let .sticker(id):
            trimStickerClip(id: id, edge: .right, atTime: editTime)
        case nil:
            guard let segment = timelineMap?.segment(atOutputTime: editTime),
                  editTime - segment.outputStart >= minimumPrimarySegmentDuration,
                  segment.outputEnd - editTime > timelineFrameDuration / 2 else { return }
            do {
                try editorStore.trimPrimarySegment(
                    id: segment.id,
                    edge: .right,
                    toOutputTime: editTime,
                    fullSourceDuration: fullSourceDuration,
                    actionName: "W 波纹删除"
                )
                primaryTrimDraft = nil
                primaryRetimeDraft = nil
                selectPrimarySegment(segment.id)
                seekTimeline(to: editTime)
            } catch {
                onError(error.localizedDescription)
            }
        }
    }

    func removeTimelineTarget(_ target: EditorTimelineDeleteTarget) {
        switch target {
        case let .primarySegment(id):
            removePrimarySegment(id: id)
        case let .screenMotion(id):
            guard let clip = persistedMotionClip(track: .screen, id: id) else { return }
            removeMotionClip(clip)
        case let .cameraMotion(id):
            guard let clip = persistedMotionClip(track: .camera, id: id) else { return }
            removeMotionClip(clip)
        case let .zoom(id):
            removeZoomAnimation(id: id)
        case .mosaic, .sticker, .progress:
            do {
                try editorStore.removeSelectedOverlay()
            } catch {
                onError(error.localizedDescription)
            }
        }
    }

    func removeDeleteKeyMonitor() {
        guard let deleteKeyMonitor else { return }
        NSEvent.removeMonitor(deleteKeyMonitor)
        self.deleteKeyMonitor = nil
    }

    /// 滚轮缩放：悬停在时间线上时把纵向滚轮拦截为时间跨度缩放（正常剪辑
    /// 软件习惯），并以指针位置为锚点保持其时间不动。触控板双指捏合走
    /// magnify 手势，同样以指针为锚。返回 nil 吞掉事件，不再触发横向滚动。
    func installScrollWheelMonitor() {
        guard scrollWheelMonitor == nil else { return }
        scrollWheelMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.scrollWheel, .magnify]
        ) { event in
            guard event.window?.identifier?.rawValue == "cn.laogou.dogsc.editor-window",
                  let scrollView = timelineScrollView,
                  event.window === scrollView.window else { return event }
            let point = scrollView.convert(event.locationInWindow, from: nil)
            let bounds = scrollView.bounds
            guard point.x >= bounds.minX, point.x <= bounds.maxX,
                  point.y >= bounds.minY, point.y <= bounds.maxY else { return event }

            let viewportX = point.x - bounds.origin.x
            hoveredTimelineViewportX = viewportX

            switch event.type {
            case .scrollWheel:
                let delta = event.deltaY
                guard delta.isFinite, abs(delta) > 0.01 else { return event }
                guard EditorTimelineScrollWheelPolicy.intent(
                    deltaX: event.deltaX,
                    deltaY: delta
                ) == .zoom else { return event }
                enqueueTimelineZoomWithWheel(deltaY: delta)
                return nil
            case .magnify:
                let delta = event.magnification
                guard delta.isFinite, abs(delta) > 0.001 else { return event }
                enqueueTimelineZoomWithWheel(deltaY: delta * 3)
                return nil
            default:
                return event
            }
        }
    }

    func removeScrollWheelMonitor() {
        guard let scrollWheelMonitor else { return }
        NSEvent.removeMonitor(scrollWheelMonitor)
        self.scrollWheelMonitor = nil
        timelineZoomInputCoalescer.cancel()
    }

    /// 悬浮定位与预览轴驱动。AppKit 的 mouse-moved 只投递给指针下最上层
    /// 的 tracking area：片段、缩切段、运镜段各自带悬浮高亮的 `.onHover`
    /// 之后，ScrollView 容器上的 `onContinuousHover` 在元素上方完全收不到
    /// 移动事件，预览轴因此只在标尺等空白区域跟手。改为窗口级监视器按滚
    /// 动视图坐标系换算，任何子视图都不再吞掉悬浮位置；事件照常透传。
    func installHoverTrackingMonitor() {
        guard hoverTrackingMonitor == nil else { return }
        hoverTrackingMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.mouseMoved]
        ) { event in
            updateTimelineHoverLocation(with: event)
            return event
        }
    }

    func removeHoverTrackingMonitor() {
        guard let hoverTrackingMonitor else { return }
        NSEvent.removeMonitor(hoverTrackingMonitor)
        self.hoverTrackingMonitor = nil
    }

    func updateTimelineHoverLocation(with event: NSEvent) {
        guard event.window?.identifier?.rawValue
                  == "cn.laogou.dogsc.editor-window",
              let scrollView = timelineScrollView,
              event.window === scrollView.window else { return }
        let point = scrollView.convert(event.locationInWindow, from: nil)
        let bounds = scrollView.bounds
        guard point.x >= bounds.minX, point.x <= bounds.maxX,
              point.y >= bounds.minY, point.y <= bounds.maxY else {
            clearTimelineHoverLocation()
            return
        }
        // 与 SwiftUI `.local` 坐标系对齐：原点左上、y 向下。
        let viewportX = point.x - bounds.origin.x
        let viewportY = scrollView.isFlipped
            ? point.y - bounds.origin.y
            : bounds.maxY - point.y
        hoveredTimelineViewportX = viewportX
        hoveredTimelineViewportY = viewportY
        // 播放中画布由播放时钟独占，悬浮只移动参考线；暂停且开启预览时才让画布
        // 实时预览所指帧（EDT-030）。
        guard isHoverPreviewEnabled, !playbackController.isPlaying else { return }
        let contentX = viewportX + scrollView.documentVisibleRect.origin.x
        let time = EditorTimelineMath.clampedTime(
            atX: Double(contentX),
            width: Double(max(timelineContentWidth, 1)),
            duration: timelineDuration
        )
        playbackController.updateHoverPreview(to: time)
    }

    func clearTimelineHoverLocation() {
        guard hoveredTimelineViewportX != nil
                || hoveredTimelineViewportY != nil else { return }
        hoveredTimelineViewportX = nil
        hoveredTimelineViewportY = nil
        playbackController.endHoverPreview()
    }

    func installModifierFlagsMonitor() {
        guard modifierFlagsMonitor == nil else { return }
        modifierFlagsMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { event in
            isOptionHeld = event.modifierFlags.contains(.option)
            return event
        }
    }

    func removeModifierFlagsMonitor() {
        guard let modifierFlagsMonitor else { return }
        NSEvent.removeMonitor(modifierFlagsMonitor)
        self.modifierFlagsMonitor = nil
    }

    /// EDT-016/020: SwiftUI may omit `onEnded` when a view disappears during a
    /// ripple edit or loses its window. Tie every timeline gesture to AppKit's
    /// real mouse lifecycle so a stale move/resize cannot own the next click.
    func installPrimarySegmentDragCompletionMonitors() {
        guard primarySegmentDragLocalMonitor == nil else { return }
        removePrimarySegmentDragGlobalCompletionMonitor()

        primarySegmentDragLocalMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown, .leftMouseUp, .keyDown]
        ) { event in
            switch event.type {
            case .leftMouseUp:
                // SwiftUI normally ends first. The deferred recovery only
                // acts when that callback was lost with a removed/rebuilt view.
                DispatchQueue.main.async {
                    recoverAbandonedTimelineGesture()
                    removePrimarySegmentDragGlobalCompletionMonitor()
                }
            case .leftMouseDown:
                // A new physical press proves any still-active semantic drag
                // belongs to an older session. Clear it before SwiftUI routes
                // this same event to the newly pressed clip.
                recoverAbandonedTimelineGesture()
                // A global mouse-up monitor is only needed between this press
                // and its release, in case the drag leaves the editor window.
                // Keeping it installed for the editor's entire lifetime made
                // every mouse-up in every other app wake our main actor.
                installPrimarySegmentDragGlobalCompletionMonitorIfNeeded()
            case .rightMouseDown:
                recoverAbandonedTimelineGesture()
                removePrimarySegmentDragGlobalCompletionMonitor()
            case .keyDown where event.keyCode == 53: // Escape
                recoverAbandonedTimelineGesture()
                removePrimarySegmentDragGlobalCompletionMonitor()
            default:
                break
            }
            return event
        }
    }

    func installPrimarySegmentDragGlobalCompletionMonitorIfNeeded() {
        guard primarySegmentDragGlobalMonitor == nil else { return }
        primarySegmentDragGlobalMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: .leftMouseUp
        ) { _ in
            DispatchQueue.main.async {
                recoverAbandonedTimelineGesture()
                removePrimarySegmentDragGlobalCompletionMonitor()
            }
        }
    }

    func removePrimarySegmentDragGlobalCompletionMonitor() {
        guard let primarySegmentDragGlobalMonitor else { return }
        NSEvent.removeMonitor(primarySegmentDragGlobalMonitor)
        self.primarySegmentDragGlobalMonitor = nil
    }

    func removePrimarySegmentDragCompletionMonitors() {
        if let primarySegmentDragLocalMonitor {
            NSEvent.removeMonitor(primarySegmentDragLocalMonitor)
            self.primarySegmentDragLocalMonitor = nil
        }
        removePrimarySegmentDragGlobalCompletionMonitor()
    }

    func endPrimarySegmentDrag() {
        draggedPrimarySegmentID = nil
        primarySegmentDragTranslation = 0
    }

    var hasTransientTimelineGesture: Bool {
        gestureOwnership.activeIntent != nil
            || draggedPrimarySegmentID != nil
            || primaryTrimDraft != nil
            || zoomTrackDrag != nil
            || zoomGestureOrigin != nil
            || manualZoomDragStart != nil
            || manualZoomDragEnd != nil
            || motionTrackDrag != nil
            || motionGestureOrigin != nil
            || motionCreateDrag != nil
    }

    func recoverAbandonedTimelineGesture() {
        guard hasTransientTimelineGesture else { return }
        cancelActiveTimelineGesture()
    }

    func enqueueTimelineZoomWithWheel(deltaY: CGFloat) {
        guard timelineDuration > 0 else { return }
        timelineZoomInputCoalescer.enqueue(
            currentZoom: timelineZoom,
            deltaY: deltaY,
            pointerViewportX: hoveredTimelineViewportX
        ) { targetZoom, pointerViewportX in
            zoomTimeline(to: targetZoom, pointerViewportX: pointerViewportX)
        }
    }

    /// TLZ-001/PRE-005: resize the native document and move its clip view in
    /// the same wheel event. Waiting for a later SwiftUI layout pass exposed
    /// one frame at the new width with the old offset, so a continuous wheel
    /// gesture visibly alternated between two positions.
    func zoomTimeline(to requestedZoom: Double, pointerViewportX: CGFloat?) {
        let oldZoom = timelineZoom
        let newZoom = min(max(requestedZoom, 1), 120)
        guard newZoom != oldZoom else { return }
        guard let scrollView = timelineScrollView else {
            timelineZoom = newZoom
            return
        }
        let viewportWidth = max(scrollView.contentView.bounds.width, 1)
        let currentWidth = max(
            scrollView.documentView?.bounds.width ?? timelineContentWidth,
            viewportWidth
        )
        let targetContentWidth = max(
            currentWidth * CGFloat(newZoom / oldZoom),
            viewportWidth
        )
        let currentOffset = scrollView.documentVisibleRect.origin.x
        let resolvedViewportX = pointerViewportX
            ?? fallbackTimelineZoomViewportX(
                contentWidth: currentWidth,
                viewportWidth: viewportWidth,
                contentOffset: currentOffset
            )
        let anchor = EditorTimelineZoomAnchor(
            pointerViewportX: resolvedViewportX,
            contentOffsetX: currentOffset,
            contentWidth: currentWidth,
            targetContentWidth: targetContentWidth
        )
        let targetOffset = anchor.scrollOffset(viewportWidth: viewportWidth)

        var transaction = Transaction(animation: nil)
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            timelineZoom = newZoom
            timelineContentWidth = targetContentWidth
        }

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0
            context.allowsImplicitAnimation = false
            if let documentView = scrollView.documentView {
                documentView.setFrameSize(
                    NSSize(
                        width: targetContentWidth,
                        height: documentView.frame.height
                    )
                )
            }
            let currentY = scrollView.documentVisibleRect.origin.y
            scrollView.contentView.scroll(to: NSPoint(x: targetOffset, y: currentY))
            scrollView.reflectScrolledClipView(scrollView.contentView)
        }
    }

    func fallbackTimelineZoomViewportX(
        contentWidth: CGFloat,
        viewportWidth: CGFloat,
        contentOffset: CGFloat
    ) -> CGFloat {
        guard timelineDuration > 0 else { return viewportWidth / 2 }
        let playheadDocumentX = CGFloat(playbackTime / timelineDuration) * contentWidth
        if playheadDocumentX >= contentOffset,
           playheadDocumentX <= contentOffset + viewportWidth {
            return playheadDocumentX - contentOffset
        }
        return viewportWidth / 2
    }

    func splitZoomAnimation(id: UUID, at time: TimeInterval) {
        guard let index = editorStore.project.zoomAnimations.firstIndex(where: { $0.id == id }),
              let pair = EditorTimelineMath.split(
                animation: editorStore.project.zoomAnimations[index],
                at: time
              ) else { return }
        var timeline = editorStore.project.timeline
        timeline.zoomClips[index] = pair.0
        timeline.zoomClips.insert(pair.1, at: index + 1)
        do {
            try editorStore.replaceTimeline(with: timeline, actionName: "拆分缩放")
        } catch {
            onError(error.localizedDescription)
            return
        }
        selectedZoomID = pair.1.id
        seekTimeline(to: time)
    }

    func createZoomRange(
        start: TimeInterval,
        end: TimeInterval,
        duration: TimeInterval
    ) {
        // 空白处创建：范围拟合进两段之间的空隙（小间隙也能放下、洞口吸到相接），
        // 只有完全没有空隙时才不创建。
        guard var animation = EditorTimelineMath.fitZoomAnimation(
            start: start,
            end: end,
            among: editorStore.project.zoomAnimations,
            duration: duration,
            easing: editorStore.project.motion.defaultZoomEasing,
            transitionDuration: editorStore.project.motion.defaultZoomTransitionDuration
        ) else { return }
        // CAM-002/CAM-008: a range drawn by hand chooses its timing, not a
        // permanently fixed camera point. Seed the automatic composition from
        // the recorded pointer at the fitted start; the inspector still lets
        // the user opt into manual positioning for this exact clip.
        if animation.origin == .automatic,
           let pointer = mediaSession.mediaPlan?.pointer.evaluation(
               at: animation.startTime,
               motion: editorStore.project.motion,
               style: editorStore.project.cursorStyle
           ).position {
            animation.focus = pointer.constrained(
                to: ZoomViewportTransform.focusEdgeInset
            )
        }
        do {
            try editorStore.insertZoom(animation, actionName: "添加缩放")
        } catch {
            onError(error.localizedDescription)
            return
        }
        selectedZoomID = animation.id
    }

    func timelineTimestamp(_ time: TimeInterval) -> String {
        let centiseconds = max(Int((time * 100).rounded(.down)), 0)
        let minutes = centiseconds / 6_000
        let seconds = (centiseconds / 100) % 60
        let fraction = centiseconds % 100
        return String(format: "%d:%02d.%02d", minutes, seconds, fraction)
    }
}
