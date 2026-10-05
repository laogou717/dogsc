import AppKit
import RecorderCore
import SwiftUI

/// Shared by zoom and screen 3D clips. All changes use the same selection
/// transaction as the other animation parameters (one drag / one undo).
struct EditorFocusEffectInspector: View {
    @ObservedObject var editorStore: EditorStore
    var sourceImage: NSImage? = nil
    let selection: EditorSelection
    let onError: (String) -> Void

    private var effect: FocusEffect? {
        switch selection {
        case let .zoom(id):
            return editorStore.previewProject.zoomAnimations.first { $0.id == id }?.focusEffect
        case let .screenMotion(id):
            return editorStore.previewProject.timeline.screenMotionClips.first { $0.id == id }?.focusEffect
        default: return nil
        }
    }

    private var isLinear: Bool {
        if case .screenMotion = selection { return true }
        return effect?.shape == .linear
    }

    var body: some View {
        EditorInspectorSection(isLinear ? "线性虚化" : "聚焦") {
            HStack {
                Text(appLocalized(isLinear ? "清晰带 · 两侧渐变虚化" : "清晰焦点 · 柔化外围"))
                    .font(.appUI(.caption))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 8)
                EditorToggle(isOn: Binding(get: { effect != nil }, set: {
                    update($0 ? FocusEffect(linear: isLinear) : nil)
                    commit()
                }))
                .accessibilityLabel("启用聚焦")
            }
            if let effect {
                if isLinear {
                    Label("实线调整区域，虚线调整羽化；拖动圆柄旋转", systemImage: "hand.draw")
                        .font(.appUI(size: 11)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    MotionValueSlider(title: "方向", value: effect.angleDegrees ?? 0, range: 0...360,
                        valueText: EditorSliderValueFormat.degrees.text(for: effect.angleDegrees ?? 0),
                        formatValue: { EditorSliderValueFormat.degrees.text(for: $0) }, inputFormat: .degrees,
                        onChanged: { value in
                            var updated = effect
                            updated.angleDegrees = value
                            update(updated)
                        }, onEditingEnded: commit, onEditingCancelled: { editorStore.cancelInteraction() },
                        onTextPreviewValidityChanged: updateTextDraftValidity)
                } else {
                EditorSegmentedControl(
                    options: FocusEffectTarget.allCases,
                    title: { target in
                        switch target {
                        case .animation: return "随运镜"
                        case .pointer: return "随鼠标"
                        case .fixed: return "固定"
                        }
                    },
                    selection: Binding(get: { effect.target }, set: { target in
                        var updated = effect
                        updated.target = target
                        update(updated)
                        commit()
                    })
                )
                if effect.target == .fixed {
                    EditorPositionPad(title: "聚焦位置", point: effect.center,
                        onChanged: { point in
                            var updated = effect
                            updated.center = point
                            update(updated)
                        }, onEnded: commit, onCancelled: { editorStore.cancelInteraction() },
                        onTextPreviewValidityChanged: updateTextDraftValidity)
                }
                }
                parameter("清晰范围", keyPath: \.size, range: 0.1...1, effect: effect)
                parameter("模糊程度", keyPath: \.blur, range: 0...1, effect: effect)
                parameter("羽化范围", keyPath: \.softness, range: 0...1, effect: effect)
                if !isLinear { parameter("暗角", keyPath: \.dimming, range: 0...1, effect: effect) }
                Text("随动画进入和退出，摄像头与贴图保持清晰。")
                    .font(.appUI(.caption2))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func parameter(_ title: String, keyPath: WritableKeyPath<FocusEffect, Double>,
                           range: ClosedRange<Double>, effect: FocusEffect) -> some View {
        MotionValueSlider(title: title, value: effect[keyPath: keyPath], range: range,
            valueText: EditorSliderValueFormat.percent.text(for: effect[keyPath: keyPath]),
            formatValue: { EditorSliderValueFormat.percent.text(for: $0) }, inputFormat: .percent,
            onChanged: { value in
                var updated = effect
                updated[keyPath: keyPath] = value
                update(updated)
            }, onEditingEnded: commit, onEditingCancelled: { editorStore.cancelInteraction() },
            onTextPreviewValidityChanged: updateTextDraftValidity)
    }

    private func update(_ proposed: FocusEffect?) {
        var effect = proposed
        if isLinear {
            effect?.shape = .linear
            effect?.target = .fixed
            effect?.dimming = 0
        }
        guard editorStore.selection == selection else { return }
        _ = editorStore.beginContinuousInteraction(commandScope: .selection)
        editorStore.updateInteraction { project in
            switch selection {
            case let .zoom(id):
                guard let index = project.zoomAnimations.firstIndex(where: { $0.id == id }) else { return }
                project.zoomAnimations[index].focusEffect = effect
            case let .screenMotion(id):
                guard let index = project.timeline.screenMotionClips.firstIndex(where: { $0.id == id }) else { return }
                project.timeline.screenMotionClips[index].focusEffect = effect
            default: break
            }
        }
    }

    private func updateTextDraftValidity(_ isValid: Bool) {
        guard editorStore.selection == selection else { return }
        updateEditorTextPreviewValidity(
            store: editorStore, isValid: isValid,
            commandScope: .selection, selection: selection,
            actionName: "调整聚焦"
        )
    }

    private func commit() {
        updateEditorContinuousInteraction(store: editorStore, isEditing: false,
            commandScope: .selection, actionName: "调整聚焦", onError: onError)
    }
}
