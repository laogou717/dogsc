import AppKit
import RecorderCore
import SwiftUI
import UniformTypeIdentifiers

extension EditorTimelineView {
var primarySegmentJunctions: [EditorTimelineSegmentJunction] {
        guard let timelineMap else { return [] }
        return derivedPresentationCache.segmentJunctions(for: timelineMap)
    }

    var primaryLeadingGap: EditorTimelineLeadingGap? {
        guard let timelineMap else { return nil }
        return derivedPresentationCache.leadingGap(for: timelineMap)
    }

    var primaryTrailingGap: EditorTimelineTrailingGap? {
        guard let timelineMap else { return nil }
        return derivedPresentationCache.trailingGap(for: timelineMap)
    }

    @ViewBuilder
    func primarySegmentContextMenu(segment: ResolvedRecordingSegment) -> some View {
        Button {
            splitPrimarySegmentAtPlayhead()
        } label: {
            Label("在播放头处分割", systemImage: "scissors")
        }
        .disabled(!canSplitPrimarySegment(segment))

        Divider()

        Button {
            rippleDeleteBeforePlayhead()
        } label: {
            Label("波纹删除播放头之前（Q）", systemImage: "delete.left")
        }
        .disabled(!canRippleDeleteBeforePlayhead(in: segment))

        Button {
            rippleDeleteAfterPlayhead()
        } label: {
            Label("波纹删除播放头之后（W）", systemImage: "delete.right")
        }
        .disabled(!canRippleDeleteAfterPlayhead(in: segment))

        let previousJunction = primarySegmentJunctions.first(where: { $0.nextSegmentID == segment.id })
        let nextJunction = primarySegmentJunctions.first(where: { $0.previousSegmentID == segment.id })
        let isFirstSegment = segment.id == primaryDisplaySegments.first?.id
        let isLastSegment = segment.id == primaryDisplaySegments.last?.id

        if previousJunction != nil || nextJunction != nil || (isFirstSegment && primaryLeadingGap != nil) || (isLastSegment && primaryTrailingGap != nil) {
            Divider()

            if isFirstSegment, let gap = primaryLeadingGap {
                Button {
                    restorePrimaryLeadingGap(gap)
                } label: {
                    Label("还原开头剪辑（已剪 \(timelineTimestamp(gap.removedDuration))）", systemImage: "arrow.uturn.backward")
                }
            }

            if let junction = previousJunction {
                if junction.hasRemovedSourceGap {
                    Button {
                        restorePrimaryGap(junction)
                    } label: {
                        Label("还原前侧剪切缺口（已剪 \(timelineTimestamp(junction.removedDuration))）", systemImage: "arrow.uturn.backward")
                    }
                } else {
                    Button {
                        mergePrimarySegments(at: junction)
                    } label: {
                        Label("合并与前一片段", systemImage: "link")
                    }
                }
            }

            if let junction = nextJunction {
                if junction.hasRemovedSourceGap {
                    Button {
                        restorePrimaryGap(junction)
                    } label: {
                        Label("还原后侧剪切缺口（已剪 \(timelineTimestamp(junction.removedDuration))）", systemImage: "arrow.uturn.backward")
                    }
                } else {
                    Button {
                        mergePrimarySegments(at: junction)
                    } label: {
                        Label("合并与后一片段", systemImage: "link")
                    }
                }
            }

            if isLastSegment, let gap = primaryTrailingGap {
                Button {
                    restorePrimaryTrailingGap(gap)
                } label: {
                    Label("还原结尾剪辑（已剪 \(timelineTimestamp(gap.removedDuration))）", systemImage: "arrow.uturn.backward")
                }
            }
        }

        Divider()

        Button(role: .destructive) {
            selectPrimarySegment(segment.id)
            removePrimarySegment(id: segment.id)
        } label: {
            Label("删除主片段", systemImage: "trash")
        }
    }

    func segmentJunctionAction(
        _ junction: EditorTimelineSegmentJunction
    ) -> some View {
        return Button {
            if junction.hasRemovedSourceGap {
                restorePrimaryGap(junction)
            } else {
                mergePrimarySegments(at: junction)
            }
        } label: {
            ZStack {
                Circle()
                    .fill(Color.black.opacity(0.9))
                Circle()
                    .stroke(editorAccent.opacity(0.95), lineWidth: 1)
                Image(systemName: junction.hasRemovedSourceGap
                    ? "arrow.uturn.backward"
                    : "link")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(.white)
            }
            .frame(width: 17, height: 17)
            .frame(width: 22, height: 22)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contentShape(Rectangle())
        .help(
            junction.hasRemovedSourceGap
                ? "撤销这一处剪辑（已剪 \(timelineTimestamp(junction.removedDuration))）"
                : "合并这两个已剪开的片段"
        )
        .accessibilityLabel(
            junction.hasRemovedSourceGap ? "还原剪切缺口" : "合并相邻主片段"
        )
        .accessibilityValue(
            junction.hasRemovedSourceGap
                ? timelineTimestamp(junction.removedDuration)
                : "未删除素材"
        )
        .accessibilityIdentifier(
            "editor.timeline.cut-junction.\(junction.nextSegmentID.uuidString)"
        )
    }

    func leadingGapAction(_ gap: EditorTimelineLeadingGap) -> some View {
        Button {
            restorePrimaryLeadingGap(gap)
        } label: {
            ZStack {
                Circle().fill(Color.black.opacity(0.9))
                Circle().stroke(editorAccent.opacity(0.95), lineWidth: 1)
                Image(systemName: "arrow.uturn.backward")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(.white)
            }
            .frame(width: 17, height: 17)
            .frame(width: 22, height: 22)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("还原开头剪辑（已剪 \(timelineTimestamp(gap.removedDuration))）")
        .accessibilityLabel("还原开头剪辑")
        .accessibilityValue(timelineTimestamp(gap.removedDuration))
        .accessibilityIdentifier("editor.timeline.leading-gap")
    }

    func trailingGapAction(_ gap: EditorTimelineTrailingGap) -> some View {
        Button {
            restorePrimaryTrailingGap(gap)
        } label: {
            ZStack {
                Circle().fill(Color.black.opacity(0.9))
                Circle().stroke(editorAccent.opacity(0.95), lineWidth: 1)
                Image(systemName: "arrow.uturn.backward")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(.white)
            }
            .frame(width: 17, height: 17)
            .frame(width: 22, height: 22)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("还原结尾剪辑（已剪 \(timelineTimestamp(gap.removedDuration))）")
        .accessibilityLabel("还原结尾剪辑")
        .accessibilityValue(timelineTimestamp(gap.removedDuration))
        .accessibilityIdentifier("editor.timeline.trailing-gap")
    }

    func restorePrimaryGap(_ junction: EditorTimelineSegmentJunction) {
        let restoredID = UUID()
        do {
            try editorStore.restorePrimaryGap(
                previousSegmentID: junction.previousSegmentID,
                nextSegmentID: junction.nextSegmentID,
                restoredSegmentID: restoredID,
                fullSourceDuration: fullSourceDuration,
                actionName: "还原该处剪切"
            )
            primaryTrimDraft = nil
            selectPrimarySegment(restoredID)
            seekTimeline(to: junction.outputTime)
            isRestoreCutMode = false
        } catch {
            onError(error.localizedDescription)
        }
    }

    func restorePrimaryLeadingGap(_ gap: EditorTimelineLeadingGap) {
        let restoredID = UUID()
        do {
            try editorStore.restorePrimaryLeadingGap(
                restoredSegmentID: restoredID,
                fullSourceDuration: fullSourceDuration,
                actionName: "还原开头剪辑"
            )
            primaryTrimDraft = nil
            selectPrimarySegment(restoredID)
            seekTimeline(to: 0)
            isRestoreCutMode = false
        } catch {
            onError(error.localizedDescription)
        }
    }

    func restorePrimaryTrailingGap(_ gap: EditorTimelineTrailingGap) {
        let restoredID = UUID()
        do {
            try editorStore.restorePrimaryTrailingGap(
                restoredSegmentID: restoredID,
                fullSourceDuration: fullSourceDuration,
                actionName: "还原结尾剪辑"
            )
            primaryTrimDraft = nil
            selectPrimarySegment(restoredID)
            seekTimeline(to: gap.outputTime)
            isRestoreCutMode = false
        } catch {
            onError(error.localizedDescription)
        }
    }

    func mergePrimarySegments(at junction: EditorTimelineSegmentJunction) {
        do {
            try editorStore.mergeAdjacentPrimarySegments(
                previousSegmentID: junction.previousSegmentID,
                nextSegmentID: junction.nextSegmentID,
                fullSourceDuration: fullSourceDuration,
                actionName: "合并相邻主片段"
            )
            primaryTrimDraft = nil
            selectPrimarySegment(junction.previousSegmentID)
            seekTimeline(to: junction.outputTime)
            isRestoreCutMode = false
        } catch {
            onError(error.localizedDescription)
        }
    }

    /// AUD-003/AUD-004: waveform pixels belong to each retained video clip.
    /// Rendering one clipped overlay per segment keeps cut gaps and segment
    /// borders visible, and uses the same output-to-source media map as
    /// preview/export instead of inventing a second audio timeline lane.
    func clipAudioWaveformOverlay(
        width: CGFloat,
        duration: TimeInterval
    ) -> some View {
        let visibleWindow = EditorTimelineWaveformPresentation.visibleWindow(
            documentWidth: width,
            outputDuration: duration,
            visibleRange: clampedTimelineVisibleDocumentRange(width: width)
        )
        return ZStack(alignment: .leading) {
            clipWaveforms(
                width: visibleWindow.width,
                outputStart: visibleWindow.outputStart,
                outputDuration: visibleWindow.outputDuration
            )
            .mask {
                Canvas { context, size in
                    var retainedSegments = Path()
                    let safeDuration = max(duration, 0.001)
                    let windowStart = visibleWindow.documentOriginX
                    let windowEnd = windowStart + visibleWindow.width
                    for segment in primaryDisplaySegments {
                        let segmentStart = CGFloat(segment.outputStart / safeDuration) * width
                        let segmentEnd = segmentStart
                            + max(CGFloat(segment.sourceDuration / safeDuration) * width, 1)
                        guard segmentEnd >= windowStart, segmentStart <= windowEnd else {
                            continue
                        }
                        let localStart = max(segmentStart - windowStart, 0)
                        let localEnd = min(segmentEnd - windowStart, size.width)
                        retainedSegments.addRoundedRect(
                            in: CGRect(
                                x: localStart,
                                y: 0,
                                width: max(localEnd - localStart, 1),
                                height: size.height
                            ),
                            cornerSize: CGSize(width: 7, height: 7)
                        )
                    }
                    context.fill(retainedSegments, with: .color(.white))
                }
            }
            .offset(x: visibleWindow.documentOriginX)
        }
        .frame(width: width, height: primaryClipContentHeight, alignment: .leading)
        .clipped()
        .accessibilityElement(children: .contain)
        .accessibilityLabel("片段内音频波形")
    }

    func clipWaveforms(
        width: CGFloat,
        outputStart: TimeInterval,
        outputDuration: TimeInterval
    ) -> some View {
        // EDT-WAVE-003: 系统声与麦克风波形叠放在同一全高条带（系统声紫色
        // 半透明、只画上半截贴底；麦克风近白色中线对称），各自按自身峰值
        // 自适应增益。分栏拖动全程实时跟随车道高度重绘（EDT-WAVE-003 用户
        // 明确要求实时自适应；拖动抖动已由 PRE-033 的全局坐标系修复根治，
        // 不再需要冻结波形高度）。
        let contentHeight = primaryClipContentHeight
        return ZStack {
            if showsSystemWaveform,
               let systemWaveform,
               let plan = mediaSession.mediaPlan?.systemAudio {
                waveformStrip(
                    lane: .system,
                    waveform: systemWaveform,
                    plan: plan,
                    width: width,
                    height: contentHeight,
                    outputStart: outputStart,
                    outputDuration: outputDuration
                )
            }
            if showsMicrophoneWaveform,
               let microphoneWaveform,
               let plan = mediaSession.mediaPlan?.microphone {
                waveformStrip(
                    lane: .microphone,
                    waveform: microphoneWaveform,
                    plan: plan,
                    width: width,
                    height: contentHeight,
                    outputStart: outputStart,
                    outputDuration: outputDuration
                )
            }
        }
        .frame(width: width, height: primaryClipContentHeight)
    }

    func waveformStrip(
        lane: EditorTimelineWaveformLane,
        waveform: EditorTimelineWaveformData,
        plan: TimelineMediaPlan,
        width: CGFloat,
        height: CGFloat,
        outputStart: TimeInterval,
        outputDuration: TimeInterval
    ) -> some View {
        EditorTimelineWaveformStripView(
            lane: lane,
            waveform: waveform,
            plan: plan,
            width: width,
            height: height,
            outputStart: outputStart,
            outputDuration: outputDuration
        )
        .equatable()
    }

    @MainActor
    func loadAudioWaveforms() async {
        guard let prepared = mediaSession.prepared else {
            systemWaveform = nil
            microphoneWaveform = nil
            return
        }
        let expectedGeneration = prepared.generation
        // Copy the immutable, Sendable inputs before creating child tasks.
        // The prepared media container also owns AVFoundation composition
        // objects, so sending the whole main-actor value would overstate the
        // concurrency boundary even though waveform decoding needs only URLs
        // and time ranges.
        let sourceInput = prepared.request.source
        let sourceRange = prepared.inventories.source.audioTimeRange
        let microphoneInput = prepared.request.microphone
        let microphoneRange = prepared.inventories.microphone.audioTimeRange
        let cachedSystem = systemWaveform
        let cachedMicrophone = microphoneWaveform
        async let loadedSystem = EditorTimelineWaveformLoader.load(
            input: sourceInput,
            sourceRange: sourceRange,
            cached: cachedSystem
        )
        async let loadedMicrophone = EditorTimelineWaveformLoader.load(
            input: microphoneInput,
            sourceRange: microphoneRange,
            cached: cachedMicrophone
        )
        let results = await (loadedSystem, loadedMicrophone)
        guard !Task.isCancelled,
              mediaSession.prepared?.generation == expectedGeneration else { return }
        systemWaveform = results.0
        microphoneWaveform = results.1
    }

    /// Alt+悬停主片段轨时的裁剪落点：原始 hover x，或在 7pt 内磁吸到最近的
    /// 片段端点/播放头。
    func snappedCutX(width: CGFloat, duration: TimeInterval) -> CGFloat? {
        guard isOptionHeld,
              let x = hoveredTimelineContentX,
              let y = hoveredTimelineContentY,
              y >= timelineRulerHeight,
              y <= timelineRulerHeight + primaryTimelineHeight else { return nil }
        return EditorPrimaryTimelinePresentation.snappedCutX(
            pointerX: x,
            width: width,
            duration: duration,
            segments: primaryDisplaySegments,
            playbackTime: playbackTime
        )
    }

    var primaryDisplaySegments: [ResolvedRecordingSegment] {
        guard let timelineMap else { return [] }
        return EditorPrimaryTimelinePresentation.displaySegments(
            from: timelineMap,
            trimDraft: primaryTrimDraft
        )
    }

    /// Pointer badges re-render at the parent-clock rate (60 Hz during
    /// playback); the segment mapping is pure and only changes when the map or
    /// the event array changes, so memoize it instead of re-sorting and
    /// re-mapping every frame.
    func timelinePointerClicks(outputEnd: TimeInterval) -> [PointerEventRecord] {
        guard let timelineMap else { return [] }
        let mappedPointerClicks = derivedPresentationCache.pointerClicks(
            for: timelineMap
        )
        guard primaryTrimDraft != nil else { return mappedPointerClicks }
        return EditorPrimaryTimelinePresentation.pointerClicks(
            mappedPointerClicks,
            beforeOutputEnd: outputEnd
        )
    }

    /// 点击事件标记按当前缩放级别分级呈现：1× 全片浏览时只是一颗安静的
    /// 小点（知道"这里有点击"即可），放大进入精剪上下文后才展开为带图标
    /// 的完整徽章。雾白极简下用白底深图标，不再引入紫色。
    func pointerEventBadge(_ event: PointerEventRecord, emphasized: Bool) -> some View {
        let isRightClick = event.kind == .rightClick
        return ZStack {
            Circle()
                .fill(isRightClick ? editorZoomClip : Color(white: 0.92))
                .overlay(
                    Circle().stroke(
                        .black.opacity(emphasized ? 0.35 : 0.2),
                        lineWidth: emphasized ? 1 : 0.5
                    )
                )
            if emphasized {
                Image(systemName: isRightClick ? "cursorarrow.click.2" : "cursorarrow.click")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(isRightClick ? .white : .black.opacity(0.78))
            }
        }
        .frame(width: emphasized ? 18 : 9, height: emphasized ? 18 : 9)
        .opacity(emphasized ? 1 : 0.55)
        .animation(.easeOut(duration: 0.14), value: emphasized)
        .help(
            "\(isRightClick ? "右键" : "左键")点击 · "
                + timelineTimestamp(event.time)
        )
        .accessibilityLabel(
            "\(isRightClick ? "右键" : "左键")点击，"
                + timelineTimestamp(event.time)
        )
    }

    func primaryTrimHandle(
        edge: RecordingSegmentTrimEdge,
        segment: ResolvedRecordingSegment,
        laneWidth: CGFloat,
        duration: TimeInterval
    ) -> some View {
        let intent = EditorTimelineGestureIntent.primaryTrim(segment.id, edge)
        return Capsule(style: .continuous)
            .fill(Color.white.opacity(0.95))
            .frame(
                width: 3,
                height: min(max(primaryClipContentHeight - 18, 34), 72)
            )
            .frame(width: 10, height: primaryClipContentHeight)
            .contentShape(Rectangle())
            .highPriorityGesture(
                DragGesture(
                    minimumDistance: 0,
                    coordinateSpace: .named(editorTimelineDocumentCoordinateSpace)
                    )
                    .onChanged { value in
                        guard beginTimelineGesture(intent) else { return }
                        selectPrimarySegment(segment.id)
                        let origin: PrimarySegmentTrimDraft
                        if let current = primaryTrimDraft,
                           current.segmentID == segment.id,
                           current.edge == edge {
                            origin = current
                        } else {
                            guard let map = timelineMap,
                                  let created = EditorPrimaryTimelinePresentation.trimDraftOrigin(
                                      segmentID: segment.id,
                                      edge: edge,
                                      map: map,
                                      fullSourceDuration: fullSourceDuration
                                  ) else { return }
                            origin = created
                        }
                        let rawOutputTime = EditorPrimaryTimelinePresentation.trimOutputTime(
                            for: origin.original,
                            edge: edge,
                            pointerX: value.location.x,
                            laneWidth: laneWidth,
                            outputDuration: duration,
                            minimumSegmentDuration: minimumPrimarySegmentDuration,
                            minimumOutputTime: origin.minimumOutputTime,
                            maximumOutputTime: origin.maximumOutputTime
                        )
                        let outputTime = snappedEditableTime(
                            rawOutputTime,
                            lowerBound: origin.minimumOutputTime,
                            upperBound: origin.maximumOutputTime
                        )
                        let draft = PrimarySegmentTrimDraft(
                            segmentID: segment.id,
                            edge: edge,
                            original: origin.original,
                            minimumOutputTime: origin.minimumOutputTime,
                            maximumOutputTime: origin.maximumOutputTime,
                            proposedOutputTime: outputTime
                        )
                        primaryTrimDraft = draft
                        playbackController.beginScrubbing()
                        playbackController.updateScrubbing(
                            to: EditorPrimaryTimelinePresentation.trimPreviewTime(
                                for: draft,
                                frameDuration: timelineFrameDuration
                            )
                        )
                    }
                    .onEnded { _ in
                        guard gestureOwnership.activeIntent == intent else { return }
                        playbackController.endScrubbing()
                        commitPrimaryTrimDraft()
                        endTimelineGesture(intent)
                    }
            )
            .help(edge == .left ? "拖动裁切或恢复左端" : "拖动裁切或恢复右端")
            .accessibilityLabel(edge == .left ? "裁切主片段左端" : "裁切主片段右端")
            .accessibilityIdentifier(
                "editor.timeline.primary.trim.\(segment.id.uuidString).\(edge.rawValue)"
            )
    }

    var minimumPrimarySegmentDuration: TimeInterval {
        timelineFrameDuration
    }

    var primarySplitTime: TimeInterval {
        effectiveTimelineEditTime
    }

    var primarySplitCandidate: ResolvedRecordingSegment? {
        let splitTime = primarySplitTime
        guard let segment = timelineMap?.segment(atOutputTime: splitTime),
              splitTime - segment.outputStart >= minimumPrimarySegmentDuration,
              segment.outputEnd - splitTime >= minimumPrimarySegmentDuration
        else { return nil }
        return segment
    }

    func canSplitPrimarySegment(_ segment: ResolvedRecordingSegment) -> Bool {
        primarySplitCandidate?.id == segment.id
    }

    func canRippleDeleteBeforePlayhead(
        in segment: ResolvedRecordingSegment
    ) -> Bool {
        let editTime = effectiveTimelineEditTime
        guard timelineMap?.segment(atOutputTime: editTime)?.id == segment.id else {
            return false
        }
        return editTime > segment.outputStart + timelineFrameDuration / 2
            && segment.outputEnd - editTime >= minimumPrimarySegmentDuration
    }

    func canRippleDeleteAfterPlayhead(
        in segment: ResolvedRecordingSegment
    ) -> Bool {
        let editTime = effectiveTimelineEditTime
        guard timelineMap?.segment(atOutputTime: editTime)?.id == segment.id else {
            return false
        }
        return editTime - segment.outputStart >= minimumPrimarySegmentDuration
            && segment.outputEnd - editTime > timelineFrameDuration / 2
    }

    func selectPrimarySegment(_ id: UUID) {
        editorStore.selection = .primarySegment(id)
    }

    func clearTimelineSelection() {
        primaryTrimDraft = nil
        hoveredPrimarySegmentID = nil
        hoveredZoomID = nil
        editorStore.selection = .canvas
    }

    func splitPrimarySegmentAtPlayhead() {
        guard primarySplitCandidate != nil else { return }
        let splitTime = primarySplitTime
        let rightID = UUID()
        do {
            try editorStore.splitPrimarySegment(
                atOutputTime: splitTime,
                fullSourceDuration: fullSourceDuration,
                newRightSegmentID: rightID,
                actionName: "分割主片段"
            )
        } catch {
            onError(error.localizedDescription)
            return
        }
        hoveredPrimarySegmentID = nil
        selectPrimarySegment(rightID)
        seekTimeline(to: min(splitTime, timelineDuration))
    }

    /// Option+单击快捷切分：按点击位置的比例换算输出时间，与剪刀按钮同一条
    /// 领域路径（不可分割的位置——太靠近端点——直接忽略，不打扰正常点选）。
    func splitPrimarySegmentAtClick(
        segment: ResolvedRecordingSegment,
        location: CGPoint,
        segmentWidth: CGFloat
    ) {
        guard NSEvent.modifierFlags.contains(.option) else { return }
        let fraction = TimeInterval(min(max(location.x / max(segmentWidth, 1), 0), 1))
        var outputTime = segment.outputStart
            + min(max(fraction, 0), 1) * segment.sourceDuration
        // 磁吸：落点在片段端点或播放头附近（与剪刀提示同一 7pt 容差）时对齐。
        let laneWidth = max(timelineContentWidth, 1)
        let outputX = CGFloat(outputTime / max(timelineDuration, 0.001)) * laneWidth
        let snappedX = EditorPrimaryTimelinePresentation.snappedCutX(
            pointerX: outputX,
            width: laneWidth,
            duration: timelineDuration,
            segments: primaryDisplaySegments,
            playbackTime: playbackTime
        )
        outputTime = EditorTimelineMath.clampedTime(
            atX: Double(snappedX),
            width: Double(laneWidth),
            duration: timelineDuration
        )
        outputTime = snappedEditableTime(
            outputTime,
            lowerBound: segment.outputStart,
            upperBound: segment.outputEnd
        )
        guard outputTime > segment.outputStart + minimumPrimarySegmentDuration,
              outputTime < segment.outputEnd - minimumPrimarySegmentDuration else { return }
        let rightID = UUID()
        do {
            try editorStore.splitPrimarySegment(
                atOutputTime: outputTime,
                fullSourceDuration: fullSourceDuration,
                newRightSegmentID: rightID,
                actionName: "分割主片段"
            )
        } catch {
            onError(error.localizedDescription)
            return
        }
        hoveredPrimarySegmentID = nil
        selectPrimarySegment(rightID)
        seekTimeline(to: outputTime)
    }

    func removeSelectedPrimarySegment() {
        guard let selectedPrimarySegmentID else { return }
        removePrimarySegment(id: selectedPrimarySegmentID)
    }

    func movePrimarySegment(
        _ draggedID: UUID,
        relativeTo targetID: UUID,
        placeAfterTarget: Bool
    ) {
        guard let map = timelineMap,
              let oldIndex = map.segments.firstIndex(where: { $0.id == draggedID }),
              let targetIndex = map.segments.firstIndex(where: { $0.id == targetID }) else {
            return
        }
        var destination = targetIndex + (placeAfterTarget ? 1 : 0)
        if oldIndex < destination { destination -= 1 }
        destination = min(max(destination, 0), map.segments.count - 1)
        guard destination != oldIndex else { return }
        do {
            try editorStore.movePrimarySegment(
                id: draggedID,
                toIndex: destination,
                fullSourceDuration: fullSourceDuration,
                actionName: "调整主片段顺序"
            )
            primaryTrimDraft = nil
            hoveredPrimarySegmentID = nil
            selectPrimarySegment(draggedID)
            if let updatedMap = try? EditorPrimaryTimelinePresentation.timelineMap(
                fullSourceDuration: fullSourceDuration,
                project: editorStore.project
            ), let moved = updatedMap.segments.first(where: { $0.id == draggedID }) {
                seekTimeline(to: moved.outputStart)
            }
        } catch {
            onError(error.localizedDescription)
        }
    }

    /// EDT-016: reordering stays inside the timeline's own gesture lifecycle.
    /// SwiftUI/AppKit drag-and-drop can outlive its source view when the window
    /// deactivates, leaving the source segment permanently dimmed. A direct
    /// drag has a deterministic end/cancel path and never creates an external
    /// pasteboard session.
    func updatePrimarySegmentDrag(segmentID: UUID, translation: CGFloat) {
        if draggedPrimarySegmentID == nil {
            draggedPrimarySegmentID = segmentID
        }
        guard draggedPrimarySegmentID == segmentID else { return }
        primarySegmentDragTranslation = translation
    }

    func finishPrimarySegmentDrag(
        segmentID: UUID,
        documentX: CGFloat,
        laneWidth: CGFloat,
        duration: TimeInterval
    ) {
        defer { endPrimarySegmentDrag() }
        guard draggedPrimarySegmentID == segmentID,
              laneWidth > 0,
              duration > 0 else { return }

        let x = min(max(documentX, 0), laneWidth)
        let segments = primaryDisplaySegments
        guard let target = segments.min(by: { lhs, rhs in
            let lhsCenter = CGFloat(
                (lhs.outputStart + lhs.sourceDuration / 2) / duration
            ) * laneWidth
            let rhsCenter = CGFloat(
                (rhs.outputStart + rhs.sourceDuration / 2) / duration
            ) * laneWidth
            return abs(lhsCenter - x) < abs(rhsCenter - x)
        }), target.id != segmentID else { return }

        let targetCenter = CGFloat(
            (target.outputStart + target.sourceDuration / 2) / duration
        ) * laneWidth
        movePrimarySegment(
            segmentID,
            relativeTo: target.id,
            placeAfterTarget: x >= targetCenter
        )
    }

    func removePrimarySegment(id: UUID) {
        let segmentIDs = EditorTimelineSelectionPresentation.primarySegmentIDs(
            in: editorStore.project.timeline.sourceSequence
        )
        guard let removedIndex = segmentIDs.firstIndex(of: id) else { return }
        do {
            try editorStore.removePrimarySegment(
                id: id,
                fullSourceDuration: fullSourceDuration,
                actionName: "删除主片段"
            )
        } catch {
            // The final primary segment remains the only intentional removal
            // restriction. Timed effects are reauthored by the ripple model.
            onError(error.localizedDescription)
            return
        }

        primaryTrimDraft = nil
        hoveredPrimarySegmentID = nil
        let updatedIDs = EditorTimelineSelectionPresentation.primarySegmentIDs(
            in: editorStore.project.timeline.sourceSequence
        )
        if !updatedIDs.isEmpty {
            let nextIndex = min(removedIndex, updatedIDs.count - 1)
            selectPrimarySegment(updatedIDs[nextIndex])
            let updatedMap = try? EditorPrimaryTimelinePresentation.timelineMap(
                fullSourceDuration: fullSourceDuration,
                project: editorStore.project
            )
            seekTimeline(to: min(playbackTime, updatedMap?.outputDuration ?? playbackTime))
        } else {
            editorStore.selection = .screen
        }
    }

    func commitPrimaryTrimDraft() {
        guard let draft = primaryTrimDraft else { return }
        defer { primaryTrimDraft = nil }
        let finalPlayheadTime: TimeInterval = switch draft.edge {
        case .left: draft.original.outputStart
        case .right: draft.proposedOutputTime
        }
        do {
            try editorStore.trimPrimarySegment(
                id: draft.segmentID,
                edge: draft.edge,
                toOutputTime: draft.proposedOutputTime,
                fullSourceDuration: fullSourceDuration,
                actionName: "裁切主片段"
            )
        } catch {
            // Timed effects follow the same ripple edit. Only genuinely invalid
            // segment bounds should now reach this error path.
            onError(error.localizedDescription)
            return
        }
        selectPrimarySegment(draft.segmentID)
        // The drag sampled the old composition clock. Re-anchor once at the
        // resulting edit point so the replacement generation preserves the
        // intended frame instead of an unrelated pre-ripple position.
        seekTimeline(to: finalPlayheadTime)
    }
}
