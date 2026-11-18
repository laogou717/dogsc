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
        case .saved: return "已保存"
        case .saving: return "正在保存"
        case .editing: return "编辑中"
        case .failed: return "保存失败"
        }
    }

    var accessibilityKey: String {
        switch self {
        case .saved: return "项目已自动保存"
        case .saving: return "正在保存项目"
        case .editing: return "正在编辑项目"
        case .failed: return "查看自动保存失败原因"
        }
    }

    var identifier: String {
        switch self {
        case .saved: return "editor.persistence.saved"
        case .saving: return "editor.persistence.saving"
        case .editing: return "editor.persistence.editing"
        case .failed: return "editor.persistence.failed"
        }
    }
}

/// One 26 pt capsule beside the project title. Hidden labels reserve the
/// same advance in either language, so saving/saved never shift history.
struct EditorPersistenceBadge: View {
    let state: EditorPersistenceBadgeState
    @ObservedObject private var languageSettings = AppLanguageSettings.shared

    var body: some View {
        HStack(spacing: 7) {
            marker.frame(width: 12, height: 12)
            ZStack(alignment: .leading) {
                ForEach(EditorPersistenceBadgeState.allCases, id: \.self) { item in
                    Text(appLocalized(item.titleKey))
                        .hidden().accessibilityHidden(true)
                }
                Text(appLocalized(state.titleKey))
                    .contentTransition(.opacity)
            }
            .font(.appUI(size: 12, weight: .medium))
            .foregroundStyle(state == .failed ? RecorderStyle.amberInk : EditorTheme.secondaryText)
        }
        .padding(.horizontal, 11)
        .frame(height: 26)
        .fixedSize(horizontal: true, vertical: false)
        .background(state == .failed ? RecorderStyle.amberInk.opacity(0.10) : EditorTheme.chrome(0.045),
            in: Capsule(style: .continuous))
        .overlay {
            Capsule(style: .continuous).strokeBorder(
                state == .failed ? RecorderStyle.amberInk.opacity(0.25) : EditorTheme.chrome(0.06),
                lineWidth: 0.5)
        }
        .animation(SpringMotion.crossfade, value: state)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(appLocalized(state.accessibilityKey))
        .accessibilityIdentifier(state.identifier)
    }

    @ViewBuilder private var marker: some View {
        switch state {
        case .saved:
            AppLineIcon(kind: .check, size: 12)
                .foregroundStyle(RecorderStyle.positiveInk)
        case .saving:
            EditorSaveProgressDot()
        case .editing:
            AppLineIcon(kind: .pencil, size: 11)
                .foregroundStyle(EditorTheme.secondaryText)
        case .failed:
            AppLineIcon(kind: .warning, size: 12)
                .foregroundStyle(RecorderStyle.amberInk)
        }
    }
}

private struct EditorSaveProgressDot: View {
    @State private var breathing = false
    var body: some View {
        Circle().fill(EditorTheme.platinumAccent)
            .frame(width: 6, height: 6)
            .scaleEffect(breathing ? 1 : 0.6)
            .opacity(breathing ? 1 : 0.45)
            .onAppear {
                guard !RecorderMotion.reduces else { breathing = true; return }
                withAnimation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true)) { breathing = true }
            }
    }
}
