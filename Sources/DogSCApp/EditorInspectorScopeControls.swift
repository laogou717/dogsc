import RecorderCore
import SwiftUI

extension EditorInspectorView {
    var backgroundBlurSection: some View {
        VStack(spacing: 8) {
            if editorStore.previewProject.canvas.backgroundSource.usesWallpaperMedia {
                sliderRow("背景模糊", value: canvasBinding(\.backgroundBlur, actionName: "调整背景模糊"),
                          range: 0...80, format: .points)
            }
        }
    }

    @ViewBuilder
    func zoomTransitionAvailability(_ animation: ZoomAnimationClip) -> some View {
        if let resolved = ZoomTransitionResolution.resolve(
            editorStore.previewProject.zoomAnimations.filter { $0.target == animation.target }, outputDuration: timelineDuration
        ).first(where: { $0.id == animation.id }) {
            let constrained = abs(resolved.enterDuration - animation.requestedEnterDuration) > 0.001
                || abs(resolved.exitDuration - animation.requestedExitDuration()) > 0.001
                || abs(resolved.endTime - animation.endTime) > 0.001
            if constrained {
                EditorInfoNote(
                    systemImage: "clock.badge.checkmark",
                    title: "已按可用时间适配",
                    lines: [
                        String(format: appLocalized("实际进入 %@ · 退出 %@"),
                               EditorSliderValueFormat.seconds.text(for: resolved.enterDuration),
                               EditorSliderValueFormat.seconds.text(for: resolved.exitDuration)),
                        appLocalized("保留上方设定；片尾前完成退出，相邻动画紧接时连续衔接。")
                    ]
                )
            } else {
                Text("设定时长均可完整播放。")
                    .font(.appUI(size: 10)).foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    func selectedAudioContext(_ segmentID: UUID) -> some View {
        if let context = primarySegmentContext(id: segmentID) {
            let overrides = editorStore.previewProject.timeline.primarySegmentAudioOverrides[segmentID]
            let inherits = overrides?.inheritsMix ?? true
            VStack(alignment: .leading, spacing: usesCompactSelectedAudioLayout ? 6 : 9) {
                HStack(alignment: .firstTextBaseline) {
                    if usesCompactSelectedAudioLayout {
                        Text(appLocalized(inherits ? "继承全片声音设置" : "已覆盖此段的声音设置"))
                            .font(.appUI(size: 11)).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    } else {
                        Text(String(format: appLocalized("第 %lld 段"), Int64(context.index + 1)))
                            .font(.appUI(size: 12, weight: .semibold))
                    }
                    Spacer(minLength: 4)
                    Text("\(segmentTimestamp(context.segment.outputStart)) – \(segmentTimestamp(context.segment.outputEnd))")
                        .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                        .fixedSize(horizontal: usesCompactSelectedAudioLayout, vertical: false)
                }
                if !usesCompactSelectedAudioLayout {
                    Text(appLocalized(inherits ? "继承全片声音设置" : "已覆盖此段的声音设置"))
                        .font(.appUI(size: 11)).foregroundStyle(.secondary)
                }
                HStack(spacing: 8) {
                    Button("定位到此段") {
                        playbackController.seek(to: context.segment.outputStart)
                    }
                    .buttonStyle(.editorQuiet)
                    if !inherits {
                        Button("恢复继承") {
                            var timeline = editorStore.project.timeline
                            timeline.resetSegmentAudioMix(segmentID)
                            performEditorCommand {
                                try editorStore.replaceTimeline(with: timeline, actionName: "恢复片段声音继承")
                            }
                        }
                        .buttonStyle(.editorGhost)
                    }
                }
                if playbackTime < context.segment.outputStart || playbackTime >= context.segment.outputEnd {
                    Text("播放头在其他位置，当前调整仍只作用于选中片段。")
                        .font(.appUI(size: 10)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.horizontal, 2)
            .padding(.vertical, usesCompactSelectedAudioLayout ? 0 : 4)
        }
    }

    /// Canvas, cursor, camera and motion edits are routed to one occurrence
    /// while the page still reads as whole-video. Name the clip the controls
    /// are editing and offer the way back, exactly as per-clip sound does.
    @ViewBuilder
    func sceneScopeContext(_ segmentID: UUID) -> some View {
        if let context = primarySegmentContext(id: segmentID) {
            let segment = editorStore.previewProject.timeline.recordingSegment(id: segmentID)
            let isInserted = segment?.media != nil
            let overridden = segment?.sceneStyle != nil
            VStack(alignment: .leading, spacing: 9) {
                HStack(alignment: .firstTextBaseline) {
                    Text(String(format: appLocalized("第 %lld 段"), Int64(context.index + 1)))
                        .font(.appUI(size: 12, weight: .semibold))
                    Spacer(minLength: 4)
                    Text("\(segmentTimestamp(context.segment.outputStart)) – \(segmentTimestamp(context.segment.outputEnd))")
                        .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                }
                Text(appLocalized(isInserted
                    ? (overridden ? "已自定义此素材的外观" : "使用插入素材的默认外观")
                    : (overridden ? "已覆盖此段的画面外观" : "继承全片画面外观")))
                    .font(.appUI(size: 11)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if editorStore.sceneEditingMarkerSegmentID == segmentID {
                    // The clip is being edited through the playhead, not
                    // picked: say so, and the timeline marks the same clip.
                    Text("播放头停在这一段，调整只作用于它")
                        .font(.appUI(size: 11)).foregroundStyle(EditorTheme.accent)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if overridden {
                    Button(appLocalized(isInserted ? "恢复默认外观" : "恢复继承")) {
                        performEditorCommand {
                            try editorStore.clearSceneStyle(
                                forSegmentID: segmentID, actionName: "恢复片段外观继承")
                        }
                    }
                    .buttonStyle(.editorGhost)
                }
                if !isInserted { sceneStyleSpreadControls(segmentID) }
                segmentCropScope(segmentID)
            }
            .padding(.horizontal, 2)
            .padding(.vertical, 4)
        }
    }

    /// Crop is its own override, independent of the appearance style: a clip
    /// framed on its own has to say so wherever the user is editing it, and
    /// offer the way back to the recording's one rectangle.
    @ViewBuilder
    func segmentCropScope(_ segmentID: UUID) -> some View {
        if editorStore.previewProject.timeline.recordingSegment(id: segmentID)?.crop != nil {
            Text("已单独裁切此段，不跟随整份录制")
                .font(.appUI(size: 11)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                Button("恢复跟随整份录制") {
                    var timeline = editorStore.project.timeline
                    timeline.setSegmentCrop(nil, forSegmentID: segmentID)
                    performEditorCommand {
                        try editorStore.replaceTimeline(with: timeline, actionName: "恢复片段裁切继承")
                    }
                }
                .buttonStyle(.editorGhost)
                // Crop is its own authority, so pushing it outwards is its own
                // action: the appearance spread above must never reframe clips.
                Button("把此段裁切用于整份录制") {
                    performEditorCommand {
                        try editorStore.spreadSegmentCropToRecording(
                            segmentID: segmentID, actionName: "把片段裁切应用到整份录制")
                    }
                }
                .buttonStyle(.editorGhost)
            }
        }
    }

    /// Per-clip appearance is a dead end without a way back out: a recording
    /// cut into eight clips has to be restylable as a whole from any one of
    /// them. Counts are on the buttons so neither action can be mistaken for
    /// the other, and neither carries crop or sound along.
    @ViewBuilder
    func sceneStyleSpreadControls(_ segmentID: UUID) -> some View {
        let recordingCount = editorStore.sceneStyleSpreadCount(.recording, forSegmentID: segmentID)
        let programmeCount = editorStore.sceneStyleSpreadCount(.programme, forSegmentID: segmentID)
        if programmeCount > 1 {
            VStack(alignment: .leading, spacing: 6) {
                Text("把这一段的外观应用到")
                    .font(.appUI(size: 11)).foregroundStyle(EditorTheme.tertiaryText)
                HStack(spacing: 8) {
                    if recordingCount > 1, recordingCount < programmeCount {
                        Button(String(format: appLocalized("这份录制 · %lld 段"), Int64(recordingCount))) {
                            performEditorCommand {
                                try editorStore.spreadSceneStyle(
                                    ofSegmentID: segmentID, to: .recording,
                                    actionName: "应用此段外观到整份录制")
                            }
                        }
                        .buttonStyle(.editorGhost)
                        .help("同一份录制的每一段都用这一段的画面外观，其他录制不变。")
                    }
                    Button(String(format: appLocalized("全片 · %lld 段"), Int64(programmeCount))) {
                        performEditorCommand {
                            try editorStore.spreadSceneStyle(
                                ofSegmentID: segmentID, to: .programme,
                                actionName: "应用此段外观到全片")
                        }
                    }
                    .buttonStyle(.editorGhost)
                    .help("把这一段的外观写回全片设置，并清掉其他片段的单独外观。")
                }
                Text("裁切和声音不随这个操作改变。")
                    .font(.appUI(size: 10)).foregroundStyle(EditorTheme.tertiaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// The same note for a clip that carries only a crop: it has no appearance
    /// override, so the scope block that usually hosts this is absent.
    @ViewBuilder
    func segmentCropScopeNote(_ segmentID: UUID) -> some View {
        VStack(alignment: .leading, spacing: 9) { segmentCropScope(segmentID) }
            .padding(.horizontal, 2)
            .padding(.vertical, 4)
    }

    func segmentAudioSourceDetail(_ segmentID: UUID, microphone: Bool) -> String {
        let value = editorStore.previewProject.timeline.primarySegmentAudioOverrides[segmentID]
        let volume = microphone ? value?.microphoneVolume : value?.systemVolume
        let mute = microphone ? value?.isMicrophoneMuted : value?.isSystemMuted
        return appLocalized(volume == nil && mute == nil ? "继承全片设置" : "仅此片段，自定义设置")
    }
}
