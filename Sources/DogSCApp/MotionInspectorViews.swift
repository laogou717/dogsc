import Foundation
import RecorderCore
import SwiftUI

// MARK: - Inspector scope

struct MotionInspectorScopeHeader: View {
    let title: String
    let detail: String
    var statusTitle: String? = nil
    var showsContextHeader = true
    let addTitle: String
    let onAdd: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            if showsContextHeader {
                HStack(spacing: 8) {
                    Label(title, systemImage: "rectangle.stack")
                        .font(.appUI(.caption, weight: .semibold))
                        .foregroundStyle(Color.secondary)
                    Spacer(minLength: 4)
                    Text(statusTitle ?? "初始状态")
                        .font(.appUI(size: 10, weight: .semibold))
                        .foregroundStyle(Color.secondary)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 4)
                        .background(
                            EditorTheme.chrome(0.07),
                            in: Capsule()
                        )
                }
            }

            Text(detail)
                .font(.appUI(.caption2))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Button(action: onAdd) {
                Label(addTitle, systemImage: "plus.circle.fill")
                    .font(.appUI(.caption, weight: .semibold))
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.editorPrimary(minHeight: 32))
            .accessibilityIdentifier("motion.add-at-playhead")
        }
        .padding(11)
        .background(EditorTheme.chrome(0.03), in: RoundedRectangle(cornerRadius: 11))
        .overlay {
            RoundedRectangle(cornerRadius: 11)
                .stroke(EditorTheme.chrome(0.06), lineWidth: 1)
        }
    }
}

// MARK: - Screen motion

struct ScreenMotionTargetInspector: View {
    var sourceImage: NSImage? = nil
    @ObservedObject var editorStore: EditorStore
    let clipID: UUID
    let onError: (String) -> Void

    private var clip: ScreenMotionClip? {
        editorStore.previewProject.timeline.screenMotionClips.first { $0.id == clipID }
    }

    var body: some View {
        if let clip {
            VStack(alignment: .leading, spacing: 13) {
                EditorInspectorSection("构图") {
                    EditorPositionPad(
                        title: "缩放锚点",
                        detail: "放大时画面向锚点的反方向展开；缩小时会向锚点收拢，因此 1× 两侧的移动方向会自然相反。",
                        point: clip.target.position,
                        onChanged: { point in
                            updateDraft { $0.target.position = point }
                        },
                        onEnded: { commitDraft(actionName: "调整屏幕 3D 位置") },
                        onCancelled: { editorStore.cancelInteraction() }
                    )

                    MotionValueSlider(
                        title: "目标大小",
                        value: clip.target.scale,
                        range: 0.25...4,
                        valueText: String(format: "%.2f×", clip.target.scale),
                        formatValue: { String(format: "%.2f×", $0) },
                        inputFormat: .multiplier,
                        onChanged: { value in updateDraft { $0.target.scale = value } },
                        onEditingEnded: { commitDraft(actionName: "调整屏幕 3D 大小") },
                        onEditingCancelled: { editorStore.cancelInteraction() }
                    )
                }

                EditorInspectorSection("空间姿态") {
                    EditorTiltPad(
                        rotationX: clip.target.rotationX,
                        rotationY: clip.target.rotationY,
                        onChanged: { x, y in
                            updateDraft {
                                $0.target.rotationX = x
                                $0.target.rotationY = y
                            }
                        },
                        onEnded: { commitDraft(actionName: "调整屏幕 3D 倾斜") },
                        onCancelled: { editorStore.cancelInteraction() }
                    )

                    EditorDisclosure(
                        "平面旋转与透视",
                        detail: "Z \(String(format: "%.1f°", clip.target.rotationZ)) · 透视 \(String(format: "%.2f", clip.target.perspective))"
                    ) {
                        VStack(alignment: .leading, spacing: 11) {
                            MotionValueSlider(
                                title: "平面旋转",
                                value: clip.target.rotationZ,
                                range: -30...30,
                                valueText: String(format: "%.1f°", clip.target.rotationZ),
                                formatValue: { String(format: "%.1f°", $0) },
                                inputFormat: .decimal1,
                                onChanged: { value in updateDraft { $0.target.rotationZ = value } },
                                onEditingEnded: { commitDraft(actionName: "调整屏幕平面旋转") },
                                onEditingCancelled: { editorStore.cancelInteraction() }
                            )
                            MotionValueSlider(
                                title: "透视强度",
                                value: clip.target.perspective,
                                range: 0...2,
                                valueText: String(format: "%.2f", clip.target.perspective),
                                formatValue: { String(format: "%.2f", $0) },
                                inputFormat: .decimal2,
                                onChanged: { value in updateDraft { $0.target.perspective = value } },
                                onEditingEnded: { commitDraft(actionName: "调整屏幕透视") },
                                onEditingCancelled: { editorStore.cancelInteraction() }
                            )
                        }
                    }
                }

                EditorFocusEffectInspector(editorStore: editorStore, sourceImage: sourceImage,
                    selection: .screenMotion(clipID), onError: onError)

                EditorInspectorSection("动画时间") {
                    MotionTimingControls(
                        timing: clip.timing,
                        maximumDuration: maximumDuration,
                        showsHeader: false,
                        onDurationChanged: { value in updateDraft { $0.timing.duration = value } },
                        onDurationEnded: { commitDraft(actionName: "调整屏幕 3D 时长") },
                        onDurationCancelled: { editorStore.cancelInteraction() },
                        onLeadInChanged: { value in updateDraft {
                        $0.timing.leadInDuration = value
                        $0.timing.preferredLeadInDuration = value
                        $0.timing.leadInProgressOffset = 0
                    } },
                        onLeadInEnded: { commitDraft(actionName: "调整屏幕 3D 过渡") },
                        onLeadInCancelled: { editorStore.cancelInteraction() }
                    )
                }

                motionFooter(
                    baseTitle: "返回屏幕初始状态",
                    onBase: { editorStore.selection = .screen },
                    onDelete: deleteClip
                )
            }
        } else {
            EditorInspectorEmptyState(
                title: "动画已不存在",
                detail: "它可能已在时间线中删除或被撤销。",
                systemImage: "cube.transparent",
                actionTitle: "返回屏幕初始状态",
                action: { editorStore.selection = .screen }
            )
        }
    }

    private var maximumDuration: Double {
        MotionInspectorLogic.maximumScreenDuration(
            after: clipID,
            in: editorStore.project.timeline,
            fallback: 3
        )
    }

    private func beginDraftIfNeeded() {
        let selection = EditorSelection.screenMotion(clipID)
        guard editorStore.interaction?.selection != selection else { return }
        editorStore.cancelInteraction()
        editorStore.beginInteraction(tool: .editScreenMotion, selection: selection)
    }

    private func updateDraft(_ update: @escaping (inout ScreenMotionClip) -> Void) {
        beginDraftIfNeeded()
        editorStore.updateInteraction { project in
            guard let index = project.timeline.screenMotionClips.firstIndex(where: { $0.id == clipID }) else {
                return
            }
            update(&project.timeline.screenMotionClips[index])
        }
    }

    private func commitDraft(actionName: String) {
        do {
            try editorStore.commitInteraction(actionName: actionName)
        } catch {
            editorStore.cancelInteraction()
            onError(error.localizedDescription)
        }
    }

    private func deleteClip() {
        do {
            try editorStore.removeScreenMotion(id: clipID)
            editorStore.selection = .screen
        } catch {
            onError(error.localizedDescription)
        }
    }
}

// MARK: - Camera motion

struct CameraMotionTargetInspector: View {
    @ObservedObject var editorStore: EditorStore
    let clipID: UUID
    let onError: (String) -> Void

    private var clip: CameraMotionClip? {
        editorStore.previewProject.timeline.cameraMotionClips.first { $0.id == clipID }
    }

    private var targetIsVisible: Bool {
        (clip?.target.opacity ?? 0) > 0.001
    }

    var body: some View {
        if let clip {
            VStack(alignment: .leading, spacing: 13) {
                EditorInspectorSection("目标状态") {
                    EditorToggle(
                        isOn: Binding(
                            get: { targetIsVisible },
                            set: { visible in
                                replaceImmediately { $0.target.opacity = visible ? 1 : 0 }
                            }
                        ),
                        title: "显示摄像头"
                    )
                    MotionValueSlider(
                        title: "不透明度",
                        value: clip.target.opacity,
                        range: 0...1,
                        valueText: String(format: "%.0f%%", clip.target.opacity * 100),
                        formatValue: { String(format: "%.0f%%", $0 * 100) },
                        inputFormat: .percent,
                        onChanged: { value in updateDraft { $0.target.opacity = value } },
                        onEditingEnded: { commitDraft(actionName: "调整摄像运动透明度") },
                        onEditingCancelled: { editorStore.cancelInteraction() }
                    )

                    if targetIsVisible {
                        EditorSegmentedControl(
                            options: CameraTargetLayoutChoice.allCases,
                            title: { $0 == .shape ? "形状" : "全屏" },
                            selection: layoutChoiceBinding
                        )
                        .accessibilityIdentifier("camera-motion.layout")

                        if case .shape = clip.target.layout {
                            CameraShapeIconPicker(
                                selection: shapeBinding.wrappedValue,
                                onSelect: { shapeBinding.wrappedValue = $0 }
                            )
                        }
                    } else {
                        Text("这段动画只让摄像头原地淡出，位置和形状不参与过渡。")
                            .font(.appUI(.caption2))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                if targetIsVisible, case .shape = clip.target.layout {
                    EditorInspectorSection("位置与尺寸") {
                        EditorPositionPad(
                            title: "目标位置",
                            point: clip.target.position,
                            onChanged: { point in updateDraft { $0.target.position = point } },
                            onEnded: { commitDraft(actionName: "调整摄像运动位置") },
                            onCancelled: { editorStore.cancelInteraction() }
                        )

                        MotionValueSlider(
                            title: "目标大小",
                            value: clip.target.size,
                            range: 0.05...1,
                            valueText: String(format: "%.0f%%", clip.target.size * 100),
                            formatValue: { String(format: "%.0f%%", $0 * 100) },
                            inputFormat: .percent,
                            onChanged: { value in updateDraft { $0.target.size = value } },
                            onEditingEnded: { commitDraft(actionName: "调整摄像运动大小") },
                            onEditingCancelled: { editorStore.cancelInteraction() }
                        )

                        if case let .shape(shape) = clip.target.layout, shape != .circle {
                            MotionValueSlider(
                                title: "圆角",
                                value: clip.target.roundness,
                                range: 0...1,
                                valueText: String(format: "%.0f%%", clip.target.roundness * 100),
                                formatValue: { String(format: "%.0f%%", $0 * 100) },
                                inputFormat: .percent,
                                onChanged: { value in updateDraft { $0.target.roundness = value } },
                                onEditingEnded: { commitDraft(actionName: "调整摄像运动圆角") },
                                onEditingCancelled: { editorStore.cancelInteraction() }
                            )
                        }
                    }
                }

                EditorInspectorSection("动画时间") {
                    MotionTimingControls(
                        timing: clip.timing,
                        maximumDuration: maximumDuration,
                        showsHeader: false,
                        onDurationChanged: { value in updateDraft { $0.timing.duration = value } },
                        onDurationEnded: { commitDraft(actionName: "调整摄像运动时长") },
                        onDurationCancelled: { editorStore.cancelInteraction() },
                        onLeadInChanged: { value in updateDraft {
                        $0.timing.leadInDuration = value
                        $0.timing.preferredLeadInDuration = value
                        $0.timing.leadInProgressOffset = 0
                    } },
                        onLeadInEnded: { commitDraft(actionName: "调整摄像运动过渡") },
                        onLeadInCancelled: { editorStore.cancelInteraction() }
                    )
                }

                motionFooter(
                    baseTitle: "返回摄像头初始状态",
                    onBase: { editorStore.selection = .camera },
                    onDelete: deleteClip
                )
            }
        } else {
            EditorInspectorEmptyState(
                title: "动画已不存在",
                detail: "它可能已在时间线中删除或被撤销。",
                systemImage: "video.fill",
                actionTitle: "返回摄像头初始状态",
                action: { editorStore.selection = .camera }
            )
        }
    }

    private var maximumDuration: Double {
        MotionInspectorLogic.maximumCameraDuration(
            after: clipID,
            in: editorStore.project.timeline,
            fallback: 3
        )
    }

    private var layoutChoiceBinding: Binding<CameraTargetLayoutChoice> {
        Binding(
            get: {
                guard let clip else { return .shape }
                if case .fullscreen = clip.target.layout { return .fullscreen }
                return .shape
            },
            set: { choice in
                replaceImmediately { clip in
                    switch choice {
                    case .fullscreen:
                        clip.target.layout = .fullscreen
                    case .shape:
                        clip.target.layout = .shape(editorStore.project.camera.shape)
                    }
                }
            }
        )
    }

    private var shapeBinding: Binding<CameraShape> {
        Binding(
            get: {
                guard let clip, case let .shape(shape) = clip.target.layout else {
                    return editorStore.project.camera.shape
                }
                return shape
            },
            set: { shape in replaceImmediately { $0.target.layout = .shape(shape) } }
        )
    }

    private func beginDraftIfNeeded() {
        let selection = EditorSelection.cameraMotion(clipID)
        guard editorStore.interaction?.selection != selection else { return }
        editorStore.cancelInteraction()
        editorStore.beginInteraction(tool: .editCameraMotion, selection: selection)
    }

    private func updateDraft(_ update: @escaping (inout CameraMotionClip) -> Void) {
        beginDraftIfNeeded()
        editorStore.updateInteraction { project in
            guard let index = project.timeline.cameraMotionClips.firstIndex(where: { $0.id == clipID }) else {
                return
            }
            update(&project.timeline.cameraMotionClips[index])
        }
    }

    private func commitDraft(actionName: String) {
        do {
            try editorStore.commitInteraction(actionName: actionName)
        } catch {
            editorStore.cancelInteraction()
            onError(error.localizedDescription)
        }
    }

    private func replaceImmediately(_ update: (inout CameraMotionClip) -> Void) {
        guard var clip = editorStore.project.timeline.cameraMotionClips.first(where: { $0.id == clipID }) else {
            return
        }
        update(&clip)
        do {
            try editorStore.replaceCameraMotion(clip, actionName: "调整摄像运动")
        } catch {
            onError(error.localizedDescription)
        }
    }

    private func deleteClip() {
        do {
            try editorStore.removeCameraMotion(id: clipID)
            editorStore.selection = .camera
        } catch {
            onError(error.localizedDescription)
        }
    }
}

// MARK: - Shared motion controls

enum CameraTargetLayoutChoice: String, CaseIterable, Hashable {
    case shape
    case fullscreen
}

struct MotionValueSlider: View {
    let title: String
    let value: Double
    let range: ClosedRange<Double>
    let valueText: String
    let formatValue: (Double) -> String
    let inputFormat: EditorSliderValueFormat
    let onChanged: @MainActor @Sendable (Double) -> Void
    let onEditingEnded: @MainActor @Sendable () -> Void
    let onEditingCancelled: @MainActor @Sendable () -> Void
    @State private var isSliderEditing = false
    @State private var isTextEditing = false
    @State private var hasTextPreview = false

    var body: some View {
        HStack(spacing: 10) {
            Text(appLocalized(title)).font(.appUI(size: 13)).foregroundStyle(EditorTheme.chrome(0.82))
                .frame(width: 88, alignment: .leading).lineLimit(2)
            EditorSlider(
                value: Binding(
                    get: { value },
                    set: { newValue in onChanged(newValue) }
                ),
                range: range,
                title: nil,
                formatValue: formatValue,
                showsFloatingValue: false,
                scale: inputFormat.sliderScale(in: range),
                onEditingChanged: { editing in
                    isSliderEditing = editing
                    if !editing {
                        onEditingEnded()
                    }
                }
            )
            .disabled(isTextEditing)
            .accessibilityLabel(title)
            .accessibilityValue(valueText)
            EditorInspectorParameterReadout(
                title: title,
                valueText: valueText,
                isEditing: isSliderEditing || isTextEditing,
                editConfiguration: EditorInspectorParameterEditConfiguration(
                    draftText: inputFormat.editingText(for: value),
                    onBegin: beginTextEditing,
                    onPreview: previewTextValue,
                    onCommit: commitTextEditing,
                    onCancel: cancelTextEditing
                ),
                showsTitle: false,
                isEmbedded: false
            )
            .frame(width: 66, height: 32)
        }
    }

    private func beginTextEditing() {
        isTextEditing = true
        hasTextPreview = false
    }

    private func previewTextValue(_ text: String) -> Bool {
        guard let parsed = inputFormat.value(from: text) else { return false }
        hasTextPreview = true
        onChanged(min(max(parsed, range.lowerBound), range.upperBound))
        return true
    }

    private func commitTextEditing() {
        isTextEditing = false
        if hasTextPreview {
            onEditingEnded()
        }
        hasTextPreview = false
    }

    private func cancelTextEditing() {
        isTextEditing = false
        if hasTextPreview {
            onEditingCancelled()
        }
        hasTextPreview = false
    }
}

struct MotionTimingControls: View {
    let timing: TransitionTiming
    let maximumDuration: Double
    var showsHeader = true
    let onDurationChanged: @MainActor @Sendable (Double) -> Void
    let onDurationEnded: @MainActor @Sendable () -> Void
    let onDurationCancelled: @MainActor @Sendable () -> Void
    let onLeadInChanged: @MainActor @Sendable (Double) -> Void
    let onLeadInEnded: @MainActor @Sendable () -> Void
    let onLeadInCancelled: @MainActor @Sendable () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            if showsHeader {
                Divider().overlay(dividerColor)
            }
            HStack {
                if showsHeader {
                    Label("过渡", systemImage: "waveform.path")
                        .font(.appUI(.caption, weight: .semibold))
                } else {
                    Text("开始位置")
                        .font(.appUI(.caption))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Text(MotionInspectorLogic.timecode(timing.startTime))
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            MotionValueSlider(
                title: "过渡时长",
                value: min(timing.leadInDuration, timing.duration),
                range: 0...max(timing.duration, 0),
                valueText: String(format: "%.2fs", min(timing.leadInDuration, timing.duration)),
                formatValue: { String(format: "%.2fs", $0) },
                inputFormat: .seconds,
                onChanged: { value in onLeadInChanged(value) },
                onEditingEnded: { onLeadInEnded() },
                onEditingCancelled: { onLeadInCancelled() }
            )
            MotionValueSlider(
                title: "时长",
                value: timing.duration,
                range: 0.08...max(maximumDuration, 0.08),
                valueText: String(format: "%.2fs", timing.duration),
                formatValue: { String(format: "%.2fs", $0) },
                inputFormat: .seconds,
                onChanged: { value in onDurationChanged(value) },
                onEditingEnded: { onDurationEnded() },
                onEditingCancelled: { onDurationCancelled() }
            )
            if timing.duration - timing.leadInDuration > 0.01 {
                Text("过渡完成后保持 \(String(format: "%.2f", timing.duration - min(timing.leadInDuration, timing.duration)))s")
                    .font(.appUI(.caption2))
                    .foregroundStyle(.secondary)
            }
        }
    }
}

@MainActor
@ViewBuilder
private func motionFooter(
    baseTitle: String,
    onBase: @escaping () -> Void,
    onDelete: @escaping () -> Void
) -> some View {
    HStack(spacing: 8) {
        Button(action: onBase) {
            Label(baseTitle, systemImage: "chevron.left")
        }
            .buttonStyle(.editorGhost)
            .foregroundStyle(.secondary)
            .controlSize(.small)
        Spacer(minLength: 4)
        Button(role: .destructive, action: onDelete) {
            Image(systemName: "trash")
        }
        .buttonStyle(.editorDestructiveIcon)
        .help("删除该动画")
    }
}

// MARK: - Pure interaction math

enum MotionInspectorLogic {
    static func screenTarget(at time: TimeInterval, in project: RecorderProject) -> ScreenMotionState {
        let base = ScreenMotionState(
            position: project.canvas.contentPosition,
            scale: project.canvas.contentScale
        )
        return ScreenMotionTrack(project.timeline.screenMotionClips).sample(
            at: max(time.isFinite ? time : 0, 0),
            base: base,
            motion: project.motion
        )
    }

    static func cameraTarget(at time: TimeInterval, in project: RecorderProject) -> CameraMotionState {
        let base = CameraMotionState(
            layout: .shape(project.camera.shape),
            position: project.camera.position,
            size: project.camera.size,
            roundness: project.camera.roundness,
            opacity: 1
        )
        let safeTime = max(time.isFinite ? time : 0, 0)
        var latest: CameraMotionClip?
        for clip in project.timeline.cameraMotionClips
        where clip.timing.startTime <= safeTime {
            if latest == nil || motionOrder(latest!, clip) {
                latest = clip
            }
        }
        return latest?.target ?? base
    }

    static func maximumScreenDuration(
        after clipID: UUID,
        in timeline: ProjectTimeline,
        fallback: Double
    ) -> Double {
        maximumDuration(
            after: clipID,
            clips: timeline.screenMotionClips,
            identity: { ($0.id, $0.timing) },
            fallback: fallback
        )
    }

    static func maximumCameraDuration(
        after clipID: UUID,
        in timeline: ProjectTimeline,
        fallback: Double
    ) -> Double {
        maximumDuration(
            after: clipID,
            clips: timeline.cameraMotionClips,
            identity: { ($0.id, $0.timing) },
            fallback: fallback
        )
    }

    static func timecode(_ time: TimeInterval) -> String {
        let safe = max(time.isFinite ? time : 0, 0)
        return String(format: "%02d:%05.2f", Int(safe) / 60, safe.truncatingRemainder(dividingBy: 60))
    }

    private static func maximumDuration<Element>(
        after clipID: UUID,
        clips: [Element],
        identity: (Element) -> (UUID, TransitionTiming),
        fallback: Double
    ) -> Double {
        guard let current = clips.lazy.map(identity).first(where: { $0.0 == clipID }) else {
            return max(fallback, 0.08)
        }
        var successor: (UUID, TransitionTiming)?
        for clip in clips {
            let candidate = identity(clip)
            guard candidate.0 != clipID,
                  motionTimingPrecedes(current, candidate) else { continue }
            if successor == nil || motionTimingPrecedes(candidate, successor!) {
                successor = candidate
            }
        }
        guard let successor else {
            return max(max(fallback, current.1.duration), 0.08)
        }
        return max(successor.1.startTime - current.1.startTime, 0.08)
    }

    private static func motionTimingPrecedes(
        _ lhs: (UUID, TransitionTiming),
        _ rhs: (UUID, TransitionTiming)
    ) -> Bool {
        lhs.1.startTime == rhs.1.startTime
            ? lhs.0.uuidString < rhs.0.uuidString
            : lhs.1.startTime < rhs.1.startTime
    }

    private static func motionOrder(_ lhs: CameraMotionClip, _ rhs: CameraMotionClip) -> Bool {
        lhs.timing.startTime == rhs.timing.startTime
            ? lhs.id.uuidString < rhs.id.uuidString
            : lhs.timing.startTime < rhs.timing.startTime
    }
}

/// 摄像头形状图标选择器：圆就是圆、方就是方，直接点图标，不用下拉菜单。
struct CameraShapeIconPicker: View {
    let selection: CameraShape
    let onSelect: (CameraShape) -> Void

    private func icon(for shape: CameraShape) -> String {
        switch shape {
        case .square: return "square"
        case .horizontal: return "rectangle"
        case .vertical: return "rectangle.portrait"
        case .original: return "aspectratio"
        case .circle: return "circle"
        }
    }

    var body: some View {
        HStack(spacing: 6) {
            ForEach(CameraShape.allCases) { shape in
                let isSelected = selection == shape
                Button {
                    onSelect(shape)
                } label: {
                    Image(systemName: icon(for: shape))
                        .font(.appUI(size: 13))
                        .foregroundStyle(
                            isSelected ? Color.primary : Color.secondary
                        )
                        .frame(maxWidth: .infinity)
                        .frame(height: 30)
                        .background(
                            RoundedRectangle(cornerRadius: 7, style: .continuous)
                                .fill(EditorTheme.chrome(isSelected ? 0.14 : 0.07))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 7, style: .continuous)
                                .stroke(isSelected ? EditorTheme.chrome(0.75) : .clear, lineWidth: 1)
                        )
                }
                .buttonStyle(.editorThumbnail)
                .help(appLocalized(shape.rawValue))
                .accessibilityLabel("\(appLocalized("形状"))：\(appLocalized(shape.rawValue))")
                .accessibilityAddTraits(isSelected ? .isSelected : [])
            }
        }
        .accessibilityElement(children: .contain)
    }
}
