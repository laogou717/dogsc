import AppKit
import AVFoundation
import CoreGraphics
import SwiftUI

enum AppSettingsSection: String, CaseIterable, Identifiable {
    case general
    case editor
    case recording
    case permissions
    case about

    var id: Self { self }

    var label: String {
        switch self {
        case .general: appLocalized("通用")
        case .editor: appLocalized("编辑器")
        case .recording: appLocalized("录制")
        case .permissions: appLocalized("权限")
        case .about: appLocalized("关于")
        }
    }

    var iconName: String {
        switch self {
        case .general: "gearshape.fill"
        case .editor: "slider.horizontal.3"
        case .recording: "record.circle.fill"
        case .permissions: "lock.shield.fill"
        case .about: "info.circle.fill"
        }
    }

    var subtitle: String? {
        switch self {
        case .general: "界面、声音与文件"
        case .editor: "预览与编辑工作区"
        case .recording: "开始录制时的默认选项"
        case .permissions: "管理录制所需的系统权限"
        case .about: nil
        }
    }


}

@MainActor
final class AppSettingsNavigation: ObservableObject {
    @Published var selectedSection = AppSettingsSection.general
}

struct AppSettingsView: View {
    @ObservedObject private var updateController = AppUpdateController.shared
    @ObservedObject private var guideAccess = FirstLaunchGuideAccess.shared
    var contentHeight: CGFloat = 640
    @ObservedObject var navigation = AppSettingsNavigation()

    @AppStorage(AppPreferences.exportCompletionSoundEnabledKey)
    private var exportCompletionSoundEnabled = true
    @AppStorage(AppPreferences.previewResolutionModeKey)
    private var previewResolutionMode = EditorPreviewResolutionMode.defaultValue
    @AppStorage(AppPreferences.recordingCameraPreviewShapeKey)
    private var recordingCameraPreviewShape = RecordingCameraPreviewShape.circle
    @AppStorage(AppPreferences.appearancePreferenceKey)
    private var appearancePreference = AppAppearancePreference.system
    @AppStorage(CaptureDevicePreferenceKey.systemAudioEnabled)
    private var recordsSystemAudioByDefault = true
    @AppStorage(CaptureDevicePreferenceKey.microphoneEnabled)
    private var recordsMicrophoneByDefault = false
    @AppStorage(CaptureDevicePreferenceKey.microphoneName)
    private var preferredMicrophoneName = ""

    @FocusState private var focusedSection: AppSettingsSection?
    @FocusState private var isGuideFocused: Bool
    @Namespace private var sectionHighlight
    @State private var hoveredSection: AppSettingsSection?
    @State private var didResetWindowState = false
    @State private var isPlayingSoundPreview = false
    @State private var projectsFolder = ProjectStore.savedProjectsFolder
    @State private var exportFolder = AppPreferences.exportDirectoryURL
    @State private var fileLocationError: String?
    @State private var hasScreenRecordingPermission = CGPreflightScreenCaptureAccess()
    @State private var hasAccessibilityPermission = AXIsProcessTrusted()
    @State private var cameraPermission = CapturePermissionState(
        authorizationStatus: AVCaptureDevice.authorizationStatus(for: .video)
    )
    @State private var microphonePermission = CapturePermissionState(
        authorizationStatus: AVCaptureDevice.authorizationStatus(for: .audio)
    )

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            settingsNavigation
                .frame(width: settingsNavigationWidth)
                .frame(maxHeight: .infinity, alignment: .top)
                .background(EditorTheme.panelRaised.opacity(0.65))
            Rectangle().fill(EditorTheme.hairline).frame(width: 1)
            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: 22) {
                    VStack(alignment: .leading, spacing: 5) {
                        Text(navigation.selectedSection.label).font(.appUI(size: 22, weight: .semibold))
                        if let subtitle = navigation.selectedSection.subtitle {
                            Text(appLocalized(subtitle))
                                .font(.appUI(size: 12)).foregroundStyle(.secondary)
                        }
                    }
                    .padding(.bottom, 2)
                    Group {
                        switch navigation.selectedSection {
                        case .general: generalSettingsView
                        case .editor: editorSettingsView
                        case .recording: recordingSettingsView
                        case .permissions: permissionSettingsView
                        case .about: AppAboutSettingsView()
                        }
                    }
                }
                .id(navigation.selectedSection)
                .transition(.identity)
                .padding(24)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .transaction { $0.animation = nil }
        }
        .frame(width: 780, height: contentHeight)
        .background(EditorTheme.panelSurface)
        .font(.appUI(.body))
        .tint(editorAccent)
        .appControlFocusAppearance()
        .onChange(of: appearancePreference) { _, _ in
            AppPreferences.applyAppearancePreferenceToOpenWindows()
        }
        .onChange(of: recordingCameraPreviewShape) { _, _ in
            NotificationCenter.default.post(
                name: .recordingCameraPreviewShapeDidChange,
                object: nil
            )
        }
        .onChange(of: recordsSystemAudioByDefault) { _, enabled in
            WindowCoordinator.setDefaultSystemAudioRecordingEnabled(enabled)
        }
        .onChange(of: recordsMicrophoneByDefault) { _, enabled in
            WindowCoordinator.setDefaultMicrophoneRecordingEnabled(enabled)
        }
        .onAppear {
            refreshPermissionStates()
            updateController.startIfEligible()
        }
        .onChange(of: navigation.selectedSection) { _, section in
            if section == .permissions {
                refreshPermissionStates()
            }
        }
        .onReceive(
            NotificationCenter.default.publisher(
                for: NSApplication.didBecomeActiveNotification
            )
        ) { _ in
            if navigation.selectedSection == .permissions {
                refreshPermissionStates()
            }
        }
    }

    private var settingsNavigationWidth: CGFloat {
        // SwiftUI can evaluate the parent width before its labels. Register
        // their bundled font before measuring instead of using fallback metrics.
        _ = Font.appUI(size: 12, weight: .medium)
        let sectionFont = NSFont(name: "AlibabaPuHuiTi_3_65_Medium", size: 13)
            ?? NSFont.systemFont(ofSize: 13, weight: .medium)
        let guideFont = NSFont(name: "AlibabaPuHuiTi_3_65_Medium", size: 12)
            ?? NSFont.systemFont(ofSize: 12, weight: .medium)
        let sectionWidth = AppSettingsSection.allCases.map {
            ($0.label as NSString).size(withAttributes: [.font: sectionFont]).width + 78
        }.max() ?? 0
        let guideWidth = (appLocalized("首次使用引导") as NSString)
            .size(withAttributes: [.font: guideFont]).width + 70
        // Preserve the original Chinese width; longer translations get the
        // space their font actually needs, including a small rounding margin.
        return ceil(max(156, max(sectionWidth, guideWidth) + 4))
    }

    private var settingsNavigation: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("设置").font(.appUI(size: 13, weight: .semibold))
                .foregroundStyle(.secondary).padding(.horizontal, 12).padding(.bottom, 14)
            ForEach(AppSettingsSection.allCases) { section in
                Button {
                    focusedSection = section
                    selectSection(section)
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: section.iconName.replacingOccurrences(of: ".fill", with: ""))
                            .font(.system(size: 16)).frame(width: 20)
                        Text(section.label).font(.appUI(size: 13, weight: .medium))
                            .lineLimit(1)
                            .fixedSize(horizontal: true, vertical: false)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 12).frame(height: 40)
                    .background {
                        if navigation.selectedSection == section {
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .fill(EditorTheme.chrome(0.08))
                                .matchedGeometryEffect(id: "settings.selection", in: sectionHighlight)
                        } else if hoveredSection == section {
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .fill(EditorTheme.chrome(0.035))
                        }
                    }
                    .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                }
                .buttonStyle(EditorToolbarPressButtonStyle(cornerRadius: 10, showsHover: false))
                .focused($focusedSection, equals: section)
                .focusEffectDisabled()
                .appKeyboardFocus(in: RoundedRectangle(cornerRadius: 10, style: .continuous), isFocused: focusedSection == section)
                .onHover { hovering in
                    withAnimation(SpringMotion.interactive) {
                        hoveredSection = hovering ? section : nil
                    }
                }
                .accessibilityAddTraits(navigation.selectedSection == section ? .isSelected : [])
                .accessibilityIdentifier("settings.section.\(section.rawValue)")
            }
            Spacer(minLength: 20)
            Button {
                WindowCoordinator.showFirstLaunchGuide()
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "sparkles").font(.system(size: 14)).frame(width: 18)
                    Text("首次使用引导").font(.appUI(size: 12, weight: .medium))
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 10).frame(height: 36)
                .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(isGuideFocused ? EditorTheme.chrome(0.35) : .clear, lineWidth: 1)
                }
            }
            .buttonStyle(EditorToolbarPressButtonStyle(cornerRadius: 10))
            .focused($isGuideFocused).focusEffectDisabled()
            .disabled(!guideAccess.isAvailable)
            .help("重看启动动画、授权与当前界面教学")
            .accessibilityIdentifier("settings.first-launch-guide")
            Text("DogSC").font(.appUI(size: 11)).foregroundStyle(.tertiary).padding(12)
        }
        .padding(.horizontal, 12).padding(.top, 24).padding(.bottom, 8)
    }

    private func selectSection(_ section: AppSettingsSection) {
        guard navigation.selectedSection != section else { return }
        withAnimation(SpringMotion.fluid) { navigation.selectedSection = section }
    }

    // MARK: - 通用设置

    @ViewBuilder
    private var generalSettingsView: some View {
        appearanceSettingsCard

        // 提示与声音
        settingsCard(title: "提示与声音", icon: "bell.badge.fill") {
            VStack(spacing: 12) {
                HStack(spacing: 12) {
                    settingIconBadge("speaker.wave.2.fill", color: .orange)

                    VStack(alignment: .leading, spacing: 3) {
                        Text("导出完成后播放提示音")
                            .font(.appUI(size: 13, weight: .medium))
                            .foregroundStyle(Color.primary)
                        Text("仅在成功导出后播放")
                            .font(.appUI(.caption))
                            .foregroundStyle(EditorTheme.chrome(0.50))
                    }
                    .accessibilityHidden(true)

                    Spacer()

                    Button {
                        playSampleSound()
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: isPlayingSoundPreview ? "waveform" : "play.fill")
                                .font(.appUI(size: 10))
                            Text("试听")
                                .font(.appUI(size: 12))
                        }
                    }
                    .buttonStyle(.editorQuiet)
                    .appButtonKeyboardFocus(in: RoundedRectangle(cornerRadius: EditorInterfaceRadius.control, style: .continuous))
                    .accessibilityLabel("试听导出完成提示音")

                    EditorToggle(isOn: $exportCompletionSoundEnabled)
                        .accessibilityLabel("导出完成后播放提示音")
                        .accessibilityValue(appLocalized(exportCompletionSoundEnabled ? "开关状态 · 开启" : "开关状态 · 关闭"))
                        .accessibilityHint("导出取消或失败时不会播放提示音")
                }
            }
        }

        // 文件位置
        settingsCard(title: "存储位置", icon: "folder.fill") {
            VStack(spacing: 14) {
                fileLocationCardRow(
                    title: "项目位置",
                    subtitle: "录制成片与草稿项目包的默认保存路径",
                    icon: "doc.badge.arrow.up.fill",
                    color: .orange,
                    url: projectsFolder
                ) {
                    chooseProjectsFolder()
                }

                Divider().overlay(EditorTheme.chrome(0.06))

                fileLocationCardRow(
                    title: "导出位置",
                    subtitle: "视频导出面板记住的默认目标文件夹",
                    icon: "arrow.down.doc.fill",
                    color: .green,
                    url: exportFolder
                ) {
                    chooseExportFolder()
                }

                if let error = fileLocationError {
                    Text(error)
                        .font(.appUI(.caption))
                        .foregroundStyle(Color.red)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }

    }

    private var appearanceSettingsCard: some View {
        settingsCard(title: "外观", icon: "circle.lefthalf.filled") {
            HStack(spacing: 10) {
                ForEach(AppAppearancePreference.allCases) { preference in
                    Button { appearancePreference = preference } label: {
                        VStack(spacing: 8) {
                            SettingsAppearanceMiniature(preference: preference)
                                .frame(height: 58).padding(.horizontal, 8).padding(.top, 8)
                            Text(preference.label).font(.appUI(size: 12))
                        }
                        .padding(8).frame(maxWidth: .infinity)
                        .background(EditorTheme.groupSurface, in: RoundedRectangle(cornerRadius: EditorInterfaceRadius.group, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: EditorInterfaceRadius.group, style: .continuous)
                            .strokeBorder(appearancePreference == preference ? EditorTheme.selectionTint.opacity(0.5) : EditorTheme.hairline,
                                          lineWidth: appearancePreference == preference ? 1.25 : 0.75))
                    }
                    .buttonStyle(.editorThumbnail)
                    .appButtonKeyboardFocus(in: RoundedRectangle(cornerRadius: EditorInterfaceRadius.group, style: .continuous))
                    .accessibilityLabel(preference.label)
                    .accessibilityAddTraits(appearancePreference == preference ? .isSelected : [])
                }
            }
        }
    }

    // MARK: - 编辑器设置

    @ViewBuilder
    private var editorSettingsView: some View {
        settingsCard(title: "画布与预览", icon: "display") {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 12) {
                    settingIconBadge("speedometer", color: EditorTheme.platinumAccent)

                    VStack(alignment: .leading, spacing: 3) {
                        Text("预览画质")
                            .font(.appUI(size: 13, weight: .medium))
                        Text("清晰预览更流畅，完整分辨率保留细节；导出画质不受影响。")
                            .font(.appUI(.caption))
                            .foregroundStyle(EditorTheme.chrome(0.50))
                    }

                    Spacer()

                    previewResolutionPicker
                }
            }
        }

        settingsCard(title: "窗口与界面状态", icon: "macwindow") {
            HStack(spacing: 12) {
                settingIconBadge("arrow.counterclockwise.circle.fill", color: .orange)

                VStack(alignment: .leading, spacing: 3) {
                    Text("重置编辑窗口布局")
                        .font(.appUI(size: 13, weight: .medium))
                    Text(appLocalized(didResetWindowState
                        ? "已成功重置，将在下次打开编辑器窗口时应用默认大小与居中位置。"
                        : "清除系统记住的窗口位置、尺寸和全屏记忆状态。"))
                        .font(.appUI(.caption))
                        .foregroundStyle(didResetWindowState ? Color.green : EditorTheme.chrome(0.50))
                }

                Spacer()

                Button {
                    AppPreferences.resetRememberedEditorWindowState()
                    withAnimation(SpringMotion.interactive) {
                        didResetWindowState = true
                    }
                } label: {
                    Text(appLocalized(didResetWindowState ? "已重置" : "重置布局"))
                        .font(.appUI(size: 12, weight: .medium))
                        .foregroundStyle(didResetWindowState ? Color.green : Color.primary)
                }
                .buttonStyle(.editorQuiet)
                .appButtonKeyboardFocus(in: RoundedRectangle(cornerRadius: EditorInterfaceRadius.control, style: .continuous))
                .accessibilityLabel(appLocalized(didResetWindowState ? "编辑窗口布局已重置" : "重置编辑窗口布局"))
            }
        }
    }

    /// 预览画质切换器
    private var previewResolutionPicker: some View {
        HStack(spacing: 3) {
            ForEach(EditorPreviewResolutionMode.allCases) { mode in
                let isSelected = previewResolutionMode == mode
                Button {
                    withAnimation(SpringMotion.interactive) {
                        previewResolutionMode = mode
                    }
                } label: {
                    Text(mode.label)
                        .font(.appUI(size: 12, weight: isSelected ? .semibold : .regular))
                        .foregroundStyle(isSelected ? Color.primary : EditorTheme.chrome(0.65))
                        .padding(.horizontal, 12)
                        .frame(height: EditorInterfaceHeight.compact)
                        .background(
                            RoundedRectangle(cornerRadius: EditorInterfaceRadius.compact, style: .continuous)
                                .fill(isSelected ? EditorTheme.cardElevated : Color.clear)
                                .overlay(
                                    RoundedRectangle(cornerRadius: EditorInterfaceRadius.compact, style: .continuous)
                                        .strokeBorder(isSelected ? EditorTheme.controlBorder : Color.clear, lineWidth: 0.75)
                                )
                        )
                }
                .buttonStyle(EditorToolbarPressButtonStyle(cornerRadius: EditorInterfaceRadius.compact))
                .appButtonKeyboardFocus(in: RoundedRectangle(cornerRadius: EditorInterfaceRadius.compact, style: .continuous))
                .accessibilityAddTraits(isSelected ? .isSelected : [])
                .help(mode.detail)
            }
        }
        .padding(4)
        .background(
            RoundedRectangle(cornerRadius: EditorInterfaceRadius.group, style: .continuous)
                .fill(EditorTheme.groupSurface)
        )
    }

    // MARK: - 录制设置

    @ViewBuilder
    private var recordingSettingsView: some View {
        settingsCard(title: "默认音频输入", icon: "waveform.circle.fill") {
            VStack(spacing: 14) {
                HStack(spacing: 12) {
                    settingIconBadge("speaker.wave.3.fill", color: .orange)

                    VStack(alignment: .leading, spacing: 3) {
                        Text("录制系统声音")
                            .font(.appUI(size: 13, weight: .medium))
                        Text("默认采集 macOS 系统中各应用程序发出的声音与媒体音频。")
                            .font(.appUI(.caption))
                            .foregroundStyle(EditorTheme.chrome(0.50))
                    }
                    .accessibilityHidden(true)

                    Spacer()

                    EditorToggle(isOn: $recordsSystemAudioByDefault)
                        .accessibilityLabel("默认录制系统声音")
                        .accessibilityValue(appLocalized(recordsSystemAudioByDefault ? "开关状态 · 开启" : "开关状态 · 关闭"))
                        .accessibilityHint("控制新录制是否默认采集系统声音")
                }

                Divider().overlay(EditorTheme.chrome(0.06))

                HStack(spacing: 12) {
                    settingIconBadge("mic.fill", color: EditorTheme.amberAccent)

                    VStack(alignment: .leading, spacing: 3) {
                        Text("录制麦克风声音")
                            .font(.appUI(size: 13, weight: .medium))
                        Text(microphonePreferenceDescription)
                            .font(.appUI(.caption))
                            .foregroundStyle(EditorTheme.chrome(0.50))
                    }
                    .accessibilityHidden(true)

                    Spacer()

                    EditorToggle(isOn: $recordsMicrophoneByDefault)
                        .accessibilityLabel("默认录制麦克风声音")
                        .accessibilityValue(appLocalized(recordsMicrophoneByDefault ? "开关状态 · 开启" : "开关状态 · 关闭"))
                        .accessibilityHint(microphonePreferenceDescription)
                }
            }
        }

        settingsCard(title: "悬浮摄像头预览", icon: "camera.fill") {
            VStack(alignment: .leading, spacing: 14) {
                cameraShapeSelector

                Text("只影响录制时的悬浮预览，不改变摄像头源文件或编辑器布局。")
                    .font(.appUI(.caption))
                    .foregroundStyle(EditorTheme.chrome(0.45))
            }
        }
    }

    // MARK: - 权限设置

    @ViewBuilder
    private var permissionSettingsView: some View {
        settingsCard(title: "macOS 隐私与系统权限", icon: "lock.shield.fill") {
            VStack(spacing: 14) {
                permissionRow(
                    title: "屏幕录制权限",
                    description: "用于捕获屏幕画面、指定窗口与系统音频流",
                    icon: "display.2",
                    color: .orange,
                    status: hasScreenRecordingPermission ? "已授权" : "未授权",
                    statusColor: hasScreenRecordingPermission ? .green : .red
                )

                Divider().overlay(EditorTheme.chrome(0.06))

                permissionRow(
                    title: "辅助功能权限",
                    description: "用于记录鼠标移动与点击，生成可编辑的光标轨道",
                    icon: "cursorarrow.motionlines",
                    color: EditorTheme.platinumAccent,
                    status: hasAccessibilityPermission ? "已授权" : "未授权",
                    statusColor: hasAccessibilityPermission ? .green : .red
                )

                Divider().overlay(EditorTheme.chrome(0.06))

                permissionRow(
                    title: "摄像头权限",
                    description: "用于画中画人像出镜与外接相机输入",
                    icon: "camera.fill",
                    color: .green,
                    status: cameraPermission.label,
                    statusColor: permissionStatusColor(cameraPermission)
                )

                Divider().overlay(EditorTheme.chrome(0.06))

                permissionRow(
                    title: "麦克风权限",
                    description: "用于人声解说录音与音频设备采集",
                    icon: "mic.fill",
                    color: EditorTheme.amberAccent,
                    status: microphonePermission.label,
                    statusColor: permissionStatusColor(microphonePermission)
                )

                Divider().overlay(EditorTheme.chrome(0.06))

                HStack {
                    Text("如遇录屏黑屏、鼠标无法跟随或无声音，请检查上方未授权项。")
                        .font(.appUI(.caption))
                        .foregroundStyle(EditorTheme.chrome(0.50))

                    Spacer()

                    Button {
                        openPrivacySettings()
                    } label: {
                        HStack(spacing: 6) {
                            Text(appLocalized(privacySettingsButtonTitle))
                                .font(.appUI(size: 12, weight: .medium))
                                .lineLimit(1)
                                .fixedSize(horizontal: true, vertical: false)
                            Image(systemName: "arrow.up.forward.square.fill")
                                .font(.appUI(size: 11))
                        }
                    }
                    .buttonStyle(.editorQuiet)
                    .appButtonKeyboardFocus(in: RoundedRectangle(cornerRadius: EditorInterfaceRadius.control, style: .continuous))
                }
                .padding(.top, 2)
            }
        }
    }

    // MARK: - 辅助组件

    /// 摄像头形状选择卡片
    private var cameraShapeSelector: some View {
        HStack(spacing: 12) {
            ForEach(RecordingCameraPreviewShape.allCases) { shape in
                let isSelected = recordingCameraPreviewShape == shape
                Button {
                    withAnimation(SpringMotion.interactive) {
                        recordingCameraPreviewShape = shape
                    }
                } label: {
                    VStack(spacing: 8) {
                        ZStack {
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .fill(EditorTheme.chrome(0.06))
                                .frame(width: 44, height: 32)

                            switch shape {
                            case .circle:
                                Circle()
                                    .fill(isSelected ? EditorTheme.platinumAccent : EditorTheme.chrome(0.6))
                                    .frame(width: 20, height: 20)
                            case .roundedSquare:
                                RoundedRectangle(cornerRadius: 4, style: .continuous)
                                    .fill(isSelected ? EditorTheme.platinumAccent : EditorTheme.chrome(0.6))
                                    .frame(width: 20, height: 20)
                            case .sourceAspect:
                                RoundedRectangle(cornerRadius: 3, style: .continuous)
                                    .fill(isSelected ? EditorTheme.platinumAccent : EditorTheme.chrome(0.6))
                                    .frame(width: 26, height: 16)
                            }
                        }

                        Text(shape.label)
                            .font(.appUI(size: 12, weight: isSelected ? .medium : .regular))
                            .foregroundStyle(isSelected ? Color.primary : EditorTheme.chrome(0.70))
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                    .background(
                        RoundedRectangle(cornerRadius: EditorInterfaceRadius.group, style: .continuous)
                            .fill(isSelected ? EditorTheme.selectionWash : EditorTheme.groupSurface)
                            .overlay(
                                RoundedRectangle(cornerRadius: EditorInterfaceRadius.group, style: .continuous)
                                    .strokeBorder(
                                        isSelected ? EditorTheme.platinumAccent.opacity(0.25) : EditorTheme.hairline,
                                        lineWidth: isSelected ? 1 : 0.75
                                    )
                            )
                    )
                }
                .buttonStyle(.editorThumbnail)
                .appButtonKeyboardFocus(in: RoundedRectangle(cornerRadius: EditorInterfaceRadius.group, style: .continuous))
                .accessibilityAddTraits(isSelected ? .isSelected : [])
            }
        }
    }

    private func settingsCard<Content: View>(title: String, icon: String,
        @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: EditorInterfaceSpacing.headingGap) {
            Text(appLocalized(title))
                .font(EditorTypography.sectionTitle)
                .foregroundStyle(EditorTheme.primaryText)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.isHeader)
            content()
        }
        .padding(16).frame(maxWidth: .infinity, alignment: .leading)
        .background(EditorTheme.cardElevated.opacity(0.65), in: RoundedRectangle(cornerRadius: EditorInterfaceRadius.card, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: EditorInterfaceRadius.card, style: .continuous).strokeBorder(EditorTheme.hairline, lineWidth: 0.75))
    }

    private func settingIconBadge(_ icon: String, color: Color) -> some View {
        Image(systemName: icon.replacingOccurrences(of: ".fill", with: ""))
            .font(.system(size: 17, weight: .regular))
            .foregroundStyle(EditorTheme.chrome(0.60))
            .frame(width: 24, height: 28).accessibilityHidden(true)
    }

    /// 存储位置行
    private func fileLocationCardRow(
        title: String,
        subtitle: String,
        icon: String,
        color: Color,
        url: URL,
        action: @escaping () -> Void
    ) -> some View {
        HStack(spacing: 12) {
            settingIconBadge(icon, color: color)

            VStack(alignment: .leading, spacing: 3) {
                Text(appLocalized(title))
                    .font(EditorTypography.controlLabel)
                    .foregroundStyle(EditorTheme.primaryText)

                Text(url.path(percentEncoded: false).replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                    .font(EditorTypography.helper)
                    .foregroundStyle(EditorTheme.secondaryText)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(url.path(percentEncoded: false))
            }

            Spacer(minLength: 12)

            Button(action: action) {
                Text("更改…")
                    .font(.appUI(size: 12, weight: .medium))
            }
            .buttonStyle(.editorQuiet)
            .appButtonKeyboardFocus(in: RoundedRectangle(cornerRadius: EditorInterfaceRadius.control, style: .continuous))
            .accessibilityLabel(String(format: appLocalized("更改%@"), appLocalized(title)))
            .accessibilityValue(url.path(percentEncoded: false))
            .accessibilityHint(appLocalized(subtitle))
        }
    }

    /// 权限说明行
    private func permissionRow(
        title: String,
        description: String,
        icon: String,
        color: Color,
        status: String,
        statusColor: Color
    ) -> some View {
        HStack(spacing: 12) {
            settingIconBadge(icon, color: color)

            VStack(alignment: .leading, spacing: 3) {
                Text(appLocalized(title))
                    .font(EditorTypography.controlLabel)
                    .foregroundStyle(EditorTheme.primaryText)
                Text(appLocalized(description))
                    .font(EditorTypography.helper)
                    .foregroundStyle(EditorTheme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer()

            Text(appLocalized(status))
                .font(.appUI(size: 11, weight: .semibold))
                .foregroundStyle(statusColor)
                .padding(.horizontal, 9)
                .padding(.vertical, 4)
                .background(
                    statusColor.opacity(0.12),
                    in: Capsule()
                )
                .accessibilityLabel(String(format: appLocalized("权限状态：%@"), appLocalized(status)))
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(appLocalized(title))
        .accessibilityValue(appLocalized(status))
        .accessibilityHint(appLocalized(description))
    }

    // MARK: - 操作方法

    private func playSampleSound() {
        isPlayingSoundPreview = true
        NSSound(named: NSSound.Name("Glass"))?.play()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
            isPlayingSoundPreview = false
        }
    }

    private var microphonePreferenceDescription: String {
        if recordsMicrophoneByDefault {
            return preferredMicrophoneName.isEmpty
                ? appLocalized("尚未选择麦克风；进入录制时会自动使用首个可用设备。")
                : String(format: appLocalized("下次录制将使用：%@。"), preferredMicrophoneName)
        }
        return preferredMicrophoneName.isEmpty
            ? appLocalized("默认不开启麦克风录制。")
            : String(format: appLocalized("已关闭；重新开启时将优先使用 %@。"), preferredMicrophoneName)
    }

    private func openPrivacySettings() {
        guard let url = URL(
            string: "x-apple.systempreferences:com.apple.preference.security?\(privacySettingsSection)"
        ) else { return }
        NSWorkspace.shared.open(url)
    }

    private var privacySettingsSection: String {
        if !hasScreenRecordingPermission { return "Privacy_ScreenCapture" }
        if !hasAccessibilityPermission { return "Privacy_Accessibility" }
        if cameraPermission == .denied || cameraPermission == .restricted {
            return "Privacy_Camera"
        }
        if microphonePermission == .denied || microphonePermission == .restricted {
            return "Privacy_Microphone"
        }
        return "Privacy_ScreenCapture"
    }

    private var privacySettingsButtonTitle: String {
        switch privacySettingsSection {
        case "Privacy_Accessibility": "打开辅助功能设置"
        case "Privacy_Camera": "打开摄像头设置"
        case "Privacy_Microphone": "打开麦克风设置"
        case "Privacy_ScreenCapture": "打开屏幕录制设置"
        default: "打开系统隐私设置"
        }
    }

    private func refreshPermissionStates() {
        hasScreenRecordingPermission = CGPreflightScreenCaptureAccess()
        hasAccessibilityPermission = AXIsProcessTrusted()
        cameraPermission = CapturePermissionState(
            authorizationStatus: AVCaptureDevice.authorizationStatus(for: .video)
        )
        microphonePermission = CapturePermissionState(
            authorizationStatus: AVCaptureDevice.authorizationStatus(for: .audio)
        )
    }

    private func permissionStatusColor(_ state: CapturePermissionState) -> Color {
        switch state {
        case .authorized: .green
        case .notDetermined: .yellow
        case .restricted: .orange
        case .denied: .red
        }
    }

    private func chooseProjectsFolder() {
        guard let url = chooseDirectory(
            title: "选择项目自动保存位置",
            initialURL: projectsFolder
        ) else { return }
        do {
            try ProjectStore.setSavedProjectsFolder(url)
            projectsFolder = ProjectStore.savedProjectsFolder
            fileLocationError = nil
        } catch {
            fileLocationError = String(format: appLocalized("无法设置项目位置：%@"), error.localizedDescription)
        }
    }

    private func chooseExportFolder() {
        guard let url = chooseDirectory(
            title: "选择成片导出位置",
            initialURL: exportFolder
        ) else { return }
        do {
            try AppPreferences.setExportDirectory(url)
            exportFolder = AppPreferences.exportDirectoryURL
            fileLocationError = nil
        } catch {
            fileLocationError = String(format: appLocalized("无法设置导出位置：%@"), error.localizedDescription)
        }
    }

    private func chooseDirectory(title: String, initialURL: URL) -> URL? {
        let panel = NSOpenPanel()
        panel.title = appLocalized(title)
        panel.prompt = appLocalized("选择")
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.directoryURL = initialURL
        return panel.runModal() == .OK ? panel.url : nil
    }
}
