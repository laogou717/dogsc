import RecorderCore
import SwiftUI

extension EditorInspectorView {
    var backgroundBlurSection: some View {
        VStack(spacing: 8) {
            if editorStore.previewProject.canvas.backgroundSource.usesWallpaperMedia {
                Divider().overlay(EditorTheme.hairline)
                sliderRow("背景模糊", value: canvasBinding(\.backgroundBlur, actionName: "调整背景模糊"),
                          range: 0...80, format: .points)
            }
        }
    }

    @ViewBuilder
    func zoomTransitionAvailability(_ animation: ZoomAnimationClip) -> some View {
        if let resolved = ZoomTransitionResolution.resolve(
            editorStore.previewProject.zoomAnimations, outputDuration: timelineDuration
        ).first(where: { $0.id == animation.id }) {
            let constrained = abs(resolved.enterDuration - animation.requestedEnterDuration) > 0.001
                || abs(resolved.exitDuration - animation.requestedExitDuration()) > 0.001
                || abs(resolved.endTime - animation.endTime) > 0.001
            if constrained {
                VStack(alignment: .leading, spacing: 4) {
                    Label("已按可用时间适配", systemImage: "clock.badge.checkmark")
                        .font(.appUI(.caption, weight: .medium))
                    Text("实际进入 \(EditorSliderValueFormat.seconds.text(for: resolved.enterDuration)) · 退出 \(EditorSliderValueFormat.seconds.text(for: resolved.exitDuration))")
                        .font(.caption.monospacedDigit())
                    Text("保留上方设定；片尾前完成退出，相邻动画紧接时连续衔接。")
                        .font(.appUI(.caption2))
                        .fixedSize(horizontal: false, vertical: true)
                }
                .foregroundStyle(.secondary)
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(EditorTheme.chrome(0.04), in: RoundedRectangle(cornerRadius: 8))
            } else {
                Text("设定时长均可完整播放。")
                    .font(.appUI(.caption2)).foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    func selectedAudioContext(_ segmentID: UUID) -> some View {
        if let context = primarySegmentContext(id: segmentID) {
            let overrides = editorStore.previewProject.timeline.primarySegmentAudioOverrides[segmentID]
            let inherits = overrides?.isEmpty ?? true
            VStack(alignment: .leading, spacing: 9) {
                HStack(alignment: .firstTextBaseline) {
                    Text("第 \(context.index + 1) 段").font(.appUI(.callout, weight: .semibold))
                    Spacer(minLength: 4)
                    Text("\(segmentTimestamp(context.segment.outputStart)) – \(segmentTimestamp(context.segment.outputEnd))")
                        .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                }
                Text(appLocalized(inherits ? "继承全片声音设置" : "已覆盖此段的声音设置"))
                    .font(.appUI(.caption)).foregroundStyle(.secondary)
                HStack(spacing: 8) {
                    Button("定位到此段") {
                        playbackController.seek(to: context.segment.outputStart)
                    }
                    .buttonStyle(.editorQuiet)
                    if !inherits {
                        Button("恢复继承") {
                            var timeline = editorStore.project.timeline
                            timeline.primarySegmentAudioOverrides.removeValue(forKey: segmentID)
                            performEditorCommand {
                                try editorStore.replaceTimeline(with: timeline, actionName: "恢复片段声音继承")
                            }
                        }
                        .buttonStyle(.editorGhost)
                    }
                }
                if playbackTime < context.segment.outputStart || playbackTime >= context.segment.outputEnd {
                    Text("播放头在其他位置，当前调整仍只作用于选中片段。")
                        .font(.appUI(.caption2)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.horizontal, 2)
            .padding(.vertical, 4)
        }
    }

    func segmentAudioSourceDetail(_ segmentID: UUID, microphone: Bool) -> String {
        let value = editorStore.previewProject.timeline.primarySegmentAudioOverrides[segmentID]
        let volume = microphone ? value?.microphoneVolume : value?.systemVolume
        let mute = microphone ? value?.isMicrophoneMuted : value?.isSystemMuted
        return appLocalized(volume == nil && mute == nil ? "继承全片设置" : "仅此片段，自定义设置")
    }
}
