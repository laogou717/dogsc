import AppKit
import RecorderCore
import SwiftUI

// Each settings page is composed for what it holds, from the same parts:
// tiles on the island, the recorder's glyphs, and small live illustrations
// that show the result of a choice instead of describing it.

// MARK: - General

/// Where takes and exports land, drawn as a two-step flow, then the three
/// app-wide preferences as equal tiles.
struct SettingsGeneralPage: View {
    let projectsFolder: URL
    let exportFolder: URL
    let fileLocationError: String?
    let chooseProjectsFolder: () -> Void
    let chooseExportFolder: () -> Void
    @Binding var soundEnabled: Bool
    let isPlayingSound: Bool
    let playSound: () -> Void
    @ObservedObject private var languageSettings = AppLanguageSettings.shared
    @ObservedObject private var guideAccess = FirstLaunchGuideAccess.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingsCaption("存储位置")
            HStack(spacing: 0) {
                SettingsFolderTile(kind: .project, title: "项目目录", url: projectsFolder, change: chooseProjectsFolder)
                SettingsFlowConnector()
                SettingsFolderTile(kind: .export, title: "导出目录", url: exportFolder, change: chooseExportFolder)
            }

            if let fileLocationError {
                Text(fileLocationError)
                    .font(EditorTypography.helper)
                    .foregroundStyle(SettingsTheme.recording)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 8)
                    .padding(.top, 8)
                    .transition(.opacity)
            }

            SettingsCaption("偏好")
            HStack(alignment: .top, spacing: 8) {
                SettingsPreferenceTile(title: "界面语言") {
                    AppLineIcon(kind: .globe, size: 22)
                } control: {
                    languageMenu
                }

                SettingsPreferenceTile(title: "导出完成提示音") {
                    SettingsRingingBell(ringing: isPlayingSound, enabled: soundEnabled, size: 22)
                } control: {
                    HStack(spacing: 8) {
                        SettingsSoundPreviewButton(isPlaying: isPlayingSound, action: playSound)
                        Spacer(minLength: 0)
                        SettingsToggle(isOn: $soundEnabled, accessibilityLabel: "导出完成提示音")
                    }
                }

                SettingsPreferenceTile(title: "首次使用引导") {
                    AppLineIcon(kind: .sparkle, size: 22)
                } control: {
                    Button {
                        WindowCoordinator.showFirstLaunchGuide()
                    } label: {
                        Text(appLocalized("重新开始"))
                    }
                    .buttonStyle(SettingsPillButtonStyle(compact: true))
                    .disabled(!guideAccess.isAvailable)
                    .help(appLocalized("重看启动动画与功能教学"))
                    .accessibilityIdentifier("settings.first-launch-guide")
                }
            }
        }
        .padding(.horizontal, 6)
        .padding(.bottom, 6)
        .animation(RecorderMotion.fade, value: fileLocationError)
    }

    private var languageMenu: some View {
        Menu {
            Picker(appLocalized("界面语言"), selection: Binding(
                get: { languageSettings.selection },
                set: { languageSettings.select($0) }
            )) {
                ForEach(AppLanguagePreference.allCases) { language in
                    Text(language.label).tag(language)
                }
            }
            .pickerStyle(.inline)
            .labelsHidden()
        } label: {
            HStack(spacing: 6) {
                Text(languageSettings.selection.label)
                    .font(.appUI(size: 12, weight: .medium))
                    .lineLimit(1)
                Spacer(minLength: 0)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(SettingsTheme.textFaint)
                    .accessibilityHidden(true)
            }
            .foregroundStyle(SettingsTheme.textPrimary)
            .padding(.horizontal, 11)
            .frame(maxWidth: .infinity)
            .frame(height: 26)
            .background(SettingsTheme.thumb, in: Capsule())
            .shadow(color: SettingsTheme.thumbShadow, radius: 2, y: 1)
            .contentShape(Capsule())
        }
        // A plain button-style menu draws the custom capsule as-is; the
        // borderless style re-tints the whole label with the accent colour.
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .tint(SettingsTheme.textPrimary)
        .accessibilityLabel(appLocalized("界面语言"))
        .accessibilityValue(languageSettings.selection.label)
        .accessibilityIdentifier("settings.interface-language")
        .help(appLocalized("切换后立即生效，无需重新打开 DogSC"))
    }
}

/// Glyph on top, name in the middle, its one control along the bottom edge.
private struct SettingsPreferenceTile<Artwork: View, Control: View>: View {
    let title: String
    @ViewBuilder let artwork: () -> Artwork
    @ViewBuilder let control: () -> Control

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            artwork()
                .foregroundStyle(SettingsTheme.textSecondary)
                .frame(height: 24)
            Spacer(minLength: 12)
            Text(appLocalized(title))
                .font(.appUI(size: 12.5, weight: .semibold))
                .foregroundStyle(SettingsTheme.textPrimary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 12)
            control()
        }
        .padding(12)
        .frame(maxWidth: .infinity, minHeight: 140, alignment: .leading)
        .settingsTile()
    }
}

private struct SettingsFolderTile: View {
    let kind: SettingsFolderArtwork.Kind
    let title: String
    let url: URL
    let change: () -> Void
    @State private var hovered = false

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Button {
                NSWorkspace.shared.activateFileViewerSelecting([url])
            } label: {
                VStack(alignment: .leading, spacing: 0) {
                    SettingsFolderArtwork(kind: kind, open: hovered)
                    Spacer(minLength: 14)
                    Text(appLocalized(title))
                        .font(.appUI(size: 11, weight: .medium))
                        .foregroundStyle(SettingsTheme.textSecondary)
                    Text(FileManager.default.displayName(atPath: url.path(percentEncoded: false)))
                        .font(.appUI(size: 15, weight: .semibold))
                        .foregroundStyle(SettingsTheme.textPrimary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .padding(.top, 2)
                        .id(url)
                        .transition(.opacity.combined(with: .offset(y: 4)))
                    Text(url.deletingLastPathComponent().path(percentEncoded: false)
                        .replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                        .font(.appUI(size: 10.5))
                        .foregroundStyle(SettingsTheme.textFaint)
                        .lineLimit(1)
                        .truncationMode(.head)
                        .padding(.top, 2)
                }
                .padding(14)
                .frame(maxWidth: .infinity, minHeight: 140, alignment: .leading)
                .settingsTile(hovered: hovered)
                .contentShape(RoundedRectangle(cornerRadius: SettingsLayout.tileRadius, style: .continuous))
            }
            .buttonStyle(SettingsPressStyle(scale: 0.98))
            .appButtonKeyboardFocus(in: RoundedRectangle(cornerRadius: SettingsLayout.tileRadius, style: .continuous))
            .help(appLocalized("在访达中显示"))
            .accessibilityLabel(String(format: appLocalized("在访达中显示%@"), appLocalized(title)))
            .accessibilityValue(url.path(percentEncoded: false))

            Button(action: change) {
                Text(appLocalized("更改…"))
            }
            .buttonStyle(SettingsPillButtonStyle(compact: true))
            .padding(10)
            .accessibilityLabel(String(format: appLocalized("更改%@"), appLocalized(title)))
        }
        .onHover { inside in withAnimation(RecorderMotion.settle ?? RecorderMotion.fade) { hovered = inside } }
        .animation(RecorderMotion.settle, value: url)
    }
}

/// A folder whose front tilts open while the pointer is over its tile,
/// lifting the sheet inside. The badge says what lives there.
struct SettingsFolderArtwork: View {
    enum Kind { case project, export }
    let kind: Kind
    let open: Bool

    // Every layer is opaque so nothing behind the front panel shows through.
    private static let projectBack = Color(nsColor: RecorderStyle.adaptive(
        NSColor(white: 0.58, alpha: 1), NSColor(white: 0.30, alpha: 1)))
    private static let projectFront = Color(nsColor: RecorderStyle.adaptive(
        NSColor(white: 0.70, alpha: 1), NSColor(white: 0.44, alpha: 1)))
    private static let exportBack = Color(nsColor: RecorderStyle.adaptive(
        NSColor(calibratedRed: 0.15, green: 0.48, blue: 0.32, alpha: 1),
        NSColor(calibratedRed: 0.13, green: 0.40, blue: 0.27, alpha: 1)))
    private static let exportFront = Color(nsColor: RecorderStyle.adaptive(
        NSColor(calibratedRed: 0.25, green: 0.64, blue: 0.44, alpha: 1),
        NSColor(calibratedRed: 0.22, green: 0.58, blue: 0.40, alpha: 1)))
    private static let sheet = Color(nsColor: RecorderStyle.adaptive(
        NSColor(white: 1, alpha: 1), NSColor(white: 0.90, alpha: 1)))

    var body: some View {
        let lift = open && !RecorderMotion.reduces
        let back = kind == .project ? Self.projectBack : Self.exportBack
        let front = kind == .project ? Self.projectFront : Self.exportFront
        ZStack(alignment: .bottom) {
            // Back panel with its tab, one opaque silhouette.
            ZStack(alignment: .topLeading) {
                UnevenRoundedRectangle(topLeadingRadius: 3, topTrailingRadius: 3, style: .continuous)
                    .frame(width: 17, height: 8)
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .frame(width: 42, height: 30)
                    .offset(y: 4)
            }
            .frame(width: 42, height: 34, alignment: .topLeading)
            .foregroundStyle(back)

            // The sheet inside.
            RoundedRectangle(cornerRadius: 3, style: .continuous)
                .fill(Self.sheet)
                .shadow(color: .black.opacity(0.12), radius: 1, y: 0.5)
                .frame(width: 32, height: 22)
                .offset(y: lift ? -12 : -7)

            // Front panel with a fine highlight along its top edge.
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(front)
                .overlay {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .strokeBorder(LinearGradient(colors: [.white.opacity(0.35), .white.opacity(0)],
                                                     startPoint: .top, endPoint: .center), lineWidth: 1)
                }
                .overlay {
                    AppLineIcon(kind: kind == .project ? .film : .share, size: 12)
                        .foregroundStyle(Color.white)
                }
                .shadow(color: .black.opacity(0.12), radius: 1.5, y: -0.5)
                .frame(width: 42, height: 24)
                .rotation3DEffect(.degrees(lift ? -28 : 0), axis: (x: 1, y: 0, z: 0),
                                  anchor: .bottom, perspective: 0.6)
        }
        .frame(width: 42, height: 36)
        .accessibilityHidden(true)
    }
}

/// Takes are saved to the project folder; finished videos go to exports.
private struct SettingsFlowConnector: View {
    var body: some View {
        HStack(spacing: 0) {
            Capsule().frame(width: 5, height: 1.5)
            AppLineIcon(kind: .chevron, size: 10)
        }
        .foregroundStyle(SettingsTheme.textFaint)
        .frame(width: 22)
        .accessibilityHidden(true)
    }
}

// MARK: - Desktop picture

/// The user's current wallpaper, decoded once at preview sizes. Both the
/// editor and recording pages paint their miniatures on the real desktop.
@MainActor
final class SettingsDesktopPicture: ObservableObject {
    static let shared = SettingsDesktopPicture()
    @Published private(set) var image: NSImage?
    /// A tiny decode drawn without interpolation: honest coarse pixels.
    @Published private(set) var coarse: NSImage?
    private var loadedPath: String?

    func refresh() {
        let path: String
        let isVideo: Bool
        switch SystemWallpaperLibrary.currentBackgroundSource() {
        case let .systemImage(absolutePath): path = absolutePath; isVideo = false
        case let .systemVideo(absolutePath): path = absolutePath; isVideo = true
        default: return
        }
        guard path != loadedPath else { return }
        loadedPath = path
        let url = URL(fileURLWithPath: path)
        Task { [weak self] in
            let full = isVideo
                ? await SystemWallpaperThumbnailLoader.image(at: url, isVideo: true)
                : await WallpaperThumbnailLoader.image(at: url, maximumPixelSize: 1100, aspectRatio: nil)
            let coarse = isVideo ? nil : await WallpaperThumbnailLoader.image(at: url, maximumPixelSize: 34, aspectRatio: nil)
            guard let self, self.loadedPath == path else { return }
            withAnimation(RecorderMotion.fade) {
                self.image = full
                self.coarse = coarse
            }
        }
    }
}

/// The wallpaper filling its frame, or a calm gradient until it arrives.
private struct SettingsDesk: View {
    @ObservedObject var picture: SettingsDesktopPicture
    var coarse = false

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [Color(red: 0.42, green: 0.52, blue: 0.70), Color(red: 0.70, green: 0.55, blue: 0.62)],
                startPoint: .topLeading, endPoint: .bottomTrailing)
            if let image = picture.image {
                Color.clear
                    .overlay { Image(nsImage: image).resizable().scaledToFill() }
                    .transition(.opacity)
            }
            if coarse, let tiny = picture.coarse {
                Color.clear
                    .overlay {
                        Image(nsImage: tiny)
                            .resizable()
                            .interpolation(.none)
                            .scaledToFill()
                    }
                    .transition(.opacity)
            }
        }
        .clipped()
        .animation(RecorderMotion.settle ?? RecorderMotion.fade, value: coarse)
    }
}

/// A caption on the left, its control filling the rest of the line.
private struct SettingsControlLine<Control: View>: View {
    let title: String
    @ViewBuilder let control: () -> Control

    var body: some View {
        HStack(spacing: 12) {
            Text(appLocalized(title))
                .font(.appUI(size: 12.5, weight: .semibold))
                .foregroundStyle(SettingsTheme.textPrimary)
                .lineLimit(2)
                .frame(width: 104, alignment: .leading)
            control()
        }
        .padding(.leading, 8)
        .frame(minHeight: 50)
    }
}

// MARK: - Editor

/// One live miniature of the editor, standing on the user's desktop. The
/// appearance repaints its chrome; preview quality changes how sharply the
/// canvas draws the picture. Controls sit underneath as plain lines.
struct SettingsEditorPage: View {
    @Binding var appearance: AppAppearancePreference
    @Binding var previewMode: EditorPreviewResolutionMode
    let didResetWindowState: Bool
    let resetWindowState: () -> Void
    @Environment(\.colorScheme) private var colorScheme
    @ObservedObject private var desktop = SettingsDesktopPicture.shared

    private var showsDark: Bool {
        switch appearance {
        case .dark: return true
        case .light: return false
        case .system: return colorScheme == .dark
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingsEditorMiniature(
                dark: showsDark,
                sharp: previewMode == .full,
                qualityNote: previewMode.detail,
                resetPulse: didResetWindowState,
                desktop: desktop
            )
            .padding(.top, 6)
            .padding(.bottom, 8)

            SettingsControlLine(title: "外观") {
                SettingsSegmented(
                    options: AppAppearancePreference.allCases,
                    selection: $appearance,
                    label: { $0.label },
                    icon: { preference in
                        switch preference {
                        case .system: return .appearance
                        case .light: return .sun
                        case .dark: return .moon
                        }
                    }
                )
                .accessibilityElement(children: .contain)
                .accessibilityLabel(appLocalized("外观偏好"))
            }

            SettingsControlLine(title: "预览画质") {
                SettingsSegmented(
                    options: EditorPreviewResolutionMode.allCases,
                    selection: $previewMode,
                    label: { $0.label },
                    help: { $0.detail }
                )
            }

            SettingsControlLine(title: "编辑窗口布局") {
                HStack(spacing: 8) {
                    if didResetWindowState {
                        Text(appLocalized("已恢复默认大小与位置"))
                            .font(.appUI(size: 11, weight: .medium))
                            .foregroundStyle(RecorderStyle.positiveInk)
                            .lineLimit(1)
                            .minimumScaleFactor(0.85)
                            .transition(.opacity.combined(with: .offset(x: 6)))
                    }
                    Spacer(minLength: 0)
                    Button(action: resetWindowState) {
                        HStack(spacing: 5) {
                            AppLineIcon(kind: didResetWindowState ? .check : .refresh, size: 12)
                                .contentTransition(.opacity)
                            Text(appLocalized(didResetWindowState ? "已重置" : "重置布局"))
                        }
                        .foregroundStyle(didResetWindowState ? RecorderStyle.positiveInk : SettingsTheme.textPrimary)
                    }
                    .buttonStyle(SettingsPillButtonStyle(compact: true))
                    .accessibilityLabel(appLocalized(didResetWindowState ? "编辑窗口布局已重置" : "重置编辑窗口布局"))
                }
            }
        }
        .padding(.horizontal, 6)
        .padding(.bottom, 4)
        .onAppear { desktop.refresh() }
    }
}

/// A small but complete editor: title bar, canvas, inspector and timeline.
private struct SettingsEditorMiniature: View {
    let dark: Bool
    let sharp: Bool
    let qualityNote: String
    let resetPulse: Bool
    @ObservedObject var desktop: SettingsDesktopPicture

    var body: some View {
        let chrome = Color(white: dark ? 0.115 : 0.985)
        let panel = Color(white: dark ? 0.19 : 0.925)
        let line = Color(white: dark ? 0.30 : 0.80)
        let stage = Color(white: dark ? 0.05 : 0.88)
        let frame = RoundedRectangle(cornerRadius: SettingsLayout.tileRadius, style: .continuous)

        ZStack {
            SettingsDesk(picture: desktop)
                .overlay(Color.black.opacity(dark ? 0.18 : 0.04))

            // A menu bar sells the wallpaper as a display, not a cropped
            // picture behind the window.
            HStack(spacing: 5) {
                Image(systemName: "applelogo")
                    .font(.system(size: 7))
                Capsule().fill(.primary.opacity(0.5)).frame(width: 20, height: 3)
                Capsule().fill(.primary.opacity(0.3)).frame(width: 13, height: 3)
                Spacer(minLength: 0)
                Image(systemName: "wifi")
                    .font(.system(size: 6, weight: .semibold))
                Image(systemName: "battery.100")
                    .font(.system(size: 7))
                Capsule().fill(.primary.opacity(0.5)).frame(width: 16, height: 3)
            }
            .foregroundStyle(.primary.opacity(0.8))
            .padding(.horizontal, 9)
            .frame(height: 15)
            .background(.ultraThinMaterial)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)

            VStack(spacing: 0) {
                // Title bar.
                HStack(spacing: 4) {
                    Circle().fill(Color(red: 1.0, green: 0.37, blue: 0.34)).frame(width: 6, height: 6)
                    Circle().fill(Color(red: 1.0, green: 0.74, blue: 0.18)).frame(width: 6, height: 6)
                    Circle().fill(Color(red: 0.16, green: 0.79, blue: 0.25)).frame(width: 6, height: 6)
                    Spacer()
                    Capsule().fill(line).frame(width: 54, height: 5)
                    Spacer()
                    Capsule().fill(panel).frame(width: 30, height: 10)
                    Capsule().fill(Color(white: dark ? 0.92 : 0.14)).frame(width: 26, height: 10)
                }
                .padding(.horizontal, 9)
                .frame(height: 22)

                HStack(spacing: 6) {
                    // Canvas: the picture drawn at the chosen quality.
                    ZStack(alignment: .bottomLeading) {
                        stage
                        SettingsDesk(picture: desktop, coarse: !sharp)
                            .clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))
                            .shadow(color: .black.opacity(0.25), radius: 3, y: 1)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 10)
                        Text(qualityNote)
                            .font(.appUI(size: 9, weight: .semibold))
                            .foregroundStyle(Color.white)
                            .padding(.horizontal, 6)
                            .frame(height: 15)
                            .background(Color.black.opacity(0.55), in: Capsule())
                            .padding(6)
                            .id(qualityNote)
                            .transition(.opacity.combined(with: .scale(scale: 0.9, anchor: .bottomLeading)))
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))

                    // Inspector.
                    VStack(alignment: .leading, spacing: 7) {
                        Capsule().fill(line).frame(width: 40, height: 4)
                        RoundedRectangle(cornerRadius: 3).fill(panel).frame(height: 18)
                        Capsule().fill(line.opacity(0.7)).frame(width: 52, height: 4)
                        ZStack(alignment: .leading) {
                            Capsule().fill(panel).frame(height: 3)
                            Capsule().fill(RecorderStyle.mint).frame(width: 34, height: 3)
                            Circle().fill(Color.white).frame(width: 8, height: 8)
                                .shadow(color: .black.opacity(0.25), radius: 1, y: 0.5)
                                .offset(x: 30)
                        }
                        Capsule().fill(line.opacity(0.7)).frame(width: 34, height: 4)
                        HStack(spacing: 4) {
                            RoundedRectangle(cornerRadius: 3).fill(panel)
                            RoundedRectangle(cornerRadius: 3).fill(panel)
                        }
                        .frame(height: 16)
                        Spacer(minLength: 0)
                    }
                    .padding(7)
                    .frame(width: 88)
                    .background(panel.opacity(0.45), in: RoundedRectangle(cornerRadius: 5, style: .continuous))
                }
                .padding(.horizontal, 6)

                // Timeline.
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 4).fill(panel.opacity(0.6))
                    HStack(spacing: 3) {
                        RoundedRectangle(cornerRadius: 3).fill(Color(red: 0.36, green: 0.55, blue: 0.95).opacity(0.85)).frame(width: 120)
                        RoundedRectangle(cornerRadius: 3).fill(Color(red: 0.30, green: 0.78, blue: 0.55).opacity(0.85)).frame(width: 70)
                        RoundedRectangle(cornerRadius: 3).fill(Color(red: 0.98, green: 0.66, blue: 0.30).opacity(0.85)).frame(width: 96)
                    }
                    .padding(4)
                    Rectangle().fill(Color(white: dark ? 0.95 : 0.15)).frame(width: 1.5).offset(x: 150)
                }
                .frame(height: 26)
                .padding(6)
            }
            .background(chrome, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(Color.white.opacity(dark ? 0.10 : 0.5), lineWidth: 0.5)
            }
            .shadow(color: .black.opacity(dark ? 0.5 : 0.25), radius: 16, y: 7)
            .padding(.horizontal, 40)
            .padding(.top, 30)
            .padding(.bottom, 20)
            // Resetting the layout settles the window back into place.
            .scaleEffect(resetPulse && !RecorderMotion.reduces ? 0.96 : 1)
            .animation(.spring(response: 0.4, dampingFraction: 0.6), value: resetPulse)
        }
        .frame(height: 238)
        .clipShape(frame)
        .animation(RecorderMotion.settle ?? RecorderMotion.fade, value: dark)
        .animation(RecorderMotion.settle ?? RecorderMotion.fade, value: qualityNote)
        .accessibilityHidden(true)
    }
}

// MARK: - Recording

/// A miniature of the next take: the user's desktop inside the capture
/// viewfinder, the recording bar with the default inputs, and the floating
/// camera in the chosen shape. Controls underneath change the scene.
struct SettingsRecordingPage: View {
    @Binding var recordsSystemAudio: Bool
    @Binding var recordsMicrophone: Bool
    let microphoneName: String
    @Binding var cameraShape: RecordingCameraPreviewShape
    @ObservedObject private var desktop = SettingsDesktopPicture.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingsRecordingScene(
                systemAudio: recordsSystemAudio,
                microphone: recordsMicrophone,
                shape: cameraShape,
                desktop: desktop
            )
            .padding(.top, 6)
            .padding(.bottom, 8)

            SettingsControlLine(title: "默认音频输入") {
                HStack(spacing: 6) {
                    SettingsInputChip(title: "系统声音", onSymbol: "speaker.wave.2.fill", offSymbol: "speaker.slash.fill",
                                      isOn: $recordsSystemAudio, accessibilityLabel: "默认录制系统声音")
                    SettingsInputChip(title: "麦克风", onSymbol: "mic.fill", offSymbol: "mic.slash.fill",
                                      isOn: $recordsMicrophone, accessibilityLabel: "默认录制麦克风声音")
                        .help(microphoneName)
                }
            }

            if recordsMicrophone && !microphoneName.isEmpty {
                HStack(spacing: 5) {
                    Image(systemName: "mic.fill").font(.system(size: 9, weight: .medium))
                    Text(microphoneName).lineLimit(1).truncationMode(.middle)
                }
                .font(.appUI(size: 11, weight: .medium))
                .foregroundStyle(SettingsTheme.textFaint)
                .padding(.leading, 124)
                .padding(.top, -8)
                .padding(.bottom, 4)
                .transition(.opacity.combined(with: .offset(y: -4)))
            }

            SettingsControlLine(title: "悬浮窗形状") {
                SettingsSegmented(
                    options: RecordingCameraPreviewShape.allCases,
                    selection: $cameraShape,
                    label: { $0.label },
                    icon: { shape in
                        switch shape {
                        case .circle: return .shapeCircle
                        case .roundedSquare: return .shapeRounded
                        case .sourceAspect: return .shapeWide
                        }
                    }
                )
                .accessibilityElement(children: .contain)
                .accessibilityLabel(appLocalized("悬浮窗形状"))
            }
        }
        .padding(.horizontal, 6)
        .padding(.bottom, 4)
        .animation(RecorderMotion.settle, value: recordsMicrophone)
        .onAppear { desktop.refresh() }
    }
}

/// An input switch as a compact capsule: lit with the recorder's filled
/// glyph when on, sunk and struck through when off.
private struct SettingsInputChip: View {
    let title: String
    let onSymbol: String
    let offSymbol: String
    @Binding var isOn: Bool
    let accessibilityLabel: String
    @State private var hovered = false

    var body: some View {
        Button {
            withAnimation(RecorderMotion.settle) { isOn.toggle() }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: isOn ? onSymbol : offSymbol)
                    .font(.system(size: 11.5, weight: .medium))
                    .contentTransition(.symbolEffect(.replace))
                    .foregroundStyle(isOn ? RecorderStyle.positiveInk : SettingsTheme.textFaint)
                    .frame(width: 16)
                Text(appLocalized(title))
                    .font(.appUI(size: 12, weight: .semibold))
                    .foregroundStyle(isOn ? SettingsTheme.textPrimary : SettingsTheme.textSecondary)
                    .lineLimit(1)
            }
            .padding(.horizontal, 12)
            .frame(maxWidth: .infinity)
            .frame(height: 34)
            .background {
                Capsule(style: .continuous)
                    .fill(isOn ? SettingsTheme.thumb : RecorderStyle.chrome.opacity(hovered ? 0.08 : 0.05))
                    .shadow(color: isOn ? SettingsTheme.thumbShadow : .clear, radius: 3, y: 1)
            }
            .overlay {
                Capsule(style: .continuous)
                    .strokeBorder(RecorderStyle.positiveInk.opacity(isOn ? 0.35 : 0), lineWidth: 1)
            }
            .contentShape(Capsule(style: .continuous))
        }
        .buttonStyle(SettingsPressStyle(scale: 0.95))
        .appButtonKeyboardFocus(in: Capsule(style: .continuous))
        .onHover { hovered = $0 }
        .animation(RecorderMotion.settle, value: isOn)
        .animation(RecorderMotion.fade, value: hovered)
        .accessibilityLabel(appLocalized(accessibilityLabel))
        .accessibilityValue(appLocalized(isOn ? "开关状态 · 开启" : "开关状态 · 关闭"))
    }
}

private struct SettingsRecordingScene: View {
    let systemAudio: Bool
    let microphone: Bool
    let shape: RecordingCameraPreviewShape
    @ObservedObject var desktop: SettingsDesktopPicture
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let frame = RoundedRectangle(cornerRadius: SettingsLayout.tileRadius, style: .continuous)
        ZStack {
            SettingsDesk(picture: desktop)

            // A window on the recorded desktop.
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 3) {
                    ForEach(0..<3, id: \.self) { _ in
                        Circle().fill(Color.primary.opacity(0.18)).frame(width: 5, height: 5)
                    }
                }
                Capsule().fill(Color.primary.opacity(0.12)).frame(width: 96, height: 5)
                Capsule().fill(Color.primary.opacity(0.08)).frame(width: 140, height: 5)
                Capsule().fill(Color.primary.opacity(0.08)).frame(width: 74, height: 5)
            }
            .padding(12)
            .frame(width: 210, height: 108, alignment: .topLeading)
            .background(RecorderStyle.base, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            .shadow(color: .black.opacity(0.22), radius: 10, y: 4)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .padding(.leading, 34)
            .padding(.top, 30)

            // The capture viewfinder, as on the real display selection.
            CaptureViewfinder(inset: 10, arm: 18, radius: 10)
                .stroke(Color.white.opacity(0.92), style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                .shadow(color: .black.opacity(0.3), radius: 3)

            // The floating camera.
            SettingsCameraBubble(shape: shape)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                .padding(.trailing, 24)
                .padding(.bottom, 22)

            // The recording bar, showing the defaults it will start with.
            SettingsMiniRecorderBar(systemAudio: systemAudio, microphone: microphone)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                .padding(.bottom, 20)
        }
        .frame(height: 236)
        .clipShape(frame)
        .accessibilityHidden(true)
    }
}

/// The idle recording bar at a third of its size.
private struct SettingsMiniRecorderBar: View {
    let systemAudio: Bool
    let microphone: Bool

    var body: some View {
        HStack(spacing: 2) {
            HStack(spacing: 5) {
                RecorderModeGlyph(mode: .display, size: 11)
                Text(appLocalized("显示器"))
                    .font(.appUI(size: 10, weight: .semibold))
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 5.5, weight: .bold))
                    .foregroundStyle(RecorderStyle.faint)
            }
            .padding(.horizontal, 9)
            .frame(height: 24)
            .background(RecorderStyle.well, in: Capsule())

            glyph(microphone ? "mic.fill" : "mic.slash.fill", on: microphone, ring: true)
            glyph(systemAudio ? "speaker.wave.2.fill" : "speaker.slash.fill", on: systemAudio)

            ZStack {
                Circle().fill(RecorderStyle.recording).frame(width: 22, height: 22)
                Circle().fill(Color.white).frame(width: 7, height: 7)
            }
            .frame(width: 28, height: 28)
        }
        .padding(.horizontal, 5)
        .frame(height: 34)
        .foregroundStyle(RecorderStyle.ink)
        .recorderSurface(radius: 17, castsShadow: true)
    }

    private func glyph(_ symbol: String, on: Bool, ring: Bool = false) -> some View {
        ZStack {
            if ring {
                Circle()
                    .strokeBorder(RecorderStyle.mint, lineWidth: 1)
                    .frame(width: 20, height: 20)
                    .scaleEffect(on ? 1 : 0.6)
                    .opacity(on ? 1 : 0)
            }
            Image(systemName: symbol)
                .font(.system(size: 10, weight: .medium))
                .contentTransition(.symbolEffect(.replace))
                .foregroundStyle(on ? RecorderStyle.ink : RecorderStyle.faint)
        }
        .frame(width: 26, height: 28)
        .animation(RecorderMotion.settle, value: on)
    }
}

/// The floating camera bubble. Its size and corners travel on the morph
/// spring, so switching shape reads as one object changing form.
private struct SettingsCameraBubble: View {
    let shape: RecordingCameraPreviewShape

    private var bubbleSize: CGSize {
        switch shape {
        case .circle, .roundedSquare: return CGSize(width: 62, height: 62)
        case .sourceAspect: return CGSize(width: 100, height: 57)
        }
    }

    private var bubbleRadius: CGFloat {
        switch shape {
        case .circle: return 31
        case .roundedSquare: return 15
        case .sourceAspect: return 10
        }
    }

    var body: some View {
        let outline = RoundedRectangle(cornerRadius: bubbleRadius, style: .continuous)
        outline
            .fill(LinearGradient(
                colors: [Color(red: 0.86, green: 0.78, blue: 0.70), Color(red: 0.56, green: 0.50, blue: 0.48)],
                startPoint: .top, endPoint: .bottom))
            .overlay(alignment: .bottom) {
                Portrait()
                    .fill(LinearGradient(colors: [Color(red: 0.24, green: 0.27, blue: 0.34), Color(red: 0.14, green: 0.15, blue: 0.20)],
                                         startPoint: .top, endPoint: .bottom))
                    .frame(width: 46, height: 46)
            }
            .clipShape(outline)
            .overlay { outline.strokeBorder(Color.white.opacity(0.9), lineWidth: 2) }
            .frame(width: bubbleSize.width, height: bubbleSize.height)
            .shadow(color: .black.opacity(0.3), radius: 8, y: 3)
            .animation(RecorderMotion.morph, value: shape)
    }

    /// Head and shoulders, filled.
    private struct Portrait: Shape {
        func path(in rect: CGRect) -> Path {
            var path = Path()
            let head = rect.width * 0.38
            path.addEllipse(in: CGRect(x: rect.midX - head / 2, y: rect.minY + rect.height * 0.14, width: head, height: head))
            path.addRoundedRect(in: CGRect(x: rect.minX + rect.width * 0.10, y: rect.minY + rect.height * 0.64,
                                           width: rect.width * 0.80, height: rect.height * 0.6),
                                cornerSize: CGSize(width: rect.width * 0.38, height: rect.width * 0.38),
                                style: .continuous)
            return path
        }
    }
}

// MARK: - Permissions

enum SettingsPermissionStatus: Equatable {
    case granted
    case askLater(String)
    case missing(String)
}

struct SettingsPermissionItem: Identifiable {
    let title: String
    let icon: AppLineIcon.Kind
    let required: Bool
    let status: SettingsPermissionStatus
    let pane: String
    var id: String { pane }
}

/// A ring that counts what is granted, then one tile per permission. A
/// missing required permission turns its tile amber and carries the fix.
struct SettingsPermissionsPage: View {
    let items: [SettingsPermissionItem]
    let requiredReady: Bool
    let openSettings: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            SettingsPermissionSummary(
                granted: items.filter { $0.status == .granted }.count,
                total: items.count,
                requiredReady: requiredReady
            )
            .padding(.top, 6)

            LazyVGrid(columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)], spacing: 8) {
                ForEach(items) { item in
                    tile(item)
                }
            }
        }
        .padding(.horizontal, 6)
        .padding(.bottom, 6)
    }

    private func tile(_ item: SettingsPermissionItem) -> some View {
        let missing: Bool
        if case .missing = item.status { missing = true } else { missing = false }
        return VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top) {
                AppLineIcon(kind: item.icon, size: 22)
                    .foregroundStyle(item.status == .granted ? SettingsTheme.textPrimary : SettingsTheme.textSecondary)
                Spacer(minLength: 0)
                statusMark(item.status)
            }
            Spacer(minLength: 14)
            HStack(spacing: 6) {
                Text(appLocalized(item.title))
                    .font(.appUI(size: 13, weight: .semibold))
                    .foregroundStyle(SettingsTheme.textPrimary)
                    .lineLimit(1)
                if item.required {
                    Text(appLocalized("必需"))
                        .font(.appUI(size: 9.5, weight: .semibold))
                        .foregroundStyle(SettingsTheme.textSecondary)
                        .padding(.horizontal, 5)
                        .frame(height: 16)
                        .background(RecorderStyle.chrome.opacity(0.07), in: Capsule())
                }
            }
            Group {
                switch item.status {
                case .granted:
                    Text(appLocalized("已授权"))
                        .font(.appUI(size: 11, weight: .medium))
                        .foregroundStyle(RecorderStyle.positiveInk)
                case let .askLater(label):
                    Text(label)
                        .font(.appUI(size: 11, weight: .medium))
                        .foregroundStyle(SettingsTheme.textFaint)
                case .missing:
                    Button {
                        openSettings(item.pane)
                    } label: {
                        Text(appLocalized("前往授权"))
                    }
                    .buttonStyle(SettingsPillButtonStyle(prominent: true, compact: true))
                    .accessibilityLabel(String(format: appLocalized("前往授权：%@"), appLocalized(item.title)))
                }
            }
            .frame(height: 26, alignment: .leading)
            .padding(.top, 4)
            .transition(.opacity.combined(with: .offset(y: 3)))
        }
        .padding(14)
        .frame(maxWidth: .infinity, minHeight: 132, alignment: .leading)
        .settingsTile(tint: missing && item.required ? SettingsTheme.amber : nil)
        .animation(RecorderMotion.settle, value: item.status)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(appLocalized(item.title))
    }

    @ViewBuilder
    private func statusMark(_ status: SettingsPermissionStatus) -> some View {
        switch status {
        case .granted:
            ZStack {
                Circle().fill(RecorderStyle.positiveInk)
                AppLineIcon(kind: .check, size: 12).foregroundStyle(Color.white)
            }
            .frame(width: 20, height: 20)
            .transition(.scale.combined(with: .opacity))
        case .askLater:
            Circle().strokeBorder(SettingsTheme.textFaint, lineWidth: 1.5).frame(width: 20, height: 20)
        case let .missing(label):
            Text(label)
                .font(.appUI(size: 10.5, weight: .semibold))
                .foregroundStyle(SettingsTheme.recording)
        }
    }
}
