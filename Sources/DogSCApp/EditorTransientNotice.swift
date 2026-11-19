import SwiftUI

/// Ephemeral editor feedback. Ongoing failures retain their own save/preview
/// status entry; this card never holds the workspace until manually dismissed.
struct EditorTransientNotice: View {
    let message: String
    let dismiss: () -> Void

    private var content: (title: String, detail: String) {
        if message == appLocalized("此处已有同轨道动画，无法粘贴完整片段。请在足够长的空白处粘贴。") {
            return (appLocalized("这里已有片段"), appLocalized("移到空白处，或贴近边缘再粘贴"))
        }
        if message == appLocalized("此位置到片尾的时长不足，无法粘贴完整片段。请选择更靠前的位置。") {
            return (appLocalized("剩余空间不够"), appLocalized("移到更靠前的位置，保留完整片段"))
        }
        let prefix = appLocalized("项目已打开，但%@").replacingOccurrences(of: "%@", with: "")
        if !prefix.isEmpty, message.hasPrefix(prefix) {
            return (appLocalized("项目已打开，需要留意"), appLocalized(String(message.dropFirst(prefix.count))))
        }
        return (appLocalized("操作未完成"), appLocalized(message))
    }

    var body: some View {
        let text = content
        let lifetime = min(max(Double(text.detail.count) * 0.08, 5), 10)
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text(text.title).font(.appUI(size: 13, weight: .semibold))
                    .foregroundStyle(EditorTheme.primaryText)
                Text(text.detail).font(.appUI(size: 12))
                    .foregroundStyle(EditorTheme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Button(action: dismiss) {
                AppLineIcon(kind: .close, size: 11)
            }
            .buttonStyle(.editorDismissIcon(size: 22))
            .help(appLocalized("关闭提示"))
            .accessibilityLabel(appLocalized("关闭提示"))
        }
        .padding(12)
        .frame(width: 320)
        .modifier(EditorFloatingSurface())
        .appControlFocusAppearance()
        .accessibilityElement(children: .contain)
        .accessibilityLabel(String(format: appLocalized("%@：%@"), text.title, text.detail))
        .task {
            do { try await Task.sleep(for: .seconds(lifetime)) }
            catch { return }
            guard !Task.isCancelled else { return }
            dismiss()
        }
    }
}
