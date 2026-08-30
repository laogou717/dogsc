import SwiftUI

private struct TimelineTrackManagerLabel: View {
    @State private var isHovered = false

    var body: some View {
        return HStack(spacing: 4) {
            Text("轨道")
                .font(.system(size: 10.5, weight: .semibold))
            Spacer(minLength: 2)
            Image(systemName: "chevron.down")
                .font(.system(size: 8, weight: .bold))
                .foregroundStyle(Color.white.opacity(isHovered ? 0.78 : 0.46))
                .accessibilityHidden(true)
        }
        .foregroundStyle(Color.white.opacity(isHovered ? 0.94 : 0.74))
        .padding(.horizontal, 8)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            Color.white.opacity(isHovered ? 0.075 : 0),
            in: RoundedRectangle(cornerRadius: 7, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .stroke(Color.white.opacity(isHovered ? 0.11 : 0), lineWidth: 0.75)
        }
        .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        .scaleEffect(isHovered ? 1.018 : 1)
        .onHover { hovering in
            withAnimation(SpringMotion.interactive) {
                isHovered = hovering
            }
        }
    }
}

fileprivate struct TimelineTrackVisibilityButtonStyle: ButtonStyle {
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
                    Color.white.opacity(backgroundOpacity),
                    in: RoundedRectangle(cornerRadius: 7, style: .continuous)
                )
                .overlay {
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .stroke(
                            Color.white.opacity(isHovered && isEnabled ? 0.10 : 0),
                            lineWidth: 0.75
                        )
                }
                .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                .scaleEffect(
                    configuration.isPressed && isEnabled
                        ? 0.92
                        : isHovered && isEnabled ? 1.06 : 1
                )
                .onHover { hovering in
                    withAnimation(SpringMotion.interactive) {
                        isHovered = hovering
                    }
                }
                .animation(SpringMotion.interactive, value: configuration.isPressed)
        }

        private var backgroundOpacity: Double {
            guard isEnabled else { return 0 }
            if configuration.isPressed { return 0.13 }
            return isHovered ? 0.075 : 0
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
        return HStack(spacing: 6) {
            Image(systemName: "plus")
                .font(.system(size: 8.5, weight: .bold))
                .foregroundStyle(Color.black.opacity(0.72))
                .frame(width: 16, height: 16)
                .background(
                    EditorTheme.platinumMuted.opacity(0.78),
                    in: Circle()
                )

            Text(title)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(Color.secondary.opacity(0.80))
                .lineLimit(1)
        }
        .padding(.leading, 10)
        .frame(width: visibleWidth, alignment: .leading)
        .offset(x: visibleRange.lowerBound)
        .allowsHitTesting(false)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
    }

    var timelineTrackManager: some View {
        Menu {
            timelineTrackMenuButton(
                "缩放",
                track: .zoom,
                clipCount: editorStore.previewProject.zoomAnimations.count
            )
            timelineTrackMenuButton(
                "屏幕 3D",
                track: .screenMotion,
                clipCount: editorStore.previewProject.timeline.screenMotionClips.count
            )
            timelineTrackMenuButton(
                "摄像运动",
                track: .cameraMotion,
                clipCount: editorStore.previewProject.timeline.cameraMotionClips.count,
                isEnabled: mediaSession.inventories.camera.hasVideo
            )
            Divider()
            timelineTrackMenuButton(
                "叠加",
                track: .overlays,
                clipCount: editorStore.previewProject.timeline.mosaicClips.count
                    + editorStore.previewProject.timeline.stickerClips.count
            )
            timelineTrackMenuButton(
                "进度条",
                track: .progress,
                clipCount: editorStore.previewProject.timeline.progressOverlay == nil ? 0 : 1
            )
        } label: {
            TimelineTrackManagerLabel()
        }
        .menuStyle(.borderlessButton)
        .help("管理动画轨道")
        .accessibilityLabel("管理动画轨道")
    }

    @ViewBuilder
    func timelineTrackMenuButton(
        _ title: String,
        track: EditorTimelineTrackVisibility,
        clipCount: Int,
        isEnabled: Bool = true
    ) -> some View {
        let isVisible = track == .overlays
            ? !visibleTracks.intersection(.overlays).isEmpty
            : visibleTracks.contains(track)
        Button {
            setTimelineTrack(track, visible: !isVisible)
        } label: {
            Label(
                clipCount > 0 ? "\(title)（\(clipCount)）" : title,
                systemImage: isVisible ? "checkmark" : "circle"
            )
        }
        .disabled(!isEnabled)
    }

    func optionalTimelineLabel(
        _ title: String,
        tint: Color,
        height: CGFloat,
        track: EditorTimelineTrackVisibility
    ) -> some View {
        let isFocused: Bool = switch track {
        case .zoom: focusedTimelineLane == .zoom
        case .screenMotion: focusedTimelineLane == .screenMotion
        case .cameraMotion: focusedTimelineLane == .cameraMotion
        case .overlays: focusedTimelineLane == .overlays
        case .progress: focusedTimelineLane == .progress
        default: false
        }
        return HStack(spacing: 4) {
            RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                .fill(tint.opacity(isFocused ? 1 : 0.82))
                .frame(width: isFocused ? 3.5 : 2.5, height: isFocused ? 24 : 18)

            Text(title)
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(Color.white.opacity(isFocused ? 0.96 : 0.72))
                .lineLimit(1)
                .accessibilityHidden(true)

            Spacer(minLength: 0)

            Button {
                setTimelineTrack(track, visible: false)
            } label: {
                Image(systemName: "eye.slash")
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(Color.white.opacity(0.64))
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(TimelineTrackVisibilityButtonStyle())
            .help("隐藏“\(title)”轨道；动画仍会生效")
            .accessibilityLabel("隐藏“\(title)”轨道")
        }
        .padding(.leading, 8)
        .padding(.trailing, 3)
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
