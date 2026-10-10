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

    var icon: AppLineIcon.Kind {
        switch self {
        case .general: .settings
        case .editor: .sliders
        case .recording: .record
        case .permissions: .shield
        case .about: .info
        }
    }
}

@MainActor
final class AppSettingsNavigation: ObservableObject {
    @Published var selectedSection = AppSettingsSection.general
}

/// Settings shares the recorder palette in both application appearances.
struct AppSettingsView: View {
    @ObservedObject private var updateController = AppUpdateController.shared
    @ObservedObject private var guideAccess = FirstLaunchGuideAccess.shared
    var contentHeight: CGFloat = 600
    @ObservedObject var navigation = AppSettingsNavigation()

    @AppStorage(AppPreferences.exportCompletionSoundEnabledKey)
    private var exportCompletionSoundEnabled = true
    @AppStorage(AppPreferences.previewResolutionModeKey)
    private var previewResolutionMode = EditorPreviewResolutionMode.defaultValue
    @AppStorage(AppPreferences.recordingCameraPreviewShapeKey)
    private var recordingCameraPreviewShape = RecordingCameraPreviewShape.circle
    @AppStorage(AppPreferences.appearancePreferenceKey)
    private var appearancePreference = AppAppearancePreference.dark
    @AppStorage(CaptureDevicePreferenceKey.systemAudioEnabled)
    private var recordsSystemAudioByDefault = true
    @AppStorage(CaptureDevicePreferenceKey.microphoneEnabled)
    private var recordsMicrophoneByDefault = false
    @AppStorage(CaptureDevicePreferenceKey.microphoneName)
    private var preferredMicrophoneName = ""

    @Namespace private var tabHighlight
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

    private var requiredPermissionsReady: Bool {
        hasScreenRecordingPermission && hasAccessibilityPermission
    }

    var body: some View {
        VStack(spacing: 0) {
            topNavigationBar
                .padding(.top, contentHeight < 520 ? 44 : 64)
                .padding(.bottom, 28)

            ScrollView(.vertical) {
                pageContent(for: navigation.selectedSection)
                    .frame(maxWidth: 496)
                    .padding(.horizontal, 32)
                    .padding(.top, 8)
                    .padding(.bottom, 40)
                    .frame(maxWidth: .infinity, alignment: .top)
                    .id(navigation.selectedSection)
                    // Recorder handoff: the old page leaves quickly, the new
                    // one arrives a beat later and settles upward.
                    .transition(RecorderMotion.reduces ? .opacity : .asymmetric(
                        insertion: .opacity.combined(with: .offset(y: 10))
                            .animation((RecorderMotion.settle ?? .easeOut(duration: 0.2)).delay(0.06)),
                        removal: .opacity.animation(.easeOut(duration: 0.12))))
            }
            .scrollIndicators(.automatic)
            .animation(RecorderMotion.fade, value: navigation.selectedSection)
        }
        .frame(width: 560)
        .frame(minHeight: contentHeight, maxHeight: .infinity)
        .background(SettingsTheme.canvasBackground)
        .ignoresSafeArea(.container, edges: .top)
        .tint(SettingsTheme.mint)
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
            if section == .permissions { refreshPermissionStates() }
        }
        .onReceive(
            NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)
        ) { _ in
            refreshPermissionStates()
        }
    }

    // MARK: - Top Navigation Bar (Floating Island Tabs)

    private var topNavigationBar: some View {
        HStack(spacing: 3) {
            ForEach(AppSettingsSection.allCases) { section in
                let isSelected = navigation.selectedSection == section
                AppChoiceButton(isSelected: isSelected) {
                    switchTab(to: section)
                } label: {
                    HStack(spacing: 6) {
                        AppLineIcon(kind: section.icon, size: 15)
                            .modifier(AppChoiceIconFeedback())

                        Text(section.label)
                            .font(.appUI(size: 12, weight: isSelected ? .semibold : .medium))
                            .lineLimit(1)
                            .fixedSize()

                        if section == .permissions && !requiredPermissionsReady {
                            Circle()
                                .fill(SettingsTheme.recording)
                                .frame(width: 5, height: 5)
                        }
                    }
                    .modifier(AppChoiceContentFeedback())
                    .foregroundStyle(isSelected ? RecorderStyle.ink : SettingsTheme.textSecondary)
                    .padding(.horizontal, 13)
                    .frame(height: 36)
                    .background {
                        if isSelected {
                            Capsule(style: .continuous)
                                .fill(RecorderStyle.selection)
                                .matchedGeometryEffect(id: "nav.tab.thumb", in: tabHighlight)
                        }
                    }
                    .contentShape(Capsule(style: .continuous))
                }
                .accessibilityAddTraits(isSelected ? .isSelected : [])
                .accessibilityIdentifier("settings.section.\(section.rawValue)")
            }
        }
        .padding(6)
        // Same island as the recording bar: 48 pt capsule, 6 pt inset so the
        // selection pill stays concentric with the outer edge.
        .recorderSurface(radius: 24, castsShadow: true)
    }

    private func switchTab(to section: AppSettingsSection) {
        guard navigation.selectedSection != section else { return }
        withAnimation(RecorderMotion.settle) {
            navigation.selectedSection = section
        }
    }

    // MARK: - Pages

    @ViewBuilder
    private func pageContent(for section: AppSettingsSection) -> some View {
        VStack(spacing: 24) {
            switch section {
            case .general:
                generalPageView
            case .editor:
                editorPageView
            case .recording:
                recordingPageView
            case .permissions:
                permissionsPageView
            case .about:
                AppAboutSettingsView()
            }
        }
    }

    // MARK: - 通用设置

    @ViewBuilder
    private var generalPageView: some View {
        SettingsCard("声音") {
            SettingsRow(
                icon: .bell,
                title: "导出完成提示音"
            ) {
                HStack(spacing: 8) {
                    Button {
                        playSampleSound()
                    } label: {
                        HStack(spacing: 5) {
                            AppLineIcon(kind: .speaker, size: 15)
                                .foregroundStyle(isPlayingSoundPreview ? RecorderStyle.positiveInk : SettingsTheme.textPrimary)
                                .modifier(SettingsActivationFeedback(trigger: isPlayingSoundPreview ? 1 : 0))
                            Text("试听")
                        }
                    }
                    .buttonStyle(SettingsPillButtonStyle())
                    .accessibilityLabel("试听导出完成提示音")

                    SettingsToggle(
                        isOn: $exportCompletionSoundEnabled,
                        accessibilityLabel: "导出完成提示音"
                    )
                }
            }
        }

        SettingsCard("存储与引导", footer: fileLocationError, footerColor: SettingsTheme.recording) {
            fileLocationRow(
                title: "项目目录",
                icon: .box,
                url: projectsFolder
            ) {
                chooseProjectsFolder()
            }

            SettingsDivider()

            fileLocationRow(
                title: "导出目录",
                icon: .download,
                url: exportFolder
            ) {
                chooseExportFolder()
            }

            SettingsDivider()

            SettingsRow(
                icon: .sparkle,
                title: "首次使用引导"
            ) {
                Button {
                    WindowCoordinator.showFirstLaunchGuide()
                } label: {
                    Text("重新开始")
                }
                .buttonStyle(SettingsPillButtonStyle())
                .disabled(!guideAccess.isAvailable)
                .help("重看启动动画与功能教学")
                .accessibilityIdentifier("settings.first-launch-guide")
            }
        }
    }

    // MARK: - 编辑器设置

    @ViewBuilder
    private var editorPageView: some View {
        SettingsCard("界面外观") {
            SettingsRow(
                icon: .appearance,
                title: "外观偏好",
                stacksControl: true
            ) {
                SettingsAppearancePicker(selection: $appearancePreference)
            }
        }

        SettingsCard("画布与窗口") {
            SettingsRow(
                icon: .display,
                title: "预览画质",
                stacksControl: true
            ) {
                SettingsSegmented(
                    options: EditorPreviewResolutionMode.allCases,
                    selection: $previewResolutionMode,
                    label: { $0.label },
                    help: { $0.detail }
                )
            }

            SettingsDivider()

            SettingsRow(
                icon: .window,
                title: "编辑窗口布局",
                detail: didResetWindowState ? "已恢复默认大小与位置" : nil,
                detailColor: RecorderStyle.positiveInk
            ) {
                Button {
                    AppPreferences.resetRememberedEditorWindowState()
                    withAnimation(SettingsMotion.springMorph) {
                        didResetWindowState = true
                    }
                } label: {
                    HStack(spacing: 5) {
                        if didResetWindowState {
                            AppLineIcon(kind: .check, size: 14)
                                .transition(.scale(scale: 0.3).combined(with: .opacity))
                        }
                        Text(appLocalized(didResetWindowState ? "已重置" : "重置布局"))
                    }
                    .foregroundStyle(didResetWindowState ? RecorderStyle.positiveInk : SettingsTheme.textPrimary)
                }
                .buttonStyle(SettingsPillButtonStyle())
                .accessibilityLabel(appLocalized(didResetWindowState ? "编辑窗口布局已重置" : "重置编辑窗口布局"))
            }
        }
    }

    // MARK: - 录制设置

    @ViewBuilder
    private var recordingPageView: some View {
        SettingsCard("默认音频输入") {
            SettingsRow(
                icon: .speaker,
                title: "录制系统声音"
            ) {
                SettingsToggle(
                    isOn: $recordsSystemAudioByDefault,
                    accessibilityLabel: "默认录制系统声音"
                )
            }

            SettingsDivider()

            SettingsRow(
                icon: .microphone,
                title: "录制麦克风声音",
                detail: recordsMicrophoneByDefault && !preferredMicrophoneName.isEmpty ? preferredMicrophoneName : nil,
                singleLineDetail: true
            ) {
                SettingsToggle(
                    isOn: $recordsMicrophoneByDefault,
                    accessibilityLabel: "默认录制麦克风声音"
                )
            }
        }

        SettingsCard("悬浮人像预览") {
            SettingsCameraShapePicker(selection: $recordingCameraPreviewShape)
                .padding(12)
        }
    }

    // MARK: - 权限设置

    private enum PermissionDisplay {
        case granted
        case askLater(String)
        case missing(String)
    }

    @ViewBuilder
    private var permissionsPageView: some View {
        if !requiredPermissionsReady {
            SettingsCard {
                HStack(spacing: 12) {
                    AppLineIcon(kind: .warning, size: 18)
                        .foregroundStyle(SettingsTheme.amber)

                    Text(appLocalized("屏幕录制或辅助功能尚未就绪，录制可能缺少画面或光标。"))
                        .font(.appUI(size: 12))
                        .foregroundStyle(SettingsTheme.textPrimary)

                    Spacer(minLength: 0)
                }
                .padding(12)
            }
        }

        SettingsCard("系统隐私权限") {
            permissionRow(
                title: "屏幕录制",
                icon: .display,
                display: hasScreenRecordingPermission ? .granted : .missing(appLocalized("未授权")),
                pane: "Privacy_ScreenCapture"
            )

            SettingsDivider()

            permissionRow(
                title: "辅助功能",
                icon: .cursor,
                display: hasAccessibilityPermission ? .granted : .missing(appLocalized("未授权")),
                pane: "Privacy_Accessibility"
            )

            SettingsDivider()

            permissionRow(
                title: "摄像头",
                icon: .camera,
                display: display(for: cameraPermission),
                pane: "Privacy_Camera"
            )

            SettingsDivider()

            permissionRow(
                title: "麦克风",
                icon: .microphone,
                display: display(for: microphonePermission),
                pane: "Privacy_Microphone"
            )
        }
    }

    private func display(for state: CapturePermissionState) -> PermissionDisplay {
        switch state {
        case .authorized: return .granted
        case .notDetermined: return .askLater(state.label)
        case .denied, .restricted: return .missing(state.label)
        }
    }

    private func permissionRow(
        title: String,
        icon: AppLineIcon.Kind,
        display: PermissionDisplay,
        pane: String
    ) -> some View {
        SettingsRow(icon: icon, title: title) {
            Group {
                switch display {
                case .granted:
                    HStack(spacing: 5) {
                        AppLineIcon(kind: .checkCircle, size: 15)
                            .foregroundStyle(RecorderStyle.positiveInk)
                        Text(appLocalized("已授权"))
                            .font(.appUI(size: 12, weight: .medium))
                            .foregroundStyle(SettingsTheme.textSecondary)
                    }
                    .padding(.horizontal, 9)
                    .padding(.vertical, 4)
                    .background(SettingsTheme.mint.opacity(0.12), in: Capsule(style: .continuous))

                case let .askLater(label):
                    HStack(spacing: 5) {
                        Circle().fill(RecorderStyle.chrome.opacity(0.3)).frame(width: 5, height: 5)
                        Text(label)
                            .font(.appUI(size: 12, weight: .medium))
                            .foregroundStyle(SettingsTheme.textSecondary)
                    }
                    .padding(.horizontal, 9)
                    .padding(.vertical, 4)
                    .background(RecorderStyle.chrome.opacity(0.06), in: Capsule(style: .continuous))

                case let .missing(label):
                    HStack(spacing: 8) {
                        HStack(spacing: 5) {
                            Circle().fill(SettingsTheme.recording).frame(width: 5, height: 5)
                            Text(label)
                                .font(.appUI(size: 12, weight: .medium))
                                .foregroundStyle(SettingsTheme.recording)
                        }

                        Button {
                            openPrivacySettings(pane)
                        } label: {
                            Text(appLocalized("前往授权"))
                        }
                        .buttonStyle(SettingsPillButtonStyle())
                        .accessibilityLabel(String(format: appLocalized("前往授权：%@"), appLocalized(title)))
                    }
                }
            }
        }
        .accessibilityLabel(appLocalized(title))
    }

    // MARK: - 存储位置辅助行

    private func fileLocationRow(
        title: String,
        icon: AppLineIcon.Kind,
        url: URL,
        action: @escaping () -> Void
    ) -> some View {
        SettingsRow(
            icon: icon,
            title: title,
            detail: url.path(percentEncoded: false).replacingOccurrences(of: NSHomeDirectory(), with: "~"),
            singleLineDetail: true
        ) {
            HStack(spacing: 8) {
                Button {
                    NSWorkspace.shared.activateFileViewerSelecting([url])
                } label: {
                    AppLineIcon(kind: .folder, size: 15)
                        .foregroundStyle(SettingsTheme.textSecondary)
                        .frame(width: 28, height: 28)
                        .background(RecorderStyle.chrome.opacity(0.06), in: Circle())
                        .contentShape(Circle())
                }
                .buttonStyle(SettingsPressStyle(scale: 0.92))
                .help("在访达中显示")
                .accessibilityLabel(String(format: appLocalized("在访达中显示%@"), appLocalized(title)))

                Button(action: action) {
                    Text(appLocalized("更改…"))
                }
                .buttonStyle(SettingsPillButtonStyle())
                .accessibilityLabel(String(format: appLocalized("更改%@"), appLocalized(title)))
                .accessibilityValue(url.path(percentEncoded: false))
            }
        }
        .help(url.path(percentEncoded: false))
    }

    // MARK: - 操作方法

    private func playSampleSound() {
        withAnimation(SettingsMotion.springSnappy) { isPlayingSoundPreview = true }
        NSSound(named: NSSound.Name("Glass"))?.play()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
            withAnimation(SettingsMotion.springSnappy) { isPlayingSoundPreview = false }
        }
    }

    private func openPrivacySettings(_ section: String) {
        guard let url = URL(
            string: "x-apple.systempreferences:com.apple.preference.security?\(section)"
        ) else { return }
        NSWorkspace.shared.open(url)
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
