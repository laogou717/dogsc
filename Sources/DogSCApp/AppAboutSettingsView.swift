import AppKit
import SwiftUI

/// App information and update controls share the existing settings window.
struct AppAboutSettingsView: View {
    @ObservedObject private var updateController = AppUpdateController.shared
    @State private var showsSupportSheet = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 16) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable().scaledToFit()
                    .frame(width: 64, height: 64)
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 6) {
                    Text(AppIdentity.displayName)
                        .font(.appUI(size: 18, weight: .semibold))
                    Text(updateController.currentVersionDescription)
                        .font(.appUI(size: 12))
                        .foregroundStyle(EditorTheme.secondaryText)
                }

                Spacer(minLength: 16)

                Button {
                    updateController.checkForUpdates()
                } label: {
                    Text("检查更新").frame(height: 34)
                }
                .buttonStyle(.editorQuiet)
                .disabled(!updateController.isFormalRelease || !updateController.isReady)
                .help(appLocalized(updateController.availabilityDescription))
                .accessibilityHint("从 GitHub Release 检查并安装 DogSC 新版本")
            }

            HStack {
                Text("自动检查更新")
                    .font(.appUI(size: 13, weight: .medium))
                Spacer()
                EditorToggle(isOn: Binding(
                    get: { updateController.automaticallyChecksForUpdates },
                    set: { updateController.setAutomaticallyChecksForUpdates($0) }
                ))
                .disabled(!updateController.isFormalRelease)
                .accessibilityLabel("自动检查更新")
            }
            .frame(minHeight: 34)
            .padding(.top, 24)
            .help("每天检查一次；下载与安装前仍会显示确认界面。")

            sectionDivider

            VStack(spacing: 8) {
                projectLink("查看源码", icon: "chevron.left.forwardslash.chevron.right",
                            url: AppProjectLinks.source)
                projectLink("反馈建议", icon: "bubble.left", url: AppProjectLinks.feedback)
            }

            sectionDivider

            Button { showsSupportSheet = true } label: {
                HStack(spacing: 14) {
                    Image(systemName: "cup.and.saucer")
                        .font(.system(size: 17)).frame(width: 24)
                    VStack(alignment: .leading, spacing: 5) {
                        Text("请杯咖啡")
                            .font(.appUI(size: 13, weight: .medium))
                        Text("免费开源 · 自愿支持")
                            .font(EditorTypography.helper)
                            .foregroundStyle(EditorTheme.secondaryText)
                    }
                    Spacer(minLength: 12)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 11))
                        .foregroundStyle(EditorTheme.secondaryText)
                }
                .padding(.horizontal, 8).frame(minHeight: 58)
                .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
            .buttonStyle(EditorToolbarPressButtonStyle(cornerRadius: 8))
            .appButtonKeyboardFocus(in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .accessibilityIdentifier("settings.about.support")
            .accessibilityHint("打开赞赏码")
        }
        .foregroundStyle(EditorTheme.primaryText)
        .sheet(isPresented: $showsSupportSheet) { AppSupportSheet() }
    }

    private var sectionDivider: some View {
        Rectangle().fill(EditorTheme.hairline).frame(height: 1)
            .padding(.vertical, 20)
    }

    private func projectLink(_ title: String, icon: String, url: URL) -> some View {
        Button { NSWorkspace.shared.open(url) } label: {
            HStack(spacing: 14) {
                Image(systemName: icon)
                    .font(.system(size: 17)).frame(width: 24)
                Text(appLocalized(title))
                    .font(.appUI(size: 13, weight: .medium))
                Spacer(minLength: 12)
                Image(systemName: "arrow.up.forward.square")
                    .font(.system(size: 12))
                    .foregroundStyle(EditorTheme.secondaryText)
            }
            .padding(.horizontal, 8).frame(minHeight: 44)
            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(EditorToolbarPressButtonStyle(cornerRadius: 8))
        .appButtonKeyboardFocus(in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .accessibilityHint("在浏览器中打开")
    }
}

private enum AppProjectLinks {
    static let source = URL(string: "https://github.com/laogou717/dogsc")!
    static let feedback = URL(string: "https://github.com/laogou717/dogsc/issues")!
}
