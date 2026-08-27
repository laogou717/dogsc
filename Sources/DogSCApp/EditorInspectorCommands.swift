import AppKit
import Foundation
import RecorderCore
import SwiftUI

extension EditorInspectorView {
    func addScreenMotionAtPlayhead() {
        let clips = editorStore.project.timeline.screenMotionClips
        if let active = clips.first(where: {
            playbackTime >= $0.timing.startTime && playbackTime < $0.timing.endTime
        }) {
            visibleTimelineTracks.insert(.screenMotion)
            editorStore.selection = .screenMotion(active.id)
            return
        }
        guard let timing = EditorTimelineMath.fitMotionTiming(
            start: playbackTime,
            end: playbackTime,
            among: clips.map(\.timing),
            duration: timelineDuration,
            easing: editorStore.project.motion.defaultZoomEasing,
            returnDuration: editorStore.project.motion.defaultZoomTransitionDuration,
            leadInDuration: editorStore.project.motion.defaultZoomTransitionDuration
        ) else {
            onError("播放头附近没有空间添加屏幕 3D，请先移动播放头。")
            return
        }
        let clip = ScreenMotionClip(
            timing: timing,
            target: MotionInspectorLogic.screenTarget(at: timing.startTime, in: editorStore.project)
        )
        performEditorCommand {
            try editorStore.insertScreenMotion(clip, actionName: "在播放头添加屏幕 3D")
            visibleTimelineTracks.insert(.screenMotion)
            editorStore.selection = .screenMotion(clip.id)
        }
    }

    func addCameraMotionAtPlayhead() {
        let clips = editorStore.project.timeline.cameraMotionClips
        if let active = clips.first(where: {
            playbackTime >= $0.timing.startTime && playbackTime < $0.timing.endTime
        }) {
            visibleTimelineTracks.insert(.cameraMotion)
            editorStore.selection = .cameraMotion(active.id)
            return
        }
        guard let timing = EditorTimelineMath.fitMotionTiming(
            start: playbackTime,
            end: playbackTime,
            among: clips.map(\.timing),
            duration: timelineDuration,
            easing: editorStore.project.motion.defaultZoomEasing,
            returnDuration: editorStore.project.motion.defaultZoomTransitionDuration,
            leadInDuration: editorStore.project.motion.defaultZoomTransitionDuration
        ) else {
            onError("播放头附近没有空间添加摄像运动，请先移动播放头。")
            return
        }
        let clip = CameraMotionClip(
            timing: timing,
            target: MotionInspectorLogic.cameraTarget(at: timing.startTime, in: editorStore.project)
        )
        performEditorCommand {
            try editorStore.insertCameraMotion(clip, actionName: "在播放头添加摄像运动")
            visibleTimelineTracks.insert(.cameraMotion)
            editorStore.selection = .cameraMotion(clip.id)
        }
    }

    /// 布局预设按钮：在播放头处以一次缓动过渡（≈淡入淡出）切到指定布局；
    /// 播放头已落在某段布局动画内时改为直接更新该段的目标。
    func cameraLayoutPresetButton(
        _ title: String,
        icon: String,
        action: @escaping () -> Void
    ) -> some View {
        EditorCameraLayoutPresetButton(title: title, icon: icon, action: action)
    }

    /// 插入（或更新播放头所在的）布局动画。`screenTarget` 非空时同时插入/更新
    /// 同时间窗的屏幕动画并配对 groupID（拖动一侧另一侧跟随），两条轨道一次
    /// replaceTimeline 提交，撤销也是一次。
    func insertCameraLayoutPreset(
        layout: CameraLayoutMode,
        position: NormalizedPoint,
        size: Double,
        roundness: Double? = nil,
        screenTarget: ScreenMotionState? = nil
    ) {
        var timeline = editorStore.project.timeline
        let cameraTarget = CameraMotionState(
            layout: layout,
            position: position,
            size: size,
            roundness: roundness ?? editorStore.project.camera.roundness,
            opacity: 1
        )

        // 配对 ID：两侧已有配对则沿用，否则新建
        let activeCamera = timeline.cameraMotionClips.first(where: {
            playbackTime >= $0.timing.startTime && playbackTime < $0.timing.endTime
        })
        let activeScreen = screenTarget == nil ? nil : timeline.screenMotionClips.first(where: {
            playbackTime >= $0.timing.startTime && playbackTime < $0.timing.endTime
        })
        let pairID = screenTarget == nil
            ? nil
            : (activeCamera?.groupID ?? activeScreen?.groupID ?? UUID())

        let timing: TransitionTiming
        let selectedCameraClipID: UUID
        if let activeCamera {
            timing = activeCamera.timing
            selectedCameraClipID = activeCamera.id
            if let index = timeline.cameraMotionClips.firstIndex(where: { $0.id == activeCamera.id }) {
                timeline.cameraMotionClips[index].target = cameraTarget
                timeline.cameraMotionClips[index].groupID = pairID
            }
        } else {
            // 与时间线上手动点击创建完全一致：贴合相邻片段、带默认回落时长，
            // 片段结束后自动回到基础状态（布局想“变回来”不需要再手动加动画）。
            // 组合预设的两侧时间窗取两条轨道的并集贴合，保证成对一致。
            let among = timeline.cameraMotionClips.map(\.timing)
                + (screenTarget == nil ? [] : timeline.screenMotionClips.map(\.timing))
            guard let fitted = EditorTimelineMath.fitMotionTiming(
                start: playbackTime,
                end: playbackTime,
                among: among,
                duration: timelineDuration,
                easing: editorStore.project.motion.defaultZoomEasing,
                returnDuration: editorStore.project.motion.defaultZoomTransitionDuration,
                leadInDuration: editorStore.project.motion.defaultZoomTransitionDuration
            ) else {
                onError("播放头附近没有空间添加布局动画，请先移动播放头。")
                return
            }
            let clip = CameraMotionClip(timing: fitted, target: cameraTarget, groupID: pairID)
            timing = fitted
            selectedCameraClipID = clip.id
            timeline.cameraMotionClips.append(clip)
        }

        if let screenTarget {
            if let activeScreen,
               let index = timeline.screenMotionClips.firstIndex(where: { $0.id == activeScreen.id }) {
                timeline.screenMotionClips[index].target = screenTarget
                timeline.screenMotionClips[index].groupID = pairID
            } else {
                timeline.screenMotionClips.append(
                    ScreenMotionClip(timing: timing, target: screenTarget, groupID: pairID)
                )
            }
            timeline.screenMotionClips.sort { $0.timing.startTime < $1.timing.startTime }
        }
        timeline.cameraMotionClips.sort { $0.timing.startTime < $1.timing.startTime }

        performEditorCommand {
            try editorStore.replaceTimeline(with: timeline, actionName: "切换摄像头布局")
            visibleTimelineTracks.insert(.cameraMotion)
            if screenTarget != nil {
                visibleTimelineTracks.insert(.screenMotion)
            }
            editorStore.selection = .cameraMotion(selectedCameraClipID)
        }
    }

    func performEditorCommand(_ operation: () throws -> Void) {
        do {
            try operation()
        } catch {
            onError(error.localizedDescription)
        }
    }

    // MARK: - 自定义布局预设

    static let savedLayoutPresetsKey = "layout-presets"

    static var presetsDefaults: UserDefaults {
        UserDefaults(suiteName: "cn.laogou.dogsc") ?? .standard
    }

    static func loadSavedLayoutPresets() -> [SavedLayoutPreset] {
        guard let data = presetsDefaults.data(forKey: savedLayoutPresetsKey),
              let presets = try? JSONDecoder().decode([SavedLayoutPreset].self, from: data)
        else { return [] }
        return presets
    }

    func persistSavedLayoutPresets(_ presets: [SavedLayoutPreset]) {
        guard let data = try? JSONEncoder().encode(presets) else { return }
        Self.presetsDefaults.set(data, forKey: Self.savedLayoutPresetsKey)
        savedLayoutPresets = presets
    }

    func saveCurrentLayoutAsPreset() {
        let name = layoutPresetName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        let camera = editorStore.project.camera
        let preset = SavedLayoutPreset(
            name: name,
            layout: .shape(camera.shape),
            cameraPosition: camera.position,
            cameraSize: camera.size,
            cameraRoundness: camera.roundness,
            screenPosition: editorStore.project.canvas.contentPosition,
            screenScale: editorStore.project.canvas.contentScale
        )
        var presets = savedLayoutPresets.filter { $0.name != name }
        presets.append(preset)
        persistSavedLayoutPresets(presets)
    }

    func deleteSavedLayoutPreset(_ preset: SavedLayoutPreset) {
        persistSavedLayoutPresets(savedLayoutPresets.filter { $0.name != preset.name })
    }

    func applySavedLayoutPreset(_ preset: SavedLayoutPreset) {
        insertCameraLayoutPreset(
            layout: preset.layout,
            position: preset.cameraPosition,
            size: preset.cameraSize,
            roundness: preset.cameraRoundness,
            screenTarget: ScreenMotionState(
                position: preset.screenPosition,
                scale: preset.screenScale
            )
        )
    }

    var selectedZoomAnimationIndex: Int? {
        guard let selectedZoomID else { return nil }
        return editorStore.previewProject.zoomAnimations.firstIndex(where: { $0.id == selectedZoomID })
    }

    func zoomAnimationDoubleBinding(
        _ index: Int,
        keyPath: WritableKeyPath<ZoomAnimationClip, Double>
    ) -> Binding<Double> {
        let id = editorStore.previewProject.zoomAnimations.indices.contains(index)
            ? editorStore.previewProject.zoomAnimations[index].id
            : selectedZoomID
        return Binding<Double>(
            get: {
                guard let id,
                      let currentIndex = editorStore.previewProject.zoomAnimations.firstIndex(where: { $0.id == id })
                else { return keyPath == \ZoomAnimationClip.scale ? 1.0 : 0.0 }
                return editorStore.previewProject.zoomAnimations[currentIndex][keyPath: keyPath]
            },
            set: { (value: Double) in
                guard let id,
                      let current = editorStore.previewProject.zoomAnimations.first(where: { $0.id == id })
                else { return }
                var updated = current
                updated[keyPath: keyPath] = value
                updateZoomAnimation(updated)
            }
        )
    }

    func zoomAnimationFocusBinding(_ index: Int) -> Binding<NormalizedPoint> {
        let id = editorStore.previewProject.zoomAnimations.indices.contains(index)
            ? editorStore.previewProject.zoomAnimations[index].id
            : selectedZoomID
        return Binding<NormalizedPoint>(
            get: {
                guard let id,
                      let currentIndex = editorStore.previewProject.zoomAnimations.firstIndex(where: { $0.id == id })
                else { return NormalizedPoint(x: 0.5, y: 0.5) }
                return editorStore.previewProject.zoomAnimations[currentIndex].focus
            },
            set: { value in
                guard let id,
                      let current = editorStore.previewProject.zoomAnimations.first(where: { $0.id == id })
                else { return }
                var updated = current
                updated.focus = value.constrained(
                    to: ZoomViewportTransform.focusEdgeInset
                )
                updated.origin = .manual
                updateZoomAnimation(updated)
            }
        )
    }

    func zoomAnimationFocusComponentBinding(
        _ index: Int,
        keyPath: WritableKeyPath<NormalizedPoint, Double>
    ) -> Binding<Double> {
        let point = zoomAnimationFocusBinding(index)
        return Binding(
            get: { point.wrappedValue[keyPath: keyPath] },
            set: { value in
                var updated = point.wrappedValue
                updated[keyPath: keyPath] = value
                point.wrappedValue = updated
            }
        )
    }

    func zoomAnimationOriginBinding(_ index: Int) -> Binding<ZoomKeyframeOrigin> {
        let id = editorStore.previewProject.zoomAnimations.indices.contains(index)
            ? editorStore.previewProject.zoomAnimations[index].id
            : selectedZoomID
        return Binding<ZoomKeyframeOrigin>(
            get: {
                guard let id,
                      let currentIndex = editorStore.previewProject.zoomAnimations.firstIndex(where: { $0.id == id })
                else { return ZoomKeyframeOrigin.manual }
                return editorStore.previewProject.zoomAnimations[currentIndex].origin
            },
            set: { (value: ZoomKeyframeOrigin) in
                guard let id,
                      let current = editorStore.previewProject.zoomAnimations.first(where: { $0.id == id })
                else { return }
                var updated = current
                updated.origin = value
                updateZoomAnimation(updated)
            }
        )
    }

    func zoomAnimationTransitionDurationBinding(_ index: Int) -> Binding<Double> {
        let id = editorStore.previewProject.zoomAnimations.indices.contains(index)
            ? editorStore.previewProject.zoomAnimations[index].id
            : selectedZoomID
        return Binding(
            get: {
                guard let id,
                      let animation = editorStore.previewProject.zoomAnimations.first(where: {
                          $0.id == id
                      }) else { return 0.7 }
                return (animation.enterDuration + animation.exitDuration) / 2
            },
            set: { value in
                guard let id,
                      let current = editorStore.previewProject.zoomAnimations.first(where: { $0.id == id })
                else { return }
                var updated = current
                let duration = min(max(value, 0.08), 3)
                updated.enterDuration = duration
                updated.exitDuration = duration
                updateZoomAnimation(updated)
            }
        )
    }

    func zoomAnimationStartBinding(_ index: Int) -> Binding<Double> {
        let id = editorStore.previewProject.zoomAnimations.indices.contains(index)
            ? editorStore.previewProject.zoomAnimations[index].id
            : selectedZoomID
        return Binding(
            get: {
                guard let id,
                      let current = editorStore.previewProject.zoomAnimations.first(where: { $0.id == id })
                else { return 0 }
                return current.startTime
            },
            set: { value in
                guard let id,
                      let current = editorStore.previewProject.zoomAnimations.first(where: { $0.id == id })
                else { return }
                updateZoomAnimation(
                    EditorTimelineMath.moving(
                        animation: current,
                        to: value,
                        among: editorStore.previewProject.zoomAnimations,
                        duration: timelineDuration
                    )
                )
            }
        )
    }

    func zoomAnimationDurationBinding(_ index: Int) -> Binding<Double> {
        let id = editorStore.previewProject.zoomAnimations.indices.contains(index)
            ? editorStore.previewProject.zoomAnimations[index].id
            : selectedZoomID
        return Binding(
            get: {
                guard let id,
                      let current = editorStore.previewProject.zoomAnimations.first(where: { $0.id == id })
                else { return 0.16 }
                return current.duration
            },
            set: { value in
                guard let id,
                      let current = editorStore.previewProject.zoomAnimations.first(where: { $0.id == id })
                else { return }
                updateZoomAnimation(
                    EditorTimelineMath.resizing(
                        animation: current,
                        proposedEnd: current.startTime + value,
                        among: editorStore.previewProject.zoomAnimations,
                        duration: timelineDuration
                    )
                )
            }
        )
    }

    func zoomTimeStepper(
        _ title: String,
        value: Binding<Double>,
        range: ClosedRange<Double>
    ) -> some View {
        Stepper(value: value, in: range, step: 0.1) {
            HStack {
                Text(title)
                Spacer()
                Text(String(format: "%.2fs", value.wrappedValue))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
        }
        .font(.caption)
        .padding(.horizontal, 8)
        .frame(height: 32)
        .background(Color.white.opacity(0.045), in: RoundedRectangle(cornerRadius: 7))
    }

    var cropSizeText: String {
        let crop = cropDraft.clamped()
        return "\(max(Int((crop.width * sourcePixelSize.width).rounded()), 1)) × "
            + "\(max(Int((crop.height * sourcePixelSize.height).rounded()), 1))"
    }

    func isNearPosition(_ position: NormalizedPoint, x: Double, y: Double) -> Bool {
        abs(position.x - x) < 0.08 && abs(position.y - y) < 0.08
    }


    func updateZoomAnimation(_ animation: ZoomAnimationClip) {
        if editorStore.interaction?.commandScope == .selection,
           editorStore.interaction?.selection == .zoom(animation.id) {
            editorStore.updateInteraction { project in
                guard let index = project.zoomAnimations.firstIndex(where: {
                    $0.id == animation.id
                }) else { return }
                project.zoomAnimations[index] = animation
            }
            return
        }
        do {
            try editorStore.replaceZoom(animation, actionName: "调整缩放")
        } catch {
            onError(error.localizedDescription)
        }
    }
}

/// 用户保存的摄像头+录屏组合布局预设（存 UserDefaults，按名称去重）。
struct SavedLayoutPreset: Codable, Equatable {
    var name: String
    var layout: CameraLayoutMode
    var cameraPosition: NormalizedPoint
    var cameraSize: Double
    var cameraRoundness: Double
    var screenPosition: NormalizedPoint
    var screenScale: Double
}
