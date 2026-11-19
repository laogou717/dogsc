import AppKit
import SwiftUI

/// Icon, version, updates, feedback, source, support and the first-use guide.
struct AppAboutSettingsView: View {
    @ObservedObject private var updateController = AppUpdateController.shared
    @ObservedObject private var guideAccess = FirstLaunchGuideAccess.shared
    @State private var showsSupportSheet = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(spacing: 6) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 76, height: 76)
                    .shadow(color: .black.opacity(0.18), radius: 12, y: 10)
                    .accessibilityHidden(true)
                Text(AppIdentity.displayName)
                    .font(.appUI(size: 20, weight: .semibold))
                    .foregroundStyle(EditorTheme.primaryText)
                    .padding(.top, 8)
                Text(String(format: appLocalized("版本 %@"), updateController.currentVersionDescription))
                    .font(.system(size: 12.5, design: .monospaced))
                    .foregroundStyle(EditorTheme.tertiaryText)
                    .textSelection(.enabled)
            }
            .frame(maxWidth: .infinity)
            .padding(.top, 18)
            .padding(.bottom, 10)
            SettingsGroup {
                SettingsRow("自动检查更新") {
                    EditorToggle(isOn: Binding(
                        get: { updateController.automaticallyChecksForUpdates },
                        set: { updateController.setAutomaticallyChecksForUpdates($0) }
                    ))
                    .disabled(!updateController.isFormalRelease)
                    .accessibilityLabel(appLocalized("自动检查更新"))
                }
                SettingsRow("检查更新", detail: updateController.isFormalRelease ? nil : "开发版不检查更新", last: true) {
                    Button(appLocalized("立即检查")) { updateController.checkForUpdates() }
                        .buttonStyle(.appSheet)
                        .disabled(!updateController.isFormalRelease || !updateController.isReady)
                }
            }
            SettingsGroup {
                SettingsRow("反馈问题", detail: "在 GitHub 上提交") {
                    Button(appLocalized("打开")) { NSWorkspace.shared.open(AppProjectLinks.feedback) }
                        .buttonStyle(.appSheet)
                }
                SettingsRow("源代码", detail: "在 GitHub 上查看") {
                    Button(appLocalized("打开")) { NSWorkspace.shared.open(AppProjectLinks.source) }
                        .buttonStyle(.appSheet)
                }
                SettingsRow("首次使用引导", detail: "重新看一遍") {
                    Button(appLocalized("重新开始")) { WindowCoordinator.showFirstLaunchGuide() }
                        .buttonStyle(.appSheet)
                        .disabled(!guideAccess.isAvailable)
                        .accessibilityIdentifier("settings.first-launch-guide")
                }
                SettingsRow("请作者喝杯咖啡", last: true) {
                    Button { showsSupportSheet = true } label: {
                        HStack(spacing: 6) {
                            AppLineIcon(kind: .cup, size: 13)
                            Text(appLocalized("赞赏…"))
                        }
                    }
                    .buttonStyle(.appSheetGhost)
                    .accessibilityIdentifier("settings.about.support")
                }
            }
        }
        .sheet(isPresented: $showsSupportSheet) { AppSupportSheet() }
    }
}

private enum AppProjectLinks {
    static let source = URL(string: "https://github.com/laogou717/dogsc")!
    static let feedback = URL(string: "https://github.com/laogou717/dogsc/issues")!
}
