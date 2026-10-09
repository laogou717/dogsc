import RecorderCore
import SwiftUI

enum EditorCanvasPaddingEdge: String, CaseIterable {
    case top, right, bottom, left

    var isHorizontal: Bool { self == .left || self == .right }
    var title: String {
        switch self {
        case .top: "上边距"
        case .right: "右边距"
        case .bottom: "下边距"
        case .left: "左边距"
        }
    }
    var shortTitle: String {
        switch self {
        case .top: "上"
        case .right: "右"
        case .bottom: "下"
        case .left: "左"
        }
    }
    var keyPath: WritableKeyPath<CanvasPadding, Double> {
        switch self {
        case .top: \.top
        case .right: \.right
        case .bottom: \.bottom
        case .left: \.left
        }
    }
}

/// Exact entry uses the same preview, validation and commit boundary as sliders.
struct EditorCanvasPaddingValue: View {
    @ObservedObject var editorStore: EditorStore
    let edge: EditorCanvasPaddingEdge
    @Binding var value: Double
    let isSelected: Bool
    let isSliderEditing: Bool
    let onSelect: () -> Void
    let onError: (String) -> Void
    @State private var isTextEditing = false
    @State private var hasPreview = false

    var body: some View {
        VStack(spacing: 3) {
            Button(action: onSelect) {
                Text(appLocalized(edge.shortTitle))
                    .font(.appUI(size: 10, weight: .medium))
                    .foregroundStyle(isSelected ? EditorTheme.primaryText : EditorTheme.secondaryText)
                    .frame(width: 56, height: 14)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .appButtonKeyboardFocus(in: RoundedRectangle(cornerRadius: 4))
            .accessibilityLabel(String(format: appLocalized("选择%@"), appLocalized(edge.title)))
            .accessibilityIdentifier("editor.canvas.padding.select.\(edge.rawValue)")

            EditorInspectorParameterReadout(
                title: edge.title,
                valueText: EditorSliderValueFormat.points.text(for: value),
                isEditing: isTextEditing || (isSelected && isSliderEditing),
                editConfiguration: EditorInspectorParameterEditConfiguration(
                    draftText: EditorSliderValueFormat.points.editingText(for: value),
                    onBegin: beginEditing, onPreview: preview,
                    onCommit: { finish(commits: true) }, onCancel: { finish(commits: false) }
                ),
                showsTitle: false, isEmbedded: true
            )
            .frame(width: 56, height: 30)
            .background(isSelected ? EditorTheme.selectionWash.opacity(0.55) : EditorTheme.chrome(0.025),
                        in: RoundedRectangle(cornerRadius: 6))
            .overlay {
                RoundedRectangle(cornerRadius: 6)
                    .stroke(EditorTheme.chrome(isSelected ? 0.18 : 0.055), lineWidth: 0.75)
                    .allowsHitTesting(false)
            }
            .accessibilityIdentifier("editor.canvas.padding.\(edge.rawValue)")
        }
    }

    private func beginEditing() {
        onSelect()
        isTextEditing = true
        hasPreview = false
        updateEditorTextPreviewValidity(store: editorStore, isValid: true,
                                        commandScope: .canvas, actionName: "调整画布边距")
    }

    private func preview(_ text: String) -> Bool {
        let parsed = EditorSliderValueFormat.points.value(from: text)
        updateEditorTextPreviewValidity(store: editorStore, isValid: parsed != nil,
                                        commandScope: .canvas, actionName: "调整画布边距")
        guard let parsed else { return false }
        hasPreview = true
        value = min(max(parsed, 0), 360)
        return true
    }

    private func finish(commits: Bool) {
        isTextEditing = false
        if commits && hasPreview {
            updateEditorContinuousInteraction(store: editorStore, isEditing: false,
                                              commandScope: .canvas, actionName: "调整画布边距",
                                              onError: onError)
        } else if editorStore.interaction?.commandScope == .canvas {
            editorStore.cancelInteraction()
        }
        hasPreview = false
    }
}
