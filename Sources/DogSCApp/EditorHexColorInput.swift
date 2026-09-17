import RecorderCore
import SwiftUI

/// Local text state plus the stable color captured when an edit begins.
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

    mutating func cancel() {
        text = committed.hexString
    }

    /// Synchronizes an external undo, preset or project switch while this
    /// field is not actively editing.
    mutating func rebase(_ value: HexColor) {
        committed = value
        text = value.hexString
    }
}

/// Shared background/border color editor. Valid picker and text changes are
/// published immediately for visual feedback; the owner decides how the whole
/// editing session is committed as one undoable command.
struct EditorHexColorInput: View {
    let title: String
    let value: HexColor
    let onEditingChanged: (Bool) -> Void
    let onPreview: (HexColor) -> Void

    @State private var draft: HexColorDraft
    @State private var pickerDraft: HexColor
    @State private var showsPicker = false
    @State private var interactionIsActive = false
    @FocusState private var textIsFocused: Bool

    init(
        title: String,
        value: HexColor,
        onEditingChanged: @escaping (Bool) -> Void = { _ in },
        onPreview: @escaping (HexColor) -> Void
    ) {
        self.title = title
        self.value = value
        self.onEditingChanged = onEditingChanged
        self.onPreview = onPreview
        _draft = State(initialValue: HexColorDraft(committed: value))
        _pickerDraft = State(initialValue: value)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title)
                .font(.appUI(.caption))
                // Both actual controls below already carry this context:
                // "选择\(title)" and "\(title)十六进制值". Keep the
                // visual heading without adding a third, non-actionable stop.
                .accessibilityHidden(true)

            HStack(spacing: 8) {
                Button {
                    pickerDraft = draft.parsed ?? draft.committed
                    showsPicker = true
                } label: {
                    RoundedRectangle(cornerRadius: 5)
                        .fill(Color(hex: draft.parsed ?? draft.committed))
                        .frame(width: 32, height: 26)
                        .overlay(
                            RoundedRectangle(cornerRadius: 5)
                                .stroke(EditorTheme.chrome(0.24), lineWidth: 1)
                        )
                        .frame(width: 36, height: 30)
                        .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                }
                .buttonStyle(.editorSwatch)
                .accessibilityLabel("选择\(title)")
                .help("打开\(title)取色器")
                .popover(isPresented: $showsPicker, arrowEdge: .trailing) {
                    pickerPopover.appControlFocusAppearance()
                }

                TextField(
                    "#RRGGBB",
                    text: Binding(
                        get: { draft.text },
                        set: { updateTextDraft($0) }
                    )
                )
                .textFieldStyle(.plain)
                .font(.appUI(size: 12, weight: .medium, design: .monospaced))
                .padding(.horizontal, 9)
                .frame(height: 30)
                .background(
                    textIsFocused ? EditorTheme.cardElevated : EditorTheme.chrome(0.035),
                    in: RoundedRectangle(cornerRadius: 7, style: .continuous)
                )
                .overlay {
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .stroke(
                            EditorTheme.chrome(textIsFocused ? 0.24 : 0.085),
                            lineWidth: textIsFocused ? 1 : 0.75
                        )
                }
                .focused($textIsFocused)
                .onSubmit(submitTextDraft)
                .onExitCommand {
                    pickerDraft = draft.committed
                    draft.cancel()
                    onPreview(draft.committed)
                    textIsFocused = false
                }
                .onChange(of: textIsFocused) { _, isFocused in
                    if isFocused {
                        beginColorInteraction()
                    } else {
                        finishTextEditing()
                        endColorInteraction()
                    }
                }
                .accessibilityLabel("\(title)十六进制值")
                .animation(SpringMotion.interactive, value: textIsFocused)
            }

            if draft.isDirty, !draft.isValid {
                Text("请输入 6 位十六进制颜色，例如 #D8B26A")
                    .font(.appUI(.caption2))
                    .foregroundStyle(.red)
                    .accessibilityLabel("\(title)格式无效")
            }
        }
        .onChange(of: value) { _, newValue in
            guard !interactionIsActive else { return }
            draft.rebase(newValue)
            pickerDraft = newValue
        }
        .onChange(of: showsPicker) { _, isPresented in
            if isPresented {
                beginColorInteraction()
            } else {
                draft.rebase(pickerDraft)
                endColorInteraction()
            }
        }
        .onDisappear {
            endColorInteraction()
        }
    }

    private var pickerPopover: some View {
        EditorColorPalette(title: title, value: pickerDraft, onPreview: previewPickerColor)
    }

    private func submitTextDraft() {
        guard let color = draft.parsed else { return }
        pickerDraft = color
        onPreview(color)
        draft.rebase(color)
        textIsFocused = false
    }

    private func finishTextEditing() {
        guard let color = draft.parsed else {
            draft.updateText(pickerDraft.hexString)
            return
        }
        pickerDraft = color
        onPreview(color)
        draft.rebase(color)
    }

    private func updateTextDraft(_ text: String) {
        draft.updateText(text)
        guard let color = draft.parsed else { return }
        beginColorInteraction()
        pickerDraft = color
        onPreview(color)
    }

    private func previewPickerColor(_ color: HexColor) {
        beginColorInteraction()
        pickerDraft = color
        draft.updateText(color.hexString)
        onPreview(color)
    }

    private func beginColorInteraction() {
        guard !interactionIsActive else { return }
        interactionIsActive = true
        onEditingChanged(true)
    }

    private func endColorInteraction() {
        guard interactionIsActive else { return }
        interactionIsActive = false
        onEditingChanged(false)
    }
}

/// Gives every editor color well the same direct-preview and single-command
/// lifecycle as the transactional sliders.
struct EditorTransactionalColorInput: View {
    @ObservedObject var editorStore: EditorStore
    let title: String
    let value: Binding<HexColor>
    let commandScope: EditorInteractionCommandScope
    var selection: EditorSelection? = nil
    let actionName: String
    let onError: (String) -> Void
    var presentsPalette = false
    @State private var ownedInteractionID: UUID?

    var body: some View {
        Group {
            if presentsPalette {
                EditorColorPalette(title: title, value: value.wrappedValue) { color in
                    value.wrappedValue = color
                }
                .onAppear { updateInteraction(true) }
                .onDisappear { updateInteraction(false) }
            } else {
                EditorHexColorInput(
                    title: title,
                    value: value.wrappedValue,
                    onEditingChanged: updateInteraction
                ) { color in
                    value.wrappedValue = color
                }
            }
        }
    }

    private func updateInteraction(_ isEditing: Bool) {
        if isEditing {
            _ = editorStore.beginContinuousInteraction(
                commandScope: commandScope,
                selection: selection,
                commitsWhenReplacedAs: actionName
            )
            ownedInteractionID = editorStore.interaction?.id
            return
        }
        defer { ownedInteractionID = nil }
        guard let ownedInteractionID,
              editorStore.interaction?.id == ownedInteractionID,
              editorStore.interaction?.commandScope == commandScope
        else { return }
        do {
            _ = try editorStore.commitInteraction(actionName: actionName)
        } catch {
            editorStore.cancelInteraction()
            onError(error.localizedDescription)
        }
    }
}
