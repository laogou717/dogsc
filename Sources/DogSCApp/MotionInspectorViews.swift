import Foundation
import RecorderCore
import SwiftUI

// MARK: - Inspector scope

struct MotionInspectorScopeHeader: View {
    let title: String
    let detail: String
    let isTarget: Bool
    let addTitle: String?
    let onAdd: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 8) {
                Label(title, systemImage: isTarget ? "keyframe" : "rectangle.stack")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(isTarget ? Color.white : Color.secondary)
                Spacer(minLength: 4)
                Text(isTarget ? "动画目标" : "初始状态")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(isTarget ? Color.white : Color.secondary)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 4)
                    .background(
                        isTarget ? Color.white.opacity(0.14) : Color.white.opacity(0.07),
                        in: Capsule()
                    )
            }

            Text(detail)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if let addTitle, let onAdd {
                Button(action: onAdd) {
                    Label(addTitle, systemImage: "plus.circle.fill")
                        .font(.caption.weight(.semibold))
                        .frame(maxWidth: .infinity)
                        .frame(height: 28)
                }
                .buttonStyle(.plain)
                // 雾白极简的主动作：米白底 + 深字，一个面板只此一处。
                .foregroundStyle(Color.black.opacity(0.85))
                .background(Color(white: 0.9), in: RoundedRectangle(cornerRadius: 8))
                .accessibilityIdentifier("motion.add-at-playhead")
            }
        }
        .padding(11)
        .background(Color.white.opacity(isTarget ? 0.055 : 0.03), in: RoundedRectangle(cornerRadius: 11))
        .overlay {
            RoundedRectangle(cornerRadius: 11)
                .stroke(isTarget ? Color.white.opacity(0.22) : Color.white.opacity(0.06), lineWidth: 1)
        }
    }
}

// MARK: - Screen motion

struct ScreenMotionTargetInspector: View {
    @ObservedObject var editorStore: EditorStore
    let clipID: UUID
    let onError: (String) -> Void

    private var clip: ScreenMotionClip? {
        editorStore.previewProject.timeline.screenMotionClips.first { $0.id == clipID }
    }

    var body: some View {
        if let clip {
            VStack(alignment: .leading, spacing: 13) {
                MotionInspectorScopeHeader(
                    title: "屏幕空间动画",
                    detail: "这些值只定义这一段动画的空间目标，不会改动初始状态或全片外观。",
                    isTarget: true,
                    addTitle: nil,
                    onAdd: nil
                )

                MotionPositionPad(
                    title: "目标位置",
                    point: clip.target.position,
                    onChanged: { point in
                        updateDraft { $0.target.position = point }
                    },
                    onEnded: { commitDraft(actionName: "调整屏幕动画位置") }
                )

                MotionValueSlider(
                    title: "目标大小",
                    value: clip.target.scale,
                    range: 0.25...4,
                    valueText: String(format: "%.2f×", clip.target.scale),
                    onChanged: { value in updateDraft { $0.target.scale = value } },
                    onEditingEnded: { commitDraft(actionName: "调整屏幕动画大小") }
                )

                VStack(alignment: .leading, spacing: 7) {
                    HStack {
                        Text("3D 倾斜")
                            .font(.caption.weight(.semibold))
                        Spacer()
                        Text("拖动平面")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    TiltPad(
                        rotationX: clip.target.rotationX,
                        rotationY: clip.target.rotationY,
                        onChanged: { x, y in
                            updateDraft {
                                $0.target.rotationX = x
                                $0.target.rotationY = y
                            }
                        },
                        onEnded: { commitDraft(actionName: "调整屏幕 3D 倾斜") }
                    )
                }

                EditorDisclosure("高级数值") {
                    VStack(alignment: .leading, spacing: 11) {
                        HStack(spacing: 6) {
                            MotionMetricTile(title: "X", value: clip.target.rotationX, suffix: "°")
                            MotionMetricTile(title: "Y", value: clip.target.rotationY, suffix: "°")
                        }
                        MotionValueSlider(
                            title: "平面旋转",
                            value: clip.target.rotationZ,
                            range: -30...30,
                            valueText: String(format: "%.1f°", clip.target.rotationZ),
                            onChanged: { value in updateDraft { $0.target.rotationZ = value } },
                            onEditingEnded: { commitDraft(actionName: "调整屏幕平面旋转") }
                        )
                        MotionValueSlider(
                            title: "透视强度",
                            value: clip.target.perspective,
                            range: 0...2,
                            valueText: String(format: "%.2f", clip.target.perspective),
                            onChanged: { value in updateDraft { $0.target.perspective = value } },
                            onEditingEnded: { commitDraft(actionName: "调整屏幕透视") }
                        )
                    }
                }

                MotionTimingControls(
                    timing: clip.timing,
                    maximumDuration: maximumDuration,
                    onDurationChanged: { value in updateDraft { $0.timing.duration = value } },
                    onDurationEnded: { commitDraft(actionName: "调整屏幕动画时长") },
                    onLeadInChanged: { value in updateDraft { $0.timing.leadInDuration = value } },
                    onLeadInEnded: { commitDraft(actionName: "调整屏幕动画过渡") },
                    onEasingChanged: { easing in replaceImmediately { $0.timing.easing = easing } }
                )

                motionFooter(
                    baseTitle: "返回屏幕初始状态",
                    onBase: { editorStore.selection = .screen },
                    onDelete: deleteClip
                )
            }
        } else {
            VStack(spacing: 10) {
                ContentUnavailableView(
                    "动画已不存在",
                    systemImage: "keyframe",
                    description: Text("可能已在时间线中删除或被撤销。")
                )
                Button("返回屏幕初始状态") { editorStore.selection = .screen }
                    .buttonStyle(.editorQuiet)
            }
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

    private func replaceImmediately(_ update: (inout ScreenMotionClip) -> Void) {
        guard var clip = editorStore.project.timeline.screenMotionClips.first(where: { $0.id == clipID }) else {
            return
        }
        update(&clip)
        do {
            try editorStore.replaceScreenMotion(clip, actionName: "调整屏幕动画缓动")
        } catch {
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

    var body: some View {
        if let clip {
            VStack(alignment: .leading, spacing: 13) {
                MotionInspectorScopeHeader(
                    title: "摄像头布局动画",
                    detail: "形状到全屏会使用同一组连续几何值过渡，不会在中途切换布局。",
                    isTarget: true,
                    addTitle: nil,
                    onAdd: nil
                )

                EditorSegmentedControl(
                    options: CameraTargetLayoutChoice.allCases,
                    title: { $0 == .shape ? "形状" : "全屏" },
                    selection: layoutChoiceBinding
                )
                .accessibilityLabel("目标布局")
                .accessibilityIdentifier("camera-motion.layout")

                Toggle(
                    "显示摄像头",
                    isOn: Binding(
                        get: { clip.target.opacity > 0.5 },
                        set: { visible in
                            replaceImmediately { $0.target.opacity = visible ? 1 : 0 }
                        }
                    )
                )
                if clip.target.opacity <= 0.5 {
                    Text("这一段摄像头完全隐藏，进入和离开时自动淡入淡出")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }

                if case .shape = clip.target.layout {
                    CameraShapeIconPicker(
                        selection: shapeBinding.wrappedValue,
                        onSelect: { shapeBinding.wrappedValue = $0 }
                    )
                }

                MotionPositionPad(
                    title: "目标位置",
                    point: clip.target.position,
                    onChanged: { point in updateDraft { $0.target.position = point } },
                    onEnded: { commitDraft(actionName: "调整摄像头动画位置") }
                )

                MotionValueSlider(
                    title: "目标大小",
                    value: clip.target.size,
                    range: 0.05...1,
                    valueText: String(format: "%.0f%%", clip.target.size * 100),
                    onChanged: { value in updateDraft { $0.target.size = value } },
                    onEditingEnded: { commitDraft(actionName: "调整摄像头动画大小") }
                )

                if case let .shape(shape) = clip.target.layout, shape != .circle {
                    MotionValueSlider(
                        title: "圆角",
                        value: clip.target.roundness,
                        range: 0...1,
                        valueText: String(format: "%.0f%%", clip.target.roundness * 100),
                        onChanged: { value in updateDraft { $0.target.roundness = value } },
                        onEditingEnded: { commitDraft(actionName: "调整摄像头动画圆角") }
                    )
                }

                MotionValueSlider(
                    title: "不透明度",
                    value: clip.target.opacity,
                    range: 0...1,
                    valueText: String(format: "%.0f%%", clip.target.opacity * 100),
                    onChanged: { value in updateDraft { $0.target.opacity = value } },
                    onEditingEnded: { commitDraft(actionName: "调整摄像头动画透明度") }
                )

                MotionTimingControls(
                    timing: clip.timing,
                    maximumDuration: maximumDuration,
                    onDurationChanged: { value in updateDraft { $0.timing.duration = value } },
                    onDurationEnded: { commitDraft(actionName: "调整摄像头动画时长") },
                    onLeadInChanged: { value in updateDraft { $0.timing.leadInDuration = value } },
                    onLeadInEnded: { commitDraft(actionName: "调整摄像头动画过渡") },
                    onEasingChanged: { easing in replaceImmediately { $0.timing.easing = easing } }
                )

                motionFooter(
                    baseTitle: "返回摄像头初始状态",
                    onBase: { editorStore.selection = .camera },
                    onDelete: deleteClip
                )
            }
        } else {
            VStack(spacing: 10) {
                ContentUnavailableView(
                    "动画已不存在",
                    systemImage: "keyframe",
                    description: Text("可能已在时间线中删除或被撤销。")
                )
                Button("返回摄像头初始状态") { editorStore.selection = .camera }
                    .buttonStyle(.editorQuiet)
            }
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
            try editorStore.replaceCameraMotion(clip, actionName: "调整摄像头动画")
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
    let onChanged: @MainActor @Sendable (Double) -> Void
    let onEditingEnded: @MainActor @Sendable () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(title).font(.caption)
                Spacer()
                Text(valueText)
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            EditorSlider(
                value: Binding(get: { value }, set: onChanged),
                range: range,
                onEditingChanged: { editing in
                    if !editing { onEditingEnded() }
                }
            )
            .accessibilityLabel(title)
            .accessibilityValue(valueText)
        }
    }
}

struct MotionPositionPad: View {
    let title: String
    let point: NormalizedPoint
    let onChanged: (NormalizedPoint) -> Void
    let onEnded: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title).font(.caption.weight(.semibold))
                Spacer()
                Text(String(format: "%.0f, %.0f", point.x * 100, point.y * 100))
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(.secondary)
                Button {
                    onChanged(NormalizedPoint(x: 0.5, y: 0.5))
                    onEnded()
                } label: {
                    Text("重置")
                        .font(.caption2)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .disabled(abs(point.x - 0.5) < 0.001 && abs(point.y - 0.5) < 0.001)
                .accessibilityLabel("重置\(title)")
            }
            GeometryReader { proxy in
                let inset: CGFloat = 10
                let usableWidth = max(proxy.size.width - inset * 2, 1)
                let usableHeight = max(proxy.size.height - inset * 2, 1)
                ZStack {
                    RoundedRectangle(cornerRadius: 10)
                        .fill(Color.black.opacity(0.22))
                    // 九宫格参考线（三分线），中线略亮
                    Path { path in
                        for fraction in [1.0 / 3.0, 2.0 / 3.0] {
                            let x = inset + usableWidth * fraction
                            let y = inset + usableHeight * fraction
                            path.move(to: CGPoint(x: x, y: inset))
                            path.addLine(to: CGPoint(x: x, y: inset + usableHeight))
                            path.move(to: CGPoint(x: inset, y: y))
                            path.addLine(to: CGPoint(x: inset + usableWidth, y: y))
                        }
                    }
                    .stroke(Color.white.opacity(0.08), style: StrokeStyle(lineWidth: 1, dash: [3, 4]))
                    Path { path in
                        path.move(to: CGPoint(x: proxy.size.width / 2, y: inset))
                        path.addLine(to: CGPoint(x: proxy.size.width / 2, y: proxy.size.height - inset))
                        path.move(to: CGPoint(x: inset, y: proxy.size.height / 2))
                        path.addLine(to: CGPoint(x: proxy.size.width - inset, y: proxy.size.height / 2))
                    }
                    .stroke(Color.white.opacity(0.14), style: StrokeStyle(lineWidth: 1, dash: [3, 4]))
                    // 网格交点标记
                    ForEach([0.0, 1.0 / 3.0, 0.5, 2.0 / 3.0, 1.0], id: \.self) { fx in
                        ForEach([0.0, 1.0 / 3.0, 0.5, 2.0 / 3.0, 1.0], id: \.self) { fy in
                            Circle()
                                .fill(Color.white.opacity(0.16))
                                .frame(width: 2.5, height: 2.5)
                                .position(x: inset + usableWidth * fx, y: inset + usableHeight * fy)
                        }
                    }
                    Circle()
                        .fill(editorAccent)
                        .frame(width: 13, height: 13)
                        .shadow(color: editorAccent.opacity(0.6), radius: 5)
                        .position(
                            x: inset + CGFloat(MotionInspectorLogic.clamp01(point.x)) * usableWidth,
                            y: inset + CGFloat(MotionInspectorLogic.clamp01(point.y)) * usableHeight
                        )
                }
                .contentShape(RoundedRectangle(cornerRadius: 10))
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { gesture in
                            onChanged(
                                MotionInspectorLogic.snappedToGrid(
                                    MotionInspectorLogic.normalizedPoint(
                                        location: gesture.location,
                                        size: proxy.size,
                                        inset: inset
                                    )
                                )
                            )
                        }
                        .onEnded { _ in onEnded() }
                )
            }
            .frame(height: 72)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(title)
            .accessibilityValue(String(format: "X %.0f，Y %.0f", point.x * 100, point.y * 100))
        }
    }
}

struct TiltPad: View {
    let rotationX: Double
    let rotationY: Double
    let onChanged: (Double, Double) -> Void
    let onEnded: () -> Void

    var body: some View {
        GeometryReader { proxy in
            let center = CGPoint(x: proxy.size.width / 2, y: proxy.size.height / 2)
            let point = MotionInspectorLogic.tiltPoint(
                rotationX: rotationX,
                rotationY: rotationY,
                size: proxy.size
            )
            ZStack {
                RoundedRectangle(cornerRadius: 12)
                    .fill(
                        LinearGradient(
                            colors: [Color.white.opacity(0.075), Color.black.opacity(0.22)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                RoundedRectangle(cornerRadius: 9)
                    .stroke(editorAccent.opacity(0.35), lineWidth: 1)
                    .padding(7)
                    .rotation3DEffect(.degrees(rotationX * 0.35), axis: (x: 1, y: 0, z: 0), perspective: 0.55)
                    .rotation3DEffect(.degrees(rotationY * 0.35), axis: (x: 0, y: 1, z: 0), perspective: 0.55)
                Path { path in
                    path.move(to: CGPoint(x: center.x, y: 8))
                    path.addLine(to: CGPoint(x: center.x, y: proxy.size.height - 8))
                    path.move(to: CGPoint(x: 8, y: center.y))
                    path.addLine(to: CGPoint(x: proxy.size.width - 8, y: center.y))
                }
                .stroke(Color.white.opacity(0.11), lineWidth: 1)
                Circle()
                    .fill(Color.white)
                    .frame(width: 14, height: 14)
                    .overlay(Circle().stroke(editorAccent, lineWidth: 3))
                    .shadow(color: editorAccent.opacity(0.65), radius: 6)
                    .position(point)
            }
            .contentShape(RoundedRectangle(cornerRadius: 12))
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { gesture in
                        let tilt = MotionInspectorLogic.tilt(
                            location: gesture.location,
                            size: proxy.size
                        )
                        onChanged(tilt.rotationX, tilt.rotationY)
                    }
                    .onEnded { _ in onEnded() }
            )
        }
        .frame(height: 92)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("3D 倾斜平面")
        .accessibilityValue(String(format: "X %.1f 度，Y %.1f 度", rotationX, rotationY))
        .accessibilityIdentifier("screen-motion.tilt-pad")
    }
}

struct MotionMetricTile: View {
    let title: String
    let value: Double
    let suffix: String

    var body: some View {
        HStack(spacing: 5) {
            Text(title)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
            Spacer()
            Text(String(format: "%.1f%@", value, suffix))
                .font(.system(.caption2, design: .monospaced))
        }
        .padding(.horizontal, 8)
        .frame(height: 27)
        .background(Color.white.opacity(0.045), in: RoundedRectangle(cornerRadius: 7))
    }
}

struct MotionTimingControls: View {
    let timing: TransitionTiming
    let maximumDuration: Double
    let onDurationChanged: @MainActor @Sendable (Double) -> Void
    let onDurationEnded: @MainActor @Sendable () -> Void
    let onLeadInChanged: @MainActor @Sendable (Double) -> Void
    let onLeadInEnded: @MainActor @Sendable () -> Void
    let onEasingChanged: @MainActor @Sendable (ZoomEasingPreset) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            Divider().overlay(dividerColor)
            HStack {
                Label("过渡", systemImage: "waveform.path")
                    .font(.caption.weight(.semibold))
                Spacer()
                Text(MotionInspectorLogic.timecode(timing.startTime))
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            // 速度预设：只改进入过渡（leadIn），整段时长决定保持多久
            HStack(spacing: 6) {
                ForEach([(title: "慢", duration: 1.2), (title: "标准", duration: 0.7), (title: "快", duration: 0.25)], id: \.title) { preset in
                    Button {
                        onLeadInChanged(min(preset.duration, max(timing.duration, 0.08)))
                        onLeadInEnded()
                    } label: {
                        Text(preset.title)
                            .font(.caption2)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 3)
                            .background(
                                RoundedRectangle(cornerRadius: 6)
                                    .fill(abs(timing.leadInDuration - preset.duration) < 0.001
                                          ? Color.white.opacity(0.16)
                                          : Color.white.opacity(0.07))
                            )
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("\(preset.title)速过渡")
                }
            }
            MotionValueSlider(
                title: "过渡",
                value: min(timing.leadInDuration, timing.duration),
                range: 0.08...max(max(timing.duration, 0.08), 0.08),
                valueText: String(format: "%.2fs", min(timing.leadInDuration, timing.duration)),
                onChanged: { value in onLeadInChanged(value) },
                onEditingEnded: { onLeadInEnded() }
            )
            MotionValueSlider(
                title: "时长",
                value: timing.duration,
                range: 0.08...max(maximumDuration, 0.08),
                valueText: String(format: "%.2fs", timing.duration),
                onChanged: { value in onDurationChanged(value) },
                onEditingEnded: { onDurationEnded() }
            )
            if timing.duration - timing.leadInDuration > 0.01 {
                Text("过渡完成后保持 \(String(format: "%.2f", timing.duration - min(timing.leadInDuration, timing.duration)))s")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Picker(
                "缓动",
                selection: Binding(get: { timing.easing }, set: onEasingChanged)
            ) {
                ForEach(ZoomEasingPreset.allCases) { preset in
                    Text(preset.shortName).tag(preset)
                }
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
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .controlSize(.small)
        Spacer(minLength: 4)
        Button(role: .destructive, action: onDelete) {
            Image(systemName: "trash")
                .frame(width: 24, height: 22)
        }
        .buttonStyle(.editorQuiet)
        .controlSize(.small)
        .help("删除该动画")
    }
}

// MARK: - Pure interaction math

enum MotionInspectorLogic {
    static let maximumTiltX = 28.0
    static let maximumTiltY = 32.0

    static func clamp01(_ value: Double) -> Double {
        min(max(value.isFinite ? value : 0.5, 0), 1)
    }

    static func normalizedPoint(location: CGPoint, size: CGSize, inset: CGFloat) -> NormalizedPoint {
        let width = max(size.width - inset * 2, 1)
        let height = max(size.height - inset * 2, 1)
        return NormalizedPoint(
            x: clamp01(Double((location.x - inset) / width)),
            y: clamp01(Double((location.y - inset) / height))
        )
    }

    /// 轻吸附到九宫格关键位（边缘、三分线、中心），阈值内才吸附，避免发粘。
    static func snappedToGrid(_ point: NormalizedPoint, threshold: Double = 0.035) -> NormalizedPoint {
        let anchors: [Double] = [0, 1.0 / 3.0, 0.5, 2.0 / 3.0, 1.0]
        func snap(_ value: Double) -> Double {
            for anchor in anchors where abs(value - anchor) <= threshold {
                return anchor
            }
            return value
        }
        return NormalizedPoint(x: snap(point.x), y: snap(point.y))
    }

    static func tilt(location: CGPoint, size: CGSize) -> (rotationX: Double, rotationY: Double) {
        let x = clamp01(Double(location.x / max(size.width, 1)))
        let y = clamp01(Double(location.y / max(size.height, 1)))
        return (
            rotationX: (0.5 - y) * maximumTiltX * 2,
            rotationY: (x - 0.5) * maximumTiltY * 2
        )
    }

    static func tiltPoint(rotationX: Double, rotationY: Double, size: CGSize) -> CGPoint {
        let x = clamp01(rotationY / (maximumTiltY * 2) + 0.5)
        let y = clamp01(0.5 - rotationX / (maximumTiltX * 2))
        return CGPoint(x: x * size.width, y: y * size.height)
    }

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
                Button {
                    onSelect(shape)
                } label: {
                    Image(systemName: icon(for: shape))
                        .font(.system(size: 13))
                        .foregroundStyle(
                            selection == shape ? Color.primary : Color.secondary
                        )
                        .frame(maxWidth: .infinity)
                        .frame(height: 26)
                        .background(
                            RoundedRectangle(cornerRadius: 7, style: .continuous)
                                .fill(selection == shape ? Color.white.opacity(0.14) : Color.white.opacity(0.07))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 7, style: .continuous)
                                .stroke(selection == shape ? Color.white.opacity(0.75) : .clear, lineWidth: 1)
                        )
                }
                .buttonStyle(.plain)
                .help(shape.rawValue)
                .accessibilityLabel("形状：\(shape.rawValue)")
            }
        }
        .accessibilityElement(children: .contain)
    }
}
