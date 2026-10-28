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
        case .general: return appLocalized("通用")
        case .editor: return appLocalized("编辑器")
        case .recording: return appLocalized("录制")
        case .permissions: return appLocalized("权限")
        case .about: return appLocalized("关于")
        }
    }

    var icon: AppLineIcon.Kind {
        switch self {
        case .general: return .settings
        case .editor: return .sliders
        case .recording: return .record
        case .permissions: return .shield
        case .about: return .info
        }
    }
}

@MainActor
final class AppSettingsNavigation: ObservableObject {
    @Published var selectedSection = AppSettingsSection.general
}

/// Settings is a second recorder island. The navigation behaves like the
/// recording bar's source wheel — one name showing, the capsule stretching to
/// fit it — and the page below is a single solid shape that morphs between
/// sections while its content hands off.
struct AppSettingsView: View {
    @ObservedObject private var languageSettings = AppLanguageSettings.shared
    @ObservedObject private var updateController = AppUpdateController.shared
    @ObservedObject private var guideAccess = FirstLaunchGuideAccess.shared
    /// The tallest the window may become on this screen.
    var contentHeight: CGFloat = 640
    @ObservedObject var navigation = AppSettingsNavigation()
    /// The window follows the island; it reports the content height it needs.
    var onPreferredHeightChange: (CGFloat) -> Void = { _ in }

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

    private static let pageWidth: CGFloat = 496

    private var requiredPermissionsReady: Bool {
        hasScreenRecordingPermission && hasAccessibilityPermission
    }

    private var topInset: CGFloat { contentHeight < 520 ? 34 : 44 }
    /// Everything around the page island: top inset, navigation, the gap
    /// beneath it and room for the island's shadow at the bottom.
    private var chromeHeight: CGFloat { topInset + 56 + 18 + 30 }

    var body: some View {
        VStack(spacing: 0) {
            navigationIsland
                .padding(.top, topInset)
                .padding(.bottom, 18)

            SettingsIsland(
                pageID: navigation.selectedSection,
                maxHeight: max(160, contentHeight - chromeHeight),
                onHeightChange: { onPreferredHeightChange($0 + chromeHeight) }
            ) {
                pageContent(for: navigation.selectedSection)
            }
            .frame(width: Self.pageWidth)

            Spacer(minLength: 0)
        }
        .frame(width: 560)
        .frame(maxHeight: .infinity, alignment: .top)
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
            languageSettings.refreshFromPreferences()
            refreshPermissionStates()
            updateController.startIfEligible()
        }
        .onChange(of: navigation.selectedSection) { _, section in
            if section == .permissions { refreshPermissionStates() }
        }
        .onReceive(
            NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)
        ) { _ in
            languageSettings.refreshFromPreferences()
            refreshPermissionStates()
        }
    }

    // MARK: - Navigation island

    /// Same proportions as the recording bar: a 56 pt capsule, 44 pt targets.
    /// Only the current section shows its name; the others are glyphs.
    private var navigationIsland: some View {
        HStack(spacing: 2) {
            ForEach(AppSettingsSection.allCases) { section in
                navigationItem(section)
            }
        }
        .padding(6)
        .frame(height: 56)
        .recorderSurface(radius: 28, castsShadow: true)
        .animation(RecorderMotion.fade, value: hoveredSection)
    }

    private func navigationItem(_ section: AppSettingsSection) -> some View {
        let isSelected = navigation.selectedSection == section
        return AppChoiceButton(isSelected: isSelected) {
            switchTab(to: section)
        } label: {
            HStack(spacing: 7) {
                AppLineIcon(kind: section.icon, size: 17)
                    .modifier(AppChoiceIconFeedback())
                    .overlay(alignment: .topTrailing) {
                        if section == .permissions && !requiredPermissionsReady {
                            Circle()
                                .fill(RecorderStyle.recording)
                                .frame(width: 6, height: 6)
                                .overlay { Circle().strokeBorder(RecorderStyle.base, lineWidth: 1.5).padding(-1.5) }
                                .offset(x: 3, y: -2)
                                .transition(.scale.combined(with: .opacity))
                        }
                    }

                if isSelected {
                    Text(section.label)
                        .font(.appUI(size: 13, weight: .semibold))
                        .lineLimit(1)
                        .fixedSize()
                        .transition(.settingsLabel)
                }
            }
            .modifier(AppChoiceContentFeedback())
            .foregroundStyle(isSelected || hoveredSection == section ? RecorderStyle.ink : SettingsTheme.textSecondary)
            .padding(.leading, isSelected ? 14 : 0)
            .padding(.trailing, isSelected ? 16 : 0)
            .frame(minWidth: 44, minHeight: 44)
            .background {
                if isSelected {
                    Capsule(style: .continuous)
                        .fill(RecorderStyle.selection)
                        .matchedGeometryEffect(id: "nav.tab.thumb", in: tabHighlight)
                } else if hoveredSection == section {
                    Circle().fill(SettingsTheme.hover)
                }
            }
            .contentShape(Capsule(style: .continuous))
        }
        .onHover { inside in
            if inside { hoveredSection = section }
            else if hoveredSection == section { hoveredSection = nil }
        }
        .help(section.label)
        .accessibilityLabel(section.label)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityIdentifier("settings.section.\(section.rawValue)")
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
        switch section {
        case .general:
            SettingsGeneralPage(
                projectsFolder: projectsFolder,
                exportFolder: exportFolder,
                fileLocationError: fileLocationError,
                chooseProjectsFolder: chooseProjectsFolder,
                chooseExportFolder: chooseExportFolder,
                soundEnabled: $exportCompletionSoundEnabled,
                isPlayingSound: isPlayingSoundPreview,
                playSound: playSampleSound
            )
        case .editor:
            SettingsEditorPage(
                appearance: $appearancePreference,
                previewMode: $previewResolutionMode,
                didResetWindowState: didResetWindowState
            ) {
                AppPreferences.resetRememberedEditorWindowState()
                withAnimation(SettingsMotion.springMorph) { didResetWindowState = true }
            }
        case .recording:
            SettingsRecordingPage(
                recordsSystemAudio: $recordsSystemAudioByDefault,
                recordsMicrophone: $recordsMicrophoneByDefault,
                microphoneName: preferredMicrophoneName,
                cameraShape: $recordingCameraPreviewShape
            )
        case .permissions:
            SettingsPermissionsPage(
                items: permissionItems,
                requiredReady: requiredPermissionsReady,
                openSettings: openPrivacySettings
            )
        case .about:
            AppAboutSettingsView()
        }
    }

    private var permissionItems: [SettingsPermissionItem] {
        [
            SettingsPermissionItem(title: "屏幕录制", icon: .display, required: true,
                                   status: hasScreenRecordingPermission ? .granted : .missing(appLocalized("未授权")),
                                   pane: "Privacy_ScreenCapture"),
            SettingsPermissionItem(title: "辅助功能", icon: .cursor, required: true,
                                   status: hasAccessibilityPermission ? .granted : .missing(appLocalized("未授权")),
                                   pane: "Privacy_Accessibility"),
            SettingsPermissionItem(title: "摄像头", icon: .camera, required: false,
                                   status: status(for: cameraPermission), pane: "Privacy_Camera"),
            SettingsPermissionItem(title: "麦克风", icon: .microphone, required: false,
                                   status: status(for: microphonePermission), pane: "Privacy_Microphone"),
        ]
    }

    private func status(for state: CapturePermissionState) -> SettingsPermissionStatus {
        switch state {
        case .authorized: return .granted
        case .notDetermined: return .askLater(state.label)
        case .denied, .restricted: return .missing(state.label)
        }
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
