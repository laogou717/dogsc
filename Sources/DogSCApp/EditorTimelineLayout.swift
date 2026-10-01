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
                .opacity(isEnabled ? 1 : 0.30)
                .background(
                    backgroundColor,
                    in: RoundedRectangle(cornerRadius: 9, style: .continuous)
                )
                .contentShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                .scaleEffect(configuration.isPressed && isEnabled ? 0.96 : 1.0)
                .onHover { isHovered = $0 }
                .animation(SpringMotion.interactive, value: isHovered)
                .animation(SpringMotion.interactive, value: configuration.isPressed)
                .animation(SpringMotion.interactive, value: isEnabled)
        }

        private var backgroundColor: Color {
            guard isEnabled else { return .clear }
            if configuration.isPressed { return EditorTheme.chrome(0.14) }
            if isHovered { return EditorTheme.chrome(0.08) }
            return .clear
        }
    }
}

/// Playback buttons are centred on the workspace; the clock follows them on
/// the right. Compact windows shift the group just enough to keep tools clear.
fileprivate struct EditorTimelineControlsLayout: Layout {
    var compact = false
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        CGSize(width: proposal.width ?? 1080, height: proposal.height ?? 44)
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard subviews.count == 4 else { return }
        let sizes = subviews.map { $0.sizeThatFits(.unspecified) }
        let edge: CGFloat = compact ? 4 : 18
        let gap: CGFloat = compact ? 10 : 20
        let clockGap: CGFloat = compact ? 8 : 16
        let leadingX = bounds.minX + edge
        let toolsX = bounds.maxX - edge - sizes[3].width
        let playX = max(leadingX + sizes[0].width + gap,
                       min(bounds.midX - sizes[1].width / 2,
                           toolsX - gap - sizes[1].width - clockGap - sizes[2].width))
        let positions = [leadingX, playX, playX + sizes[1].width + clockGap, toolsX]
        for index in 0..<4 {
            subviews[index].place(at: CGPoint(x: positions[index], y: bounds.midY - sizes[index].height / 2),
                                  proposal: ProposedViewSize(sizes[index]))
        }
    }
}

extension EditorTimelineView {
    enum TimelineLaneFocus: Equatable {
        case primary
        case cameraSync
        case zoom
        case screenMotion
        case cameraMotion
        case overlays
    }

    var focusedTimelineLane: TimelineLaneFocus? {
        if selectedCameraSyncAnchorID != nil { return .cameraSync }
        switch editorStore.selection {
        case .primarySegment:
            return .primary
        case .zoomTrack, .zoom:
            return .zoom
        case .screenMotionTrack, .screenMotion:
            return .screenMotion
        case .cameraMotion:
            return .cameraMotion
        case .mosaic, .sticker:
            return .overlays
        default:
            return nil
        }
    }

    func timelineLaneSurface(
        tint: Color,
        isFocused: Bool
    ) -> some View {
        EditorTheme.selectionWash.opacity(isFocused ? 0.18 : 0)
            .allowsHitTesting(false)
            .animation(SpringMotion.interactive, value: isFocused)
    }

    /// 传输条按用户任务分区：播放 / 剪辑 / 视图状态 / 缩放，
    /// 不按“一次性按钮还是开关”这种实现形态分组。
    private func timelineCapsule<Content: View>(
        @ViewBuilder _ content: () -> Content
    ) -> some View {
        HStack(spacing: layout.compactTimelineControls ? 4 : 8) { content() }.fixedSize(horizontal: true, vertical: false).frame(height: 44)
    }

    func timelineControls(duration: TimeInterval) -> some View {
        let maximumTimelineZoom = EditorTimelineZoomPolicy.maximum
        let zoomSliderPosition = Binding<Double>(
            get: {
                let clampedZoom = min(max(timelineZoom, 1), maximumTimelineZoom)
                return log(clampedZoom) / log(maximumTimelineZoom)
            },
            set: { position in
                let clampedPosition = min(max(position, 0), 1)
                timelineZoomInputCoalescer.enqueue(
                    targetZoom: pow(maximumTimelineZoom, clampedPosition),
                    pointerViewportX: nil
                ) { targetZoom, pointerViewportX in
                    zoomTimeline(
                        to: targetZoom,
                        pointerViewportX: pointerViewportX
                    )
                }
            }
        )

        return EditorTimelineControlsLayout(compact: layout.isCompact) {
                timelineCapsule {
                    Button(action: splitCurrentTimelineSelectionAtPlayhead) {
                        Image(systemName: "scissors")
                            .frame(width: 30, height: 30)
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
                            .frame(width: 30, height: 30)
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
                        Image(systemName: isRestoreCutMode
                            ? "arrow.uturn.backward.circle.fill"
                            : "arrow.uturn.backward.circle")
                            .foregroundStyle(isRestoreCutMode ? editorAccent : Color.secondary)
                            .frame(width: 30, height: 30)
                            .background(
                                isRestoreCutMode ? EditorTheme.chrome(0.10) : Color.clear,
                                in: RoundedRectangle(cornerRadius: 8, style: .continuous)
                            )
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

                    Rectangle().fill(EditorTheme.hairline).frame(width: 1, height: 18).padding(.horizontal, 3)
                    timelineDisplayModePicker
                    recordingMarkerMenu
                }


            HStack(spacing: layout.compactTimelineControls ? 4 : 10) {
                    Button { stepTimeline(byFrames: -1) } label: {
                        Image(systemName: "backward.frame.fill").font(.appUI(size: 16))
                            .frame(width: layout.compactTimelineControls ? 34 : 48, height: layout.compactTimelineControls ? 34 : 42)
                    }
                    .buttonStyle(EditorSoftRaisedButtonStyle())
                    .help("上一帧（←；Shift+← 移动 5 帧）")
                    .accessibilityLabel("上一帧")
                    Button { playbackController.togglePlayback() } label: {
                        Image(systemName: transportIsPlaying ? "pause.fill" : "play.fill")
                            .font(.appUI(size: 19, weight: .semibold))
                            .frame(width: layout.compactTimelineControls ? 38 : 52, height: layout.compactTimelineControls ? 34 : 42)
                    }
                    .buttonStyle(EditorSoftRaisedButtonStyle())
                    .disabled(!transportCanPlay)
                    .help(transportIsPlaying ? "暂停（空格）" : "播放（空格）")
                    .accessibilityLabel(transportIsPlaying ? "暂停" : "播放")
                    Button { stepTimeline(byFrames: 1) } label: {
                        Image(systemName: "forward.frame.fill").font(.appUI(size: 16))
                            .frame(width: layout.compactTimelineControls ? 34 : 48, height: layout.compactTimelineControls ? 34 : 42)
                    }
                    .buttonStyle(EditorSoftRaisedButtonStyle())
                    .help("下一帧（→；Shift+→ 移动 5 帧）")
                    .accessibilityLabel("下一帧")
            }
            HStack(spacing: 5) {
                    NativePlaybackTimeView(playbackController: playbackController)
                        .frame(width: 72, height: 30)
                    Text("/ " + transportTimestamp(duration))
                        .font(.appUI(size: 13, weight: .regular)).monospacedDigit()
                        .foregroundStyle(.secondary)
            }

            HStack(spacing: layout.compactTimelineControls ? 4 : 10) {

                timelineCapsule {
                    Button { isSnappingEnabled.toggle() } label: {
                        Group {
                            if layout.iconOnlyTimelineControls {
                                EditorMagnetIcon().frame(width: 13, height: 13)
                            } else {
                                Label { Text(isSnappingEnabled ? "吸附" : "吸附已关") } icon: { EditorMagnetIcon().frame(width: 13, height: 13) }
                            }
                        }
                            .font(.appUI(.caption, weight: .medium))
                            .foregroundStyle(isSnappingEnabled ? editorAccent : Color.secondary)
                            .padding(.horizontal, 7).frame(height: 30)
                            .background(isSnappingEnabled ? EditorTheme.chrome(0.10) : Color.clear,
                                in: RoundedRectangle(cornerRadius: 8))
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(EditorTimelineControlButtonStyle())
                    .help(isSnappingEnabled ? "靠近边界吸附，继续拖动脱开；Shift 临时跳过" : "吸附已关闭，点击开启片段边界吸附")
                    .accessibilityLabel("时间线吸附")
                    .accessibilityValue(isSnappingEnabled ? "开启" : "关闭")
                }

                timelineCapsule {
                    Button {
                        isHoverPreviewEnabled.toggle()
                        hoverPreviewGate.isEnabled = isHoverPreviewEnabled
                        if !isHoverPreviewEnabled {
                            setTimelineHoverLocation(nil)
                            playbackController.endHoverPreview()
                        }
                    } label: {
                        Group {
                            if layout.iconOnlyTimelineControls {
                                Image(systemName: isHoverPreviewEnabled ? "eye" : "eye.slash")
                            } else {
                                Label("预览", systemImage: isHoverPreviewEnabled ? "eye" : "eye.slash")
                            }
                        }
                        .font(.appUI(.caption, weight: .medium))
                        .foregroundStyle(
                            isHoverPreviewEnabled
                                ? editorAccent
                                : Color.secondary
                        )
                        .padding(.horizontal, 7)
                        .frame(height: 30)
                        .background(
                            isHoverPreviewEnabled ? EditorTheme.chrome(0.10) : Color.clear,
                            in: RoundedRectangle(cornerRadius: 8, style: .continuous)
                        )
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
                            .frame(width: 30, height: 30)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(EditorTimelineControlButtonStyle())
                    .disabled(timelineZoom <= 1.01)
                    .help("显示完整时间线")
                    .accessibilityLabel("显示完整时间线")
                    .accessibilityIdentifier("editor.timeline.zoom-to-fit")

                    Button { zoomTimeline(to: max(timelineZoom / 1.5, 1), pointerViewportX: nil) } label: {
                        Image(systemName: "minus").frame(width: 28, height: 28)
                    }.buttonStyle(EditorTimelineControlButtonStyle()).accessibilityLabel("缩小时间线")
                    EditorSlider(value: zoomSliderPosition, range: 0...1, showsFloatingValue: false, onEditingChanged: { editing in
                        if !editing { timelineZoomInputCoalescer.flush() }
                    })
                        .frame(width: layout.compactTimelineControls ? 64 : 100)

                        .help("时间线缩放：常用倍率会占用更多滑动空间")
                        .accessibilityLabel("时间线缩放")
                        .accessibilityValue("\(Int((timelineZoom * 100).rounded()))%")
                    Button { zoomTimeline(to: min(timelineZoom * 1.5, maximumTimelineZoom), pointerViewportX: nil) } label: {
                        Image(systemName: "plus").frame(width: 28, height: 28)
                    }.buttonStyle(EditorTimelineControlButtonStyle()).accessibilityLabel("放大时间线")

                }
            }
        }
        .padding(.horizontal, 14)
        .frame(height: timelineControlsHeight)
        .background(EditorTheme.panelSurface)
    }

    private var transportIsPlaying: Bool {
        playbackController.isPlaying
    }

    private var transportCanPlay: Bool {
        playbackController.canPlay
    }

    private var timelineDisplayModePicker: some View {
        HStack(spacing: 2) {
            timelineDisplayModeButton("画面", symbol: "film", waveform: false)
            timelineDisplayModeButton("波形", symbol: "waveform", waveform: true)
        }
        .padding(3).fixedSize()
        .background(EditorTheme.chrome(0.045), in: RoundedRectangle(cornerRadius: 11))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("片段显示方式")
    }

    private func timelineDisplayModeButton(_ title: String, symbol: String, waveform: Bool) -> some View {
        let selected = usesWaveformClips == waveform
        return Button {
            guard !selected else { return }
            if gestureOwnership.activeIntent != nil || editorStore.interaction != nil {
                cancelActiveTimelineGesture()
            }
            withAnimation(SpringMotion.fluid) { usesWaveformClips = waveform }
        } label: {
            HStack(spacing: 7) {
                Image(systemName: symbol).frame(width: 14)
                if !layout.iconOnlyTimelineControls { Text(title).lineLimit(1).fixedSize() }
            }
                .font(.appUI(size: 11, weight: .medium))
                .foregroundStyle(selected ? EditorTheme.chrome(0.90) : EditorTheme.chrome(0.55))
                .frame(width: layout.iconOnlyTimelineControls ? 32 : 76, height: 30)
                .contentShape(RoundedRectangle(cornerRadius: 8))
                .background {
                    if selected {
                        RoundedRectangle(cornerRadius: 8)
                            .fill(EditorTheme.cardElevated)
                            .overlay(RoundedRectangle(cornerRadius: 8)
                                .strokeBorder(EditorTheme.hairline, lineWidth: 0.75))
                            .matchedGeometryEffect(id: "display-mode", in: displayModeSelection)
                    }
                }
        }
        .buttonStyle(EditorToolbarPressButtonStyle(cornerRadius: 8, cornerStyle: .circular))
        .help(waveform ? "放大显示片段内的音频波形" : "上方画面，下方波形")
        .accessibilityLabel(waveform ? "波形：放大音频波形" : "画面：上方缩略图，下方波形")
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityIdentifier(waveform ? "editor.timeline.display.waveform" : "editor.timeline.display.film")
    }

    var timelineLabels: some View {
        VStack(spacing: 0) {
            timelineTrackManager
                .frame(height: timelineRulerHeight)
            VStack(spacing: 0) {
                timelineLabel("屏幕录制", symbol: usesWaveformClips ? "waveform" : "display", tint: EditorTheme.platinumMuted,
                    height: primaryVideoHeight + 12, isFocused: focusedTimelineLane == .primary)
            }
            if showsCameraSyncTimeline {
                timelineLabel(
                    "摄像同步",
                    symbol: "waveform.path.ecg",
                    tint: editorCameraSyncClip,
                    height: cameraSyncTimelineHeight,
                    isFocused: focusedTimelineLane == .cameraSync
                )
            }
            if showsZoomTimeline {
                optionalTimelineLabel(
                    "缩放",
                    tint: editorZoomClip,
                    height: zoomTimelineHeight,
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
                    tint: editorOverlayClip,
                    height: overlayTimelineHeight,
                    track: .overlays
                )
            }
        }
        .background(Color.clear)
    }

    func timelineLabel(
        _ title: String,
        symbol: String,
        tint: Color,
        height: CGFloat,
        isFocused: Bool
    ) -> some View {
        EditorTimelineLaneLabel(title: title, symbol: symbol,
                                horizontalInset: layout.value(regular: 16, compact: 6))
            .frame(height: height)
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
                        .transition(.opacity.combined(with: .offset(y: 8)))
                }
                if showsZoomTimeline {
                    zoomTimeline(width: width, duration: duration)
                        .transition(.opacity.combined(with: .offset(y: 8)))
                }
                if showsScreenMotionTimeline {
                    motionTimeline(
                        track: .screen,
                        clips: screenMotionTimelineClips,
                        width: width,
                        duration: duration
                    )
                    .transition(.opacity.combined(with: .offset(y: 8)))
                }
                if showsCameraMotionTimeline {
                    motionTimeline(
                        track: .camera,
                        clips: cameraMotionTimelineClips,
                        width: width,
                        duration: duration
                    )
                    .transition(.opacity.combined(with: .offset(y: 8)))
                }
                if showsOverlayTimeline {
                    combinedOverlayTimeline(width: width, duration: duration)
                        .transition(.opacity.combined(with: .offset(y: 8)))
                }
            }

            NativeTimelinePlayheadView(
                playbackController: playbackController,
                duration: duration,
                part: .line
            )
            .frame(width: width, height: timelineCanvasHeight)
            .allowsHitTesting(false)
            // The playhead is the authoritative current time. Keep it above
            // the passive hover guide when both occupy the same x position.
            .zIndex(20)

            // CUT-003/CUT-004: the action itself lives in the dedicated lane;
            // only its non-interactive guide enters the primary clip.
            if let cutX {
                Rectangle()
                    .fill(EditorTheme.chrome(0.85))
                    .frame(width: 1, height: primaryTimelineHeight)
                    .offset(x: cutX - 0.5, y: timelineRulerHeight)
                    .allowsHitTesting(false)
                    // Holding Option expresses a concrete edit target, so it
                    // outranks both the current-time and hover indicators.
                    .zIndex(30)
            }

            NativeTimelineHoverGuideView(
                location: timelineHoverLocation,
                scrollView: timelineScrollView,
                duration: duration,
                canvasHeight: timelineCanvasHeight,
                badgeY: isRestoreCutMode ? 2 : timelineRulerHeight - 22,
                isEnabled: gestureOwnership.activeIntent == nil
                    && draggedPrimarySegmentID == nil && isHoverPreviewEnabled
            )
            .frame(width: width, height: timelineDocumentHeight)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
            .zIndex(10)

            magneticGuide(width: width, duration: duration)

        }
        .frame(width: width, height: timelineDocumentHeight, alignment: .topLeading)
        .coordinateSpace(name: editorTimelineDocumentCoordinateSpace)
        .contentShape(Rectangle())
        .contextMenu {
            Button("粘贴片段") {
                pasteTimelineClip(at: clipboardContextTime ?? clipboardInsertionTime)
            }
            .disabled(!EditorClipClipboard.shared.hasClip)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("时间线")
        .accessibilityValue("播放头位于 \(timelineTimestamp(playbackTime))")
        // All time-bound geometry (clips, waveform masks and handles) changes
        // in one display update. Do not inherit a button/delete/layout spring.
        // Explicit local ink and display-mode fades remain scoped below this.
        .transaction { $0.animation = nil }
    }

    func timelineRuler(
        width: CGFloat,
        duration: TimeInterval,
        cutX: CGFloat?
    ) -> some View {
        let visibleRange = clampedTimelineVisibleDocumentRange(width: width)
        let preparedRange = EditorTimelineWaveformPresentation.bufferedVisibleRange(
            documentWidth: width,
            visibleRange: visibleRange
        )
        let scaleLayers = EditorTimelineRulerPresentation.scaleLayers(
            duration: duration,
            width: width
        )
        let labelStep = scaleLayers.max { $0.opacity < $1.opacity }?.majorStep
        let visibleTimeRange = EditorTimelineViewportPresentation.bufferedTimeRange(
            documentWidth: width,
            duration: duration,
            visibleRange: visibleRange
        )
        return ZStack(alignment: .topLeading) {
            LinearGradient(
                colors: [Color.clear, Color.clear],
                startPoint: .top,
                endPoint: .bottom
            )
            // The ruler is a small, viewport-bounded drawing. Rendering it in
            // the current display pass avoids the blank asynchronous frame
            // that used to appear while its size changed during zoom.
            Canvas(opaque: false, rendersAsynchronously: false) { context, size in
                let safeDuration = max(duration, 0.001)
                for layer in scaleLayers where layer.opacity > 0.001 {
                    let ticks = EditorTimelineRulerPresentation.visibleTicks(
                        majorStep: layer.majorStep,
                        duration: duration,
                        width: width,
                        visibleRange: preparedRange,
                        guardBand: 0
                    )
                    var majorPath = Path()
                    var minorPath = Path()
                    var layerContext = context
                    layerContext.opacity = layer.opacity
                    for tick in ticks {
                        let rawX = width * CGFloat(tick.time / safeDuration) - preparedRange.lowerBound
                        let x = min(max(rawX, 0), max(size.width - 0.5, 0)) + 0.5
                        if tick.isMajor {
                            majorPath.move(to: CGPoint(x: x, y: size.height - 12))
                            majorPath.addLine(to: CGPoint(x: x, y: size.height - 2))
                            let labelX = min(max(x + 4, 0), max(size.width - 42, 0))
                            if layer.majorStep == labelStep {
                            context.draw(
                                Text(timelineTimestamp(tick.time))
                                    .font(.appUI(size: 11)).monospacedDigit()
                                    .foregroundStyle(.secondary),
                                at: CGPoint(x: labelX, y: 10),
                                anchor: .topLeading
                            )
                            }
                        } else {
                            minorPath.move(to: CGPoint(x: x, y: size.height - 7))
                            minorPath.addLine(to: CGPoint(x: x, y: size.height - 2))
                        }
                    }
                    layerContext.stroke(
                        majorPath,
                        with: .color(EditorTheme.chrome(0.20)),
                        lineWidth: 1
                    )
                    layerContext.stroke(
                        minorPath,
                        with: .color(EditorTheme.chrome(0.09)),
                        lineWidth: 1
                    )
                }
            }
            .frame(width: max(preparedRange.upperBound - preparedRange.lowerBound, 1), height: timelineRulerHeight)
            .offset(x: preparedRange.lowerBound)
            .allowsHitTesting(false)
            if primaryTrimDraft == nil && primaryReorderDraft == nil && isRestoreCutMode {
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
                    .font(.appUI(size: 9, weight: .bold))
                    .foregroundStyle(EditorTheme.onAccent)
                    .frame(width: 18, height: 18)
                    .background(Circle().fill(editorAccent))
                    .offset(x: cutX - 9, y: timelineRulerHeight - 20)
                    .allowsHitTesting(false)
                    .zIndex(31)
            }
        }
        .frame(width: width, height: timelineRulerHeight)
        .contentShape(Rectangle())
        .gesture(timelineScrubGesture(width: width, duration: duration))
        .overlay(alignment: .topLeading) {
            ZStack(alignment: .topLeading) {
                recordingMarkerRuler(width: width, duration: duration, visibleRange: visibleTimeRange)
            }
            .frame(width: width, height: timelineRulerHeight, alignment: .topLeading)
        }
        .help("拖动播放头靠近边界时吸附；继续拖动或按住 Shift 可脱开")
    }

    func clampedTimelineVisibleDocumentRange(width: CGFloat) -> ClosedRange<CGFloat> {
        EditorTimelineViewportPresentation.visibleDocumentRange(
            documentWidth: width,
            nativeVisibleRect: timelineScrollView?.documentVisibleRect,
            fallback: timelineVisibleDocumentRange
        )
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
        // The buffered viewport already owns enough labels, clips and waveform
        // on both sides. Publishing SwiftUI state every 40 points only creates
        // a periodic hitch during play/pause searching, so advance presentation
        // state solely when that prepared viewport bucket changes.
        if currentBucket != nextBucket {
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
                let isBeginning = gestureOwnership.activeIntent == nil
                guard beginTimelineGesture(intent) else { return }
                let rawTime = EditorTimelineMath.clampedTime(
                    atX: Double(value.location.x),
                    width: Double(width),
                    duration: duration
                )
                let time = magneticTime(snappedTimelineTime(rawTime), width: width, duration: duration)
                if isBeginning { clearTimelineSelection() }
                playbackController.beginScrubbing()
                playbackController.updateScrubbing(to: time)
            }
            .onEnded { _ in
                playbackController.endScrubbing()
                endTimelineGesture(intent)
            }
    }

    func primarySegmentLabel(
        segment: ResolvedRecordingSegment,
        emphasis: EditorTimelineClipEmphasis,
        filmstripVisibleRange: ClosedRange<CGFloat>,
        filmstripPriorityRange: ClosedRange<CGFloat>
    ) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: 10)
                .fill(isPrimaryWaveformSelected(segment.id) ? EditorTheme.selectionWash : EditorTheme.chrome(0.035))
            GeometryReader { geometry in
                let bandHeight = showsClipWaveforms
                    ? geometry.size.height * EditorTimelineClipGeometry.waveformBandFraction : 0
                VStack(spacing: 0) {
                    // Keep the filmstrip's identity and decoded frames across
                    // mode changes. The audio band never covers the picture.
                    EditorTimelineFilmstrip(mediaSession: mediaSession,
                        sourceStart: segment.sourceStart, sourceDuration: segment.sourceDuration,
                        visibleRange: filmstripVisibleRange,
                        priorityRange: filmstripPriorityRange,
                        isEnabled: !usesWaveformClips && !playbackController.isPlaying
                            && editorStore.interaction == nil && gestureOwnership.activeIntent == nil)
                        .frame(height: geometry.size.height - bandHeight)
                    if showsClipWaveforms {
                        Rectangle()
                            .fill(EditorTheme.chrome(0.02))
                            .frame(height: bandHeight)
                            .overlay(alignment: .top) {
                                Rectangle().fill(EditorTheme.chrome(0.08)).frame(height: 0.5)
                            }
                    }
                }
                .opacity(usesWaveformClips ? 0 : 1)
            }
        }
            .animation(SpringMotion.fluid, value: usesWaveformClips)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .padding(EditorTimelineClipGeometry.contentInset)
            .background(EditorTheme.cardElevated, in: RoundedRectangle(cornerRadius: 13))
            .editorTimelineClipChrome(cornerRadius: 13, emphasis: emphasis)
    }

    private func primaryDurationBadge(_ duration: TimeInterval) -> some View {
        Text(timelineTimestamp(duration))
            .font(.appUI(size: 11, weight: .medium)).monospacedDigit()
            .lineLimit(1)
            .foregroundStyle(usesWaveformClips ? EditorTheme.chrome(0.72) : .white)
            .padding(.horizontal, 7).padding(.vertical, 4)
            .background(usesWaveformClips ? EditorTheme.cardElevated.opacity(0.94) : .black.opacity(0.42), in: Capsule())
            .animation(SpringMotion.fluid, value: usesWaveformClips)
            .accessibilityHidden(true)
    }

    private func isPrimaryWaveformSelected(_ id: UUID) -> Bool {
        selectedPrimarySegmentIDs.contains(id)
    }

    func primarySegmentTitle(
        index: Int,
        segment: ResolvedRecordingSegment,
        segmentsCount: Int
    ) -> String {
        segmentsCount == 1 ? "屏幕片段" : "片段 \(index + 1)"
    }



    func primarySegmentView(
        index: Int,
        segment: ResolvedRecordingSegment,
        segmentsCount: Int,
        startX: CGFloat,
        segmentWidth: CGFloat,
        isSelected: Bool,
        emphasis: EditorTimelineClipEmphasis,
        laneWidth: CGFloat,
        duration: TimeInterval,
        filmstripDocumentRange: ClosedRange<CGFloat>
    ) -> some View {
        let filmstripOrigin = startX + EditorTimelineClipGeometry.contentInset
            + (draggedPrimarySegmentID == segment.id
                ? primaryFloatingTranslation(width: laneWidth, duration: duration) : 0)
        let filmstripVisibleRange = (filmstripDocumentRange.lowerBound - filmstripOrigin)...(filmstripDocumentRange.upperBound - filmstripOrigin)
        let viewport = clampedTimelineVisibleDocumentRange(width: laneWidth)
        let filmstripPriorityRange = (viewport.lowerBound - filmstripOrigin)...(viewport.upperBound - filmstripOrigin)
        let floatingOffset = draggedPrimarySegmentID == segment.id
            ? primaryFloatingTranslation(width: laneWidth, duration: duration) : 0
        let hitRange = EditorTimelineClipGeometry.interactionRange(
            segmentOriginX: startX + floatingOffset,
            segmentWidth: segmentWidth,
            documentRange: filmstripDocumentRange
        )
        let hitWidth = hitRange.upperBound - hitRange.lowerBound
        return ZStack(alignment: .topLeading) {
            primarySegmentLabel(
                segment: segment,
                emphasis: emphasis,
                filmstripVisibleRange: filmstripVisibleRange,
                filmstripPriorityRange: filmstripPriorityRange
            )
            .frame(width: segmentWidth, height: primaryVideoHeight)
            .allowsHitTesting(false)

            ZStack(alignment: .topLeading) {
                Color.clear
                    .frame(width: hitWidth, height: primaryVideoHeight)
                    .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                    .simultaneousGesture(
                        DragGesture(
                            minimumDistance: 4,
                            coordinateSpace: .named(editorTimelineDocumentCoordinateSpace)
                        )
                        .onChanged { value in
                            updatePrimarySegmentDrag(
                                segmentID: segment.id,
                                translation: value.translation.width,
                                documentX: value.location.x, laneWidth: laneWidth, duration: duration
                            )
                        }
                        .onEnded { value in
                            finishPrimarySegmentDrag(
                                segmentID: segment.id,
                                translation: value.translation.width,
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
                                        location: CGPoint(
                                            x: event.location.x + hitRange.lowerBound,
                                            y: event.location.y
                                        ),
                                        segmentWidth: segmentWidth
                                    )
                                } else {
                                    selectPrimarySegment(
                                        segment.id,
                                        extendingWith: NSEvent.modifierFlags
                                    )
                                }
                            }
                    )
                    .contextMenu {
                        primarySegmentContextMenu(segment: segment)
                    }

                if emphasis.showsHandles,
                   !isSelected || selectedPrimarySegmentID == segment.id {
                    // Only the real clip endpoints are trim handles. A viewport
                    // edge in the middle of a long clip must never act as one.
                    if hitWidth > 0, hitRange.lowerBound == 0 {
                        primaryTrimHandle(edge: .left, segment: segment,
                            laneWidth: laneWidth, duration: duration)
                            .offset(x: 1)
                            .opacity(emphasis.handleOpacity)
                            .zIndex(20)
                    }
                    if hitWidth > 0, hitRange.upperBound == segmentWidth {
                        primaryTrimHandle(edge: .right, segment: segment,
                            laneWidth: laneWidth, duration: duration)
                            .offset(x: max(hitWidth - 13, 0))
                            .opacity(emphasis.handleOpacity)
                            .zIndex(20)
                    }
                }
            }
            .frame(width: hitWidth, height: primaryVideoHeight)
            .contentShape(Rectangle())
            .allowsHitTesting(hitWidth > 0)
            .onHover { hovering in
                if hovering {
                    hoveredPrimarySegmentID = segment.id
                } else if hoveredPrimarySegmentID == segment.id {
                    hoveredPrimarySegmentID = nil
                }
            }
            .offset(x: hitRange.lowerBound)
        }
        .frame(width: segmentWidth, height: primaryVideoHeight)
        .contentShape(.interaction, Path(CGRect(
            x: hitRange.lowerBound, y: 0,
            width: hitWidth, height: primaryVideoHeight
        )))
        .offset(
            x: startX + (draggedPrimarySegmentID == segment.id
                ? primaryFloatingTranslation(width: laneWidth, duration: duration)
                : 0)
        )
        .opacity(draggedPrimarySegmentID == segment.id ? 0.82 : 1)
        .zIndex(
            draggedPrimarySegmentID == segment.id
                ? 10
                : isSelected ? 3 : emphasis == .hovered ? 1 : 0
        )
        .shadow(
            color: draggedPrimarySegmentID == segment.id
                ? EditorTheme.softShadow
                : .clear,
            radius: 8,
            y: 2
        )
        .help("主片段 \(index + 1) · \(timelineTimestamp(segment.outputDuration)) · ⇧ 连选 · ⌘ 增减选择 · ⌥ 单击切分")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            primarySegmentTitle(
                index: index,
                segment: segment,
                segmentsCount: segmentsCount
            )
        )
        .accessibilityValue(timelineTimestamp(segment.outputDuration))
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
        // Splitting selects the new right-hand piece. Keep that target alive
        // even while the native viewport is attaching or changing bounds.
        let retainedIDs = [selectedPrimarySegmentID, draggedPrimarySegmentID,
                           primaryTrimDraft?.segmentID, primaryRetimeDraft?.segmentID]
            .compactMap { $0 }
        let retainedSegmentIndices = retainedIDs.compactMap { id in
            segments.firstIndex(where: { $0.id == id })
        }
        let visibleTimeRange = EditorTimelineViewportPresentation.bufferedTimeRange(
            documentWidth: width,
            duration: duration,
            visibleRange: clampedTimelineVisibleDocumentRange(width: width)
        )
        let filmstripDocumentRange = EditorTimelineViewportPresentation.bufferedDocumentRange(
            documentWidth: width,
            visibleRange: clampedTimelineVisibleDocumentRange(width: width)
        )
        let visibleSegmentIndices = EditorTimelineViewportPresentation.visibleIntervalIndices(
            in: segments,
            timeRange: visibleTimeRange,
            startTime: \.outputStart,
            endTime: \.outputEnd,
            retainingIndices: retainedSegmentIndices
        )
        // Keep the view (and its hover/filmstrip state) with the clip when a
        // split, removal or reorder changes its slot in the timeline.
        let visibleSegments = visibleSegmentIndices.map { (index: $0, clip: segments[$0]) }
        return ZStack(alignment: .topLeading) {
            timelineLaneSurface(
                tint: editorClipAmberTop,
                isFocused: focusedTimelineLane == .primary
            )
            Color.clear
                .contentShape(Rectangle())
                .onTapGesture {
                    clearTimelineSelection()
                }
            ForEach(visibleSegments, id: \.clip.id) { item in
                let index = item.index
                let segment = item.clip
                let startX = CGFloat(segment.outputStart / max(duration, 0.001)) * width
                let segmentWidth = max(
                    CGFloat(segment.outputDuration / max(duration, 0.001)) * width,
                    1
                )
                let isSelected = selectedPrimarySegmentIDs.contains(segment.id)
                let isHovered = hoveredPrimarySegmentID == segment.id
                let isEditing = draggedPrimarySegmentID == segment.id
                    || primaryTrimDraft?.segmentID == segment.id
                    || primaryRetimeDraft?.segmentID == segment.id
                let emphasis = EditorTimelineClipEmphasis.resolve(
                    isEditing: isEditing,
                    isSelected: isSelected,
                    isHovered: isHovered
                )

                primarySegmentView(
                    index: index,
                    segment: segment,
                    segmentsCount: segments.count,
                    startX: startX,
                    segmentWidth: segmentWidth,
                    isSelected: isSelected,
                    emphasis: emphasis,
                    laneWidth: width,
                    duration: duration,
                    filmstripDocumentRange: filmstripDocumentRange
                )
            }

            if showsClipWaveforms {
                clipAudioWaveformOverlay(width: width, duration: duration)
                    .allowsHitTesting(false)
                    .zIndex(15)
            }

            ForEach(visibleSegments, id: \.clip.id) { item in
                let segment = item.clip
                let segmentWidth = CGFloat(segment.outputDuration / max(duration, 0.001)) * width
                if segmentWidth > 82 {
                    primaryDurationBadge(segment.outputDuration)
                        .frame(width: 76, alignment: .trailing)
                        .offset(x: CGFloat(segment.outputStart / max(duration, 0.001)) * width
                            + segmentWidth - 82
                            + (draggedPrimarySegmentID == segment.id
                                ? primaryFloatingTranslation(width: width, duration: duration) : 0), y: 9)
                        .zIndex(30)
                        .allowsHitTesting(false)
                }
            }

        }
        .padding(.vertical, 6)
        .frame(width: width, height: primaryTimelineHeight, alignment: .leading)
    }

    // SYNC-003: camera drift is authored against the original screen clock,
    // but presented on the ripple-edited output clock. This keeps markers at
    // the same recorded moment after cuts while making the correction visible
    // exactly where the editor will hear and see it.
    func cameraSyncTimeline(width: CGFloat, duration: TimeInterval) -> some View {
        let displayRange = cameraSyncDisplayRange
        return ZStack(alignment: .topLeading) {
            timelineLaneSurface(
                tint: editorCameraSyncClip,
                isFocused: focusedTimelineLane == .cameraSync
            )
            Color.clear
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
                editorCameraSyncClip.opacity(0.30),
                style: StrokeStyle(lineWidth: 1, dash: [4, 4])
            )
            .allowsHitTesting(false)

            cameraSyncCurvePath(
                width: width,
                duration: duration,
                displayRange: displayRange
            )
            .stroke(editorCameraSyncClip.opacity(0.92), style: StrokeStyle(lineWidth: 2, lineJoin: .round))
            .allowsHitTesting(false)

            Text("基准 \(cameraSyncOffsetLabel(cameraSyncBaselineOffset))")
                .font(.appUI(size: 9, weight: .semibold, design: .monospaced))
                .foregroundStyle(editorCameraSyncClip.opacity(0.92))
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background(EditorTheme.panelRaised.opacity(0.92), in: Capsule())
                .offset(x: 7, y: 5)
                .allowsHitTesting(false)

            if cameraSyncAnchors.isEmpty {
                Text("双击添加同步点 · 单击空白取消选中")
                    .font(.appUI(size: 9))
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
                        x: min(max(x + 15, 98), max(width - 188, 98)),
                        y: 3
                    )
            }
        }
        .frame(width: width, height: cameraSyncTimelineHeight, alignment: .topLeading)
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
                    .font(.appUI(size: 8, weight: .semibold, design: .monospaced))
                    .foregroundStyle(editorCameraSyncClip.opacity(0.96))
                    .frame(width: 70)
                    .offset(x: min(max(x - 35, 0), max(width - 70, 0)), y: 3)
                    .allowsHitTesting(false)
            }

            ZStack {
                RoundedRectangle(cornerRadius: 2, style: .continuous)
                    .fill(isSelected ? Color.white : editorCameraSyncClip)
                    .overlay {
                        RoundedRectangle(cornerRadius: 2, style: .continuous)
                            .stroke(Color.black.opacity(0.72), lineWidth: 1)
                    }
                    .frame(width: 11, height: 11)
                    .rotationEffect(.degrees(45))
                    .shadow(color: Color.black.opacity(0.45), radius: 2, y: 1)
            }
                .frame(width: 28, height: 28)
                .contentShape(Rectangle())
                .offset(x: x - 14, y: y - 14)
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
        HStack(spacing: 3) {
            Text(cameraSyncOffsetLabel(cameraSyncBaselineOffset + anchor.offset))
                .font(.appUI(size: 9, weight: .bold, design: .monospaced))
                .foregroundStyle(editorCameraSyncClip)
            Button { nudgeCameraSyncAnchor(id: anchor.id, by: -cameraSyncAdjustmentStep) } label: {
                Text("延\(cameraSyncAdjustmentStepMilliseconds)")
                    .font(.appUI(size: 9.5, weight: .semibold))
            }
            .buttonStyle(.editorQuiet)
            .help("画面延后 \(cameraSyncAdjustmentStepMilliseconds)ms，并自动试听")
            Button { nudgeCameraSyncAnchor(id: anchor.id, by: cameraSyncAdjustmentStep) } label: {
                Text("提\(cameraSyncAdjustmentStepMilliseconds)")
                    .font(.appUI(size: 9.5, weight: .semibold))
            }
            .buttonStyle(.editorQuiet)
            .help("画面提前 \(cameraSyncAdjustmentStepMilliseconds)ms，并自动试听")
            Button(role: .destructive) { removeCameraSyncAnchor(id: anchor.id) } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.editorDestructiveIcon)
            .help("删除同步点")
        }
        .padding(.horizontal, 6)
        .frame(height: 34)
        .background(
            Color.black.opacity(0.84),
            in: RoundedRectangle(cornerRadius: 9, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .stroke(editorCameraSyncClip.opacity(0.45), lineWidth: 0.75)
        }
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
                playbackController.scheduleCameraSyncAudition(at: outputTime)
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
                    playbackController.scheduleCameraSyncAudition(at: outputTime)
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
            playbackController.scheduleCameraSyncAudition(at: outputTime)
        }
    }
}
