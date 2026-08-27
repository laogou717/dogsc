import AppKit
import AVFoundation
import CoreGraphics
import SwiftUI

private enum AppSettingsSection: String, CaseIterable, Identifiable {
    case general
    case editor
    case recording
    case permissions

    var id: Self { self }

    var label: String {
        switch self {
        case .general: "通用"
        case .editor: "编辑器"
        case .recording: "录制"
        case .permissions: "权限"
        }
    }

    var iconName: String {
        switch self {
        case .general: "gearshape.fill"
        case .editor: "slider.horizontal.3"
        case .recording: "record.circle.fill"
        case .permissions: "lock.shield.fill"
        }
    }

    var preferredContentHeight: CGFloat {
        switch self {
        case .general: 370
        case .editor: 330
        case .recording, .permissions: 440
        }
    }
}

struct AppSettingsView: View {
    private let onPreferredContentHeightChange: (@MainActor (CGFloat) -> Void)?

    init(
        onPreferredContentHeightChange: (@MainActor (CGFloat) -> Void)? = nil
    ) {
        self.onPreferredContentHeightChange = onPreferredContentHeightChange
    }

    @AppStorage(AppPreferences.exportCompletionSoundEnabledKey)
    private var exportCompletionSoundEnabled = true
    @AppStorage(AppPreferences.previewResolutionModeKey)
    private var previewResolutionMode = EditorPreviewResolutionMode.low
    @AppStorage(AppPreferences.recordingCameraPreviewShapeKey)
    private var recordingCameraPreviewShape = RecordingCameraPreviewShape.circle
    @AppStorage(CaptureDevicePreferenceKey.systemAudioEnabled)
    private var recordsSystemAudioByDefault = true
    @AppStorage(CaptureDevicePreferenceKey.microphoneEnabled)
    private var recordsMicrophoneByDefault = false
    @AppStorage(CaptureDevicePreferenceKey.microphoneName)
    private var preferredMicrophoneName = ""

    @State private var selectedSection = AppSettingsSection.general
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
        VStack(spacing: 0) {
            // 顶部优雅分段导航栏
            headerTabBar
                .padding(.horizontal, 20)
                .padding(.top, 16)
                .padding(.bottom, 14)

            Divider()
                .overlay(Color.white.opacity(0.08))

            // 主内容区域
            ScrollView(.vertical, showsIndicators: true) {
                VStack(spacing: 20) {
                    switch selectedSection {
                    case .general:
                        generalSettingsView
                    case .editor:
                        editorSettingsView
                    case .recording:
                        recordingSettingsView
                    case .permissions:
                        permissionSettingsView
                    }
                }
                .padding(22)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(width: 620, height: selectedSection.preferredContentHeight)
        .background(Color(red: 0.10, green: 0.102, blue: 0.114))
        .preferredColorScheme(.dark)
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
            onPreferredContentHeightChange?(selectedSection.preferredContentHeight)
        }
        .onChange(of: selectedSection) { _, section in
            if section == .permissions {
                refreshPermissionStates()
            }
            onPreferredContentHeightChange?(section.preferredContentHeight)
        }
        .onReceive(
            NotificationCenter.default.publisher(
                for: NSApplication.didBecomeActiveNotification
            )
        ) { _ in
            if selectedSection == .permissions {
                refreshPermissionStates()
            }
        }
    }

    // MARK: - 顶部导航栏

    private var headerTabBar: some View {
        HStack(spacing: 6) {
            ForEach(AppSettingsSection.allCases) { section in
                let isSelected = selectedSection == section
                Button {
                    withAnimation(.easeInOut(duration: 0.18)) {
                        selectedSection = section
                    }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: section.iconName)
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(isSelected ? Color.white : Color.white.opacity(0.55))

                        Text(section.label)
                            .font(.system(size: 13, weight: isSelected ? .semibold : .regular))
                            .foregroundStyle(isSelected ? Color.white : Color.white.opacity(0.70))
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 7)
                    .background {
                        if isSelected {
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(Color.white.opacity(0.12))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                                        .stroke(Color.white.opacity(0.14), lineWidth: 1)
                                )
                        } else {
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(Color.clear)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(isSelected ? .isSelected : [])
            }
            Spacer()
        }
    }

    // MARK: - 通用设置

    @ViewBuilder
    private var generalSettingsView: some View {
        // 提示与声音
        settingsCard(title: "提示与声音", icon: "bell.badge.fill") {
            VStack(spacing: 12) {
                HStack(spacing: 12) {
                    settingIconBadge("speaker.wave.2.fill", color: .blue)

                    VStack(alignment: .leading, spacing: 3) {
                        Text("导出完成后播放提示音")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(Color.primary)
                        Text("导出取消或失败时不会播放提示音。")
                            .font(.caption)
                            .foregroundStyle(Color.white.opacity(0.50))
                    }
                    .accessibilityHidden(true)

                    Spacer()

                    Button {
                        playSampleSound()
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: isPlayingSoundPreview ? "waveform" : "play.fill")
                                .font(.system(size: 10))
                            Text("试听")
                                .font(.system(size: 12))
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .fill(Color.white.opacity(0.08))
                        )
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("试听导出完成提示音")

                    Toggle("", isOn: $exportCompletionSoundEnabled)
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .controlSize(.small)
                        .accessibilityLabel("导出完成后播放提示音")
                        .accessibilityValue(exportCompletionSoundEnabled ? "开启" : "关闭")
                        .accessibilityHint("导出取消或失败时不会播放提示音")
                }
            }
        }

        // 文件位置
        settingsCard(title: "存储位置", icon: "folder.fill") {
            VStack(spacing: 14) {
                fileLocationCardRow(
                    title: "项目自动保存位置",
                    subtitle: "录制成片与草稿项目包的默认保存路径",
                    icon: "doc.badge.arrow.up.fill",
                    color: .orange,
                    url: projectsFolder
                ) {
                    chooseProjectsFolder()
                }

                Divider().overlay(Color.white.opacity(0.06))

                fileLocationCardRow(
                    title: "成片导出默认位置",
                    subtitle: "视频导出面板记住的默认目标文件夹",
                    icon: "arrow.down.doc.fill",
                    color: .green,
                    url: exportFolder
                ) {
                    chooseExportFolder()
                }

                if let error = fileLocationError {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(Color.red)
                        .frame(maxWidth: .infinity, alignment: .leading)
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
                    settingIconBadge("speedometer", color: .purple)

                    VStack(alignment: .leading, spacing: 3) {
                        Text("默认预览画质")
                            .font(.system(size: 13, weight: .medium))
                        Text("低分辨率减少播放负担，完整分辨率在播放与暂停时都保留素材细节。")
                            .font(.caption)
                            .foregroundStyle(Color.white.opacity(0.50))
                    }

                    Spacer()

                    previewResolutionPicker
                }
            }
        }

        settingsCard(title: "窗口与界面状态", icon: "macwindow") {
            HStack(spacing: 12) {
                settingIconBadge("arrow.counterclockwise.circle.fill", color: .cyan)

                VStack(alignment: .leading, spacing: 3) {
                    Text("重置编辑窗口布局")
                        .font(.system(size: 13, weight: .medium))
                    Text(didResetWindowState
                        ? "已成功重置，将在下次打开编辑器窗口时应用默认大小与居中位置。"
                        : "清除系统记住的窗口位置、尺寸和全屏记忆状态。")
                        .font(.caption)
                        .foregroundStyle(didResetWindowState ? Color.green : Color.white.opacity(0.50))
                }

                Spacer()

                Button {
                    AppPreferences.resetRememberedEditorWindowState()
                    withAnimation { didResetWindowState = true }
                } label: {
                    Text(didResetWindowState ? "已重置" : "重置布局")
                        .font(.system(size: 12, weight: .medium))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .fill(didResetWindowState ? Color.green.opacity(0.18) : Color.white.opacity(0.08))
                        )
                        .foregroundStyle(didResetWindowState ? Color.green : Color.primary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(didResetWindowState ? "编辑窗口布局已重置" : "重置编辑窗口布局")
            }
        }
    }

    /// 预览画质切换器
    private var previewResolutionPicker: some View {
        HStack(spacing: 3) {
            ForEach(EditorPreviewResolutionMode.allCases) { mode in
                let isSelected = previewResolutionMode == mode
                Button {
                    withAnimation(.easeInOut(duration: 0.12)) {
                        previewResolutionMode = mode
                    }
                } label: {
                    Text(mode.label)
                        .font(.system(size: 12, weight: isSelected ? .semibold : .regular))
                        .foregroundStyle(isSelected ? Color.white : Color.white.opacity(0.65))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 5)
                        .background(
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .fill(isSelected ? Color.white.opacity(0.16) : Color.clear)
                                .overlay(
                                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                                        .stroke(isSelected ? Color.white.opacity(0.20) : Color.clear, lineWidth: 1)
                                )
                        )
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(isSelected ? .isSelected : [])
            }
        }
        .padding(3)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.white.opacity(0.06))
        )
    }

    // MARK: - 录制设置

    @ViewBuilder
    private var recordingSettingsView: some View {
        settingsCard(title: "默认音频输入", icon: "waveform.circle.fill") {
            VStack(spacing: 14) {
                HStack(spacing: 12) {
                    settingIconBadge("speaker.wave.3.fill", color: .indigo)

                    VStack(alignment: .leading, spacing: 3) {
                        Text("录制系统声音")
                            .font(.system(size: 13, weight: .medium))
                        Text("默认采集 macOS 系统中各应用程序发出的声音与媒体音频。")
                            .font(.caption)
                            .foregroundStyle(Color.white.opacity(0.50))
                    }
                    .accessibilityHidden(true)

                    Spacer()

                    Toggle("", isOn: $recordsSystemAudioByDefault)
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .controlSize(.small)
                        .accessibilityLabel("默认录制系统声音")
                        .accessibilityValue(recordsSystemAudioByDefault ? "开启" : "关闭")
                        .accessibilityHint("控制新录制是否默认采集系统声音")
                }

                Divider().overlay(Color.white.opacity(0.06))

                HStack(spacing: 12) {
                    settingIconBadge("mic.fill", color: .pink)

                    VStack(alignment: .leading, spacing: 3) {
                        Text("录制麦克风声音")
                            .font(.system(size: 13, weight: .medium))
                        Text(microphonePreferenceDescription)
                            .font(.caption)
                            .foregroundStyle(Color.white.opacity(0.50))
                    }
                    .accessibilityHidden(true)

                    Spacer()

                    Toggle("", isOn: $recordsMicrophoneByDefault)
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .controlSize(.small)
                        .accessibilityLabel("默认录制麦克风声音")
                        .accessibilityValue(recordsMicrophoneByDefault ? "开启" : "关闭")
                        .accessibilityHint(microphonePreferenceDescription)
                }
            }
        }

        settingsCard(title: "悬浮摄像头预览", icon: "camera.fill") {
            VStack(alignment: .leading, spacing: 14) {
                cameraShapeSelector

                Text("只影响录制时的悬浮预览，不改变摄像头源文件或编辑器布局。")
                    .font(.caption)
                    .foregroundStyle(Color.white.opacity(0.45))
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
                    color: .blue,
                    status: hasScreenRecordingPermission ? "已授权" : "未授权",
                    statusColor: hasScreenRecordingPermission ? .green : .red
                )

                Divider().overlay(Color.white.opacity(0.06))

                permissionRow(
                    title: "辅助功能权限",
                    description: "用于记录鼠标移动与点击，生成可编辑的光标轨道",
                    icon: "cursorarrow.motionlines",
                    color: .purple,
                    status: hasAccessibilityPermission ? "已授权" : "未授权",
                    statusColor: hasAccessibilityPermission ? .green : .red
                )

                Divider().overlay(Color.white.opacity(0.06))

                permissionRow(
                    title: "摄像头权限",
                    description: "用于画中画人像出镜与外接相机输入",
                    icon: "camera.fill",
                    color: .green,
                    status: cameraPermission.label,
                    statusColor: permissionStatusColor(cameraPermission)
                )

                Divider().overlay(Color.white.opacity(0.06))

                permissionRow(
                    title: "麦克风权限",
                    description: "用于人声解说录音与音频设备采集",
                    icon: "mic.fill",
                    color: .pink,
                    status: microphonePermission.label,
                    statusColor: permissionStatusColor(microphonePermission)
                )

                Divider().overlay(Color.white.opacity(0.06))

                HStack {
                    Text("如遇录屏黑屏、鼠标无法跟随或无声音，请检查上方未授权项。")
                        .font(.caption)
                        .foregroundStyle(Color.white.opacity(0.50))

                    Spacer()

                    Button {
                        openPrivacySettings()
                    } label: {
                        HStack(spacing: 6) {
                            Text(privacySettingsButtonTitle)
                                .font(.system(size: 12, weight: .medium))
                            Image(systemName: "arrow.up.forward.square.fill")
                                .font(.system(size: 11))
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .fill(Color.white.opacity(0.10))
                        )
                        .foregroundStyle(Color.white)
                    }
                    .buttonStyle(.plain)
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
                    withAnimation(.easeInOut(duration: 0.15)) {
                        recordingCameraPreviewShape = shape
                    }
                } label: {
                    VStack(spacing: 8) {
                        ZStack {
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .fill(Color.white.opacity(0.06))
                                .frame(width: 44, height: 32)

                            switch shape {
                            case .circle:
                                Circle()
                                    .fill(isSelected ? Color.blue : Color.white.opacity(0.6))
                                    .frame(width: 20, height: 20)
                            case .roundedSquare:
                                RoundedRectangle(cornerRadius: 4, style: .continuous)
                                    .fill(isSelected ? Color.blue : Color.white.opacity(0.6))
                                    .frame(width: 20, height: 20)
                            case .sourceAspect:
                                RoundedRectangle(cornerRadius: 3, style: .continuous)
                                    .fill(isSelected ? Color.blue : Color.white.opacity(0.6))
                                    .frame(width: 26, height: 16)
                            }
                        }

                        Text(shape.label)
                            .font(.system(size: 12, weight: isSelected ? .medium : .regular))
                            .foregroundStyle(isSelected ? Color.white : Color.white.opacity(0.70))
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                    .background(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(isSelected ? Color.white.opacity(0.08) : Color.white.opacity(0.03))
                            .overlay(
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .stroke(
                                        isSelected ? Color.blue.opacity(0.6) : Color.white.opacity(0.06),
                                        lineWidth: isSelected ? 1.5 : 1
                                    )
                            )
                    )
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(isSelected ? .isSelected : [])
            }
        }
    }

    /// 卡片化容器
    private func settingsCard<Content: View>(
        title: String,
        icon: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color.white.opacity(0.60))
                    .accessibilityHidden(true)

                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color.white.opacity(0.85))
                    .accessibilityAddTraits(.isHeader)
            }
            .padding(.leading, 2)

            VStack(alignment: .leading, spacing: 0) {
                content()
            }
            .padding(16)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color(white: 0.13, opacity: 0.55))
                    .overlay(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .stroke(Color.white.opacity(0.08), lineWidth: 1)
                    )
            )
        }
    }

    /// 统一图标前缀徽章
    private func settingIconBadge(_ icon: String, color: Color) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(color.opacity(0.18))
                .frame(width: 28, height: 28)

            Image(systemName: icon)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(color)
        }
        .accessibilityHidden(true)
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
                Text(title)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Color.primary)

                Text(url.path(percentEncoded: false))
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(Color.white.opacity(0.50))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(url.path(percentEncoded: false))
            }

            Spacer(minLength: 12)

            Button(action: action) {
                Text("更改…")
                    .font(.system(size: 12, weight: .medium))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(Color.white.opacity(0.08))
                    )
            }
            .buttonStyle(.plain)
            .accessibilityLabel("更改\(title)")
            .accessibilityValue(url.path(percentEncoded: false))
            .accessibilityHint(subtitle)
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
                Text(title)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Color.primary)
                Text(description)
                    .font(.caption)
                    .foregroundStyle(Color.white.opacity(0.50))
            }

            Spacer()

            Text(status)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(statusColor)
                .padding(.horizontal, 9)
                .padding(.vertical, 4)
                .background(
                    statusColor.opacity(0.12),
                    in: Capsule()
                )
                .accessibilityLabel("权限状态：\(status)")
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityValue(status)
        .accessibilityHint(description)
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
                ? "尚未选择麦克风；进入录制时会自动使用首个可用设备。"
                : "下次录制将使用：\(preferredMicrophoneName)。"
        }
        return preferredMicrophoneName.isEmpty
            ? "默认不开启麦克风录制。"
            : "已关闭；重新开启时将优先使用 \(preferredMicrophoneName)。"
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
            fileLocationError = "无法设置项目位置：\(error.localizedDescription)"
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
            fileLocationError = "无法设置导出位置：\(error.localizedDescription)"
        }
    }

    private func chooseDirectory(title: String, initialURL: URL) -> URL? {
        let panel = NSOpenPanel()
        panel.title = title
        panel.prompt = "选择"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.directoryURL = initialURL
        return panel.runModal() == .OK ? panel.url : nil
    }
}
