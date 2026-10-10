import AppKit
import SwiftUI

/// App information, updates and voluntary support sharing the recorder appearance.
struct AppAboutSettingsView: View {
    @ObservedObject private var updateController = AppUpdateController.shared
    @State private var showsSupportSheet = false

    var body: some View {
        VStack(spacing: 24) {
            // Identity gets its own space; update controls share the row below.
            SettingsCard {
                HStack(alignment: .top, spacing: 18) {
                    Image(nsImage: NSApp.applicationIconImage)
                        .resizable()
                        .scaledToFit()
                        .frame(width: 56, height: 56)
                        .shadow(color: RecorderStyle.lift, radius: 6, y: 3)
                        .accessibilityHidden(true)

                    VStack(alignment: .leading, spacing: 8) {
                        Text(AppIdentity.displayName)
                            .font(.appUI(size: 19, weight: .semibold))
                            .foregroundStyle(RecorderStyle.ink)

                        Text(updateController.currentVersionDescription)
                            .font(.system(size: 10.5, weight: .semibold, design: .rounded))
                            .foregroundStyle(SettingsTheme.textSecondary)

                        Text("丝滑、优雅的高性能屏幕录制工具")
                            .font(.appUI(size: 11.5))
                            .foregroundStyle(SettingsTheme.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 22)
                .padding(.vertical, 22)

                SettingsDivider()

                SettingsRow(
                    icon: .refresh,
                    title: "自动检查更新"
                ) {
                    HStack(spacing: 16) {
                        Button {
                            updateController.checkForUpdates()
                        } label: {
                            Text("检查更新")
                        }
                        .buttonStyle(SettingsPillButtonStyle())
                        .disabled(!updateController.isFormalRelease || !updateController.isReady)
                        .help(appLocalized(updateController.availabilityDescription))
                        .accessibilityHint("从 GitHub Release 检查并安装 DogSC 新版本")

                        SettingsToggle(
                            isOn: Binding(
                                get: { updateController.automaticallyChecksForUpdates },
                                set: { updateController.setAutomaticallyChecksForUpdates($0) }
                            ),
                            accessibilityLabel: "自动检查更新"
                        )
                        .disabled(!updateController.isFormalRelease)
                    }
                }
            }

            // Open Source & Support
            SettingsCard("开源与支持") {
                SettingsLinkRow(
                    icon: .code,
                    title: "开源仓库 (GitHub)",
                    action: { NSWorkspace.shared.open(AppProjectLinks.source) }
                )

                SettingsDivider()

                SettingsLinkRow(
                    icon: .feedback,
                    title: "反馈与建议",
                    action: { NSWorkspace.shared.open(AppProjectLinks.feedback) }
                )

                SettingsDivider()

                SettingsLinkRow(
                    icon: .cup,
                    title: "自愿赞赏支持",
                    trailingIcon: .chevron,
                    accessibilityIdentifier: "settings.about.support",
                    action: { showsSupportSheet = true }
                )
            }
        }
        .sheet(isPresented: $showsSupportSheet) { AppSupportSheet() }
    }
}

private enum AppProjectLinks {
    static let source = URL(string: "https://github.com/laogou717/dogsc")!
    static let feedback = URL(string: "https://github.com/laogou717/dogsc/issues")!
}
