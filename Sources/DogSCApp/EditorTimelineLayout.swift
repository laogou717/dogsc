import AVFoundation
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
                    in: RoundedRectangle(cornerRadius: EditorInterfaceRadius.control, style: .continuous)
                )
                .contentShape(RoundedRectangle(cornerRadius: EditorInterfaceRadius.control, style: .continuous))
                .onHover { isHovered = $0 }
                .animation(SpringMotion.micro, value: isHovered)
        }

        private var backgroundColor: Color {
            guard isEnabled else { return .clear }
            if configuration.isPressed { return EditorTheme.chrome(EditorStateWash.pressed) }
            if isHovered { return EditorTheme.chrome(EditorStateWash.hover) }
            return .clear
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
        isFocused: Bool
    ) -> some View {
        // A neutral lift: lane colour is an accent, never a full-row wash.
        EditorTheme.chrome(isFocused ? 0.025 : 0)
            .allowsHitTesting(false)
    }

    /// 传输条按用户任务分区：播放 / 剪辑 / 视图状态 / 缩放，
    /// 不按“一次性按钮还是开关”这种实现形态分组。
    private func timelineCapsule<Content: View>(
        @ViewBuilder _ content: () -> Content
    ) -> some View {
        HStack(spacing: 2) { content() }
            .fixedSize(horizontal: true, vertical: false)
            .frame(height: 32)
    }

    /// Active timeline modes (snap, hover preview, restore cuts) share the
    /// segmented thumb so an engaged mode reads as a raised key, not a tint.
    /// EDT-079: an engaged toggle (snap, scrub, cut points) is told by its
    /// accent ink alone; the button keeps the plain hover wash.
    @ViewBuilder
    private func timelineModeSurface(isOn: Bool) -> some View {
        EmptyView()
    }

    private func timelineToggleInk(_ isOn: Bool) -> Color {
        isOn ? EditorTheme.accent : EditorTheme.secondaryText
    }

    func timelineControls() -> some View {
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

        return HStack(spacing: 4) {
                timelineToolPicker

                timelineCapsule {
                    Button {
                        editorStore.prepareForUserUndoOrRedo()
                        undoManager?.undo()
                    } label: {
                        AppLineIcon(kind: .undo, size: 16)
                            .frame(width: 28, height: 28)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(EditorTimelineControlButtonStyle())
                    .foregroundStyle(EditorTheme.secondaryText)
                    .help(appLocalized("撤销（⌘Z）"))
                    .accessibilityLabel(appLocalized("撤销"))
                    .accessibilityIdentifier("editor.timeline.undo")

                    Button {
                        _ = removeCurrentTimelineSelection()
                    } label: {
                        AppLineIcon(kind: .trash, size: 16)
                            .frame(width: 28, height: 28)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(EditorTimelineControlButtonStyle())
                    .foregroundStyle(EditorTheme.secondaryText)
                    .disabled(!canRemoveCurrentTimelineSelection)
                    .help(currentTimelineDeleteHelp)
                    .accessibilityLabel(appLocalized(currentTimelineDeleteAccessibilityLabel))
                    .accessibilityIdentifier("editor.timeline.primary.delete")

                    recordingMarkerMenu
                }

                Spacer(minLength: 12)

            HStack(spacing: 4) {
                timelineDisplayModePicker

                timelineBarButton("吸附", icon: .magnet, isOn: isSnappingEnabled) {
                    isSnappingEnabled.toggle()
                }
                .help(appLocalized(isSnappingEnabled
                    ? "吸附播放头、相邻片段边缘和字幕起止；按住 ⌘ 拖动临时关闭"
                    : "吸附已关闭，点击开启"))
                .accessibilityLabel("时间线吸附")
                .accessibilityValue(appLocalized(isSnappingEnabled ? "开关状态 · 开启" : "开关状态 · 关闭"))

                timelineBarButton("扫视", icon: .eye, isOn: isHoverPreviewEnabled) {
                    isHoverPreviewEnabled.toggle()
                    hoverPreviewGate.isEnabled = isHoverPreviewEnabled
                    if !isHoverPreviewEnabled {
                        setTimelineHoverLocation(nil)
                        playbackController.endHoverPreview()
                    }
                }
                .help(appLocalized(isHoverPreviewEnabled
                    ? "扫视已开启：指针扫过时间线即在画布显示该帧，S/Q/W 作用于指针位置"
                    : "扫视：开启后指针扫过时间线即在画布显示该帧"))
                .accessibilityLabel("时间线悬浮预览")
                .accessibilityValue(appLocalized(isHoverPreviewEnabled ? "开关状态 · 开启" : "开关状态 · 关闭"))
                .accessibilityIdentifier("editor.timeline.hover-preview-toggle")

                timelineBarButton("适应", icon: .fit, isOn: false) {
                    timelineZoomInputCoalescer.cancel()
                    zoomTimeline(to: 1, pointerViewportX: nil)
                }
                .disabled(timelineZoom <= 1.01)
                .help("适应窗口：显示完整时间线")
                .accessibilityLabel("显示完整时间线")
                .accessibilityIdentifier("editor.timeline.zoom-to-fit")

                timelineCapsule {
                    Button { enqueueTimelineZoom(scaleBy: 1 / 1.5) } label: {
                        AppLineIcon(kind: .minus, size: 14).frame(width: 28, height: 28)
                    }
                    .buttonStyle(EditorTimelineControlButtonStyle())
                    .foregroundStyle(EditorTheme.secondaryText)
                    .disabled(timelineZoom <= EditorTimelineZoomPolicy.minimum)
                    .help(timelineZoom <= EditorTimelineZoomPolicy.minimum
                        ? appLocalized("已显示完整时间线")
                        : appLocalized("缩小时间线，显示更多内容"))
                    .accessibilityLabel("缩小时间线")
                    EditorSlider(value: zoomSliderPosition, range: 0...1, showsFloatingValue: false, onEditingChanged: { editing in
                        if !editing { timelineZoomInputCoalescer.flush() }
                    })
                        .frame(width: layout.compactTimelineControls ? 64 : 96)
                        .help("向左显示更多内容，向右放大查看细节")
                        .accessibilityLabel("时间线缩放")
                        .accessibilityValue("\(Int((timelineZoom * 100).rounded()))%")
                    Button { enqueueTimelineZoom(scaleBy: 1.5) } label: {
                        AppLineIcon(kind: .plus, size: 14).frame(width: 28, height: 28)
                    }
                    .buttonStyle(EditorTimelineControlButtonStyle())
                    .foregroundStyle(EditorTheme.secondaryText)
                    .disabled(timelineZoom >= maximumTimelineZoom)
                    .help(timelineZoom >= maximumTimelineZoom
                        ? appLocalized("已达到最大缩放")
                        : appLocalized("放大时间线，精确查看片段"))
                    .accessibilityLabel("放大时间线")
                }
            }
        }
        .padding(.horizontal, 10)
        .frame(height: timelineControlsHeight)
    }




    /// Mockup `.tb`: a flat 28pt key, 12.5pt label beside a 16pt glyph. An
    /// engaged toggle is told by its accent ink alone.
    private func timelineBarButton(
        _ title: String,
        icon: AppLineIcon.Kind,
        isOn: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                AppLineIcon(kind: icon, size: 16)
                if !layout.iconOnlyTimelineControls {
                    Text(appLocalized(title)).lineLimit(1).fixedSize()
                }
            }
            .font(.appUI(size: 12.5, weight: .medium))
            .foregroundStyle(timelineToggleInk(isOn))
            .padding(.horizontal, layout.iconOnlyTimelineControls ? 6 : 9)
            .frame(minWidth: 28)
            .frame(height: 28)
            .contentShape(Rectangle())
        }
        .buttonStyle(EditorTimelineControlButtonStyle())
    }

    /// Mockup `.seg`: a 2pt well (fill) with a raised thumb for the choice.
    private func timelineSegment<Option: Equatable>(
        _ options: [(title: String, icon: AppLineIcon.Kind, value: Option, help: String, id: String)],
        selection: Option,
        namespaceID: String,
        select: @escaping (Option) -> Void
    ) -> some View {
        HStack(spacing: 0) {
            ForEach(options.indices, id: \.self) { index in
                let option = options[index]
                let selected = option.value == selection
                Button {
                    guard !selected else { return }
                    select(option.value)
                } label: {
                    HStack(spacing: 6) {
                        AppLineIcon(kind: option.icon, size: 16)
                        if !layout.iconOnlyTimelineControls {
                            Text(appLocalized(option.title)).lineLimit(1).fixedSize()
                        }
                    }
                    .font(.appUI(size: 13, weight: .medium))
                    .foregroundStyle(selected ? EditorTheme.primaryText : EditorTheme.secondaryText)
                    .padding(.horizontal, layout.iconOnlyTimelineControls ? 6 : 10)
                    .frame(minWidth: 28)
                    .frame(height: 28)
                    .contentShape(Rectangle())
                    .background {
                        if selected {
                            RoundedRectangle(cornerRadius: 7, style: .continuous)
                                .fill(EditorTheme.segmentThumb)
                                .shadow(color: .black.opacity(0.08), radius: 1, y: 1)
                                .overlay(
                                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                                        .strokeBorder(EditorTheme.chrome(0.075), lineWidth: 0.5)
                                )
                                .matchedGeometryEffect(id: namespaceID, in: displayModeSelection)
                        }
                    }
                }
                .buttonStyle(.plain)
                .help(appLocalized(option.help))
                .accessibilityLabel(appLocalized(option.title))
                .accessibilityAddTraits(selected ? .isSelected : [])
                .accessibilityIdentifier(option.id)
            }
        }
        .padding(2)
        .fixedSize()
        .background(EditorTheme.controlWell, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        .accessibilityElement(children: .contain)
    }

    /// 选择 (A) / 切割 (B). Cut splits the clip under the click, then the
    /// tool stays until A or Esc.
    private var timelineToolPicker: some View {
        timelineSegment(
            [
                (title: "选择", icon: .select, value: EditorTimelineTool.select,
                 help: "选择（A）：点选、拖动移动、拖两端修剪", id: "editor.timeline.tool.select"),
                (title: "切割", icon: .scissors, value: EditorTimelineTool.cut,
                 help: "切割（B）：点哪切哪，可以连续切；按 A 或 Esc 回到选择", id: "editor.timeline.tool.cut"),
            ],
            selection: timelineTool,
            namespaceID: "timeline-tool"
        ) { tool in
            setTimelineTool(tool)
        }
        .accessibilityLabel(appLocalized("时间线工具"))
    }

    private var timelineDisplayModePicker: some View {
        timelineSegment(
            [
                (title: "画面", icon: .image, value: false,
                 help: "片段显示画面缩略图与波形", id: "editor.timeline.display.film"),
                (title: "波形", icon: .waveform, value: true,
                 help: "片段显示放大的音频波形", id: "editor.timeline.display.waveform"),
            ],
            selection: usesWaveformClips,
            namespaceID: "display-mode"
        ) { waveform in
            if gestureOwnership.activeIntent != nil || editorStore.interaction != nil {
                cancelActiveTimelineGesture()
            }
            withAnimation(SpringMotion.standard) { usesWaveformClips = waveform }
        }
        .accessibilityLabel("片段显示方式")
    }

    var timelineLabels: some View {
        VStack(spacing: 0) {
            timelineTrackManager
                .frame(height: timelineRulerHeight)
                .timelineRowDivider(strong: true)
            ForEach(upperLanes, id: \.self) { lane in postLaneLabel(lane) }
                .transaction { $0.animation = nil }
            VStack(spacing: 0) {
                timelineLabel("主轨道", symbol: "film.fill", tint: EditorConsole.Track.primary.stroke,
                    height: primaryTimelineHeight, emphasized: true)
            }
            .mainTrackHairlines()
            if showsCameraSyncTimeline {
                timelineLabel(
                    "摄像同步",
                    symbol: "waveform.path.ecg",
                    tint: EditorConsole.Track.cameraSync.stroke,
                    height: cameraSyncTimelineHeight)
                .transition(.timelineLane)
            }
            if showsZoomTimeline {
                optionalTimelineLabel(
                    "缩放",
                    tint: EditorConsole.Track.zoom.stroke,
                    height: zoomTimelineHeight,
                    track: .zoom
                )
            }
            if showsScreenMotionTimeline {
                optionalTimelineLabel(
                    "3D 运镜",
                    tint: EditorConsole.Track.screenMotion.stroke,
                    height: motionTimelineHeight,
                    track: .screenMotion
                )
            }
            if showsCameraMotionTimeline {
                optionalTimelineLabel(
                    "摄像运动",
                    tint: EditorConsole.Track.cameraMotion.stroke,
                    height: motionTimelineHeight,
                    track: .cameraMotion
                )
            }
            ForEach(lowerLanes, id: \.self) { lane in postLaneLabel(lane) }
                .transaction { $0.animation = nil }
        }
        .background(Color.clear)
    }

    func timelineLabel(
        _ title: String,
        symbol: String,
        tint: Color,
        height: CGFloat,
        count: Int? = nil,
        emphasized: Bool = false) -> some View {
        EditorTimelineLaneLabel(title: title, symbol: symbol, tint: tint,
                                collapsed: timelineLabelsCollapsed, count: count,
                                emphasized: emphasized)
            .frame(height: height)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(String(format: appLocalized("%@轨道"), appLocalized(title)))
            .accessibilityAddTraits(.isHeader)
    }

    func timelineCanvas(width: CGFloat, duration: TimeInterval) -> some View {
        let cutX = snappedCutX(width: width, duration: duration)
        return ZStack(alignment: .topLeading) {
            Color.clear
                .frame(width: width, height: timelineDocumentHeight)
                .contentShape(Rectangle())
                .gesture(timelineMarqueeGesture(width: width, duration: duration))
            VStack(spacing: 0) {
                timelineRuler(width: width, duration: duration, cutX: cutX)
                    .timelineRowDivider(strong: true)
                ForEach(upperLanes, id: \.self) { lane in
                    addedLaneTimeline(lane, width: width, duration: duration)
                        .editorTimelineEdits()
                }
                .transaction { $0.animation = nil }
                mainClipTimeline(width: width, duration: duration)
                    .editorTimelineEdits()
                    .overlay(alignment: .topLeading) { mainTrackDropMarker(width: width, duration: duration) }
                    .mainTrackHairlines()
                    .zIndex(primaryVisualTransferTarget == nil ? 0 : 10)
                if showsCameraSyncTimeline {
                    cameraSyncTimeline(width: width, duration: duration)
                        .editorTimelineEdits()
                        .transition(.timelineLane)
                }
                if showsZoomTimeline {
                    zoomTimeline(width: width, duration: duration)
                        .editorTimelineEdits()
                        .transition(.timelineLane)
                }
                if showsScreenMotionTimeline {
                    motionTimeline(
                        track: .screen,
                        clips: screenMotionTimelineClips,
                        width: width,
                        duration: duration
                    )
                    .editorTimelineEdits()
                    .transition(.timelineLane)
                }
                if showsCameraMotionTimeline {
                    motionTimeline(
                        track: .camera,
                        clips: cameraMotionTimelineClips,
                        width: width,
                        duration: duration
                    )
                    .editorTimelineEdits()
                    .transition(.timelineLane)
                }
                ForEach(lowerLanes, id: \.self) { lane in
                    addedLaneTimeline(lane, width: width, duration: duration)
                        .editorTimelineEdits()
                }
                .transaction { $0.animation = nil }
            }

            timelineMarqueeOverlay().zIndex(25)
            primaryVisualTransferHint().zIndex(50)

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
                    .fill(EditorTheme.accent)
                    .frame(width: 1, height: primaryTimelineHeight)
                    .offset(x: cutX - 0.5, y: primaryLaneTop)
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

            primarySeamMergeTip(width: width, duration: duration)
                .zIndex(32)

            timelineCutToolOverlay(width: width, duration: duration)

        }
        .frame(width: width, height: timelineDocumentHeight, alignment: .topLeading)
        .coordinateSpace(name: editorTimelineDocumentCoordinateSpace)
        .onDrop(of: EditorMediaDrag.types, delegate: TimelineMediaDropDelegate(
            inspect: { item in recordingDropPreview.begin(item: item,
                project: editorStore.project, durations: sourceDurations) },
            update: updateMediaDrop, exit: clearMediaDrop,
            prepare: { point in prepareMediaDrop(at: point, width: width, duration: duration) },
            failed: { onError(appLocalized("无法读取拖入的素材，请重新拖入。")) }
        ))
        .onDisappear { clearMediaDrop() }
        .contentShape(Rectangle())
        .contextMenu { timelineContextMenu() }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("时间线")
        .accessibilityValue(String(format: appLocalized("播放头位于 %@"), timelineTimestamp(playbackTime)))
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
            Color.clear
                .contentShape(Rectangle())
                .gesture(timelineRulerGesture(width: width, duration: duration))
            // The ruler is a small, viewport-bounded drawing. Rendering it in
            // the current display pass avoids the blank asynchronous frame
            // that used to appear while its size changed during zoom.
            EditorRulerTicks(
                width: width, duration: duration, preparedRange: preparedRange,
                scaleLayers: scaleLayers, labelStep: labelStep
            )
            .equatable()
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
                AppLineIcon(kind: .scissors, size: 16)
                    .font(.appUI(size: 10, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 18, height: 18)
                    .background(Circle().fill(EditorTheme.accent))
                    .offset(x: cutX - 9, y: timelineRulerHeight - 20)
                    .allowsHitTesting(false)
                    .zIndex(31)
            }
        }
        .frame(width: width, height: timelineRulerHeight)
        .overlay(alignment: .topLeading) {
            ZStack(alignment: .topLeading) {
                recordingMarkerRuler(width: width, duration: duration, visibleRange: visibleTimeRange)
            }
            .frame(width: width, height: timelineRulerHeight, alignment: .topLeading)
        }
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
            MainActor.assumeIsolated {
                timelineViewportUpdate.submit { [weak scrollView] in
                    guard let scrollView else { return }
                    updateTimelineVisibleDocumentRange(from: scrollView)
                }
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
        timelineViewportUpdate.cancel()
        if let timelineBoundsObservation {
            NotificationCenter.default.removeObserver(timelineBoundsObservation)
            self.timelineBoundsObservation = nil
        }
    }

    func timelineRulerGesture(width: CGFloat, duration: TimeInterval) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .named(editorTimelineDocumentCoordinateSpace))
            .onChanged { value in
                if rulerPress == nil {
                    let progress = min(max(playbackController.outputTime / max(duration, 0.001), 0), 1)
                    // Use the live scroll bounds for pointer input. The drawing
                    // range can still be on its initial bucket during attachment.
                    let visibleRange = timelineScrollView.flatMap { scroll -> ClosedRange<CGFloat>? in
                        let bounds = scroll.contentView.bounds
                        return bounds.width > 1 ? bounds.minX...bounds.maxX : nil
                    } ?? (0...width)
                    rulerPress = EditorTimelineRulerPress(
                        start: value.startLocation,
                        playheadX: CGFloat(progress) * width,
                        visibleRange: visibleRange
                    )
                }
                if case let .playhead(offset) = rulerPress {
                    guard gestureOwnership.activeIntent == .scrub || Self.isTimelinePointerDrag(value.translation),
                          beginTimelineGesture(.scrub) else { return }
                    EditorDragFrameCoalescer.shared.submit {
                        guard gestureOwnership.activeIntent == .scrub else { return }
                        playbackController.updateScrubbing(to: rulerTime(atX: value.location.x + offset,
                                                                       width: width, duration: duration))
                    }
                } else {
                    updateTimelineMarquee(value, width: width, duration: duration)
                }
            }
            .onEnded { value in
                guard let press = rulerPress else { return }
                defer { rulerPress = nil }
                switch press {
                case let .playhead(offset):
                    EditorDragFrameCoalescer.shared.flush()
                    guard gestureOwnership.activeIntent == .scrub else { return }
                    playbackController.updateScrubbing(to: rulerTime(atX: value.location.x + offset,
                                                                   width: width, duration: duration))
                    playbackController.endScrubbing()
                    endTimelineGesture(.scrub)
                case .background:
                    finishTimelineBackgroundPress(value, width: width, duration: duration) { point in
                        guard beginTimelineGesture(.scrub) else { return }
                        playbackController.seek(to: rulerTime(atX: point.x, width: width, duration: duration), pausing: true)
                        endTimelineGesture(.scrub)
                    }
                }
            }
    }

    private func rulerTime(atX x: CGFloat, width: CGFloat, duration: TimeInterval) -> TimeInterval {
        let time = EditorTimelineMath.clampedTime(atX: Double(x), width: Double(width), duration: duration)
        return magneticTime(snappedTimelineTime(time), width: width, duration: duration)
    }

    func primarySegmentLabel(
        segment: ResolvedRecordingSegment,
        emphasis: EditorTimelineClipEmphasis,
        filmstripVisibleRange: ClosedRange<CGFloat>,
        filmstripPriorityRange: ClosedRange<CGFloat>
    ) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(EditorConsole.Track.primary.primaryTimelineSurface(emphasis))
            GeometryReader { geometry in
                let bandHeight = showsClipWaveforms
                    ? geometry.size.height * EditorTimelineClipGeometry.waveformBandFraction : 0
                VStack(spacing: 0) {
                    // Keep the filmstrip's identity and decoded frames across
                    // mode changes. The audio band never covers the picture.
                    Group {
                        if let media = segment.media {
                            // An inserted video shows its own frames, tinted as video.
                            InsertedMediaFilmstrip(media: media, sourceStart: segment.sourceStart,
                                                   sourceDuration: segment.sourceDuration,
                                                   visibleRange: filmstripVisibleRange,
                                                   priorityRange: filmstripPriorityRange,
                                                   isEnabled: !playbackController.isPlaying
                                                       && editorStore.interaction == nil
                                                       && gestureOwnership.activeIntent == nil)
                        } else {
                            EditorTimelineFilmstrip(mediaSession: mediaSession, sourceID: segment.sourceID,
                                sourceStart: segment.sourceStart, sourceDuration: segment.sourceDuration,
                                visibleRange: filmstripVisibleRange,
                                priorityRange: filmstripPriorityRange,
                                isEnabled: !usesWaveformClips && !playbackController.isPlaying
                                    && editorStore.interaction == nil && gestureOwnership.activeIntent == nil)
                        }
                    }
                    .frame(height: geometry.size.height - bandHeight)
                    if showsClipWaveforms {
                        Rectangle()
                            .fill(Color.clear)
                            .frame(height: bandHeight)
                            .overlay(alignment: .top) {
                                Rectangle().fill(EditorTheme.chrome(0.10)).frame(height: 0.5)
                            }
                    }
                }
                // Film and waveform swap in sequence: the outgoing layer is
                // gone before the other arrives, so the picture never shows
                // through the growing waveform.
                // 画面 → 波形: the frames lift away and soften, then the
                // sound rises to fill the clip. 波形 → 画面 runs backwards: the
                // sound sinks into its band and the frames settle down into place.
                .opacity(usesWaveformClips ? 0 : 1)
            }
            if usesWaveformClips && !showsClipWaveforms {
                // Waveform view of a silent recording: say so instead of
                // leaving an empty box that looks unfinished.
                HStack(spacing: 5) {
                    AppLineIcon(kind: .waveform, size: 12)
                    Text("没有声音")
                        .font(.appUI(size: 12, weight: .medium))
                }
                .foregroundStyle(EditorTheme.secondaryText)
                .lineLimit(1)
                .transition(.opacity)
                .allowsHitTesting(false)
            }
        }
            .animation(EditorSwapTiming.crossfade, value: usesWaveformClips)
            .overlay(alignment: .top) {
                if segment.media == nil, let color = RecordingSourcePresentation.color(segment.sourceID, in: editorStore.previewProject) {
                    Rectangle().fill(color).frame(height: 3).allowsHitTesting(false)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .padding(EditorTimelineClipGeometry.contentInset)
            // Mockup: the main track is the one picture lane; selection is
            // the accent frame and end handles, hover only brightens.
            .brightness(emphasis == .hovered ? 0.03 : 0)
            .overlay {
                EditorTimelineClipSelectionChrome(cornerRadius: 8, emphasis: emphasis, width: 100)
            }
    }

    /// Mockup `.mc .nm`: the piece's name on a dark chip at the top left.
    /// `sourceOrdinal` is counted once for the whole lane. Asking each chip to
    /// work out its own place rebuilt the lane's segment array and rescanned it
    /// per clip on every body pass, so the cost grew with the number of clips —
    /// which is why importing a second recording made dragging and zooming the
    /// timeline visibly worse.
    func primarySegmentNameChip(index: Int, segment: ResolvedRecordingSegment,
                                segmentsCount: Int, sourceOrdinal: Int?) -> some View {
        let project = editorStore.previewProject
        let color = RecordingSourcePresentation.color(segment.sourceID, in: project)
        let title = color == nil
            ? (segmentsCount == 1 ? appLocalized("屏幕录制") : String(format: appLocalized("第 %lld 段"), Int64(index + 1)))
            : String(format: appLocalized("%@ · 第 %ld 段"),
                     RecordingSourcePresentation.name(segment.sourceID, in: project),
                     Int64(sourceOrdinal ?? (index + 1)))
        return HStack(spacing: 5) {
            if let color {
                RoundedRectangle(cornerRadius: 2.5).fill(color).frame(width: 7, height: 7)
                    .overlay { RoundedRectangle(cornerRadius: 2.5).strokeBorder(.white.opacity(0.55), lineWidth: 1) }
            }
            Text(title).lineLimit(1)
        }
        .font(.appUI(size: color == nil ? 11.5 : 11, weight: .medium)).foregroundStyle(.white)
        .padding(.horizontal, 6).frame(height: color == nil ? 18 : 17)
        .background(Color.black.opacity(color == nil ? 0.28 : 0.32), in: RoundedRectangle(cornerRadius: 5))
        .padding(.leading, color == nil ? 7 : 6).padding(.top, 6)
        .opacity(usesWaveformClips ? 0 : 1).allowsHitTesting(false).accessibilityHidden(true)
    }

    /// A small, quiet length tag in the clip's corner: "4.7s" instead of a
    /// heavy "0:04.69" pill sitting on the picture.
    private func primaryDurationBadge(_ duration: TimeInterval) -> some View {
        Text(timelineClipLength(duration))
            .font(.appUI(size: 10, weight: .semibold)).monospacedDigit()
            .lineLimit(1)
            .foregroundStyle(usesWaveformClips ? EditorTheme.secondaryText : .white)
            .padding(.horizontal, 5).padding(.vertical, 1.5)
            .background(usesWaveformClips ? EditorTheme.panelRaised : .black.opacity(0.64), in: Capsule())
            .animation(EditorSwapTiming.crossfade, value: usesWaveformClips)
            .accessibilityHidden(true)
    }

    func primarySegmentTitle(
        index: Int,
        segmentsCount: Int
    ) -> String {
        segmentsCount == 1 ? appLocalized("屏幕片段") : String(format: appLocalized("片段 %d"), index + 1)
    }



    func primarySegmentView(
        index: Int,
        segment: ResolvedRecordingSegment,
        segmentsCount: Int,
        sourceOrdinal: Int?,
        startX: CGFloat,
        segmentWidth: CGFloat,
        isSelected: Bool,
        emphasis: EditorTimelineClipEmphasis,
        laneWidth: CGFloat,
        duration: TimeInterval,
        filmstripDocumentRange: ClosedRange<CGFloat>
    ) -> some View {
        let isMoving = primaryReorderDraft?.segmentIDs.contains(segment.id) == true || draggedPrimarySegmentID == segment.id
        let floatingOffset = primaryFloatingTranslation(for: segment.id, width: laneWidth, duration: duration)
        let filmstripOrigin = startX + EditorTimelineClipGeometry.contentInset + floatingOffset
        let filmstripVisibleRange = (filmstripDocumentRange.lowerBound - filmstripOrigin)...(filmstripDocumentRange.upperBound - filmstripOrigin)
        let viewport = clampedTimelineVisibleDocumentRange(width: laneWidth)
        let filmstripPriorityRange = (viewport.lowerBound - filmstripOrigin)...(viewport.upperBound - filmstripOrigin)
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

            if segment.media == nil, segmentWidth > 72 {
                primarySegmentNameChip(index: index, segment: segment,
                                       segmentsCount: segmentsCount, sourceOrdinal: sourceOrdinal)
            }

            // One fixed hit surface owns the press through release. The former
            // body/handle stacks centered the smaller body inside the full clip,
            // shifting the edge targets and letting a move steal a trim.
            Color.clear
                .frame(width: hitWidth, height: primaryVideoHeight, alignment: .topLeading)
                .contentShape(Rectangle())
                .gesture(primarySegmentPointerGesture(segment: segment, laneWidth: laneWidth, duration: duration))
                .contextMenu {
                    EditorDeferredMenuContent { primarySegmentContextMenu(segment: segment) }
                }
                .onContinuousHover { phase in
                    switch phase {
                    case let .active(point):
                        hoveredPrimarySegmentID = segment.id
                        let localX = point.x + hitRange.lowerBound
                        if primaryPointerSession == nil, !isOptionHeld, !isCutToolActive {
                            let edge = primaryTrimEdge(at: localX, segmentWidth: segmentWidth)
                            (edge == nil ? NSCursor.arrow : NSCursor.resizeLeftRight).set()
                        }
                    case .ended:
                        if hoveredPrimarySegmentID == segment.id { hoveredPrimarySegmentID = nil }
                        if primaryPointerSession == nil, !isOptionHeld, !isCutToolActive { NSCursor.arrow.set() }
                    }
                }
                .offset(x: hitRange.lowerBound)

        }
        .frame(width: segmentWidth, height: primaryVideoHeight, alignment: .topLeading)
        .contentShape(.interaction, Path(CGRect(
            x: hitRange.lowerBound, y: 0,
            width: hitWidth, height: primaryVideoHeight
        )))
        .offset(x: startX + floatingOffset, y: draggedPrimarySegmentID == segment.id ? primaryVisualTransferOffsetY : 0)
        .editorClipDragFeedback(isMoving)
        .transition(.identity)
        .zIndex(isMoving ? 10 : isSelected ? 3 : emphasis == .hovered ? 1 : 0)
        .help(segment.sourceID == RecordingSource.primaryID || segment.media != nil
            ? "主片段 \(index + 1) · \(timelineTimestamp(segment.outputDuration)) · ⇧ 连选 · ⌘ 增减选择 · ⌥ 单击切分"
            : "\(RecordingSourcePresentation.name(segment.sourceID, in: editorStore.project)) · \(timelineTimestamp(segment.sourceStart)) – \(timelineTimestamp(segment.sourceEnd))")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            primarySegmentTitle(
                index: index,
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

    /// Each clip's place within its own recording, counted once for the lane.
    func primarySourceOrdinals(_ segments: [ResolvedRecordingSegment]) -> [UUID: Int] {
        var ordinals: [UUID: Int] = [:]
        var seen: [UUID: Int] = [:]
        for segment in segments where segment.media == nil {
            let next = (seen[segment.sourceID] ?? 0) + 1
            seen[segment.sourceID] = next
            ordinals[segment.id] = next
        }
        return ordinals
    }

    func mainClipTimeline(width: CGFloat, duration: TimeInterval) -> some View {
        let segments = primaryDisplaySegments
        let ordinals = primarySourceOrdinals(segments)
        // Splitting selects the new right-hand piece. Keep that target alive
        // even while the native viewport is attaching or changing bounds.
        let retainedIDs = Set([selectedPrimarySegmentID, draggedPrimarySegmentID,
                           primaryTrimDraft?.segmentID, primaryRetimeDraft?.segmentID]
            .compactMap { $0 }).union(primaryReorderDraft?.segmentIDs ?? [])
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
                isFocused: focusedTimelineLane == .primary
            )
            ForEach(visibleSegments, id: \.clip.id) { item in
                let index = item.index
                let segment = item.clip
                let startX = CGFloat(segment.outputStart / max(duration, 0.001)) * width
                let segmentWidth = max(
                    CGFloat(segment.outputDuration / max(duration, 0.001)) * width,
                    1
                )
                let isSelected = editorStore.scenePresetPreviewSegmentIDs?.contains(segment.id) ?? selectedPrimarySegmentIDs.contains(segment.id)
                let isHovered = hoveredPrimarySegmentID == segment.id
                let isEditing = primaryReorderDraft?.segmentIDs.contains(segment.id) == true
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
                    sourceOrdinal: ordinals[segment.id],
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

            primarySeams(width: width, duration: duration)
                .allowsHitTesting(false)

            ForEach(visibleSegments, id: \.clip.id) { item in
                let segment = item.clip
                let segmentWidth = CGFloat(segment.outputDuration / max(duration, 0.001)) * width
                if editorStore.scenePresetPreviewSegmentIDs?.contains(segment.id) == true, segmentWidth > 80 {
                    Text("待应用").font(.appUI(size: 10, weight: .medium))
                        .foregroundStyle(EditorTheme.accent).padding(.horizontal, 5).padding(.vertical, 2)
                        .background(EditorTheme.panelRaised, in: RoundedRectangle(cornerRadius: 4))
                        .offset(x: CGFloat(segment.outputStart / max(duration, 0.001)) * width + segmentWidth - 48, y: 8)
                        .zIndex(31).allowsHitTesting(false)
                } else if segmentWidth > 64 {
                    primaryDurationBadge(segment.outputDuration)
                        .frame(width: 56, alignment: .trailing)
                        .offset(x: CGFloat(segment.outputStart / max(duration, 0.001)) * width
                            + segmentWidth - 64
                            + primaryFloatingTranslation(for: segment.id, width: width, duration: duration),
                            y: 8 + (draggedPrimarySegmentID == segment.id ? primaryVisualTransferOffsetY : 0))
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
                EditorConsole.Track.cameraSync.stroke.opacity(0.30),
                style: StrokeStyle(lineWidth: 1, dash: [4, 4])
            )
            .allowsHitTesting(false)

            cameraSyncCurvePath(
                width: width,
                duration: duration,
                displayRange: displayRange
            )
            .stroke(EditorConsole.Track.cameraSync.stroke, style: StrokeStyle(lineWidth: 2, lineJoin: .round))
            .allowsHitTesting(false)

            Text(String(format: appLocalized("基准 %@"), cameraSyncOffsetLabel(cameraSyncBaselineOffset)))
                .font(.appUI(size: 10, weight: .semibold, design: .monospaced))
                .foregroundStyle(EditorConsole.Track.cameraSync.text)
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background(EditorTheme.panelRaised.opacity(0.92), in: Capsule())
                .offset(x: 7, y: 5)
                .allowsHitTesting(false)

            if cameraSyncAnchors.isEmpty {
                Text("双击添加同步点 · 单击空白取消选中")
                    .font(.appUI(size: 10))
                    .foregroundStyle(.secondary.opacity(0.8))
                    .offset(x: 104, y: 8)
                    .allowsHitTesting(false)
            }

            ForEach(cameraSyncAnchors) { persistedAnchor in
                let anchor = cameraSyncAnchorDrag?.original.id == persistedAnchor.id
                    ? cameraSyncAnchorDrag?.draft ?? persistedAnchor
                    : persistedAnchor
                if let sourceID = cameraSyncSourceID {
                    ForEach(timelineMap?.outputPositions(forSourceTime: anchor.sourceTime, sourceID: sourceID) ?? []) { occurrence in
                        let x = CGFloat(occurrence.time / max(duration, 0.001)) * width
                        let y = cameraSyncY(offset: anchor.offset, displayRange: displayRange)
                        cameraSyncAnchorMarker(anchor: anchor, occurrenceID: occurrence.segmentID,
                            x: x, y: y, width: width, duration: duration)
                    }
                }
            }

            if let selectedCameraSyncAnchorID,
               let anchor = presentedCameraSyncAnchor(id: selectedCameraSyncAnchorID),
               let outputTime = cameraSyncOutputTime(forSourceTime: anchor.sourceTime) {
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
            sourceID: cameraSyncSourceID,
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
        occurrenceID: UUID,
        x: CGFloat,
        y: CGFloat,
        width: CGFloat,
        duration: TimeInterval
    ) -> some View {
        let isSelected = selectedCameraSyncAnchorID == anchor.id
        return ZStack(alignment: .topLeading) {
            if !isSelected {
                Text(cameraSyncOffsetLabel(cameraSyncBaselineOffset + anchor.offset))
                    .font(.appUI(size: 10, weight: .semibold, design: .monospaced))
                    .foregroundStyle(EditorConsole.Track.cameraSync.text)
                    .frame(width: 70)
                    .offset(x: min(max(x - 35, 0), max(width - 70, 0)), y: 3)
                    .allowsHitTesting(false)
            }

            ZStack {
                RoundedRectangle(cornerRadius: 2, style: .continuous)
                    .fill(isSelected ? Color.white : editorCameraSyncClip)
                    .overlay {
                        RoundedRectangle(cornerRadius: 2, style: .continuous)
                            .stroke(EditorConsole.Track.cameraSync.stroke, lineWidth: isSelected ? 2 : 1)
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
                    occurrenceID: occurrenceID,
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
                .font(.appUI(size: 10, weight: .bold, design: .monospaced))
                .foregroundStyle(EditorConsole.Track.cameraSync.text)
            Button { nudgeCameraSyncAnchor(id: anchor.id, by: -cameraSyncAdjustmentStep) } label: {
                Text("延\(cameraSyncAdjustmentStepMilliseconds)")
                    .font(.appUI(size: 10, weight: .semibold))
            }
            .buttonStyle(.editorQuiet)
            .help("画面延后 \(cameraSyncAdjustmentStepMilliseconds)ms，并自动试听")
            Button { nudgeCameraSyncAnchor(id: anchor.id, by: cameraSyncAdjustmentStep) } label: {
                Text("提\(cameraSyncAdjustmentStepMilliseconds)")
                    .font(.appUI(size: 10, weight: .semibold))
            }
            .buttonStyle(.editorQuiet)
            .help("画面提前 \(cameraSyncAdjustmentStepMilliseconds)ms，并自动试听")
            Button(role: .destructive) { removeCameraSyncAnchor(id: anchor.id) } label: {
                AppLineIcon(kind: .trash, size: 16)
            }
            .buttonStyle(.editorDestructiveIcon)
            .help("删除同步点")
        }
        .padding(.horizontal, 6)
        .frame(height: 34)
        .background(
            Color.black.opacity(0.84),
            in: RoundedRectangle(cornerRadius: 6, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .stroke(editorCameraSyncClip.opacity(0.45), lineWidth: 0.75)
        }
    }

    func cameraSyncAnchorGesture(
        anchor: MediaSyncAnchor,
        occurrenceID: UUID,
        width: CGFloat,
        duration: TimeInterval
    ) -> some Gesture {
        DragGesture(
            minimumDistance: 0,
            coordinateSpace: .named(editorTimelineDocumentCoordinateSpace)
        )
        .onChanged { value in
                EditorDragFrameCoalescer.shared.submit {
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
}
        .onEnded { value in
                EditorDragFrameCoalescer.shared.flush()
            defer { cameraSyncAnchorDrag = nil }
            guard hypot(value.translation.width, value.translation.height) >= 2,
                  let draft = cameraSyncAnchorDrag?.draft else {
                if let outputTime = cameraSyncOutputTime(forSourceTime: anchor.sourceTime, inSegment: occurrenceID) {
                    seekTimeline(to: outputTime)
                }
                return
            }
            if replaceCameraSyncAnchor(draft, actionName: "调整摄像头同步点"),
               let outputTime = cameraSyncOutputTime(forSourceTime: draft.sourceTime, inSegment: occurrenceID) {
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
        if let outputTime = cameraSyncOutputTime(forSourceTime: sourceTime) {
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
        guard let position = timelineMap.sourcePosition(atOutputTime: outputTime),
              position.sourceID == cameraSyncSourceID else { return nil }
        return position.time
    }

    func replaceCameraSyncAnchor(
        _ anchor: MediaSyncAnchor,
        actionName: String
    ) -> Bool {
        var project = editorStore.project
        guard let sourceID = cameraSyncSourceID, var media = project.source(sourceID)?.media, var camera = media.camera else { return false }
        if let index = camera.syncAnchors.firstIndex(where: { $0.id == anchor.id }) {
            camera.syncAnchors[index] = anchor
        } else {
            camera.syncAnchors.append(anchor)
        }
        media.camera = camera
        project.setMedia(media, for: sourceID)
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
           let outputTime = cameraSyncOutputTime(forSourceTime: anchor.sourceTime) {
            playbackController.scheduleCameraSyncAudition(at: outputTime)
        }
    }
}

/// The ruler's ticks and labels as an Equatable value view: only a zoom,
/// scroll or length change redraws it, never a clip drag.
struct EditorRulerTicks: View, Equatable {
    let width: CGFloat
    let duration: TimeInterval
    let preparedRange: ClosedRange<CGFloat>
    let scaleLayers: [EditorTimelineRulerScaleLayer]
    let labelStep: TimeInterval?

    var body: some View {
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
                                Text(Self.label(tick.time))
                                    .font(.appUI(size: 10, weight: .medium)).monospacedDigit()
                                    .foregroundStyle(EditorTheme.tertiaryText),
                                at: CGPoint(x: labelX, y: 10),
                                anchor: .topLeading
                            )
                        }
                    } else {
                        minorPath.move(to: CGPoint(x: x, y: size.height - 7))
                        minorPath.addLine(to: CGPoint(x: x, y: size.height - 2))
                    }
                }
                layerContext.stroke(majorPath, with: .color(EditorTheme.chrome(0.20)), lineWidth: 1)
                layerContext.stroke(minorPath, with: .color(EditorTheme.chrome(0.09)), lineWidth: 1)
            }
        }
    }

    /// Ruler marks drop zero hundredths: "0:18", but "0:18.50".
    static func label(_ time: TimeInterval) -> String {
        let centiseconds = max(Int((time * 100).rounded()), 0)
        let minutes = centiseconds / 6_000
        let seconds = (centiseconds / 100) % 60
        let fraction = centiseconds % 100
        return fraction == 0
            ? String(format: "%d:%02d", minutes, seconds)
            : String(format: "%d:%02d.%02d", minutes, seconds, fraction)
    }
}

/// Frames of a main-track inserted video across the part it plays, with its
/// name, in the video colour so it reads apart from the recording.
struct InsertedMediaFilmstrip: View {
    let media: InsertedMedia
    let sourceStart: TimeInterval
    let sourceDuration: TimeInterval
    let visibleRange: ClosedRange<CGFloat>
    let priorityRange: ClosedRange<CGFloat>
    let isEnabled: Bool

    var body: some View {
        GeometryReader { proxy in
            let tile = max(proxy.size.height * 16 / 9, 24)
            let count = min(max(Int(ceil(proxy.size.width / tile)), 1), 48)
            // Every HTML motion thumbnail is a WebKit snapshot taken on the
            // main thread through one shared page, so they can only be made
            // one at a time. Build the tiles on screen and leave the rest of
            // the clip's width empty: a clip wider than the viewport used to
            // queue up to 48 snapshots and freeze the window.
            let first = max(Int(floor(max(visibleRange.lowerBound, 0) / tile)), 0)
            let last = min(Int(ceil(min(visibleRange.upperBound, proxy.size.width) / tile)), count)
            ZStack(alignment: .topLeading) {
                EditorConsole.Track.video.soft
                if last > first {
                    ForEach(first..<last, id: \.self) { index in
                        let origin = CGFloat(index) * tile
                        InsertedMediaFrame(
                            media: media,
                            time: sourceStart + sourceDuration * (Double(index) + 0.5) / Double(count),
                            // Tiles under the playhead's neighbourhood render
                            // first; the rest wait for the window to settle.
                            isEnabled: isEnabled
                                && (origin + tile > priorityRange.lowerBound && origin < priorityRange.upperBound
                                    || visibleRange.contains(origin))
                        )
                        .frame(width: tile, height: proxy.size.height)
                        .clipped()
                        .offset(x: origin)
                    }
                }
            }
            .frame(width: proxy.size.width, alignment: .leading)
            .clipped()
            .overlay(EditorConsole.Track.video.fill.opacity(0.18))
            .overlay(alignment: .topLeading) {
                HStack(spacing: 4) {
                    EditorSymbol(media.motionPath == nil ? "film" : "sparkles", size: 9).font(.system(size: 9, weight: .semibold))
                    Text(media.name).font(.appUI(size: 10, weight: .semibold)).lineLimit(1)
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 6)
                .frame(height: 18)
                .background(Capsule().fill(EditorConsole.Track.video.stroke.opacity(0.9)))
                .padding(4)
            }
        }
    }
}

private struct InsertedMediaFrame: View {
    let media: InsertedMedia
    let time: TimeInterval
    /// False while playing, dragging or off screen. An already decoded picture
    /// stays on screen; only new work is withheld.
    let isEnabled: Bool
    @State private var image: NSImage?

    private var key: String {
        "\(media.motionPath ?? media.imagePath ?? media.path)|\(Int(time * 10))|" + String(describing: media.properties.sorted { $0.key < $1.key })
            + String(describing: media.elementEdits.sorted { $0.key < $1.key })
    }

    var body: some View {
        ZStack {
            EditorConsole.Track.video.soft
            if let image { Image(nsImage: image).resizable().aspectRatio(contentMode: .fill) }
        }
        .task(id: "\(isEnabled)|\(key)") {
            guard isEnabled else { return }
            if let motion = media.motionPath {
                // EDT-071: a live HTML motion shows its own page, with its
                // current fields, not the black stand-in.
                image = await InsertedMediaFrameCache.shared.motionFrame(key: key, path: motion, properties: media.properties,
                                                                         edits: media.elementEdits, time: time)
            } else if let path = media.imagePath {
                image = await InsertedMediaFrameCache.shared.imageFrame(path: path, time: time)
            } else {
                image = await InsertedMediaFrameCache.shared.frame(path: media.path, time: time)
            }
        }
    }
}

actor InsertedMediaFrameCache {
    static let shared = InsertedMediaFrameCache()
    private var frames: [String: NSImage] = [:]
    private let imageContext = CIContext(options: [.cacheIntermediates: false])
    /// One context for every motion thumbnail. Building a CIContext per frame
    /// stood up a whole GPU pipeline 48 times over for a single clip.
    @MainActor private static let motionContext = CIContext(options: [.cacheIntermediates: false])

    func imageFrame(path: String, time: TimeInterval) -> NSImage? {
        let key = "image:\(path)|\(Int(time * 10))"
        if let cached = frames[key] { return cached }
        guard let frame = ImageMediaFrameCache.shared.frame(at: ProjectFiles.url(path), time: time) else { return nil }
        let scale = min(240 / max(frame.extent.width, frame.extent.height), 1)
        let thumbnail = frame.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        guard let cg = imageContext.createCGImage(thumbnail, from: thumbnail.extent) else { return nil }
        let image = NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
        if frames.count > 600 { frames.removeAll() }
        frames[key] = image
        return image
    }

    func motionFrame(key: String, path: String, properties: [String: AnimationPropertyValue],
                     edits: [String: MotionElementEdit], time: TimeInterval) async -> NSImage? {
        if let cached = frames[key] { return cached }
        let resolved = ProjectFiles.resolve(path)
        let rendered = await Self.renderMotion(path: resolved, properties: properties, edits: edits, time: time)
        guard let rendered else { return nil }
        let image = NSImage(cgImage: rendered, size: NSSize(width: rendered.width, height: rendered.height))
        if frames.count > 600 { frames.removeAll() }
        frames[key] = image
        return image
    }

    @MainActor
    private static func renderMotion(path: String, properties: [String: AnimationPropertyValue],
                                     edits: [String: MotionElementEdit], time: TimeInterval) async -> CGImage? {
        guard let ci = await HTMLMotion.image(path: path, properties: properties, time: time,
                                              pixelSize: CGSize(width: 256, height: 144), edits: edits) else { return nil }
        let black = CIImage(color: CIColor(red: 0, green: 0, blue: 0)).cropped(to: ci.extent)
        return motionContext.createCGImage(ci.composited(over: black), from: ci.extent)
    }

    func frame(path: String, time: TimeInterval) async -> NSImage? {
        let key = "\(path)|\(Int(time * 10))"
        if let cached = frames[key] { return cached }
        let asset = AVURLAsset(url: ProjectFiles.url(path))
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 240, height: 240)
        generator.requestedTimeToleranceBefore = CMTime(seconds: 0.5, preferredTimescale: 600)
        generator.requestedTimeToleranceAfter = CMTime(seconds: 0.5, preferredTimescale: 600)
        guard let cg = try? await generator.image(at: CMTime(seconds: time, preferredTimescale: 600)).image else { return nil }
        let image = NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
        if frames.count > 600 { frames.removeAll() }
        frames[key] = image
        return image
    }
}

extension EditorTimelineView {
    /// Drop time on the main track, snapped to clip edges and the playhead.
    func mainTrackDropTime(atX x: CGFloat, width: CGFloat, duration: TimeInterval) -> TimeInterval {
        let raw = EditorTimelineMath.clampedTime(atX: Double(x), width: Double(width), duration: duration)
        return magneticTime(raw, width: width, duration: duration)
    }

    @ViewBuilder
    func mainTrackDropMarker(width: CGFloat, duration: TimeInterval) -> some View {
        if let x = mainTrackDropX {
            let time = mainTrackDropTime(atX: x, width: width, duration: duration)
            let markerX = CGFloat(time / max(duration, 0.001)) * width
            ZStack(alignment: .topLeading) {
                if let item = recordingDropPreview.item {
                    let ghostWidth = min(max(CGFloat((item.duration ?? duration / 5) / max(duration, 0.001)) * width, 100), 300)
                    let ghostX = min(markerX, max(width - ghostWidth, 0))
                    RoundedRectangle(cornerRadius: 8)
                        .fill(RecordingDesign.accentSoft)
                        .overlay { RoundedRectangle(cornerRadius: 8).strokeBorder(RecordingDesign.accent, style: StrokeStyle(lineWidth: 1.5, dash: [5, 4])) }
                        .overlay {
                            Text(item.label).font(.appUI(size: 12, weight: .medium)).lineLimit(1)
                                .foregroundStyle(RecordingDesign.accent).padding(.horizontal, 8)
                        }
                        .frame(width: ghostWidth, height: max(primaryTimelineHeight - 12, 0))
                        .offset(x: ghostX, y: 6)
                    Rectangle().fill(RecordingDesign.accent).frame(width: 2, height: max(primaryTimelineHeight - 4, 0))
                        .offset(x: markerX - 1, y: 2)
                    Circle().fill(RecordingDesign.accent).frame(width: 8, height: 8).offset(x: markerX - 4, y: -2)
                } else {
                Rectangle()
                    .fill(EditorTheme.accent)
                    .frame(width: 2, height: primaryTimelineHeight)
                    .offset(x: markerX - 1)
                Text(appLocalized("插入到这里"))
                    .font(.appUI(size: 10, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 7)
                    .frame(height: 18)
                    .background(Capsule().fill(EditorTheme.accent))
                    .offset(x: markerX + 4, y: 4)
                }
            }
            .allowsHitTesting(false)
        }
    }

    /// EDT-067: a 2 s black card on the main track at the playhead.
    func insertBlackAtPlayhead() {
        let source = sourceDurations
        guard !source.isEmpty else { return }
        playbackController.pause()
        let time = playbackTime
        Task { @MainActor in
            do { try await editorStore.insertBlackOnMainTrack(at: time, sourceDurations: source) }
            catch { onError(error.localizedDescription) }
        }
    }

    /// Videos, images and HTML motions go into the main track; audio, and
    /// anything else dropped there, goes on a layer of its own. The drop point
    /// and the marked span are all this has to say — the placement interface
    /// knows what to do with them.
    func insertAssetOnMainTrack(_ id: UUID, atX x: CGFloat, width: CGFloat, duration: TimeInterval,
                                sourceRange: ClosedRange<TimeInterval>? = nil) {
        let time = mainTrackDropTime(atX: x, width: width, duration: duration)
        editorStore.placeMediaAssetAt(id, time, lane: .mainTrack, sourceRange: sourceRange)
    }
}
