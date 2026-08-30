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
                .opacity(isEnabled ? 1 : 0.34)
                .background(
                    backgroundColor,
                    in: RoundedRectangle(cornerRadius: 9, style: .continuous)
                )
                .contentShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                .scaleEffect(configuration.isPressed && isEnabled ? 0.95 : (isHovered && isEnabled ? 1.035 : 1.0))
                .onHover { isHovered = $0 }
                .animation(SpringMotion.interactive, value: isHovered)
                .animation(SpringMotion.interactive, value: configuration.isPressed)
                .animation(SpringMotion.interactive, value: isEnabled)
        }

        private var backgroundColor: Color {
            guard isEnabled else { return .clear }
            if configuration.isPressed { return Color.white.opacity(0.14) }
            if isHovered { return Color.white.opacity(0.08) }
            return .clear
        }
    }
}

/// Keeps the primary transport visually centred for ordinary editor widths,
/// then moves it only as far left as necessary to preserve a real gap before
/// the trailing edit/view controls. A ZStack could centre the transport but
/// could not reserve the trailing controls' measured width, so the two groups
/// overlapped near the editor's minimum window size.
fileprivate struct EditorTimelineControlsLayout: Layout {
    var horizontalInset: CGFloat = 14
    var groupSpacing: CGFloat = 12

    func sizeThatFits(
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) -> CGSize {
        let sizes = subviews.map { $0.sizeThatFits(.unspecified) }
        let contentWidth = sizes.reduce(0) { $0 + $1.width }
            + groupSpacing * CGFloat(max(sizes.count - 1, 0))
            + horizontalInset * 2
        let contentHeight = sizes.map(\.height).max() ?? 0
        return CGSize(
            width: proposal.width ?? contentWidth,
            height: proposal.height ?? contentHeight
        )
    }

    func placeSubviews(
        in bounds: CGRect,
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) {
        guard subviews.count == 2 else { return }

        let transportSize = subviews[0].sizeThatFits(.unspecified)
        let toolsSize = subviews[1].sizeThatFits(.unspecified)
        let toolsX = bounds.maxX - horizontalInset - toolsSize.width
        let centredTransportX = bounds.midX - transportSize.width / 2
        let transportX = max(
            bounds.minX + horizontalInset,
            min(
                centredTransportX,
                toolsX - groupSpacing - transportSize.width
            )
        )

        subviews[0].place(
            at: CGPoint(
                x: transportX,
                y: bounds.midY - transportSize.height / 2
            ),
            proposal: ProposedViewSize(transportSize)
        )
        subviews[1].place(
            at: CGPoint(
                x: toolsX,
                y: bounds.midY - toolsSize.height / 2
            ),
            proposal: ProposedViewSize(toolsSize)
        )
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
        case progress
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
        case .progress:
            return .progress
        default:
            return nil
        }
    }

    func timelineLaneSurface(
        tint: Color,
        isFocused: Bool
    ) -> some View {
        LinearGradient(
            colors: [
                tint.opacity(isFocused ? 0.115 : 0.045),
                tint.opacity(isFocused ? 0.045 : 0.016),
                Color.black.opacity(isFocused ? 0.025 : 0.07),
            ],
            startPoint: .top,
            endPoint: .bottom
        )
        .overlay(alignment: .top) {
            if isFocused {
                Rectangle()
                    .fill(tint.opacity(0.30))
                    .frame(height: 1)
            }
        }
        .allowsHitTesting(false)
        .animation(SpringMotion.interactive, value: isFocused)
    }

    /// 传输条按用户任务分区：播放 / 剪辑 / 视图状态 / 缩放，
    /// 不按“一次性按钮还是开关”这种实现形态分组。
    private func timelineCapsule<Content: View>(
        @ViewBuilder _ content: () -> Content
    ) -> some View {
        HStack(spacing: 2) { content() }
            .padding(.horizontal, 4)
            .frame(height: 34)
            .background(
                LinearGradient(
                    colors: [Color.white.opacity(0.060), Color.white.opacity(0.030)],
                    startPoint: .top,
                    endPoint: .bottom
                ),
                in: RoundedRectangle(cornerRadius: 11, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .stroke(
                        LinearGradient(
                            colors: [
                                Color.white.opacity(0.12),
                                Color.white.opacity(0.04)
                            ],
                            startPoint: .top,
                            endPoint: .bottom
                        ),
                        lineWidth: 0.75
                    )
            }
            .shadow(color: Color.black.opacity(0.20), radius: 3, y: 1)
    }

    func timelineControls(duration: TimeInterval) -> some View {
        let maximumTimelineZoom = 120.0
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

        return EditorTimelineControlsLayout() {
            HStack(spacing: 10) {
                NativePlaybackTimeView(playbackController: playbackController)
                    .frame(width: 72, height: 28)

                timelineCapsule {
                    Button { stepTimeline(byFrames: -1) } label: {
                        Image(systemName: "backward.frame.fill")
                            .frame(width: 30, height: 30)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(EditorTimelineControlButtonStyle())
                    .help("上一帧")
                    .accessibilityLabel("上一帧")

                    Button {
                        withAnimation(SpringMotion.snappy) {
                            playbackController.togglePlayback()
                        }
                    } label: {
                        ZStack {
                            Circle()
                                .fill(
                                    LinearGradient(
                                        colors: [Color.white, Color(white: 0.88)],
                                        startPoint: .top,
                                        endPoint: .bottom
                                    )
                                )
                                .frame(width: 28, height: 28)
                                .overlay(
                                    Circle().stroke(Color.white.opacity(0.4), lineWidth: 0.5)
                                )
                                .shadow(color: Color.white.opacity(0.2), radius: 4)

                            Image(systemName: playbackController.isPlaying ? "pause.fill" : "play.fill")
                                .font(.system(size: 10, weight: .bold))
                                .foregroundStyle(Color.black.opacity(0.9))
                                .offset(x: playbackController.isPlaying ? 0 : 1)
                        }
                        .frame(width: 34, height: 30)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(EditorTimelineControlButtonStyle())
                    .disabled(!playbackController.canPlay)
                    .scaleEffect(playbackController.isPlaying ? 1.04 : 1.0)
                    .animation(SpringMotion.interactive, value: playbackController.isPlaying)
                    .help(playbackController.isPlaying ? "暂停（空格）" : "播放（空格）")
                    .accessibilityLabel(playbackController.isPlaying ? "暂停" : "播放")

                    Button { stepTimeline(byFrames: 1) } label: {
                        Image(systemName: "forward.frame.fill")
                            .frame(width: 30, height: 30)
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
                                isRestoreCutMode ? Color.white.opacity(0.10) : Color.clear,
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
                }

                timelineCapsule {
                    Button {
                        isHoverPreviewEnabled.toggle()
                        hoverPreviewGate.isEnabled = isHoverPreviewEnabled
                        if !isHoverPreviewEnabled {
                            hoveredTimelineViewportX = nil
                            hoveredTimelineViewportY = nil
                            playbackController.endHoverPreview()
                        }
                    } label: {
                        Label(
                            "预览",
                            systemImage: isHoverPreviewEnabled ? "eye" : "eye.slash"
                        )
                        .font(.caption.weight(.medium))
                        .foregroundStyle(
                            isHoverPreviewEnabled
                                ? editorAccent
                                : Color.secondary
                        )
                        .padding(.horizontal, 7)
                        .frame(height: 30)
                        .background(
                            isHoverPreviewEnabled ? Color.white.opacity(0.10) : Color.clear,
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

                    EditorSlider(
                        value: zoomSliderPosition,
                        range: 0...1,
                        formatValue: { position in
                            let clampedPosition = min(max(position, 0), 1)
                            let zoom = pow(maximumTimelineZoom, clampedPosition)
                            return zoom < 10
                                ? String(format: "%.1f×", zoom)
                                : "\(Int(zoom.rounded()))×"
                        },
                        onEditingChanged: { isEditing in
                            if !isEditing {
                                timelineZoomInputCoalescer.flush()
                            }
                        }
                    )
                        .frame(width: 126)
                        .padding(.horizontal, 4)
                        .help("时间线缩放：常用倍率会占用更多滑动空间")
                        .accessibilityLabel("时间线缩放")
                        .accessibilityValue("\(Int((timelineZoom * 100).rounded()))%")
                }
            }
        }
        .padding(.horizontal, 14)
        .frame(height: timelineControlsHeight)
        .background(
            LinearGradient(
                colors: [EditorTheme.panelSurface.opacity(0.96), Color.black.opacity(0.24)],
                startPoint: .top,
                endPoint: .bottom
            )
        )
    }

    var timelineLabels: some View {
        VStack(spacing: 0) {
            timelineTrackManager
                .frame(height: timelineRulerHeight)
            timelineLabel(
                "片段",
                symbol: "film",
                tint: editorClipAmberTop,
                height: primaryTimelineHeight,
                isFocused: focusedTimelineLane == .primary
            )
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
                    tint: editorOverlayClip,
                    height: overlayTimelineHeight,
                    track: .overlays
                )
            }
            if showsProgressTimeline {
                optionalTimelineLabel(
                    "进度条",
                    tint: editorProgressClip,
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
        height: CGFloat,
        isFocused: Bool
    ) -> some View {
        HStack(spacing: 5) {
            RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                .fill(tint.opacity(isFocused ? 1 : 0.82))
                .frame(width: isFocused ? 3.5 : 2.5, height: isFocused ? 26 : 18)

            Image(systemName: symbol)
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(tint.opacity(0.94))
                .frame(width: 14)

            Text(title)
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(Color.white.opacity(isFocused ? 0.96 : 0.78))
                .lineLimit(1)
        }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .padding(.horizontal, 8)
            .frame(height: height)
            .background(
                LinearGradient(
                    colors: [
                        tint.opacity(isFocused ? 0.15 : 0.035),
                        tint.opacity(isFocused ? 0.055 : 0.012),
                    ],
                    startPoint: .leading,
                    endPoint: .trailing
                )
            )
            .overlay(alignment: .bottom) { Divider().overlay(dividerColor) }
            .animation(SpringMotion.interactive, value: isFocused)
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
            // The playhead is the authoritative current time. Keep it above
            // the passive hover guide when both occupy the same x position.
            .zIndex(20)

            // CUT-003/CUT-004: the action itself lives in the dedicated lane;
            // only its non-interactive guide enters the primary clip.
            if let cutX {
                Rectangle()
                    .fill(Color.white.opacity(0.85))
                    .frame(width: 1, height: primaryTimelineHeight)
                    .offset(x: cutX - 0.5, y: timelineRulerHeight)
                    .allowsHitTesting(false)
                    // Holding Option expresses a concrete edit target, so it
                    // outranks both the current-time and hover indicators.
                    .zIndex(30)
            }

            // 悬停轴与真实播放头必须一眼可分：播放头保持实线，悬停定位使用
            // 虚线和独立时间胶囊。这里只改变呈现，不改变播放头或剪辑时间。
            if gestureOwnership.activeIntent == nil,
               draggedPrimarySegmentID == nil,
               isHoverPreviewEnabled,
               let previewX = hoveredTimelineContentX {
                let previewTime = EditorTimelineMath.clampedTime(
                    atX: Double(previewX),
                    width: Double(width),
                    duration: duration
                )
                timelineHoverGuide(
                    previewX: previewX,
                    previewTime: previewTime,
                    width: width
                )
                .transition(.opacity.combined(with: .scale(scale: 0.96, anchor: .top)))
            }

            timelineGestureFeedbackOverlay(width: width, duration: duration)
        }
        .frame(width: width, height: timelineCanvasHeight, alignment: .topLeading)
        .coordinateSpace(name: editorTimelineDocumentCoordinateSpace)
        .contentShape(Rectangle())
        .accessibilityElement(children: .contain)
        .accessibilityLabel("时间线")
        .accessibilityValue("播放头位于 \(timelineTimestamp(playbackTime))")
    }

    func timelineHoverGuide(
        previewX: CGFloat,
        previewTime: TimeInterval,
        width: CGFloat
    ) -> some View {
        let badgeWidth: CGFloat = 62
        let badgeX = min(
            max(previewX - badgeWidth / 2, 3),
            max(width - badgeWidth - 3, 3)
        )
        return ZStack(alignment: .topLeading) {
            Path { path in
                path.move(to: CGPoint(x: 0.5, y: 0))
                path.addLine(to: CGPoint(x: 0.5, y: timelineCanvasHeight))
            }
            .stroke(
                Color.white.opacity(0.34),
                style: StrokeStyle(lineWidth: 1, dash: [3, 4])
            )
            .frame(width: 1, height: timelineCanvasHeight)
            .offset(x: previewX - 0.5)

            Text(timelineTimestamp(previewTime))
                .font(.system(size: 9, weight: .medium, design: .monospaced))
                .foregroundStyle(Color.white.opacity(0.92))
                .frame(width: badgeWidth, height: 18)
                .background(
                    LinearGradient(
                        colors: [Color(white: 0.20), Color(white: 0.11)],
                        startPoint: .top,
                        endPoint: .bottom
                    ),
                    in: Capsule(style: .continuous)
                )
                .overlay {
                    Capsule(style: .continuous)
                        .stroke(Color.white.opacity(0.18), lineWidth: 0.75)
                }
                .shadow(color: Color.black.opacity(0.34), radius: 4, y: 2)
                .offset(
                    x: badgeX,
                    y: isRestoreCutMode ? 2 : timelineRulerHeight - 22
                )
        }
        .frame(width: width, height: timelineCanvasHeight, alignment: .topLeading)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        // Hover is a preview-only guide. It stays above clip content but
        // yields whenever it coincides with the playhead or a cut target.
        .zIndex(10)
        .animation(SpringMotion.interactive, value: hoveredTimelineContentX != nil)
    }

    func timelineRuler(
        width: CGFloat,
        duration: TimeInterval,
        cutX: CGFloat?
    ) -> some View {
        let visibleRange = clampedTimelineVisibleDocumentRange(width: width)
        let scaleLayers = EditorTimelineRulerPresentation.scaleLayers(
            duration: duration,
            width: width
        )
        let visibleTimeRange = EditorTimelineViewportPresentation.bufferedTimeRange(
            documentWidth: width,
            duration: duration,
            visibleRange: visibleRange
        )
        return ZStack(alignment: .topLeading) {
            LinearGradient(
                colors: [Color.white.opacity(0.026), Color.black.opacity(0.10)],
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
                        visibleRange: visibleRange
                    )
                    var majorPath = Path()
                    var minorPath = Path()
                    var layerContext = context
                    layerContext.opacity = layer.opacity
                    for tick in ticks {
                        let rawX = size.width * CGFloat(tick.time / safeDuration)
                        let x = min(max(rawX, 0), max(size.width - 0.5, 0)) + 0.5
                        if tick.isMajor {
                            majorPath.move(to: CGPoint(x: x, y: 0))
                            majorPath.addLine(to: CGPoint(x: x, y: 8))
                            let labelX = min(max(x + 4, 0), max(size.width - 42, 0))
                            layerContext.draw(
                                Text(timelineTimestamp(tick.time))
                                    .font(.system(size: 9, design: .monospaced))
                                    .foregroundStyle(.secondary),
                                at: CGPoint(x: labelX, y: 10),
                                anchor: .topLeading
                            )
                        } else {
                            minorPath.move(to: CGPoint(x: x, y: 0))
                            minorPath.addLine(to: CGPoint(x: x, y: 4))
                        }
                    }
                    layerContext.stroke(
                        majorPath,
                        with: .color(.white.opacity(0.20)),
                        lineWidth: 1
                    )
                    layerContext.stroke(
                        minorPath,
                        with: .color(.white.opacity(0.09)),
                        lineWidth: 1
                    )
                }
            }
            .frame(width: width, height: timelineRulerHeight)
            .allowsHitTesting(false)
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
        emphasis: EditorTimelineClipEmphasis
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
                if segmentWidth >= 96 {
                    HStack(spacing: 4) {
                        Image(systemName: "display")
                            .font(.system(size: 8, weight: .bold))
                            .foregroundStyle(.white.opacity(0.95))
                        Text(segmentsCount == 1 ? "屏幕片段" : "片段 \(index + 1)")
                            .font(.system(size: 9.5, weight: .medium))
                        if segmentWidth >= 168 {
                            Text(timelineTimestamp(segment.outputDuration))
                                .font(.system(size: 9, design: .monospaced))
                                .foregroundStyle(.white.opacity(0.70))
                            if segmentWidth >= 224,
                               abs(segment.playbackRate - 1) > 0.000_1 {
                                Text(timelinePlaybackRateText(segment.playbackRate))
                                    .font(.system(size: 8.5, weight: .semibold))
                                    .foregroundStyle(.white.opacity(0.88))
                            }
                        }
                    }
                    .foregroundStyle(.white.opacity(0.95))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(
                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                            .fill(Color.black.opacity(0.28))
                    )
                    .padding(.top, 3)
                    .padding(.leading, 6)
                    .lineLimit(1)
                } else if segmentWidth >= 48 {
                    Text("\(index + 1)")
                        .font(.system(size: 9, weight: .bold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(.white.opacity(0.94))
                        .frame(minWidth: 17, minHeight: 15)
                        .padding(.horizontal, 2)
                        .background(
                            Capsule(style: .continuous)
                                .fill(Color.black.opacity(0.30))
                        )
                        .padding(.top, 4)
                        .padding(.leading, 5)
                }
            }
            .editorTimelineClipChrome(cornerRadius: 7, emphasis: emphasis)
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
        duration: TimeInterval
    ) -> some View {
        ZStack {
            primarySegmentLabel(
                index: index,
                segment: segment,
                segmentsCount: segmentsCount,
                segmentWidth: segmentWidth,
                emphasis: emphasis
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
                        translation: value.translation.width,
                        documentX: value.location.x
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

            if emphasis.showsHandles {
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
                .opacity(emphasis.handleOpacity)
                .zIndex(20)
            }
        }
        .frame(width: segmentWidth, height: primaryClipContentHeight)
        .offset(
            x: startX + (draggedPrimarySegmentID == segment.id
                ? primarySegmentDragTranslation
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
        return ZStack(alignment: .leading) {
            timelineLaneSurface(
                tint: editorClipAmberTop,
                isFocused: focusedTimelineLane == .primary
            )
            Color.clear
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
                    duration: duration
                )
            }

            if showsClipWaveforms {
                clipAudioWaveformOverlay(width: width, duration: duration)
                    .allowsHitTesting(false)
                    .zIndex(15)
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
                .font(.system(size: 9, weight: .semibold, design: .monospaced))
                .foregroundStyle(editorCameraSyncClip.opacity(0.92))
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
                        x: min(max(x + 15, 98), max(width - 188, 98)),
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
                .font(.system(size: 9, weight: .bold, design: .monospaced))
                .foregroundStyle(editorCameraSyncClip)
            Button { nudgeCameraSyncAnchor(id: anchor.id, by: -cameraSyncAdjustmentStep) } label: {
                Text("延\(cameraSyncAdjustmentStepMilliseconds)")
                    .font(.system(size: 9.5, weight: .semibold))
            }
            .buttonStyle(.editorQuiet)
            .help("画面延后 \(cameraSyncAdjustmentStepMilliseconds)ms，并自动试听")
            Button { nudgeCameraSyncAnchor(id: anchor.id, by: cameraSyncAdjustmentStep) } label: {
                Text("提\(cameraSyncAdjustmentStepMilliseconds)")
                    .font(.system(size: 9.5, weight: .semibold))
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
