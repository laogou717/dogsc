import AppKit
import RecorderCore
import SwiftUI

fileprivate struct EditorTimelineControlButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> Body {
        Body(configuration: configuration)
    }

    fileprivate struct Body: View {
        @Environment(\.isEnabled) private var isEnabled
        @State private var isHovered = false
        let configuration: Configuration

        var body: some View {
            configuration.label
                .background(
                    backgroundColor,
                    in: RoundedRectangle(cornerRadius: 7, style: .continuous)
                )
                .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                .onHover { isHovered = $0 }
                .animation(.easeOut(duration: 0.12), value: isHovered)
                .animation(.easeOut(duration: 0.08), value: configuration.isPressed)
        }

        private var backgroundColor: Color {
            guard isEnabled else { return .clear }
            if configuration.isPressed { return Color.white.opacity(0.12) }
            if isHovered { return Color.white.opacity(0.07) }
            return .clear
        }
    }
}

extension EditorTimelineView {
    /// 传输条分区胶囊：播放 / 剪辑 / 缩放各一枚，与顶部工具栏同一语言。
    private func timelineCapsule<Content: View>(
        @ViewBuilder _ content: () -> Content
    ) -> some View {
        HStack(spacing: 2) { content() }
            .padding(.horizontal, 4)
            .frame(height: 30)
            .background(
                Color.white.opacity(0.04),
                in: RoundedRectangle(cornerRadius: 9, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .stroke(Color.white.opacity(0.05), lineWidth: 1)
            }
    }

    func timelineControls(duration: TimeInterval) -> some View {
        ZStack {
            HStack(spacing: 10) {
                NativePlaybackTimeView(playbackController: playbackController)
                    .frame(width: 72, height: 28)

                timelineCapsule {
                    Button { stepTimeline(byFrames: -1) } label: {
                        Image(systemName: "backward.frame.fill")
                            .frame(width: 28, height: 26)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(EditorTimelineControlButtonStyle())
                    .help("上一帧")
                    .accessibilityLabel("上一帧")

                    Button { playbackController.togglePlayback() } label: {
                        Image(systemName: playbackController.isPlaying
                            ? "pause.circle.fill"
                            : "play.circle.fill")
                            .font(.system(size: 21))
                            .frame(width: 32, height: 28)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(EditorTimelineControlButtonStyle())
                    .disabled(!playbackController.canPlay)
                    .help(playbackController.isPlaying ? "暂停（空格）" : "播放（空格）")
                    .accessibilityLabel(playbackController.isPlaying ? "暂停" : "播放")

                    Button { stepTimeline(byFrames: 1) } label: {
                        Image(systemName: "forward.frame.fill")
                            .frame(width: 28, height: 26)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(EditorTimelineControlButtonStyle())
                    .help("下一帧")
                    .accessibilityLabel("下一帧")
                }

                Text(timelineTimestamp(duration))
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .frame(width: 72, alignment: .leading)
            }

            HStack(spacing: 10) {
                Spacer()

                timelineCapsule {
                    Button(action: splitCurrentTimelineSelectionAtPlayhead) {
                        Image(systemName: "scissors")
                            .frame(width: 28, height: 26)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(EditorTimelineControlButtonStyle())
                    .disabled(!canSplitCurrentTimelineSelectionAtPlayhead)
                    .help(currentTimelineSplitHelp)
                    .accessibilityLabel(currentTimelineSplitAccessibilityLabel)
                    .accessibilityIdentifier("editor.timeline.primary.split")

                    Button {
                        _ = removeCurrentTimelineSelection()
                    } label: {
                        Image(systemName: "trash")
                            .frame(width: 28, height: 26)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(EditorTimelineControlButtonStyle())
                    .disabled(!canRemoveCurrentTimelineSelection)
                    .help(currentTimelineDeleteHelp)
                    .accessibilityLabel(currentTimelineDeleteAccessibilityLabel)
                    .accessibilityIdentifier("editor.timeline.primary.delete")

                    Button {
                        isRestoreCutMode.toggle()
                        if isRestoreCutMode {
                            primaryTrimDraft = nil
                            primaryRetimeDraft = nil
                        }
                    } label: {
                        Image(systemName: "arrow.uturn.backward.circle")
                            .foregroundStyle(isRestoreCutMode ? editorAccent : Color.secondary)
                            .frame(width: 28, height: 26)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(EditorTimelineControlButtonStyle())
                    .disabled(
                        primarySegmentJunctions.isEmpty
                            && primaryLeadingGap == nil
                            && primaryTrailingGap == nil
                    )
                    .help(isRestoreCutMode
                        ? "恢复剪辑模式已开启：标尺显示所有剪切缝以合并或还原；点击退出"
                        : "恢复剪辑模式：点击显示所有剪切缝，方便合并片段或还原已删除内容")
                    .accessibilityLabel("恢复剪辑模式")
                    .accessibilityValue(isRestoreCutMode ? "开启" : "关闭")
                    .accessibilityIdentifier("editor.timeline.primary.restore-mode")

                    Button {
                        showsTimelinePointerClickMarkers.toggle()
                    } label: {
                        Image(systemName: "cursorarrow.click")
                            .foregroundStyle(
                                showsTimelinePointerClickMarkers
                                    ? editorAccent
                                    : Color.secondary
                            )
                            .frame(width: 28, height: 26)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(EditorTimelineControlButtonStyle())
                    .help(showsTimelinePointerClickMarkers
                        ? "点击标记已显示：在片段上标记鼠标点击位置"
                        : "点击标记已隐藏：点击可在片段上标记鼠标点击位置")
                    .accessibilityLabel("鼠标点击标记")
                    .accessibilityValue(showsTimelinePointerClickMarkers ? "显示" : "隐藏")
                    .accessibilityIdentifier("editor.timeline.pointer-click-markers")

                    Button {
                        isHoverPreviewEnabled.toggle()
                        if !isHoverPreviewEnabled {
                            clearTimelineHoverLocation()
                        }
                    } label: {
                        Image(systemName: isHoverPreviewEnabled ? "eye" : "eye.slash")
                            .foregroundStyle(
                                isHoverPreviewEnabled
                                    ? editorAccent
                                    : Color.secondary
                            )
                            .frame(width: 28, height: 26)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(EditorTimelineControlButtonStyle())
                    .help(isHoverPreviewEnabled
                        ? "悬浮预览已开启：指针扫过时间线实时预览并优先在预览轴剪辑（S/Q/W）"
                        : "悬浮预览已关闭：点击开启；开启后扫过时间线即可实时预览画面")
                    .accessibilityLabel("时间线悬浮预览")
                    .accessibilityValue(isHoverPreviewEnabled ? "开启" : "关闭")
                    .accessibilityIdentifier("editor.timeline.hover-preview-toggle")
                }

                timelineCapsule {
                    Button {
                        zoomTimeline(to: 1, pointerViewportX: nil)
                    } label: {
                        Image(systemName: "arrow.down.right.and.arrow.up.left")
                            .foregroundStyle(timelineZoom > 1.01 ? Color.primary : Color.secondary)
                            .frame(width: 28, height: 26)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(EditorTimelineControlButtonStyle())
                    .disabled(timelineZoom <= 1.01)
                    .help("显示完整时间线")
                    .accessibilityLabel("显示完整时间线")
                    .accessibilityIdentifier("editor.timeline.zoom-to-fit")

                    EditorSlider(
                        value: Binding(
                            get: { timelineZoom },
                            set: { zoomTimeline(to: $0, pointerViewportX: nil) }
                        ),
                        range: 1...120
                    )
                        .frame(width: 110)
                        .padding(.horizontal, 4)
                        .help("时间线缩放")
                        .accessibilityLabel("时间线缩放")
                        .accessibilityValue("\(Int((timelineZoom * 100).rounded()))%")
                }
            }
        }
        .padding(.horizontal, 14)
        .frame(height: 44)
        .background(Color.black.opacity(0.12))
    }

    var timelineLabels: some View {
        VStack(spacing: 0) {
            timelineTrackManager
                .frame(height: timelineRulerHeight)
            timelineLabel(
                "片段",
                symbol: "film",
                tint: editorClipAmberTop,
                height: primaryTimelineHeight
            )
            if showsCameraSyncTimeline {
                timelineLabel(
                    "摄像同步",
                    symbol: "waveform.path.ecg",
                    tint: .cyan,
                    height: cameraSyncTimelineHeight
                )
            }
            if showsZoomTimeline {
                optionalTimelineLabel(
                    "缩放",
                    tint: editorZoomClip,
                    height: 56,
                    track: .zoom
                )
            }
            if showsScreenMotionTimeline {
                optionalTimelineLabel(
                    "屏幕 3D",
                    tint: motionTrackColor(.screen),
                    height: motionTimelineHeight,
                    track: .screenMotion
                )
            }
            if showsCameraMotionTimeline {
                optionalTimelineLabel(
                    "摄像运动",
                    tint: motionTrackColor(.camera),
                    height: motionTimelineHeight,
                    track: .cameraMotion
                )
            }
            if showsOverlayTimeline {
                optionalTimelineLabel(
                    "叠加",
                    tint: .pink,
                    height: overlayTimelineHeight,
                    track: .overlays
                )
            }
            if showsProgressTimeline {
                optionalTimelineLabel(
                    "进度条",
                    tint: .mint,
                    height: overlayTimelineHeight,
                    track: .progress
                )
            }
        }
        .background(Color.black.opacity(0.14))
    }

    func timelineLabel(
        _ title: String,
        symbol: String,
        tint: Color,
        height: CGFloat
    ) -> some View {
        HStack(spacing: 5) {
            RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                .fill(tint.opacity(0.82))
                .frame(width: 2.5, height: 18)

            Image(systemName: symbol)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(tint.opacity(0.94))
                .frame(width: 12)

            Text(title)
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(Color.white.opacity(0.72))
                .lineLimit(1)
        }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .padding(.horizontal, 8)
            .frame(height: height)
            .overlay(alignment: .bottom) { Divider().overlay(dividerColor) }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(title)轨道")
            .accessibilityAddTraits(.isHeader)
    }

    func timelineCanvas(width: CGFloat, duration: TimeInterval) -> some View {
        let cutX = snappedCutX(width: width, duration: duration)
        return ZStack(alignment: .topLeading) {
            Color.clear
                .contentShape(Rectangle())
                .onTapGesture {
                    clearTimelineSelection()
                }
            VStack(spacing: 0) {
                timelineRuler(width: width, duration: duration, cutX: cutX)
                mainClipTimeline(width: width, duration: duration)
                if showsCameraSyncTimeline {
                    cameraSyncTimeline(width: width, duration: duration)
                }
                if showsZoomTimeline {
                    zoomTimeline(width: width, duration: duration)
                }
                if showsScreenMotionTimeline {
                    motionTimeline(
                        track: .screen,
                        clips: screenMotionTimelineClips,
                        width: width,
                        duration: duration
                    )
                }
                if showsCameraMotionTimeline {
                    motionTimeline(
                        track: .camera,
                        clips: cameraMotionTimelineClips,
                        width: width,
                        duration: duration
                    )
                }
                if showsOverlayTimeline {
                    combinedOverlayTimeline(width: width, duration: duration)
                }
                if showsProgressTimeline {
                    progressOverlayTimeline(width: width, duration: duration)
                }
            }

            NativeTimelinePlayheadView(
                playbackController: playbackController,
                duration: duration
            )
            .frame(width: width, height: timelineCanvasHeight)
            .allowsHitTesting(false)

            // CUT-003/CUT-004: the action itself lives in the dedicated lane;
            // only its non-interactive guide enters the primary clip.
            if let cutX {
                Rectangle()
                    .fill(Color.white.opacity(0.85))
                    .frame(width: 1, height: primaryTimelineHeight)
                    .offset(x: cutX - 0.5, y: timelineRulerHeight)
                    .allowsHitTesting(false)
            }

            // 预览轴：悬停跟手的一根细参考线，只用来定位"在哪里停下"，
            // 不改变播放头位置；真正查看画面用标尺上的拖动预览。
            if isHoverPreviewEnabled, let previewX = hoveredTimelineContentX {
                let previewTime = EditorTimelineMath.clampedTime(
                    atX: Double(previewX),
                    width: Double(width),
                    duration: duration
                )
                Rectangle()
                    .fill(Color.white.opacity(0.24))
                    .frame(width: 1, height: timelineCanvasHeight)
                    .offset(x: previewX - 0.5)
                    .allowsHitTesting(false)
                Text(timelineTimestamp(previewTime))
                    .font(.system(size: 8, design: .monospaced))
                    .foregroundStyle(.secondary.opacity(0.75))
                    .offset(x: min(max(previewX - 14, 2), max(width - 32, 2)), y: 2)
                    .allowsHitTesting(false)
            }
        }
        .frame(width: width, height: timelineCanvasHeight, alignment: .topLeading)
        .coordinateSpace(name: editorTimelineDocumentCoordinateSpace)
        .contentShape(Rectangle())
        .accessibilityElement(children: .contain)
        .accessibilityLabel("时间线")
        .accessibilityValue("播放头位于 \(timelineTimestamp(playbackTime))")
    }

    func timelineRuler(
        width: CGFloat,
        duration: TimeInterval,
        cutX: CGFloat?
    ) -> some View {
        let ticks = derivedPresentationCache.rulerTicks(
            duration: duration,
            width: width
        )
        let visibleRange = clampedTimelineVisibleDocumentRange(width: width)
        let visibleTimeRange = EditorTimelineViewportPresentation.bufferedTimeRange(
            documentWidth: width,
            duration: duration,
            visibleRange: visibleRange
        )
        let visibleTickIndices = EditorTimelineViewportPresentation.visiblePointIndices(
            in: ticks,
            timeRange: visibleTimeRange,
            time: \.time
        )
        let labels = EditorTimelineRulerPresentation.visibleLabels(
            ticks: ticks,
            duration: duration,
            width: width,
            visibleRange: visibleRange
        )
        return ZStack(alignment: .topLeading) {
            Color.black.opacity(0.08)
            Canvas(opaque: false, rendersAsynchronously: true) { context, size in
                var majorPath = Path()
                var minorPath = Path()
                let safeDuration = max(duration, 0.001)
                for index in visibleTickIndices {
                    let tick = ticks[index]
                    let rawX = size.width * CGFloat(tick.time / safeDuration)
                    let x = min(max(rawX, 0), max(size.width - 0.5, 0)) + 0.5
                    if tick.isMajor {
                        majorPath.move(to: CGPoint(x: x, y: 0))
                        majorPath.addLine(to: CGPoint(x: x, y: 8))
                    } else {
                        minorPath.move(to: CGPoint(x: x, y: 0))
                        minorPath.addLine(to: CGPoint(x: x, y: 4))
                    }
                }
                context.stroke(majorPath, with: .color(.white.opacity(0.20)), lineWidth: 1)
                context.stroke(minorPath, with: .color(.white.opacity(0.09)), lineWidth: 1)
            }
            .frame(width: width, height: timelineRulerHeight)
            .allowsHitTesting(false)

            ForEach(labels) { label in
                Text(timelineTimestamp(label.time))
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .offset(
                        x: min(max(label.x + 4, 0), max(width - 42, 0)),
                        y: 10
                    )
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
            if primaryTrimDraft == nil && isRestoreCutMode {
                let junctions = primarySegmentJunctions
                let visibleJunctionIndices = EditorTimelineViewportPresentation
                    .visiblePointIndices(
                        in: junctions,
                        timeRange: visibleTimeRange,
                        time: \.outputTime
                    )
                ForEach(visibleJunctionIndices, id: \.self) { index in
                    let junction = junctions[index]
                    let junctionX = CGFloat(
                        junction.outputTime / max(duration, 0.001)
                    ) * width
                    segmentJunctionAction(junction)
                        .offset(
                            x: min(max(junctionX - 11, 0), max(width - 22, 0)),
                            y: timelineRulerHeight - 22
                        )
                }
                if let leadingGap = primaryLeadingGap {
                    leadingGapAction(leadingGap)
                        .offset(x: 0, y: timelineRulerHeight - 22)
                }
                if let trailingGap = primaryTrailingGap {
                    trailingGapAction(trailingGap)
                        .offset(x: max(width - 22, 0), y: timelineRulerHeight - 22)
                }
            }
            if let cutX {
                Image(systemName: "scissors")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.black.opacity(0.78))
                    .frame(width: 18, height: 18)
                    .background(Circle().fill(editorAccent))
                    .offset(x: cutX - 9, y: timelineRulerHeight - 20)
                    .allowsHitTesting(false)
                    .zIndex(31)
            }
        }
        .frame(width: width, height: timelineRulerHeight)
        .overlay(alignment: .bottom) { Divider().overlay(dividerColor) }
        .contentShape(Rectangle())
        .gesture(timelineScrubGesture(width: width, duration: duration))
    }

    func clampedTimelineVisibleDocumentRange(width: CGFloat) -> ClosedRange<CGFloat> {
        let lower = min(max(timelineVisibleDocumentRange.lowerBound, 0), max(width, 0))
        let upper = min(
            max(timelineVisibleDocumentRange.upperBound, lower),
            max(width, lower)
        )
        return lower...upper
    }

    func installTimelineBoundsObservation(on scrollView: NSScrollView?) {
        removeTimelineBoundsObservation()
        guard let scrollView else {
            timelineVisibleDocumentRange = 0...max(timelineContentWidth, 1)
            return
        }
        let clipView = scrollView.contentView
        clipView.postsBoundsChangedNotifications = true
        updateTimelineVisibleDocumentRange(from: scrollView)
        timelineBoundsObservation = NotificationCenter.default.addObserver(
            forName: NSView.boundsDidChangeNotification,
            object: clipView,
            queue: .main
        ) { [weak scrollView] _ in
            guard let scrollView else { return }
            Task { @MainActor in
                updateTimelineVisibleDocumentRange(from: scrollView)
            }
        }
    }

    func updateTimelineVisibleDocumentRange(from scrollView: NSScrollView) {
        let visible = scrollView.documentVisibleRect
        let width = max(timelineContentWidth, 1)
        let lower = min(max(visible.minX, 0), width)
        let upper = min(max(visible.maxX, lower), width)
        let next = lower...upper
        let currentBucket = EditorTimelineWaveformPresentation.bufferedVisibleRange(
            documentWidth: width,
            visibleRange: timelineVisibleDocumentRange
        )
        let nextBucket = EditorTimelineWaveformPresentation.bufferedVisibleRange(
            documentWidth: width,
            visibleRange: next
        )
        // Native scrolling moves already-rendered document layers smoothly.
        // Publish at most every 40pt (or immediately at a waveform bucket
        // boundary), instead of once per pixel. The ruler's 80pt guard band
        // keeps the next labels prepared between these bounded updates.
        let movedEnoughForLabels = abs(next.lowerBound - timelineVisibleDocumentRange.lowerBound) >= 40
            || abs(next.upperBound - timelineVisibleDocumentRange.upperBound) >= 40
        if currentBucket != nextBucket || movedEnoughForLabels {
            timelineVisibleDocumentRange = next
        }
    }

    func removeTimelineBoundsObservation() {
        if let timelineBoundsObservation {
            NotificationCenter.default.removeObserver(timelineBoundsObservation)
            self.timelineBoundsObservation = nil
        }
    }

    func timelineScrubGesture(width: CGFloat, duration: TimeInterval) -> some Gesture {
        let intent = EditorTimelineGestureIntent.scrub
        return DragGesture(minimumDistance: 0)
            .onChanged { value in
                guard beginTimelineGesture(intent) else { return }
                let rawTime = EditorTimelineMath.clampedTime(
                    atX: Double(value.location.x),
                    width: Double(width),
                    duration: duration
                )
                let time = snappedTimelineTime(rawTime)
                playbackController.beginScrubbing()
                playbackController.updateScrubbing(to: time)
            }
            .onEnded { _ in
                playbackController.endScrubbing()
                endTimelineGesture(intent)
            }
    }

    func primarySegmentLabel(
        index: Int,
        segment: ResolvedRecordingSegment,
        segmentsCount: Int,
        segmentWidth: CGFloat,
        isSelected: Bool
    ) -> some View {
        RoundedRectangle(cornerRadius: 7, style: .continuous)
            .fill(
                LinearGradient(
                    colors: [
                        editorClipAmberTop,
                        editorClipAmberBottom,
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
            )
            .overlay(alignment: .topLeading) {
                if segmentWidth > 32 {
                    HStack(spacing: 4) {
                        Image(systemName: "display")
                            .font(.system(size: 8, weight: .medium))
                        Text(segmentsCount == 1 ? "屏幕片段" : "片段 \(index + 1)")
                            .font(.system(size: 9.5, weight: .medium))
                        if segmentWidth > 120 {
                            Text(timelineTimestamp(segment.outputDuration))
                                .font(.system(size: 9, design: .monospaced))
                                .foregroundStyle(.white.opacity(0.65))
                            if abs(segment.playbackRate - 1) > 0.000_1 {
                                Text(timelinePlaybackRateText(segment.playbackRate))
                                    .font(.system(size: 8.5, weight: .semibold))
                                    .foregroundStyle(.white.opacity(0.82))
                            }
                        }
                    }
                    .foregroundStyle(.white.opacity(0.88))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(
                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                            .fill(Color.black.opacity(0.28))
                    )
                    .padding(.top, 3)
                    .padding(.leading, 6)
                    .lineLimit(1)
                }
            }
            .overlay {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .strokeBorder(
                        isSelected ? Color.white.opacity(0.95) : Color.white.opacity(0.16),
                        lineWidth: isSelected ? 1.5 : 0.75
                    )
            }
    }



    func primarySegmentView(
        index: Int,
        segment: ResolvedRecordingSegment,
        segmentsCount: Int,
        startX: CGFloat,
        segmentWidth: CGFloat,
        isSelected: Bool,
        showsHandles: Bool,
        laneWidth: CGFloat,
        duration: TimeInterval
    ) -> some View {
        ZStack {
            primarySegmentLabel(
                index: index,
                segment: segment,
                segmentsCount: segmentsCount,
                segmentWidth: segmentWidth,
                isSelected: isSelected
            )
            .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
            .simultaneousGesture(
                DragGesture(
                    minimumDistance: 4,
                    coordinateSpace: .named(editorTimelineDocumentCoordinateSpace)
                )
                .onChanged { value in
                    updatePrimarySegmentDrag(
                        segmentID: segment.id,
                        translation: value.translation.width
                    )
                }
                .onEnded { value in
                    finishPrimarySegmentDrag(
                        segmentID: segment.id,
                        documentX: value.location.x,
                        laneWidth: laneWidth,
                        duration: duration
                    )
                }
            )
            .simultaneousGesture(
                SpatialTapGesture(coordinateSpace: .local)
                    .onEnded { event in
                        if NSEvent.modifierFlags.contains(.option) {
                            splitPrimarySegmentAtClick(
                                segment: segment,
                                location: event.location,
                                segmentWidth: segmentWidth
                            )
                        } else {
                            selectPrimarySegment(segment.id)
                        }
                    }
            )
            .contextMenu {
                primarySegmentContextMenu(segment: segment)
            }

            if showsHandles {
                HStack(spacing: 0) {
                    primaryTrimHandle(
                        edge: .left,
                        segment: segment,
                        laneWidth: laneWidth,
                        duration: duration
                    )
                    Spacer(minLength: 0)
                    primaryTrimHandle(
                        edge: .right,
                        segment: segment,
                        laneWidth: laneWidth,
                        duration: duration
                    )
                }
                .padding(.horizontal, 1)
            }
        }
        .frame(width: segmentWidth, height: primaryClipContentHeight)
        .offset(
            x: startX + (draggedPrimarySegmentID == segment.id
                ? primarySegmentDragTranslation
                : 0)
        )
        .opacity(draggedPrimarySegmentID == segment.id ? 0.82 : 1)
        // Keep the selected short/retimed clip above its neighbours. A centred
        // outline at a shared boundary was previously overdrawn by the next
        // segment and looked as though the clip had been covered.
        .zIndex(
            draggedPrimarySegmentID == segment.id
                ? 10
                : isSelected ? 3 : showsHandles ? 1 : 0
        )
        .shadow(
            color: draggedPrimarySegmentID == segment.id
                ? Color.black.opacity(0.55)
                : .clear,
            radius: 8,
            y: 2
        )
        .onHover { hovering in
            if hovering {
                hoveredPrimarySegmentID = segment.id
            } else if hoveredPrimarySegmentID == segment.id {
                hoveredPrimarySegmentID = nil
            }
        }
        .help("主片段 \(index + 1) · \(timelineTimestamp(segment.sourceDuration)) · 拖动可调整顺序 · 按住 ⌥ 单击快捷切分")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("主片段 \(index + 1)")
        .accessibilityValue(timelineTimestamp(segment.sourceDuration))
        .accessibilityAddTraits(
            isSelected ? [.isButton, .isSelected] : .isButton
        )
        .accessibilityAction {
            selectPrimarySegment(segment.id)
        }
        .accessibilityIdentifier("editor.timeline.primary.segment.\(segment.id.uuidString)")
    }

    func mainClipTimeline(width: CGFloat, duration: TimeInterval) -> some View {
        let segments = primaryDisplaySegments
        let retainedSegmentIndices = timelineMap.map { map in
            [
                derivedPresentationCache.primarySegmentIndex(
                    for: draggedPrimarySegmentID,
                    in: map
                ),
                derivedPresentationCache.primarySegmentIndex(
                    for: primaryTrimDraft?.segmentID,
                    in: map
                ),
            ].compactMap { $0 }
        } ?? []
        let visibleTimeRange = EditorTimelineViewportPresentation.bufferedTimeRange(
            documentWidth: width,
            duration: duration,
            visibleRange: clampedTimelineVisibleDocumentRange(width: width)
        )
        let visibleSegmentIndices = EditorTimelineViewportPresentation.visibleIntervalIndices(
            in: segments,
            timeRange: visibleTimeRange,
            startTime: \.outputStart,
            endTime: \.outputEnd,
            retainingIndices: retainedSegmentIndices
        )
        let pointerClicks = showsTimelinePointerClickMarkers
            ? timelinePointerClicks(outputEnd: segments.last?.outputEnd ?? 0)
            : []
        let visiblePointerClickIndices = showsTimelinePointerClickMarkers
            ? EditorTimelineViewportPresentation.visiblePointIndices(
                in: pointerClicks,
                timeRange: visibleTimeRange,
                time: \.time
            )
            : 0..<0
        return ZStack(alignment: .leading) {
            Color.white.opacity(0.018)
                .contentShape(Rectangle())
                .onTapGesture {
                    clearTimelineSelection()
                }
            ForEach(visibleSegmentIndices, id: \.self) { index in
                let segment = segments[index]
                let startX = CGFloat(segment.outputStart / max(duration, 0.001)) * width
                let segmentWidth = max(
                    CGFloat(segment.outputDuration / max(duration, 0.001)) * width,
                    1
                )
                let isSelected = selectedPrimarySegmentID == segment.id
                let showsHandles = isSelected || hoveredPrimarySegmentID == segment.id

                primarySegmentView(
                    index: index,
                    segment: segment,
                    segmentsCount: segments.count,
                    startX: startX,
                    segmentWidth: segmentWidth,
                    isSelected: isSelected,
                    showsHandles: showsHandles,
                    laneWidth: width,
                    duration: duration
                )
            }

            if showsClipWaveforms {
                clipAudioWaveformOverlay(width: width, duration: duration)
                    .allowsHitTesting(false)
            }

            if showsTimelinePointerClickMarkers {
                ForEach(visiblePointerClickIndices, id: \.self) { index in
                    let event = pointerClicks[index]
                    let eventX = CGFloat(
                        EditorTimelineMath.xPosition(
                            for: event.time,
                            width: Double(width),
                            duration: duration
                        )
                    )
                    pointerEventBadge(event, emphasized: timelineZoom >= 1.8)
                        .offset(x: min(max(eventX - 9, 2), max(width - 20, 2)), y: 1)
                        .allowsHitTesting(false)
                }
            }

        }
        .padding(.vertical, 6)
        .frame(width: width, height: primaryTimelineHeight, alignment: .leading)
        .overlay(alignment: .bottom) { Divider().overlay(dividerColor) }
    }

    // SYNC-003: camera drift is authored against the original screen clock,
    // but presented on the ripple-edited output clock. This keeps markers at
    // the same recorded moment after cuts while making the correction visible
    // exactly where the editor will hear and see it.
    func cameraSyncTimeline(width: CGFloat, duration: TimeInterval) -> some View {
        let displayRange = cameraSyncDisplayRange
        return ZStack(alignment: .topLeading) {
            Color(red: 0.10, green: 0.20, blue: 0.24).opacity(0.22)
                .contentShape(Rectangle())
                .gesture(
                    SpatialTapGesture(
                        count: 2,
                        coordinateSpace: .named(editorTimelineDocumentCoordinateSpace)
                    )
                        .onEnded { event in
                            addCameraSyncAnchor(
                                atDocumentX: event.location.x,
                                width: width,
                                duration: duration
                            )
                        }
                        .exclusively(before:
                            SpatialTapGesture(
                                coordinateSpace: .named(editorTimelineDocumentCoordinateSpace)
                            )
                            .onEnded { _ in
                                dismissCameraSyncSelection()
                                clearTimelineSelection()
                            }
                        )
                )

            Path { path in
                let baselineY = cameraSyncY(offset: 0, displayRange: displayRange)
                path.move(to: CGPoint(x: 0, y: baselineY))
                path.addLine(to: CGPoint(x: width, y: baselineY))
            }
            .stroke(
                Color.cyan.opacity(0.30),
                style: StrokeStyle(lineWidth: 1, dash: [4, 4])
            )
            .allowsHitTesting(false)

            cameraSyncCurvePath(
                width: width,
                duration: duration,
                displayRange: displayRange
            )
            .stroke(Color.cyan.opacity(0.92), style: StrokeStyle(lineWidth: 2, lineJoin: .round))
            .allowsHitTesting(false)

            Text("基准 \(cameraSyncOffsetLabel(cameraSyncBaselineOffset))")
                .font(.system(size: 9, weight: .semibold, design: .monospaced))
                .foregroundStyle(Color.cyan.opacity(0.92))
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background(Color.black.opacity(0.64), in: Capsule())
                .offset(x: 7, y: 5)
                .allowsHitTesting(false)

            if cameraSyncAnchors.isEmpty {
                Text("双击添加同步点 · 单击空白取消选中")
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary.opacity(0.8))
                    .offset(x: 104, y: 8)
                    .allowsHitTesting(false)
            }

            ForEach(cameraSyncAnchors) { persistedAnchor in
                let anchor = cameraSyncAnchorDrag?.original.id == persistedAnchor.id
                    ? cameraSyncAnchorDrag?.draft ?? persistedAnchor
                    : persistedAnchor
                if let outputTime = timelineMap?.outputTime(forSourceTime: anchor.sourceTime) {
                    let x = CGFloat(outputTime / max(duration, 0.001)) * width
                    let y = cameraSyncY(offset: anchor.offset, displayRange: displayRange)
                    cameraSyncAnchorMarker(
                        anchor: anchor,
                        x: x,
                        y: y,
                        width: width,
                        duration: duration
                    )
                }
            }

            if let selectedCameraSyncAnchorID,
               let anchor = presentedCameraSyncAnchor(id: selectedCameraSyncAnchorID),
               let outputTime = timelineMap?.outputTime(forSourceTime: anchor.sourceTime) {
                let x = CGFloat(outputTime / max(duration, 0.001)) * width
                cameraSyncAnchorControls(anchor: anchor)
                    .offset(
                        x: min(max(x + 13, 98), max(width - 154, 98)),
                        y: 3
                    )
            }
        }
        .frame(width: width, height: cameraSyncTimelineHeight, alignment: .topLeading)
        .overlay(alignment: .bottom) { Divider().overlay(dividerColor) }
        .help("双击空白处添加同步点；单击空白取消选中；调整后自动试听并返回")
    }

    func cameraSyncCurvePath(
        width: CGFloat,
        duration: TimeInterval,
        displayRange: TimeInterval
    ) -> Path {
        var path = Path()
        guard let timelineMap else { return path }
        let samples = derivedPresentationCache.cameraSyncPathSamples(
            map: timelineMap,
            anchors: cameraSyncAnchors
        )
        for sample in samples {
            let point = CGPoint(
                x: CGFloat(sample.outputTime / max(duration, 0.001)) * width,
                y: cameraSyncY(
                    offset: sample.offset,
                    displayRange: displayRange
                )
            )
            if sample.startsSubpath {
                path.move(to: point)
            } else {
                path.addLine(to: point)
            }
        }
        return path
    }

    func cameraSyncAnchorMarker(
        anchor: MediaSyncAnchor,
        x: CGFloat,
        y: CGFloat,
        width: CGFloat,
        duration: TimeInterval
    ) -> some View {
        let isSelected = selectedCameraSyncAnchorID == anchor.id
        return ZStack(alignment: .topLeading) {
            if !isSelected {
                Text(cameraSyncOffsetLabel(cameraSyncBaselineOffset + anchor.offset))
                    .font(.system(size: 8, weight: .semibold, design: .monospaced))
                    .foregroundStyle(Color.cyan.opacity(0.96))
                    .frame(width: 70)
                    .offset(x: min(max(x - 35, 0), max(width - 70, 0)), y: 3)
                    .allowsHitTesting(false)
            }

            RoundedRectangle(cornerRadius: 2, style: .continuous)
                .fill(isSelected ? Color.white : Color.cyan)
                .overlay {
                    RoundedRectangle(cornerRadius: 2, style: .continuous)
                        .stroke(Color.black.opacity(0.72), lineWidth: 1)
                }
                .frame(width: 11, height: 11)
                .rotationEffect(.degrees(45))
                .shadow(color: Color.black.opacity(0.45), radius: 2, y: 1)
                .contentShape(Rectangle().inset(by: -7))
                .offset(x: x - 5.5, y: y - 5.5)
                .gesture(cameraSyncAnchorGesture(
                    anchor: anchor,
                    width: width,
                    duration: duration
                ))
                .contextMenu {
                    Button("画面延后 \(cameraSyncAdjustmentStepMilliseconds)ms") {
                        nudgeCameraSyncAnchor(id: anchor.id, by: -cameraSyncAdjustmentStep)
                    }
                    Button("画面提前 \(cameraSyncAdjustmentStepMilliseconds)ms") {
                        nudgeCameraSyncAnchor(id: anchor.id, by: cameraSyncAdjustmentStep)
                    }
                    Divider()
                    Button("删除同步点", role: .destructive) {
                        removeCameraSyncAnchor(id: anchor.id)
                    }
                }
                .accessibilityLabel("摄像头同步点")
                .accessibilityValue(cameraSyncOffsetLabel(cameraSyncBaselineOffset + anchor.offset))
        }
        .frame(width: width, height: cameraSyncTimelineHeight, alignment: .topLeading)
    }

    func cameraSyncAnchorControls(anchor: MediaSyncAnchor) -> some View {
        HStack(spacing: 4) {
            Text(cameraSyncOffsetLabel(cameraSyncBaselineOffset + anchor.offset))
                .font(.system(size: 8, weight: .bold, design: .monospaced))
                .foregroundStyle(Color.cyan)
            Button { nudgeCameraSyncAnchor(id: anchor.id, by: -cameraSyncAdjustmentStep) } label: {
                Text("延\(cameraSyncAdjustmentStepMilliseconds)")
                    .font(.system(size: 8, weight: .bold))
            }
            .help("画面延后 \(cameraSyncAdjustmentStepMilliseconds)ms，并自动试听")
            Button { nudgeCameraSyncAnchor(id: anchor.id, by: cameraSyncAdjustmentStep) } label: {
                Text("提\(cameraSyncAdjustmentStepMilliseconds)")
                    .font(.system(size: 8, weight: .bold))
            }
            .help("画面提前 \(cameraSyncAdjustmentStepMilliseconds)ms，并自动试听")
            Button(role: .destructive) { removeCameraSyncAnchor(id: anchor.id) } label: {
                Image(systemName: "trash").font(.system(size: 8, weight: .bold))
            }
            .help("删除同步点")
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 7)
        .frame(height: 23)
        .background(Color.black.opacity(0.82), in: Capsule())
        .overlay { Capsule().stroke(Color.cyan.opacity(0.45), lineWidth: 1) }
    }

    func cameraSyncAnchorGesture(
        anchor: MediaSyncAnchor,
        width: CGFloat,
        duration: TimeInterval
    ) -> some Gesture {
        DragGesture(
            minimumDistance: 0,
            coordinateSpace: .named(editorTimelineDocumentCoordinateSpace)
        )
        .onChanged { value in
            selectedCameraSyncAnchorID = anchor.id
            let origin = cameraSyncAnchorDrag?.original.id == anchor.id
                ? cameraSyncAnchorDrag?.original ?? anchor
                : anchor
            guard let sourceTime = cameraSyncSourceTime(
                atDocumentX: value.location.x,
                width: width,
                duration: duration
            ) else { return }
            var draft = origin
            draft.sourceTime = sourceTime
            draft.offset = min(max(
                origin.offset - TimeInterval(value.translation.height) * 0.010,
                -10
            ), 10)
            cameraSyncAnchorDrag = CameraSyncAnchorDrag(original: origin, draft: draft)
        }
        .onEnded { value in
            defer { cameraSyncAnchorDrag = nil }
            guard hypot(value.translation.width, value.translation.height) >= 2,
                  let draft = cameraSyncAnchorDrag?.draft else {
                if let outputTime = timelineMap?.outputTime(forSourceTime: anchor.sourceTime) {
                    seekTimeline(to: outputTime)
                }
                return
            }
            if replaceCameraSyncAnchor(draft, actionName: "调整摄像头同步点"),
               let outputTime = timelineMap?.outputTime(forSourceTime: draft.sourceTime) {
                scheduleCameraSyncAudition(at: outputTime)
            }
        }
    }

    func addCameraSyncAnchor(
        atDocumentX x: CGFloat,
        width: CGFloat,
        duration: TimeInterval
    ) {
        guard let sourceTime = cameraSyncSourceTime(
            atDocumentX: x,
            width: width,
            duration: duration
        ) else { return }
        let anchor = MediaSyncAnchor(
            sourceTime: sourceTime,
            offset: derivedPresentationCache.cameraSyncCurve(
                for: cameraSyncAnchors
            ).offset(atSourceTime: sourceTime)
        )
        let didInsert = replaceCameraSyncAnchor(anchor, actionName: "添加摄像头同步点")
        selectedCameraSyncAnchorID = anchor.id
        if let outputTime = timelineMap?.outputTime(forSourceTime: sourceTime) {
            if didInsert {
                scheduleCameraSyncAudition(at: outputTime)
            } else {
                seekTimeline(to: outputTime)
            }
        }
    }

    func cameraSyncSourceTime(
        atDocumentX x: CGFloat,
        width: CGFloat,
        duration: TimeInterval
    ) -> TimeInterval? {
        guard width > 0, duration > 0, let timelineMap else { return nil }
        let outputTime = min(
            max(TimeInterval(x / width) * duration, 0),
            max(duration - 0.000_001, 0)
        )
        return timelineMap.sourceTime(atOutputTime: outputTime)
    }

    func replaceCameraSyncAnchor(
        _ anchor: MediaSyncAnchor,
        actionName: String
    ) -> Bool {
        var project = editorStore.project
        guard var media = project.media, var camera = media.camera else { return false }
        if let index = camera.syncAnchors.firstIndex(where: { $0.id == anchor.id }) {
            camera.syncAnchors[index] = anchor
        } else {
            camera.syncAnchors.append(anchor)
        }
        media.camera = camera
        project.media = media
        do {
            try editorStore.replaceProject(with: project, actionName: actionName)
            return true
        } catch {
            onError(error.localizedDescription)
            return false
        }
    }

    func nudgeCameraSyncAnchor(id: UUID, by delta: TimeInterval) {
        guard var anchor = cameraSyncAnchors.first(where: { $0.id == id }) else { return }
        anchor.offset = min(max(anchor.offset + delta, -10), 10)
        selectedCameraSyncAnchorID = id
        if replaceCameraSyncAnchor(anchor, actionName: "微调摄像头同步点"),
           let outputTime = timelineMap?.outputTime(forSourceTime: anchor.sourceTime) {
            scheduleCameraSyncAudition(at: outputTime)
        }
    }
}
