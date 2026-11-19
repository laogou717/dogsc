import RecorderCore
import SwiftUI

/// A small quiet glyph button in the ruler row's label cell.
private struct TimelineHeaderIconLabel: View {
    let kind: AppLineIcon.Kind
    var isPresented = false
    @State private var isHovered = false

    var body: some View {
        AppLineIcon(kind: kind, size: 13)
            .foregroundStyle(isHovered || isPresented ? EditorTheme.primaryText : EditorTheme.tertiaryText)
            .frame(width: 22, height: 22)
            .background(
                EditorTheme.chrome(isPresented ? EditorStateWash.open : isHovered ? EditorStateWash.hover : 0),
                in: RoundedRectangle(cornerRadius: EditorInterfaceRadius.control, style: .continuous)
            )
            .contentShape(RoundedRectangle(cornerRadius: EditorInterfaceRadius.control, style: .continuous))
            .appKeyboardFocus(in: RoundedRectangle(cornerRadius: EditorInterfaceRadius.control, style: .continuous))
            .onHover { isHovered = $0 }
            .animation(SpringMotion.micro, value: isHovered)
    }
}

/// One row of the track menu (mockup `.mi`): lane glyph in its hue, the
/// name, a grey count and a check. Hover fills the row with the accent.
private struct TimelineTrackMenuRow: View {
    let title: String
    let symbol: String
    let hue: Color
    let count: Int
    let isOn: Bool
    let isEnabled: Bool
    let help: String
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        let lit = isHovered && isEnabled
        Button(action: action) {
            HStack(spacing: 9) {
                EditorSymbol(symbol, size: 14)
                    .foregroundStyle(lit ? Color.white : hue)
                    .frame(width: 16, height: 16)
                    .saturation(isEnabled ? 1 : 0)
                Text(appLocalized(title))
                    .font(.appUI(size: 13))
                    .foregroundStyle(lit ? Color.white : EditorTheme.primaryText)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if count > 0 {
                    Text("\(count)")
                        .font(.appUI(size: 11.5, design: .monospaced))
                        .foregroundStyle(lit ? Color.white.opacity(0.85) : EditorTheme.tertiaryText)
                        .fixedSize()
                }
                AppLineIcon(kind: .check, size: 13)
                    .foregroundStyle(lit ? Color.white : EditorTheme.secondaryText)
                    .opacity(isOn ? 1 : 0)
                    .frame(width: 14)
            }
            .padding(.horizontal, 8)
            .frame(height: 30)
            .background(
                RoundedRectangle(cornerRadius: EditorInterfaceRadius.compact, style: .continuous)
                    .fill(lit ? EditorTheme.accent : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .opacity(isEnabled ? 1 : 0.42)
        .disabled(!isEnabled)
        .onHover { isHovered = $0 }
        .help(help)
        .accessibilityLabel(String(format: appLocalized("%@轨道"), appLocalized(title)))
        .accessibilityValue(appLocalized(isOn ? "轨道状态 · 显示" : "轨道状态 · 隐藏"))
        .accessibilityAddTraits(.isToggle)
    }
}

extension EditorTimelineView {

    /// The ruler row's label cell: one quiet layers glyph that opens the
    /// track menu, and a tiny collapse glyph at the far edge.
    var timelineTrackManager: some View {
        HStack(spacing: 0) {
            if timelineLabelsCollapsed {
                Button {
                    timelineLabelsCollapsed = false
                } label: {
                    TimelineHeaderIconLabel(kind: .chevron)
                }
                .buttonStyle(.plain)
                .help(appLocalized("展开轨道名称"))
                .accessibilityLabel(appLocalized("展开轨道名称"))
                .frame(maxWidth: .infinity)
            } else {
                trackManagerButton
                Spacer(minLength: 0)
                Button {
                    isTimelineTrackManagerPresented = false
                    timelineLabelsCollapsed = true
                } label: {
                    TimelineHeaderIconLabel(kind: .chevronLeft)
                }
                .buttonStyle(.plain)
                .help(appLocalized("收起轨道名称"))
                .accessibilityLabel(appLocalized("收起轨道名称"))
            }
        }
        // Centre the 22 pt glyph button on the lane icon column below.
        .padding(.leading, EditorTimelineLabelMetrics.inset - (22 - EditorTimelineLabelMetrics.icon) / 2)
        .padding(.trailing, 6)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var trackManagerButton: some View {
        Button {
            isTimelineTrackManagerPresented.toggle()
        } label: {
            TimelineHeaderIconLabel(kind: .layers, isPresented: isTimelineTrackManagerPresented)
        }
        .buttonStyle(.plain)
        .editorPopoverKeyboardEntry {
            isTimelineTrackManagerPresented = true
        }
        .editorPopover(
            isPresented: $isTimelineTrackManagerPresented,
            arrowEdge: .top
        ) {
            timelineTrackVisibilityPanel
        }
        .help(appLocalized("显示轨道"))
        .accessibilityLabel(appLocalized("显示轨道"))
        .accessibilityValue(String(format: appLocalized("%d 条显示"), visibleOptionalTrackCount))
    }

    private var visibleOptionalTrackCount: Int {
        var count = 0
        if visibleTracks.contains(.zoom) { count += 1 }
        if visibleTracks.contains(.screenMotion) { count += 1 }
        if visibleTracks.contains(.cameraMotion) { count += 1 }
        if !visibleTracks.intersection(.overlays).isEmpty, postLaneClipCount(.effects) > 0 { count += 1 }
        count += TimelinePostLane.allCases.filter {
            $0 != .effects && postLaneClipCount($0) > 0 && !isPostLaneHidden($0)
        }.count
        return count
    }

    /// True when some available lane is hidden, so "全部显示" has work to do.
    private var hasHiddenAvailableTrack: Bool {
        let tl = editorStore.previewProject.timeline
        if !visibleTracks.contains(.zoom) { return true }
        if !visibleTracks.contains(.screenMotion) { return true }
        if mediaSession.hasCameraVideo, !visibleTracks.contains(.cameraMotion) { return true }
        if !tl.mosaicClips.isEmpty, visibleTracks.intersection(.overlays).isEmpty { return true }
        return TimelinePostLane.allCases.contains {
            $0 != .effects && postLaneClipCount($0) > 0 && isPostLaneHidden($0)
        }
    }

    private func showAllTimelineTracks() {
        cancelActiveTimelineGesture()
        let tl = editorStore.previewProject.timeline
        withAnimation(SpringMotion.settle) {
            visibleTracks.insert(.zoom)
            visibleTracks.insert(.screenMotion)
            if mediaSession.hasCameraVideo { visibleTracks.insert(.cameraMotion) }
            if !tl.mosaicClips.isEmpty { visibleTracks.formUnion(.overlays) }
        }
        for lane in TimelinePostLane.allCases where lane != .effects && postLaneClipCount(lane) > 0 {
            setPostLane(lane, visible: true)
        }
    }

    /// The track menu in the editor's menu grammar (mockup `.menu`/`.mi`):
    /// a short title, 30 pt rows, a check for each shown lane.
    private var timelineTrackVisibilityPanel: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("显示轨道")
                .font(.appUI(size: 11.5, weight: .medium))
                .foregroundStyle(EditorTheme.tertiaryText)
                .padding(.horizontal, 8)
                .frame(height: 26, alignment: .leading)
                .help(appLocalized("隐藏只收起编辑区，不会停用效果"))

            timelineTrackVisibilityRow(
                "缩放", symbol: "magnifyingglass", palette: EditorConsole.Track.zoom, track: .zoom,
                clipCount: editorStore.previewProject.zoomAnimations.count
            )
            timelineTrackVisibilityRow(
                "屏幕 3D", symbol: "cube.transparent", palette: EditorConsole.Track.screenMotion, track: .screenMotion,
                clipCount: editorStore.previewProject.timeline.screenMotionClips.count
            )
            timelineTrackVisibilityRow(
                "摄像运动", symbol: "video", palette: EditorConsole.Track.cameraMotion, track: .cameraMotion,
                clipCount: editorStore.previewProject.timeline.cameraMotionClips.count,
                isEnabled: mediaSession.hasCameraVideo,
                disabledDetail: "无摄像头素材"
            )
            timelineTrackVisibilityRow(
                "柔化与突出", symbol: "circle.dotted", palette: EditorConsole.Track.region, track: .overlays,
                clipCount: editorStore.previewProject.timeline.mosaicClips.count,
                isEnabled: !editorStore.previewProject.timeline.mosaicClips.isEmpty,
                disabledDetail: "添加后自动出现"
            )
            ForEach(TimelinePostLane.allCases.filter { $0 != .effects }, id: \.self) { lane in
                postLaneVisibilityRow(lane)
            }

            Rectangle()
                .fill(EditorTheme.hairline)
                .frame(height: 0.5)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
            TimelineTrackMenuRow(
                title: "全部显示", symbol: "eye", hue: EditorTheme.secondaryText,
                count: 0, isOn: false, isEnabled: hasHiddenAvailableTrack,
                help: appLocalized("显示所有有内容的轨道"),
                action: showAllTimelineTracks
            )
        }
        .padding(5)
        .frame(width: 240)
        .animation(SpringMotion.micro, value: visibleTracks)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(appLocalized("显示轨道"))
    }

    func timelineTrackVisibilityRow(
        _ title: String,
        symbol: String,
        palette: EditorConsolePalette,
        track: EditorTimelineTrackVisibility,
        clipCount: Int,
        isEnabled: Bool = true,
        disabledDetail: String? = nil
    ) -> some View {
        // An unavailable row reads as off, never as a switched-on placeholder.
        let isVisible = isEnabled && (track == .overlays
            ? !visibleTracks.intersection(.overlays).isEmpty
            : visibleTracks.contains(track))
        let localizedTitle = appLocalized(title)
        return TimelineTrackMenuRow(
            title: title, symbol: symbol, hue: palette.stroke, count: clipCount,
            isOn: isVisible, isEnabled: isEnabled,
            help: isEnabled
                ? String(
                    format: appLocalized("%@；隐藏不会停用效果"),
                    String(format: appLocalized(isVisible ? "隐藏“%@”轨道" : "显示“%@”轨道"), localizedTitle)
                )
                : appLocalized(disabledDetail ?? "当前不可用"),
            action: { setTimelineTrack(track, visible: !isVisible) }
        )
    }

    /// Same row grammar for the added-material lanes; a lane with nothing on
    /// it never takes space, whatever its check says.
    func postLaneVisibilityRow(_ lane: TimelinePostLane) -> some View {
        let count = postLaneClipCount(lane)
        let available = count > 0
        let visible = available && !isPostLaneHidden(lane)
        let localizedTitle = appLocalized(lane.title)
        return TimelineTrackMenuRow(
            title: lane.title, symbol: lane.symbol, hue: lane.palette.stroke, count: count,
            isOn: visible, isEnabled: available,
            help: available
                ? String(format: appLocalized(visible ? "隐藏“%@”轨道" : "显示“%@”轨道"), localizedTitle)
                : appLocalized("添加后自动出现"),
            action: { setPostLane(lane, visible: !visible) }
        )
    }

    /// Row header for an added-material lane. Picture layers show their
    /// stacking controls on hover: up = in front, down = behind.
    @ViewBuilder
    func postLaneLabel(_ lane: TimelineLane) -> some View {
        switch lane {
        case let .groupHeader(group):
            laneGroupLabel(group)
                .transition(.timelineLane)
        case .moreLayers:
            moreLayersLabel(lane)
                .transition(.timelineLane)
        case .effects:
            // Inside the 柔化与突出 group: the header names it; rows are numbered.
            effectsRowNumbersLabel(lane)
                .contentShape(Rectangle())
                .transition(.timelineLane)
                .contextMenu { clearLaneMenu(lane) }
        case .layer:
            overlayLayerNumberLabel(lane)
                .overlay(alignment: .trailing) {
                    if case let .layer(layer) = lane, !timelineLabelsCollapsed, visualLayers.count > 1 {
                        TimelineLayerOrderButtons(
                            canRaise: layer != visualLayers.first,
                            canLower: layer != visualLayers.last,
                            raise: { moveLayer(layer, toward: 1) },
                            lower: { moveLayer(layer, toward: -1) }
                        )
                        .padding(.trailing, 6)
                    }
                }
                .transition(.timelineLane)
                .contextMenu { clearLaneMenu(lane) }
        default:
            timelineLabel(laneTitle(lane), symbol: laneSymbol(lane), tint: lanePalette(lane).stroke, height: laneHeight(lane),
                          count: overlayTimelineClips.filter(lane.contains).count)
                .transition(.timelineLane)
                .contextMenu { clearLaneMenu(lane) }
        }
    }

    /// Right-click a track name to remove everything on that track at once —
    /// one undo step, so a batch of unwanted clips is never deleted one by one.
    @ViewBuilder
    func clearLaneMenu(_ lane: TimelineLane) -> some View {
        let count = overlayTimelineClips.filter(lane.contains).count
        Button(String(format: appLocalized("删除此轨道上的全部内容（%lld）"), Int64(count)), role: .destructive) {
            clearLane(lane)
        }
        .disabled(count == 0)
    }

    func clearLane(_ lane: TimelineLane) {
        cancelActiveTimelineGesture()
        let ids = Set(overlayTimelineClips.filter(lane.contains).map(\.id))
        guard !ids.isEmpty else { return }
        var timeline = editorStore.project.timeline
        timeline.subtitleCues.removeAll { ids.contains($0.id) }
        timeline.mosaicClips.removeAll { ids.contains($0.id) }
        timeline.stickerClips.removeAll { ids.contains($0.id) }
        timeline.animationClips.removeAll { ids.contains($0.id) }
        timeline.videoClips.removeAll { ids.contains($0.id) }
        timeline.audioClips.removeAll { ids.contains($0.id) }
        commitLaneClear(timeline, actionName: String(format: appLocalized("清空%@轨道"), appLocalized(laneTitle(lane))))
    }

    @ViewBuilder
    func clearMotionTrackMenu(_ track: EditorTimelineTrackVisibility) -> some View {
        let count: Int = switch track {
        case .zoom: editorStore.project.zoomAnimations.count
        case .screenMotion: editorStore.project.timeline.screenMotionClips.count
        case .cameraMotion: editorStore.project.timeline.cameraMotionClips.count
        default: 0
        }
        Button(String(format: appLocalized("删除此轨道上的全部内容（%lld）"), Int64(count)), role: .destructive) {
            cancelActiveTimelineGesture()
            var timeline = editorStore.project.timeline
            let name: String
            switch track {
            case .zoom: timeline.zoomClips.removeAll(); name = "缩放"
            case .screenMotion: timeline.screenMotionClips.removeAll(); name = "屏幕 3D"
            case .cameraMotion: timeline.cameraMotionClips.removeAll(); name = "摄像运动"
            default: return
            }
            commitLaneClear(timeline, actionName: String(format: appLocalized("清空%@轨道"), appLocalized(name)))
        }
        .disabled(count == 0)
    }

    private func commitLaneClear(_ timeline: ProjectTimeline, actionName: String) {
        do {
            try editorStore.replaceTimeline(with: timeline, actionName: actionName)
            editorStore.selection = .canvas
            multiSelection.removeAll()
        } catch {
            onError(error.localizedDescription)
        }
    }

    func optionalTimelineLabel(
        _ title: String,
        tint: Color,
        height: CGFloat,
        track: EditorTimelineTrackVisibility
    ) -> some View {
        let symbol: String = switch track {
        case .zoom: "viewfinder"
        case .screenMotion: "move.3d"
        case .cameraMotion: "video"
        case .overlays: "square.3.layers.3d"
        default: "square.stack"
        }
        let count: Int? = switch track {
        case .zoom: editorStore.project.zoomAnimations.count
        case .screenMotion: editorStore.project.timeline.screenMotionClips.count
        case .cameraMotion: editorStore.project.timeline.cameraMotionClips.count
        default: nil
        }
        return EditorTimelineLaneLabel(title: title, symbol: symbol, tint: tint, onHide: {
            setTimelineTrack(track, visible: false)
        }, collapsed: timelineLabelsCollapsed, count: count)
        .frame(height: height)
        .transition(.timelineLane)
        .contextMenu { if track != .overlays { clearMotionTrackMenu(track) } }
        .accessibilityElement(children: .contain)
    }

    func setTimelineTrack(
        _ track: EditorTimelineTrackVisibility,
        visible: Bool
    ) {
        cancelActiveTimelineGesture()
        // Labels and lanes open and close together on one spring.
        withAnimation(SpringMotion.settle) {
            if visible {
                visibleTracks.insert(track)
            } else {
                visibleTracks.remove(track)
            }
        }
    }
}

/// Small up/down controls on a picture-layer header; visible on hover.
struct TimelineLayerOrderButtons: View {
    let canRaise: Bool
    let canLower: Bool
    let raise: () -> Void
    let lower: () -> Void
    @State private var hovered = false

    var body: some View {
        VStack(spacing: 0) {
            button("chevron.up", enabled: canRaise, help: "移到上一层（显示在前面）", action: raise)
            button("chevron.down", enabled: canLower, help: "移到下一层（显示在后面）", action: lower)
        }
        .opacity(hovered ? 1 : 0.0001)
        .contentShape(Rectangle())
        .onHover { hovered = $0 }
        .frame(width: 18)
    }

    private func button(_ symbol: String, enabled: Bool, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            EditorSymbol(symbol, size: 8)
                .font(.system(size: 8, weight: .bold))
                .frame(width: 18, height: 13)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(EditorTheme.secondaryText)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.3)
        .help(appLocalized(help))
    }
}
