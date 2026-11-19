import AppKit
import AVFoundation
import CoreGraphics
import RecorderCore
import SwiftUI

enum AppSettingsSection: String, CaseIterable, Identifiable {
    case general
    case editor
    case recording
    case ai
    case shortcuts
    case permissions
    case about

    var id: Self { self }

    var label: String {
        switch self {
        case .general: appLocalized("通用")
        case .editor: appLocalized("编辑与导出")
        case .recording: appLocalized("录制")
        case .ai: "AI"
        case .shortcuts: appLocalized("快捷键")
        case .permissions: appLocalized("权限")
        case .about: String(format: appLocalized("关于 %@"), AppIdentity.displayName)
        }
    }

    var icon: AppLineIcon.Kind? {
        switch self {
        case .general: .settings
        case .editor: .editorLayout
        case .recording: .record
        case .ai: .sparkle
        case .shortcuts: nil
        case .permissions: .shield
        case .about: .info
        }
    }
}

@MainActor
final class AppSettingsNavigation: ObservableObject {
    @Published var selectedSection = AppSettingsSection.general
}

/// The settings window: categories on the left, one setting per row on the
/// right, the same controls as the editor.
struct AppSettingsView: View {
    @ObservedObject private var languageSettings = AppLanguageSettings.shared
    @ObservedObject private var updateController = AppUpdateController.shared
    /// The tallest the window may become on this screen.
    var contentHeight: CGFloat = AppSettingsWindowController.contentHeight
    @ObservedObject var navigation = AppSettingsNavigation()
    /// The window reports the content height it needs.
    var onPreferredHeightChange: (CGFloat) -> Void = { _ in }

    @AppStorage(AppPreferences.exportCompletionSoundEnabledKey)
    private var exportCompletionSoundEnabled = true
    @AppStorage(AppPreferences.audioLoudnessNormalizationEnabledKey)
    private var audioLoudnessNormalizationEnabled = true
    @AppStorage(AppPreferences.previewResolutionModeKey)
    private var previewResolutionMode = EditorPreviewResolutionMode.defaultValue
    @AppStorage(AppPreferences.editorTimelineSnappingEnabledKey)
    private var timelineSnappingEnabled = false
    @AppStorage(AppPreferences.exportDefaultResolutionKey)
    private var exportDefaultResolution = CanvasResolution.source
    @AppStorage(AppPreferences.recordingCameraPreviewShapeKey)
    private var recordingCameraPreviewShape = RecordingCameraPreviewShape.circle
    @AppStorage(AppPreferences.recordingCameraPreviewVisibleKey)
    private var recordingCameraPreviewVisible = true
    @AppStorage(AppPreferences.recordingFrameRateKey)
    private var recordingFrameRate = OutputFrameRate.fps60.rawValue
    @AppStorage(AppPreferences.recordingHidesDesktopIconsKey)
    private var recordingHidesDesktopIcons = false
    @AppStorage(AppPreferences.recordingHidesDockKey)
    private var recordingHidesDock = false
    @AppStorage(AppPreferences.appearancePreferenceKey)
    private var appearancePreference = AppAppearancePreference.dark
    @AppStorage(CaptureDevicePreferenceKey.systemAudioEnabled)
    private var recordsSystemAudioByDefault = true
    @AppStorage(CaptureDevicePreferenceKey.microphoneEnabled)
    private var recordsMicrophoneByDefault = false
    @AppStorage(CaptureDevicePreferenceKey.microphoneName)
    private var preferredMicrophoneName = ""

    @State private var hoveredSection: AppSettingsSection?
    @State private var didResetWindowState = false
    @State private var isPlayingSoundPreview = false
    @State private var microphones: [CaptureDeviceInfo] = []
    @State private var projectsFolder = ProjectStore.savedProjectsFolder
    @State private var libraryFolder = AssetLibrary.shared.folder
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
        HStack(spacing: 0) {
            sidebar
            Rectangle().fill(EditorTheme.chrome(0.075)).frame(width: 1)
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    pageContent(for: navigation.selectedSection)
                }
                .padding(.horizontal, 34)
                .padding(.top, 28)
                .padding(.bottom, 30)
                .frame(maxWidth: .infinity, alignment: .leading)
                .id(navigation.selectedSection)
                .transition(.opacity)
            }
            .scrollIndicators(.automatic)
            .background(EditorTheme.panelSurface)
        }
        .frame(width: AppSettingsWindowController.contentWidth, height: contentHeight)
        .background(EditorTheme.panelSurface)
        .ignoresSafeArea(.container, edges: .top)
        .appControlFocusAppearance()
        .onAppear { onPreferredHeightChange(AppSettingsWindowController.contentHeight) }
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
            languageSettings.refreshFromPreferences()
            refreshPermissionStates()
            updateController.startIfEligible()
        }
        .onChange(of: navigation.selectedSection) { _, section in
            if section == .permissions { refreshPermissionStates() }
            if section == .recording { refreshMicrophones() }
        }
        .onReceive(
            NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)
        ) { _ in
            languageSettings.refreshFromPreferences()
            refreshPermissionStates()
        }
    }

    // MARK: - Sidebar

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 2) {
            Color.clear.frame(height: 44) // traffic lights
            ForEach(AppSettingsSection.allCases.filter { $0 != .about }) { section in
                sidebarItem(section)
            }
            Spacer(minLength: 0)
            sidebarItem(.about)
        }
        .padding(.horizontal, 10)
        .padding(.bottom, 12)
        .frame(width: 200)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(EditorTheme.backgroundDeep)
    }

    private func sidebarItem(_ section: AppSettingsSection) -> some View {
        let selected = navigation.selectedSection == section
        let hovered = hoveredSection == section && !selected
        let shape = RoundedRectangle(cornerRadius: 8, style: .continuous)
        return Button {
            guard !selected else { return }
            navigation.selectedSection = section
        } label: {
            HStack(spacing: 9) {
                Group {
                    if let icon = section.icon {
                        AppLineIcon(kind: icon, size: 16)
                    } else {
                        EditorSymbol("keyboard", size: 16).font(.system(size: 13))
                    }
                }
                .frame(width: 16, height: 16)
                Text(section.label)
                    .font(.appUI(size: 13.5, weight: selected ? .medium : .regular))
                Spacer(minLength: 0)
                if section == .permissions && !requiredPermissionsReady {
                    Circle().fill(EditorTheme.destructiveText).frame(width: 6, height: 6)
                        .accessibilityLabel(appLocalized("有权限未开启"))
                }
            }
            .foregroundStyle(selected || hovered ? EditorTheme.primaryText : EditorTheme.secondaryText)
            .padding(.horizontal, 9)
            .frame(height: 32)
            .background(shape.fill(EditorTheme.chrome(selected ? 0.08 : hovered ? 0.045 : 0)))
            .contentShape(shape)
        }
        .buttonStyle(.plain)
        .appButtonKeyboardFocus(in: shape)
        .onHover { inside in
            if inside { hoveredSection = section } else if hoveredSection == section { hoveredSection = nil }
        }
        .animation(SpringMotion.micro, value: hovered)
        .accessibilityLabel(section.label)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityIdentifier("settings.section.\(section.rawValue)")
    }

    // MARK: - Pages

    @ViewBuilder
    private func pageContent(for section: AppSettingsSection) -> some View {
        switch section {
        case .general: generalPage
        case .editor: editorPage
        case .recording: recordingPage
        case .ai: AppSettingsAIPage()
        case .shortcuts: AppSettingsShortcutsPage()
        case .permissions: permissionsPage
        case .about: AppAboutSettingsView()
        }
    }

    @ViewBuilder
    private var generalPage: some View {
        SettingsPageHeader(title: "通用", lead: "语言、外观和文件放在哪里")
        SettingsGroup {
            SettingsRow("语言") { SettingsLanguageMenu() }
            SettingsRow("外观", last: true) {
                AppSegmentedChoice(options: [.system, .light, .dark], selection: $appearancePreference,
                                   label: { $0.label }, optionMinWidth: 64)
            }
        }
        SettingsGroup("文件") {
            SettingsRow("项目保存在", detail: "新录制自动存到这里") {
                SettingsPathControl(url: projectsFolder, action: chooseProjectsFolder)
            }
            SettingsRow("素材库", detail: "AI 生成的动效、图片、音频", last: true) {
                SettingsPathControl(url: libraryFolder, action: chooseLibraryFolder)
            }
        }
        fileLocationErrorText
    }

    @ViewBuilder
    private var editorPage: some View {
        SettingsPageHeader(title: "编辑与导出", lead: "编辑器的默认行为和导出位置")
        SettingsGroup("编辑") {
            SettingsRow("默认预览画质", detail: "编辑器里也可以随时切换") {
                AppSegmentedChoice(options: [.low, .full], selection: $previewResolutionMode,
                                   label: { $0.label }, optionMinWidth: 64)
            }
            SettingsRow("时间线吸附", detail: "拖动时吸附到播放头和片段边缘") {
                EditorToggle(isOn: $timelineSnappingEnabled)
                    .accessibilityLabel(appLocalized("时间线吸附"))
            }
            SettingsRow("编辑窗口布局", detail: didResetWindowState ? "已恢复默认大小与位置" : "恢复默认大小和面板宽度", last: true) {
                Button(appLocalized("恢复")) {
                    AppPreferences.resetRememberedEditorWindowState()
                    didResetWindowState = true
                }
                .buttonStyle(.appSheet)
                .disabled(didResetWindowState)
            }
        }
        SettingsGroup("导出") {
            SettingsRow("导出到") {
                SettingsPathControl(url: exportFolder, action: chooseExportFolder)
            }
            SettingsRow("默认分辨率") {
                SettingsMenu(resolutionTitle(exportDefaultResolution)) {
                    ForEach(CanvasResolution.allCases) { resolution in
                        Button(resolutionTitle(resolution)) { exportDefaultResolution = resolution }
                    }
                }
                .accessibilityLabel(appLocalized("默认分辨率"))
            }
            SettingsRow("声音响度自适应", detail: "自动提升偏轻的录音并保护混音峰值，剪辑试听与导出一致") {
                EditorToggle(isOn: $audioLoudnessNormalizationEnabled)
                    .accessibilityLabel(appLocalized("声音响度自适应"))
            }
            SettingsRow("导出完成时播放提示音", last: true) {
                Button(action: playSampleSound) {
                    HStack(spacing: 6) {
                        AppLineIcon(kind: .play, size: 12)
                        Text(appLocalized(isPlayingSoundPreview ? "播放中" : "试听"))
                    }
                }
                .buttonStyle(.appSheetGhost)
                .disabled(!exportCompletionSoundEnabled)
                EditorToggle(isOn: $exportCompletionSoundEnabled)
                    .accessibilityLabel(appLocalized("导出完成提示音"))
            }
        }
        fileLocationErrorText
    }

    private func resolutionTitle(_ resolution: CanvasResolution) -> String {
        resolution == .source ? appLocalized("原始") : resolution.rawValue
    }

    @ViewBuilder
    private var recordingPage: some View {
        SettingsPageHeader(title: "录制", lead: "新录制默认带上哪些声音和画面")
        SettingsGroup {
            SettingsRow("录制系统声音", detail: "电脑播放的声音") {
                EditorToggle(isOn: $recordsSystemAudioByDefault)
                    .accessibilityLabel(appLocalized("录制系统声音"))
            }
            SettingsRow("录制麦克风") {
                SettingsMenu(preferredMicrophoneName.isEmpty ? appLocalized("默认麦克风") : preferredMicrophoneName) {
                    if microphones.isEmpty {
                        Text(appLocalized("没有可用的麦克风"))
                    }
                    ForEach(microphones) { device in
                        Button(device.name) { chooseMicrophone(device) }
                    }
                }
                .accessibilityLabel(appLocalized("麦克风"))
                EditorToggle(isOn: $recordsMicrophoneByDefault)
                    .accessibilityLabel(appLocalized("录制麦克风"))
            }
            SettingsRow("摄像头悬浮窗", detail: "录制时在屏幕上显示自己", last: true) {
                SettingsMenu(recordingCameraPreviewShape.label) {
                    ForEach(RecordingCameraPreviewShape.allCases) { shape in
                        Button(shape.label) { recordingCameraPreviewShape = shape }
                    }
                }
                .disabled(!recordingCameraPreviewVisible)
                .accessibilityLabel(appLocalized("悬浮窗形状"))
                EditorToggle(isOn: $recordingCameraPreviewVisible)
                    .accessibilityLabel(appLocalized("摄像头悬浮窗"))
            }
        }
        SettingsGroup("画面") {
            SettingsRow("录制帧率") {
                AppSegmentedChoice(options: [OutputFrameRate.fps30.rawValue, OutputFrameRate.fps60.rawValue],
                                   selection: $recordingFrameRate, label: { "\($0)" }, optionMinWidth: 64)
            }
            SettingsRow("隐藏桌面图标", detail: "录制时自动隐藏") {
                EditorToggle(isOn: $recordingHidesDesktopIcons)
                    .accessibilityLabel(appLocalized("隐藏桌面图标"))
            }
            SettingsRow("隐藏程序坞", last: true) {
                EditorToggle(isOn: $recordingHidesDock)
                    .accessibilityLabel(appLocalized("隐藏程序坞"))
            }
        }
        .onAppear(perform: refreshMicrophones)
    }

    @ViewBuilder
    private var permissionsPage: some View {
        SettingsPageHeader(title: "权限", lead: "录屏需要两项权限，其余按需开启")
        let items = permissionItems
        ForEach(items) { item in
            SettingsPermissionRow(item: item, last: item.id == items.last?.id) {
                openPrivacySettings(item.pane)
            }
        }
    }

    @ViewBuilder
    private var fileLocationErrorText: some View {
        if let fileLocationError {
            Text(fileLocationError)
                .font(.appUI(size: 12.5))
                .foregroundStyle(EditorTheme.destructiveText)
                .padding(.top, 10)
        }
    }

    private var permissionItems: [SettingsPermissionItem] {
        [
            SettingsPermissionItem(title: "屏幕录制", detail: "录下屏幕画面", icon: .display, required: true,
                                   status: hasScreenRecordingPermission ? .granted : .missing,
                                   pane: "Privacy_ScreenCapture"),
            SettingsPermissionItem(title: "辅助功能", detail: "记录鼠标点击，用来自动缩放", icon: .cursor, required: true,
                                   status: hasAccessibilityPermission ? .granted : .missing,
                                   pane: "Privacy_Accessibility"),
            SettingsPermissionItem(title: "摄像头", detail: "录制时拍摄自己", icon: .lens, required: false,
                                   status: status(for: cameraPermission), pane: "Privacy_Camera"),
            SettingsPermissionItem(title: "麦克风", detail: "录下你的声音", icon: .microphone, required: false,
                                   status: status(for: microphonePermission), pane: "Privacy_Microphone"),
        ]
    }

    private func refreshMicrophones() {
        Task { @MainActor in
            microphones = await CaptureDeviceCatalog.snapshotForUI().microphones
        }
    }

    /// Remembers the chosen microphone and turns it on for new recordings.
    private func chooseMicrophone(_ device: CaptureDeviceInfo) {
        let defaults = UserDefaults.standard
        defaults.set(device.id, forKey: CaptureDevicePreferenceKey.microphoneID)
        defaults.set(device.name, forKey: CaptureDevicePreferenceKey.microphoneName)
        preferredMicrophoneName = device.name
        if recordsMicrophoneByDefault {
            WindowCoordinator.setDefaultMicrophoneRecordingEnabled(true)
        } else {
            recordsMicrophoneByDefault = true
        }
    }

    private func status(for state: CapturePermissionState) -> SettingsPermissionStatus {
        switch state {
        case .authorized: .granted
        case .notDetermined: .askLater
        case .denied, .restricted: .missing
        }
    }

    // MARK: - 操作方法

    private func playSampleSound() {
        isPlayingSoundPreview = true
        NSSound(named: NSSound.Name("Glass"))?.play()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
            isPlayingSoundPreview = false
        }
    }

    private func openPrivacySettings(_ section: String) {
        guard let url = URL(
            string: "x-apple.systempreferences:com.apple.preference.security?\(section)"
        ) else { return }
        NSWorkspace.shared.open(url)
    }

    private func refreshPermissionStates() {
        withAnimation(RecorderMotion.settle) {
            hasScreenRecordingPermission = CGPreflightScreenCaptureAccess()
            hasAccessibilityPermission = AXIsProcessTrusted()
            cameraPermission = CapturePermissionState(
                authorizationStatus: AVCaptureDevice.authorizationStatus(for: .video)
            )
            microphonePermission = CapturePermissionState(
                authorizationStatus: AVCaptureDevice.authorizationStatus(for: .audio)
            )
        }
    }

    private func chooseProjectsFolder() {
        Task { @MainActor in
            guard let url = await chooseDirectory(title: "选择项目自动保存位置", initialURL: projectsFolder) else { return }
            do {
                try ProjectStore.setSavedProjectsFolder(url)
                projectsFolder = ProjectStore.savedProjectsFolder
                fileLocationError = nil
            } catch {
                fileLocationError = String(format: appLocalized("无法设置项目位置：%@"), error.localizedDescription)
            }
        }
    }

    private func chooseLibraryFolder() {
        Task { @MainActor in
            guard let url = await chooseDirectory(title: "选择素材库位置", initialURL: libraryFolder) else { return }
            AssetLibrary.shared.setFolder(url)
            libraryFolder = AssetLibrary.shared.folder
        }
    }

    private func chooseExportFolder() {
        Task { @MainActor in
            guard let url = await chooseDirectory(title: "选择成片导出位置", initialURL: exportFolder) else { return }
            do {
                try AppPreferences.setExportDirectory(url)
                exportFolder = AppPreferences.exportDirectoryURL
                fileLocationError = nil
            } catch {
                fileLocationError = String(format: appLocalized("无法设置导出位置：%@"), error.localizedDescription)
            }
        }
    }

    private func chooseDirectory(title: String, initialURL: URL) async -> URL? {
        await AppFilePanel.open { panel in
            panel.title = appLocalized(title)
            panel.prompt = appLocalized("选择")
            panel.canChooseDirectories = true
            panel.canChooseFiles = false
            panel.canCreateDirectories = true
            panel.directoryURL = initialURL
        }?.first
    }
}
