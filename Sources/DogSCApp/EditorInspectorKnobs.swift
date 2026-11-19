import AppKit
import SwiftUI

// MARK: - Exact-entry readout

/// The value under a knob or a fader. Clicking it turns it into a text
/// field with the same one-gesture/one-command lifecycle as the slider rows.
struct EditorTransactionalReadout: View {
    @ObservedObject var editorStore: EditorStore
    let title: String
    let value: Binding<Double>
    let range: ClosedRange<Double>
    let commandScope: EditorInteractionCommandScope
    var format: EditorSliderValueFormat = .decimal2
    var accessibilityTitle: String? = nil
    var isActive = false
    var centered = true
    @Binding var isTextEditing: Bool
    let onError: (String) -> Void
    @State private var hasTextPreview = false

    var body: some View {
        EditorInspectorParameterReadout(
            title: accessibilityTitle ?? title,
            valueText: format.text(for: value.wrappedValue),
            isEditing: isActive || isTextEditing,
            editConfiguration: EditorInspectorParameterEditConfiguration(
                draftText: format.editingText(for: value.wrappedValue),
                onBegin: begin,
                onPreview: preview,
                onCommit: commit,
                onCancel: cancel
            ),
            showsTitle: false,
            isEmbedded: false,
            centered: centered
        )
    }

    private func begin() {
        isTextEditing = true
        hasTextPreview = false
        _ = editorStore.beginContinuousInteraction(
            commandScope: commandScope, commitsWhenReplacedAs: title
        )
    }

    private func preview(_ text: String) -> Bool {
        guard let parsed = format.value(from: text) else {
            editorStore.setContinuousInteractionReplacementPolicy(
                commandScope: commandScope, commitsWhenReplacedAs: nil
            )
            return false
        }
        _ = editorStore.beginContinuousInteraction(
            commandScope: commandScope, commitsWhenReplacedAs: title
        )
        hasTextPreview = true
        value.wrappedValue = min(max(parsed, range.lowerBound), range.upperBound)
        return true
    }

    private func commit() {
        isTextEditing = false
        if hasTextPreview {
            updateEditorContinuousInteraction(
                store: editorStore, isEditing: false, commandScope: commandScope,
                actionName: title, onError: onError
            )
        } else if editorStore.interaction?.commandScope == commandScope {
            editorStore.cancelInteraction()
        }
        hasTextPreview = false
    }

    private func cancel() {
        isTextEditing = false
        hasTextPreview = false
        if editorStore.interaction?.commandScope == commandScope {
            editorStore.cancelInteraction()
        }
    }
}

// MARK: - Parameter row (formerly a knob)

/// The former rotary control, now the inspector's one parameter row: label,
/// rail and an editable value. The name and call sites stay so every page
/// that used a knob picks up the same grammar.
struct EditorTransactionalKnob: View {
    @ObservedObject var editorStore: EditorStore
    let title: String
    var label: String? = nil
    let value: Binding<Double>
    let range: ClosedRange<Double>
    let commandScope: EditorInteractionCommandScope
    var format: EditorSliderValueFormat = .decimal2
    var accessibilityTitle: String? = nil
    let onError: (String) -> Void

    var body: some View {
        EditorTransactionalSliderRow(
            editorStore: editorStore,
            title: label ?? title,
            value: value,
            range: range,
            commandScope: commandScope,
            format: format,
            accessibilityTitle: accessibilityTitle ?? title,
            style: .slim,
            onError: onError
        )
    }
}

/// Related parameters stacked as rows.
struct EditorKnobRow<Content: View>: View {
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 4) { content() }
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Volume row

/// One audio channel: icon and name, a volume rail with an editable value,
/// and a mute toggle. Same row grammar as every other parameter.
struct EditorMixerStrip: View {
    @ObservedObject var editorStore: EditorStore
    let title: String
    let icon: AppLineIcon.Kind
    let detail: String
    let volume: Binding<Double>
    let isMuted: Binding<Bool>
    let commandScope: EditorInteractionCommandScope
    let accessibilityStem: String
    let onError: (String) -> Void

    var body: some View {
        let muted = isMuted.wrappedValue
        // EDT-079 (声音): name, slider and value in one row, the mute button
        // after them; everything centred on the 30 pt row.
        HStack(alignment: .center, spacing: 6) {
            EditorTransactionalSliderRow(
                editorStore: editorStore,
                title: title,
                value: volume,
                range: 0...1,
                commandScope: commandScope,
                format: .percent,
                accessibilityTitle: String(format: appLocalized("%@音量"), appLocalized(title)),
                style: .slim,
                onError: onError
            )
            .disabled(muted)
            .opacity(muted ? 0.5 : 1)
            Button {
                isMuted.wrappedValue.toggle()
            } label: {
                AppLineIcon(kind: muted ? .speakerOff : icon, size: 15)
                    .foregroundStyle(muted ? EditorTheme.accent : EditorTheme.tertiaryText)
                    .frame(width: 26, height: 26)
                    .contentShape(Rectangle())
            }
            .buttonStyle(EditorToolbarPressButtonStyle(cornerRadius: 7))
            .help(appLocalized(muted ? "取消静音" : "静音"))
            .accessibilityLabel(String(format: appLocalized("%@启用"), appLocalized(title)))
            .accessibilityValue(appLocalized(muted ? "开关状态 · 关闭" : "开关状态 · 开启"))
            .accessibilityAddTraits(.isToggle)
            .accessibilityIdentifier("\(accessibilityStem).enabled")
        }
        .frame(minHeight: EditorPropertyRowMetrics.height)
        .help(appLocalized(detail))
        .accessibilityElement(children: .contain)
    }
}

/// A channel the recording did not capture.
struct EditorMixerGhostStrip: View {
    let title: String
    let icon: AppLineIcon.Kind

    var body: some View {
        HStack(spacing: EditorPropertyRowMetrics.gap) {
            Text(appLocalized(title))
                .font(.appUI(size: 13))
                .foregroundStyle(EditorTheme.tertiaryText)
                .frame(width: EditorPropertyRowMetrics.labelWidth, alignment: .leading)
            Text(appLocalized("未录制"))
                .font(.appUI(size: 12.5))
                .foregroundStyle(EditorTheme.tertiaryText)
            Spacer(minLength: 8)
        }
        .frame(height: EditorPropertyRowMetrics.height)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(String(format: appLocalized("%@未录制"), appLocalized(title)))
    }
}
