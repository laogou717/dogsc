import RecorderCore
import SwiftUI

/// One page of the 全片设置 stack. Each opens what used to be a tab or a
/// frame sub-tab; their controls are unchanged, only how you reach them.
enum EditorSettingsPage: String, CaseIterable, Identifiable {
    case background, layout, mockup, cursor, camera, sound, opening, motion

    var id: String { rawValue }

    var title: String {
        switch self {
        case .background: "背景"
        case .layout: "布局"
        case .mockup: "样机"
        case .cursor: "光标"
        case .camera: "摄像头"
        case .sound: "声音"
        case .opening: "开场"
        case .motion: "运镜"
        }
    }

    var tab: InspectorTab {
        switch self {
        case .background, .layout, .mockup: .frame
        case .cursor: .cursor
        case .camera: .camera
        case .sound: .audio
        case .opening: .opening
        case .motion: .zoom
        }
    }

    var frameTab: FrameInspectorTab? {
        switch self {
        case .background: .background
        case .layout: .layout
        case .mockup: .mockup
        default: nil
        }
    }

    var isFrame: Bool { frameTab != nil }

    var icon: AppLineIcon.Kind {
        switch self {
        case .background: .layers
        case .layout: .layout
        case .mockup: .display
        case .cursor: .cursor
        case .camera: .camera
        case .sound: .speaker
        case .opening: .opening
        case .motion: .zoom
        }
    }

    static func page(for tab: InspectorTab, frame: FrameInspectorTab) -> EditorSettingsPage {
        switch tab {
        case .frame:
            switch frame {
            case .background: .background
            case .layout: .layout
            case .mockup: .mockup
            }
        case .opening: .opening
        case .zoom: .motion
        case .cursor: .cursor
        case .camera: .camera
        case .audio: .sound
        }
    }
}

enum EditorInspectorStackLevel: Equatable {
    case overview, settings, object
}

struct EditorSettingsOverviewRow: Identifiable {
    let page: EditorSettingsPage
    var value: String
    var isAvailable = true
    var id: EditorSettingsPage { page }
}

/// The first page of the inspector: every whole-video setting with its
/// current value, so the state of the project reads at a glance. Click a row
/// to open it.
struct EditorSettingsOverview: View {
    @ObservedObject var editorStore: EditorStore
    let rows: [EditorSettingsOverviewRow]
    let open: (EditorSettingsPage) -> Void

    private static let groups: [[EditorSettingsPage]] = [
        [.background, .layout, .mockup],
        [.cursor, .camera, .sound],
        [.opening, .motion],
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(Self.groups.enumerated()), id: \.offset) { index, group in
                if index > 0 {
                    Rectangle().fill(EditorTheme.hairline).frame(height: 1).padding(.vertical, 6)
                }
                VStack(spacing: 1) {
                    ForEach(group, id: \.self) { page in
                        if let row = rows.first(where: { $0.page == page }) {
                            EditorSettingsOverviewRowView(row: row) { open(page) }
                        }
                    }
                }
            }
        }
    }
}

private struct EditorSettingsOverviewRowView: View {
    let row: EditorSettingsOverviewRow
    let action: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                AppLineIcon(kind: row.page.icon, size: 16)
                    .foregroundStyle(EditorTheme.secondaryText)
                Text(appLocalized(row.page.title))
                    .font(.appUI(size: 13.5))
                    .foregroundStyle(row.isAvailable ? EditorTheme.primaryText : EditorTheme.tertiaryText)
                Spacer(minLength: 8)
                Text(row.value)
                    .font(.appUI(size: 12.5))
                    .foregroundStyle(EditorTheme.tertiaryText)
                    .lineLimit(1)
                    .truncationMode(.tail)
                AppLineIcon(kind: .chevron, size: 12)
                    .foregroundStyle(EditorTheme.tertiaryText)
            }
            .padding(.horizontal, 8)
            .frame(minHeight: 34)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(EditorTheme.chrome(hovered ? EditorStateWash.hover * 0.7 : 0))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, -8)
        .onHover { hovered = $0 }
        .animation(SpringMotion.micro, value: hovered)
        .disabled(!row.isAvailable)
        .accessibilityLabel(appLocalized(row.page.title))
        .accessibilityValue(row.value)
        .accessibilityIdentifier("editor.settings.\(row.page.rawValue)")
    }
}

extension EditorInspectorView {
    /// Current values for the overview, in the user's terms.
    var overviewRows: [EditorSettingsOverviewRow] {
        let project = editorStore.sceneEditingPreviewProject
        let canvas = screenAppearanceCanvas
        let camera = project.camera
        let cursor = project.cursorStyle
        let audio = project.audio
        let backgroundValue: String = switch canvas.backgroundSource {
        case let .pattern(preset): appLocalized(preset.displayName)
        case let .dynamicFlow(preset): appLocalized(preset.displayName)
        case .projectImage, .systemImage: appLocalized("图片")
        case .projectVideo, .systemVideo: appLocalized("动态壁纸")
        }
        let frameValue: String = switch canvas.screenFrame {
        case .none: appLocalized("无边框")
        case .windowLight, .windowDark: appLocalized("macOS 窗口")
        case .browserLight, .browserDark: appLocalized("浏览器")
        case .devicePhone, .devicePhonePortrait, .devicePhoneLandscape: "iPhone"
        case .deviceTablet, .deviceTabletPortrait, .deviceTabletLandscape: "iPad"
        }
        let cursorName = cursorAssets.first(where: { $0.id == cursor.assetID })?.displayName ?? "系统"
        let cursorValue = cursor.assetID == .hidden
            ? appLocalized("隐藏")
            : String(format: appLocalized("%@ · %@ 倍"), appLocalized(cursorName), Self.number(cursor.size))
        let cameraValue = camera.isHidden
            ? appLocalized("已隐藏")
            : String(format: appLocalized("%@ · %lld%%"), appLocalized(camera.shape.rawValue), Int64((camera.size * 100).rounded()))
        var soundParts: [String] = []
        if projectHasSystemAudio {
            soundParts.append(audio.isSystemMuted ? appLocalized("系统静音") : "\(Int((audio.systemVolume * 100).rounded()))%")
        }
        if projectHasMicrophoneAudio {
            soundParts.append(audio.isMicrophoneMuted ? appLocalized("麦克风静音") : "\(Int((audio.microphoneVolume * 100).rounded()))%")
        }
        let openingValue = project.openingSequence.isEnabled
            ? String(format: appLocalized("%@ · %@ 秒"), appLocalized(project.openingSequence.preset.rawValue),
                     Self.number(project.openingSequence.duration))
            : appLocalized("未启用")
        let zoomCount = project.zoomAnimations.count
        let motionCount = project.timeline.screenMotionClips.count
        let motionValue: String = {
            var parts: [String] = []
            if zoomCount > 0 { parts.append(String(format: appLocalized("缩放 %lld 处"), Int64(zoomCount))) }
            if motionCount > 0 { parts.append(String(format: appLocalized("3D %lld 处"), Int64(motionCount))) }
            return parts.isEmpty ? appLocalized("无") : parts.joined(separator: " · ")
        }()
        return [
            .init(page: .background, value: backgroundValue),
            .init(page: .layout, value: String(format: appLocalized("边距 %lld · 圆角 %lld"),
                                               Int64(canvas.padding.rounded()), Int64(canvas.cornerRadius.rounded()))),
            .init(page: .mockup, value: frameValue),
            // 这一层描述整段视频：可用性按项目里有没有这类素材判断，
            // 不看播放头此刻停在哪个片段上。
            .init(page: .cursor, value: cursorValue, isAvailable: projectHasPointerEvents),
            .init(page: .camera, value: projectHasCameraVideo ? cameraValue : appLocalized("没有摄像头"),
                  isAvailable: projectHasCameraVideo),
            .init(page: .sound, value: soundParts.isEmpty ? appLocalized("没有声音") : soundParts.joined(separator: " · "),
                  isAvailable: projectHasSystemAudio || projectHasMicrophoneAudio),
            .init(page: .opening, value: openingValue),
            .init(page: .motion, value: motionValue),
        ]
    }

    /// 片段页用的同一组行：值已经由 `sceneEditingPreviewProject` 解析到这一段，
    /// 这里只把可用性改成看这一段自己的录制。开场属于整片，不在片段这一层
    /// 出现；插入素材的声音有自己的控件，不重复给一行。
    func segmentOverviewRows(_ segment: ResolvedRecordingSegment) -> [EditorSettingsOverviewRow] {
        let isInserted = segment.media != nil
        let source = isInserted ? nil : editorStore.project.source(segment.sourceID)
        return overviewRows.compactMap { row in
            var row = row
            switch row.page {
            case .opening:
                return nil
            case .sound:
                if isInserted {
                    guard let summary = insertedSegmentSoundSummary(segment) else { return nil }
                    row.value = summary
                    row.isAvailable = true
                } else {
                    row.isAvailable = sourceHasAudio || microphoneHasAudio
                }
            case .cursor:
                row.isAvailable = source?.media.pointerEvents != nil
            case .camera:
                let hasCamera = source?.media.camera != nil
                row.isAvailable = hasCamera
                if !hasCamera { row.value = appLocalized("没有摄像头") }
            default:
                break
            }
            return row
        }
    }

    static func number(_ value: Double) -> String {
        let rounded = (value * 10).rounded() / 10
        return rounded == rounded.rounded() ? String(format: "%.0f", rounded) : String(format: "%.1f", rounded)
    }
}
