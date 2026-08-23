import RecorderCore
import SwiftUI

/// Pure edit state for a canonical project color.
///
/// Keystrokes only mutate `text`. A caller receives a value exactly once when
/// `submit()` advances the committed baseline. Cancelling or finishing an
/// invalid draft restores the baseline without producing a project command.
struct HexColorDraft: Equatable {
    private(set) var committed: HexColor
    private(set) var text: String

    init(committed: HexColor) {
        self.committed = committed
        text = committed.hexString
    }

    var parsed: HexColor? {
        HexColor(text)
    }

    var isValid: Bool {
        parsed != nil
    }

    var isDirty: Bool {
        text != committed.hexString
    }

    mutating func updateText(_ value: String) {
        text = value
    }

    /// Returns a new canonical value only when this edit advances the current
    /// committed baseline. Calling it again after Return followed by focus loss
    /// is therefore a no-op rather than a second command.
    mutating func submit() -> HexColor? {
        guard let value = parsed else { return nil }
        text = value.hexString
        guard value != committed else { return nil }
        committed = value
        return value
    }

    /// Focus loss commits a valid draft and restores an invalid one.
    mutating func finishEditing() -> HexColor? {
        guard parsed != nil else {
            cancel()
            return nil
        }
        return submit()
    }

    mutating func cancel() {
        text = committed.hexString
    }

    mutating func applyPicker(_ value: HexColor) -> HexColor? {
        text = value.hexString
        return submit()
    }

    /// Synchronizes an external undo, preset or project switch while this
    /// field is not actively editing.
    mutating func rebase(_ value: HexColor) {
        committed = value
        text = value.hexString
    }
}

/// Shared background/border color editor. The text field and ColorPicker both
/// remain local until an explicit submit boundary, so neither can create one
/// undo/autosave entry per character or picker sample.
struct EditorHexColorInput: View {
    let title: String
    let value: HexColor
    let onCommit: (HexColor) -> Void

    @State private var draft: HexColorDraft
    @State private var pickerDraft: HexColor
    @State private var showsPicker = false
    @FocusState private var textIsFocused: Bool

    init(
        title: String,
        value: HexColor,
        onCommit: @escaping (HexColor) -> Void
    ) {
        self.title = title
        self.value = value
        self.onCommit = onCommit
        _draft = State(initialValue: HexColorDraft(committed: value))
        _pickerDraft = State(initialValue: value)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title)
                .font(.caption)

            HStack(spacing: 8) {
                Button {
                    pickerDraft = draft.parsed ?? draft.committed
                    showsPicker = true
                } label: {
                    RoundedRectangle(cornerRadius: 5)
                        .fill(Color(hex: draft.parsed ?? draft.committed))
                        .frame(width: 28, height: 22)
                        .overlay(
                            RoundedRectangle(cornerRadius: 5)
                                .stroke(Color.white.opacity(0.18), lineWidth: 1)
                        )
                }
                .buttonStyle(.plain)
                .accessibilityLabel("选择\(title)")
                .popover(isPresented: $showsPicker, arrowEdge: .trailing) {
                    pickerPopover
                }

                TextField(
                    "#RRGGBB",
                    text: Binding(
                        get: { draft.text },
                        set: { draft.updateText($0) }
                    )
                )
                .textFieldStyle(.roundedBorder)
                .font(.system(.body, design: .monospaced))
                .focused($textIsFocused)
                .onSubmit(submitTextDraft)
                .onExitCommand {
                    draft.cancel()
                    textIsFocused = false
                }
                .onChange(of: textIsFocused) { _, isFocused in
                    guard !isFocused else { return }
                    finishTextEditing()
                }
                .accessibilityLabel("\(title)十六进制值")
            }

            if draft.isDirty, !draft.isValid {
                Text("请输入 6 位十六进制颜色，例如 #D9C8FF")
                    .font(.caption2)
                    .foregroundStyle(.red)
                    .accessibilityLabel("\(title)格式无效")
            }
        }
        .onChange(of: value) { _, newValue in
            guard !textIsFocused, !showsPicker else { return }
            draft.rebase(newValue)
            pickerDraft = newValue
        }
    }

    private var pickerPopover: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(.headline)

            ColorPicker(
                title,
                selection: Binding(
                    get: { Color(hex: pickerDraft) },
                    set: { pickerDraft = $0.hexColor }
                ),
                supportsOpacity: false
            )
            .labelsHidden()

            Text(pickerDraft.hexString)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)

            HStack {
                Button("取消") {
                    pickerDraft = draft.parsed ?? draft.committed
                    showsPicker = false
                }
                Spacer()
                Button("应用") {
                    showsPicker = false
                    guard let color = draft.applyPicker(pickerDraft) else { return }
                    onCommit(color)
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(14)
        .frame(width: 220)
    }

    private func submitTextDraft() {
        guard let color = draft.submit() else { return }
        onCommit(color)
    }

    private func finishTextEditing() {
        guard let color = draft.finishEditing() else { return }
        onCommit(color)
    }
}
