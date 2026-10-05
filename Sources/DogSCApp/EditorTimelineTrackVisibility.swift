import SwiftUI

private struct TimelineTrackManagerLabel: View {
    @State private var isHovered = false
    let isPresented: Bool
    var horizontalInset: CGFloat = 16

    var body: some View {
        return HStack(spacing: 8) {
            Image(systemName: "rectangle.stack")
                .font(.appUI(size: 12, weight: .medium))
                .frame(width: 20)
                .accessibilityHidden(true)
            Text("轨道")
                .font(.appUI(size: 11, weight: .medium))
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
            Image(systemName: isPresented ? "chevron.up" : "chevron.down")
                .font(.appUI(size: 8, weight: .medium))
                .frame(width: 24)
                .foregroundStyle(EditorTheme.chrome(isHovered || isPresented ? 0.82 : 0.46))
                .accessibilityHidden(true)
        }
        .foregroundStyle(EditorTheme.chrome(isHovered || isPresented ? 0.96 : 0.74))
        .padding(.horizontal, horizontalInset)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            EditorTheme.chrome(isPresented ? 0.105 : isHovered ? 0.075 : 0),
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
        return HStack(spacing: 8) {
            Image(systemName: "plus")
                .font(.appUI(size: 12, weight: .medium))
                .foregroundStyle(EditorTheme.chrome(0.38))
                .frame(width: 20, height: 20)

            Text(appLocalized(title))
                .font(.appUI(size: 12, weight: .medium))
                .foregroundStyle(EditorTheme.chrome(0.46))
                .lineLimit(1)
        }
        .padding(.leading, layout.value(regular: 24, compact: 20))
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
                horizontalInset: layout.value(regular: 16, compact: 6)
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

    private var timelineTrackVisibilityPanel: some View {
        VStack(spacing: 0) {
            HStack(alignment: .center, spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("轨道显示")
                        .font(.appUI(size: 13, weight: .semibold))
                        .foregroundStyle(EditorTheme.chrome(0.94))
                    Text("隐藏只收起编辑区，不会停用效果")
                        .font(.appUI(size: 10, weight: .medium))
                        .foregroundStyle(EditorTheme.popoverSecondaryText)
                }

                Spacer(minLength: 8)

                Text("\(visibleOptionalTrackCount) / 4")
                    .font(.appUI(size: 10, weight: .semibold, design: .monospaced))
                    .foregroundStyle(EditorTheme.chrome(0.66))
                    .padding(.horizontal, 8)
                    .frame(height: 22)
                    .background(
                        EditorTheme.chrome(0.065),
                        in: Capsule(style: .continuous)
                    )
                    .accessibilityHidden(true)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 11)

            Divider().overlay(dividerColor)

            VStack(spacing: 3) {
                timelineTrackVisibilityRow(
                    "缩放",
                    symbol: "magnifyingglass",
                    tint: editorZoomClip,
                    track: .zoom,
                    clipCount: editorStore.previewProject.zoomAnimations.count
                )
                timelineTrackVisibilityRow(
                    "屏幕 3D",
                    symbol: "cube.transparent",
                    tint: motionTrackColor(.screen),
                    track: .screenMotion,
                    clipCount: editorStore.previewProject.timeline.screenMotionClips.count
                )
                timelineTrackVisibilityRow(
                    "摄像运动",
                    symbol: "video",
                    tint: motionTrackColor(.camera),
                    track: .cameraMotion,
                    clipCount: editorStore.previewProject.timeline.cameraMotionClips.count,
                    isEnabled: mediaSession.inventories.camera.hasVideo,
                    disabledDetail: "无摄像头素材"
                )

                Divider()
                    .overlay(dividerColor)
                    .padding(.vertical, 3)

                timelineTrackVisibilityRow(
                    "叠加",
                    symbol: "square.on.square",
                    tint: editorOverlayClip,
                    track: .overlays,
                    clipCount: editorStore.previewProject.timeline.mosaicClips.count
                        + editorStore.previewProject.timeline.stickerClips.count
                )
            }
            .padding(8)
        }
        .frame(width: 286)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("轨道显示设置")
    }

    func timelineTrackVisibilityRow(
        _ title: String,
        symbol: String,
        tint: Color,
        track: EditorTimelineTrackVisibility,
        clipCount: Int,
        isEnabled: Bool = true,
        disabledDetail: String? = nil
    ) -> some View {
        let isVisible = track == .overlays
            ? !visibleTracks.intersection(.overlays).isEmpty
            : visibleTracks.contains(track)
        let localizedTitle = appLocalized(title)
        let actionTitle = String(
            format: appLocalized(isVisible ? "隐藏“%@”轨道" : "显示“%@”轨道"),
            localizedTitle
        )
        let contentCount = String(format: appLocalized("%d 个内容"), clipCount)
        let visibilityTitle = appLocalized(isVisible ? "轨道状态 · 显示" : "轨道状态 · 隐藏")
        let toggleVisibility = {
            setTimelineTrack(track, visible: !isVisible)
        }
        return Button(action: toggleVisibility) {
            HStack(spacing: 10) {
                Image(systemName: symbol)
                    .font(.appUI(size: 11, weight: .semibold))
                    .foregroundStyle(tint.opacity(isVisible ? 1 : 0.62))
                    .frame(width: 25, height: 25)
                    .background(
                        tint.opacity(isVisible ? 0.20 : 0.09),
                        in: RoundedRectangle(cornerRadius: EditorInterfaceRadius.compact, style: .continuous)
                    )
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 2) {
                    Text(localizedTitle)
                        .font(.appUI(size: 11.5, weight: .semibold))
                        .foregroundStyle(EditorTheme.primaryText)

                    Text(isEnabled ? contentCount : appLocalized(disabledDetail ?? "当前不可用"))
                        .font(.appUI(size: 9.5, weight: .medium))
                        .foregroundStyle(EditorTheme.secondaryText)
                        .lineLimit(1)
                }

                Spacer(minLength: 6)

                HStack(spacing: 5) {
                    Image(systemName: isVisible ? "eye.fill" : "eye.slash")
                        .font(.appUI(size: 9.5, weight: .semibold))
                    Text(visibilityTitle)
                        .font(.appUI(size: 10, weight: .medium))
                }
                .foregroundStyle(
                    isVisible
                        ? EditorTheme.primaryText
                        : EditorTheme.popoverSecondaryText
                )
                .padding(.horizontal, 8)
                .frame(height: 24)
                .background(
                    isVisible
                        ? EditorTheme.chrome(0.075)
                        : EditorTheme.chrome(0.055),
                    in: Capsule(style: .continuous)
                )
                .overlay {
                    if !isVisible {
                        Capsule(style: .continuous)
                            .stroke(EditorTheme.chrome(0.085), lineWidth: 0.75)
                    }
                }
                .accessibilityHidden(true)
            }
            .padding(.horizontal, 7)
            .frame(height: 45)
            .background(
                isVisible ? EditorTheme.popoverSelectionSurface : Color.clear,
                in: RoundedRectangle(cornerRadius: EditorInterfaceRadius.control, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: EditorInterfaceRadius.control, style: .continuous)
                    .stroke(
                        isVisible ? EditorTheme.chrome(0.14) : Color.clear,
                        lineWidth: 0.75
                    )
            }
        }
        .buttonStyle(TimelineTrackVisibilityRowButtonStyle())
        .appButtonKeyboardFocus(in: RoundedRectangle(cornerRadius: EditorInterfaceRadius.control, style: .continuous))
        .disabled(!isEnabled)
        .help(
            isEnabled
                ? String(format: appLocalized("%@；隐藏不会停用效果"), actionTitle)
                : appLocalized(disabledDetail ?? "当前不可用")
        )
        .accessibilityLabel(actionTitle)
        .accessibilityValue(String(format: appLocalized("目前%@，%@"), visibilityTitle, contentCount))
        .accessibilityHint("隐藏轨道不会停用其中效果")
        .onKeyPress(keys: [.return], phases: .down) { press in
            guard isEnabled,
                  press.modifiers.intersection([.command, .control, .option, .shift]).isEmpty else {
                return .ignored
            }
            toggleVisibility()
            return .handled
        }
    }

    func optionalTimelineLabel(
        _ title: String,
        tint: Color,
        height: CGFloat,
        track: EditorTimelineTrackVisibility
    ) -> some View {
        let symbol: String = switch track {
        case .zoom: "plus.magnifyingglass"
        case .screenMotion: "cube.transparent"
        case .cameraMotion: "video"
        case .overlays: "square.3.layers.3d"
        default: "square.stack"
        }
        return EditorTimelineLaneLabel(title: title, symbol: symbol, onHide: {
            setTimelineTrack(track, visible: false)
        }, horizontalInset: layout.value(regular: 16, compact: 6))
        .frame(height: height)
        .transition(.opacity.combined(with: .offset(y: 8)))
        .accessibilityElement(children: .contain)
    }

    func setTimelineTrack(
        _ track: EditorTimelineTrackVisibility,
        visible: Bool
    ) {
        cancelActiveTimelineGesture()
        if visible {
            visibleTracks.insert(track)
        } else {
            visibleTracks.remove(track)
        }
    }
}
