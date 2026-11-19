import SwiftUI

/// Reflect the write pipeline, never a timer. A live editor draft has not
/// been submitted yet; even a clean persisted snapshot cannot mark it saved.
enum EditorPersistenceBadgeState: CaseIterable, Hashable {
    case saved, saving, editing, failed

    init(status: ProjectPersistenceStatus, hasDraft: Bool) {
        switch status {
        case .failed: self = .failed
        case .saving: self = .saving
        case .clean: self = hasDraft ? .editing : .saved
        }
    }

    var titleKey: String {
        switch self {
        case .saved: "已保存"
        case .saving: "正在保存"
        case .editing: "编辑中"
        case .failed: "保存失败"
        }
    }

    var accessibilityKey: String {
        switch self {
        case .saved: "项目已自动保存"
        case .saving: "正在保存项目"
        case .editing: "正在编辑项目"
        case .failed: "查看自动保存失败原因"
        }
    }

    var identifier: String {
        switch self {
        case .saved: "editor.persistence.saved"
        case .saving: "editor.persistence.saving"
        case .editing: "editor.persistence.editing"
        case .failed: "editor.persistence.failed"
        }
    }
}

/// A quiet status beside the project title. Saved and mid-edit are the
/// normal states and show nothing (every slider drag is "editing"); only a
/// failure, which needs the user, takes space. Saving is a dim dot.
struct EditorPersistenceBadge: View {
    let state: EditorPersistenceBadgeState
    @ObservedObject private var languageSettings = AppLanguageSettings.shared

    var body: some View {
        HStack(spacing: 5) {
            switch state {
            case .failed:
                marker.frame(width: 12, height: 12)
                Text(appLocalized(state.titleKey))
                    .font(EditorTypography.helper)
                    .foregroundStyle(RecorderStyle.amberInk)
                    .fixedSize()
            case .saving:
                marker.frame(width: 12, height: 12)
            case .saved, .editing:
                EmptyView()
            }
        }
        .padding(.horizontal, state == .failed ? 6 : 0)
        .frame(height: 24)
        .transaction { $0.animation = nil }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(appLocalized(state.accessibilityKey))
        .accessibilityIdentifier(state.identifier)
    }

    @ViewBuilder private var marker: some View {
        switch state {
        case .saved:
            AppLineIcon(kind: .check, size: 11)
                .foregroundStyle(EditorTheme.tertiaryText)
        case .saving:
            Circle().fill(EditorTheme.tertiaryText).frame(width: 5, height: 5)
        case .editing:
            Circle().fill(EditorTheme.secondaryText).frame(width: 5, height: 5)
        case .failed:
            AppLineIcon(kind: .warning, size: 12)
                .foregroundStyle(RecorderStyle.amberInk)
        }
    }
}
