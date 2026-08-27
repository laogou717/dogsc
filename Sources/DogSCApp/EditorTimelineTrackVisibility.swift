import SwiftUI

extension EditorTimelineView {
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
            Text("轨道")
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(Color.white.opacity(0.72))
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                .padding(.horizontal, 8)
                .contentShape(Rectangle())
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
        HStack(spacing: 4) {
            RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                .fill(tint.opacity(0.82))
                .frame(width: 2.5, height: 18)

            Text(title)
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(Color.white.opacity(0.72))
                .lineLimit(1)
                .accessibilityHidden(true)

            Spacer(minLength: 0)

            Button {
                setTimelineTrack(track, visible: false)
            } label: {
                Image(systemName: "eye.slash")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(Color.white.opacity(0.50))
                    .frame(width: 15, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("隐藏“\(title)”轨道；动画仍会生效")
            .accessibilityLabel("隐藏“\(title)”轨道")
        }
        .padding(.leading, 8)
        .padding(.trailing, 4)
        .frame(height: height)
        .overlay(alignment: .bottom) { Divider().overlay(dividerColor) }
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
