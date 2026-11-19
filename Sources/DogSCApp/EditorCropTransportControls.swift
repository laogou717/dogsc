import SwiftUI

/// The canvas bar's left group while cropping: the mode name, then 还原 and
/// 取消 as quiet text buttons and one primary 完成. Keyboard hints live in
/// the tooltips, so the canvas itself stays clear.
struct EditorCropTransportControls: View {
    let canReset: Bool
    let onReset: () -> Void
    let onCancel: () -> Void
    let onConfirm: () -> Void

    var body: some View {
        HStack(spacing: 2) {
            HStack(spacing: 6) {
                AppLineIcon(kind: .crop, size: 16)
                Text(appLocalized("裁切"))
            }
            .font(.appUI(size: 13, weight: .medium))
            .foregroundStyle(EditorTheme.primaryText)
            .padding(.horizontal, 9)
            .frame(height: 30)
            .accessibilityAddTraits(.isHeader)

            EditorToolbarDivider()

            Button { onReset() } label: { label("还原") }
                .buttonStyle(EditorToolbarPressButtonStyle(cornerRadius: 8, showsHover: false))
                .disabled(!canReset)
                .help(appLocalized("还原为完整画面"))
                .accessibilityIdentifier("editor.crop.reset")

            Button { onCancel() } label: { label("取消") }
                .buttonStyle(EditorToolbarPressButtonStyle(cornerRadius: 8, showsHover: false))
                .help(appLocalized("取消裁切（Esc）"))
                .accessibilityIdentifier("editor.crop.cancel")

            Button { onConfirm() } label: {
                Text(appLocalized("完成"))
            }
            .buttonStyle(.editorPrimary(minHeight: 28))
            .padding(.leading, 4)
            .help(appLocalized("完成裁切（↩）"))
            .accessibilityIdentifier("editor.crop.confirm")
        }
    }

    private func label(_ title: String) -> some View {
        EditorMonitorBarButtonSurface(accessibilityTitle: title) {
            Text(appLocalized(title))
        }
    }
}
