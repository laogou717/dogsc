import SwiftUI

private struct TimelineTrackManagerLabel: View {
    @State private var isHovered = false
    let isPresented: Bool
    var horizontalInset: CGFloat = 16
    var collapsed = false

    var body: some View {
        return HStack(spacing: 8) {
            EditorSymbol("rectangle.stack", size: 15.5)
                .font(.appUI(size: 12, weight: .medium))
                .frame(width: 20)
                .accessibilityHidden(true)
            if !collapsed {
                Text("轨道")
                    .font(.appUI(size: 11, weight: .medium))
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                EditorSymbol(isPresented ? "chevron.up" : "chevron.down", size: 10.5)
                    .font(.appUI(size: 8, weight: .medium))
                    .frame(width: 24)
                    .foregroundStyle(EditorTheme.chrome(isHovered || isPresented ? 0.82 : 0.46))
                    .accessibilityHidden(true)
            }
        }
        .foregroundStyle(EditorTheme.chrome(isHovered || isPresented ? 0.96 : 0.74))
        .padding(.horizontal, collapsed ? 16 : horizontalInset)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .clipped()
        .background(
            EditorTheme.chrome(isPresented ? EditorStateWash.open : isHovered ? EditorStateWash.hover : 0),
            in: RoundedRectangle(cornerRadius: EditorInterfaceRadius.compact, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: EditorInterfaceRadius.compact, style: .continuous)
                .stroke(
                    EditorTheme.chrome(isPresented ? 0.18 : isHovered ? 0.11 : 0),
                    lineWidth: 0.75
                )
        }
        .contentShape(RoundedRectangle(cornerRadius: EditorInterfaceRadius.compact, style: .continuous))
        .appKeyboardFocus(in: RoundedRectangle(cornerRadius: EditorInterfaceRadius.compact, style: .continuous))
        .onHover { hovering in
            withAnimation(SpringMotion.interactive) {
                isHovered = hovering
            }
        }
    }
}

fileprivate struct TimelineTrackVisibilityRowButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> Body {
        Body(configuration: configuration)
    }

    fileprivate struct Body: View {
        @Environment(\.isEnabled) private var isEnabled
        @State private var isHovered = false
        let configuration: Configuration

        var body: some View {
            configuration.label
                .opacity(isEnabled ? 1 : 0.42)
                .background(
                    EditorTheme.chrome(backgroundOpacity),
                    in: RoundedRectangle(cornerRadius: EditorInterfaceRadius.control, style: .continuous)
                )
                .contentShape(RoundedRectangle(cornerRadius: EditorInterfaceRadius.control, style: .continuous))
                .appKeyboardFocus(in: RoundedRectangle(cornerRadius: EditorInterfaceRadius.control, style: .continuous))
                .scaleEffect(configuration.isPressed && isEnabled ? 0.985 : 1)
                .onHover { hovering in
                    withAnimation(SpringMotion.interactive) {
                        isHovered = hovering
                    }
                }
                .animation(SpringMotion.interactive, value: configuration.isPressed)
                .animation(SpringMotion.interactive, value: isEnabled)
        }

        private var backgroundOpacity: Double {
            guard isEnabled else { return 0 }
            if configuration.isPressed { return 0.11 }
            return isHovered ? 0.065 : 0
        }
    }
}

extension EditorTimelineView {
    /// Empty optional lanes use one quiet instruction instead of appearing as
    /// broken blank space. The hint never owns the click or drag gesture; the
    /// lane remains the sole interaction surface.
    func timelineEmptyTrackHint(
        _ title: String,
        documentWidth: CGFloat
    ) -> some View {
        let visibleRange = clampedTimelineVisibleDocumentRange(width: documentWidth)
        let measuredVisibleWidth = visibleRange.upperBound - visibleRange.lowerBound
        // `0...1` is the bridge's initial sentinel. Give the first frame a
        // realistic viewport instead of squeezing the hint into one point.
        let visibleWidth = measuredVisibleWidth > 1
            ? measuredVisibleWidth
            : min(max(documentWidth, 1), 1_200)
        return HStack(spacing: 7) {
            EditorSymbol("plus", size: 13.5)
                .font(.appUI(size: 11, weight: .semibold))
                .foregroundStyle(EditorTheme.chrome(0.40))

            Text(appLocalized(title))
                .font(.appUI(size: 12, weight: .medium))
                .foregroundStyle(EditorTheme.chrome(0.48))
                .lineLimit(1)
        }
        .padding(.horizontal, 13)
        .frame(height: 28)
        .background {
            // A recessed drop slot: the dashed edge reads "place content here"
            // instead of a dead row, and the fill sits below every lane tint.
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(EditorTheme.chrome(0.030))
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(
                    EditorTheme.chrome(0.14),
                    style: StrokeStyle(lineWidth: 1, dash: [5, 4])
                )
        }
        .padding(.leading, layout.value(regular: 26, compact: 22))
        .frame(width: visibleWidth, alignment: .leading)
        .offset(x: visibleRange.lowerBound)
        .allowsHitTesting(false)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(appLocalized(title))
    }

    var timelineTrackManager: some View {
        Button {
            withAnimation(SpringMotion.interactive) {
                isTimelineTrackManagerPresented.toggle()
            }
        } label: {
            TimelineTrackManagerLabel(
                isPresented: isTimelineTrackManagerPresented,
                horizontalInset: timelineLabelsCollapsed ? 0 : layout.value(regular: 12, compact: 6),
                collapsed: timelineLabelsCollapsed
            )
        }
        .buttonStyle(.plain)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .editorPopoverKeyboardEntry {
            withAnimation(SpringMotion.interactive) {
                isTimelineTrackManagerPresented = true
            }
        }
        .editorPopover(
            isPresented: $isTimelineTrackManagerPresented,
            arrowEdge: .top
        ) {
            timelineTrackVisibilityPanel
        }
        .help("管理动画轨道")
        .accessibilityLabel("管理动画轨道")
        .accessibilityValue(String(format: appLocalized("%d 条显示"), visibleOptionalTrackCount))
    }

    private var visibleOptionalTrackCount: Int {
        var count = 0
        if visibleTracks.contains(.zoom) { count += 1 }
        if visibleTracks.contains(.screenMotion) { count += 1 }
        if visibleTracks.contains(.cameraMotion) { count += 1 }
        if !visibleTracks.intersection(.overlays).isEmpty { count += 1 }
        return count
    }

    /// The track panel in the editor's own grammar: a title, then one tile
    /// of rows, each with its lane colour, a count and a real switch. Space
    /// separates the parts; there are no rules.
    private var timelineTrackVisibilityPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("轨道显示")
                        .font(.appUI(size: 14, weight: .semibold))
                        .foregroundStyle(EditorTheme.primaryText)
                    Text("隐藏只收起编辑区，不会停用效果")
                        .font(.appUI(size: 11))
                        .foregroundStyle(EditorTheme.secondaryText)
                }
                Spacer(minLength: 8)
                Text("\(visibleOptionalTrackCount) / 4")
                    .font(.appUI(size: 11, weight: .semibold).monospacedDigit())
                    .foregroundStyle(EditorTheme.secondaryText)
                    .contentTransition(.numericText())
                    .padding(.horizontal, 9)
                    .frame(height: 24)
                    .background(EditorTheme.chrome(0.06), in: Capsule(style: .continuous))
                    .animation(SpringMotion.snappy, value: visibleOptionalTrackCount)
                    .accessibilityHidden(true)
            }
            .padding(.horizontal, 4)

            VStack(spacing: 2) {
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
                    isEnabled: mediaSession.inventories.camera.hasVideo,
                    disabledDetail: "无摄像头素材"
                )
                timelineTrackVisibilityRow(
                    "叠加", symbol: "square.on.square", palette: EditorConsole.Track.overlay, track: .overlays,
                    clipCount: editorStore.previewProject.timeline.mosaicClips.count
                        + editorStore.previewProject.timeline.stickerClips.count
                )
            }
            .padding(6)
            .background(EditorTheme.cardFill, in: RoundedRectangle(cornerRadius: EditorInterfaceRadius.tile, style: .continuous))
            .environment(\.editorInsideTile, true)
        }
        .padding(12)
        .frame(width: 300)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("轨道显示设置")
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
        let isVisible = track == .overlays
            ? !visibleTracks.intersection(.overlays).isEmpty
            : visibleTracks.contains(track)
        let localizedTitle = appLocalized(title)
        let contentCount = String(format: appLocalized("%d 个内容"), clipCount)
        return HStack(spacing: 11) {
            EditorSymbol(symbol, size: 15)
                .foregroundStyle(palette.stroke)
                .frame(width: 30, height: 30)
                .background(palette.soft, in: RoundedRectangle(cornerRadius: EditorInterfaceRadius.compact, style: .continuous))
                .saturation(isVisible ? 1 : 0.2)
                .opacity(isVisible ? 1 : 0.7)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(localizedTitle)
                    .font(.appUI(size: 13, weight: .medium))
                    .foregroundStyle(EditorTheme.primaryText)
                Text(isEnabled ? contentCount : appLocalized(disabledDetail ?? "当前不可用"))
                    .font(.appUI(size: 11))
                    .foregroundStyle(EditorTheme.secondaryText)
                    .lineLimit(1)
            }
            .accessibilityHidden(true)
            Spacer(minLength: 6)
            EditorToggle(isOn: Binding(
                get: { isVisible },
                set: { setTimelineTrack(track, visible: $0) }
            ))
            .accessibilityLabel(String(format: appLocalized("%@轨道"), localizedTitle))
            .accessibilityValue(appLocalized(isVisible ? "轨道状态 · 显示" : "轨道状态 · 隐藏"))
            .help(
                isEnabled
                    ? String(
                        format: appLocalized("%@；隐藏不会停用效果"),
                        String(format: appLocalized(isVisible ? "隐藏“%@”轨道" : "显示“%@”轨道"), localizedTitle)
                    )
                    : appLocalized(disabledDetail ?? "当前不可用")
            )
        }
        .padding(.horizontal, 8)
        .frame(height: 48)
        .opacity(isEnabled ? 1 : 0.45)
        .disabled(!isEnabled)
        .animation(SpringMotion.settle, value: isVisible)
    }

    func optionalTimelineLabel(
        _ title: String,
        tint: Color,
        height: CGFloat,
        track: EditorTimelineTrackVisibility
    ) -> some View {
        let symbol: String
        switch track {
        case .zoom: symbol = "plus.magnifyingglass"
        case .screenMotion: symbol = "cube.transparent"
        case .cameraMotion: symbol = "video"
        case .overlays: symbol = "square.3.layers.3d"
        default: symbol = "square.stack"
        }
        return EditorTimelineLaneLabel(title: title, symbol: symbol, tint: tint, onHide: {
            setTimelineTrack(track, visible: false)
        }, horizontalInset: layout.value(regular: 12, compact: 6), collapsed: timelineLabelsCollapsed)
        .frame(height: height)
        .timelineRowDivider()
        .transition(.timelineLane)
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
