import AppKit
import Foundation
import RecorderCore

enum RecordingCameraPreviewShape: String, CaseIterable, Identifiable {
    case circle
    case roundedSquare
    case sourceAspect

    var id: String { rawValue }

    var label: String {
        switch self {
        case .circle: return "圆形"
        case .roundedSquare: return "圆角方形"
        case .sourceAspect: return "画面比例"
        }
    }
}

/// Timeline rows are editor presentation, not authored video state. Keeping
/// this bit set outside `RecorderProject` lets a user hide a busy row without
/// deleting its clips or changing preview/export output.
struct EditorTimelineTrackVisibility: OptionSet, Equatable, Sendable {
    let rawValue: Int

    static let zoom = Self(rawValue: 1 << 0)
    static let screenMotion = Self(rawValue: 1 << 1)
    static let cameraMotion = Self(rawValue: 1 << 2)
    static let mosaic = Self(rawValue: 1 << 3)
    static let sticker = Self(rawValue: 1 << 4)
    static let overlays = Self(rawValue: mosaic.rawValue | sticker.rawValue)
    static let progress = Self(rawValue: 1 << 5)

    static func initial(for _: RecorderProject) -> Self {
        // Keep the first timeline view focused on cutting plus the default
        // zoom lane. Existing animations still play; their rows appear only
        // after the editor explicitly asks for them from the track menu.
        [.zoom]
    }
}

extension Notification.Name {
    static let recordingCameraPreviewShapeDidChange = Notification.Name(
        "cn.laogou.dogsc.recording-camera-preview-shape-did-change"
    )
}

enum AppPreferences {
    static let exportCompletionSoundEnabledKey =
        "cn.laogou.dogsc.export-completion-sound-enabled"
    static let previewResolutionModeKey = "editor.previewResolutionMode"
    static let editorTimelinePrimaryLaneHeightKey =
        "editor.timeline.primary-lane-height"
    static let editorTimelinePointerClickMarkersKey =
        "editor.timeline.pointer-click-markers"
    static let editorTimelineHoverPreviewEnabledKey =
        "editor.timeline.hover-preview-enabled"
    private static let editorTimelineTrackVisibilityPrefix =
        "editor.timeline.visible-tracks"
    static let editorInspectorVisibleKey = "editor.inspector.visible"
    static let editorInspectorWidthKey = "editor.inspector.content-width"
    static let recordingCameraPreviewShapeKey =
        "recording.cameraPreviewShape"
    static let editorWindowFrameAutosaveName =
        "cn.laogou.dogsc.editor-window-frame"
    static let editorWindowFullScreenKey =
        "cn.laogou.dogsc.editor-window-full-screen"
    static let exportDirectoryKey =
        "cn.laogou.dogsc.export-directory"

    static var isExportCompletionSoundEnabled: Bool {
        let defaults = UserDefaults.standard
        guard defaults.object(forKey: exportCompletionSoundEnabledKey) != nil else {
            return true
        }
        return defaults.bool(forKey: exportCompletionSoundEnabledKey)
    }

    static var isTimelineHoverPreviewEnabled: Bool {
        let defaults = UserDefaults.standard
        guard defaults.object(forKey: editorTimelineHoverPreviewEnabledKey) != nil else {
            return true
        }
        return defaults.bool(forKey: editorTimelineHoverPreviewEnabledKey)
    }

    static func timelineTrackVisibility(
        for project: RecorderProject
    ) -> EditorTimelineTrackVisibility {
        let defaults = UserDefaults.standard
        let key = timelineTrackVisibilityKey(for: project)
        guard defaults.object(forKey: key) != nil else {
            return .initial(for: project)
        }
        return EditorTimelineTrackVisibility(rawValue: defaults.integer(forKey: key))
    }

    static func rememberTimelineTrackVisibility(
        _ visibility: EditorTimelineTrackVisibility,
        for project: RecorderProject
    ) {
        UserDefaults.standard.set(
            visibility.rawValue,
            forKey: timelineTrackVisibilityKey(for: project)
        )
    }

    /// `createdAt` is persisted, survives package renames and does not modify
    /// the project schema merely to remember editor chrome. Millisecond
    /// precision is sufficient to distinguish independently created projects.
    private static func timelineTrackVisibilityKey(for project: RecorderProject) -> String {
        let createdMilliseconds = Int64(
            (project.createdAt.timeIntervalSinceReferenceDate * 1_000).rounded()
        )
        return "\(editorTimelineTrackVisibilityPrefix).\(createdMilliseconds)"
    }

    /// 固定应用图标：直接从 Bundle 加载 AppIcon.icns。
    /// 图标为单一品牌资产，不再支持运行时更换或自定义导入。
    static var bundledAppIcon: NSImage? {
        guard let url = Bundle.main.url(
            forResource: "AppIcon",
            withExtension: "icns"
        ) else { return nil }
        return NSImage(contentsOf: url)
    }

    static var recordingCameraPreviewShape: RecordingCameraPreviewShape {
        let rawValue = UserDefaults.standard.string(
            forKey: recordingCameraPreviewShapeKey
        )
        return rawValue.flatMap(RecordingCameraPreviewShape.init(rawValue:))
            ?? .circle
    }

    static var isDefaultSystemAudioRecordingEnabled: Bool {
        let defaults = UserDefaults.standard
        guard defaults.object(
            forKey: CaptureDevicePreferenceKey.systemAudioEnabled
        ) != nil else { return true }
        return defaults.bool(forKey: CaptureDevicePreferenceKey.systemAudioEnabled)
    }

    static var defaultSystemAudioScope: SystemAudioScope {
        let rawValue = UserDefaults.standard.string(
            forKey: CaptureDevicePreferenceKey.systemAudioScope
        )
        return rawValue.flatMap(SystemAudioScope.init(rawValue:)) ?? .all
    }

    static var isDefaultMicrophoneRecordingEnabled: Bool {
        UserDefaults.standard.bool(
            forKey: CaptureDevicePreferenceKey.microphoneEnabled
        )
    }

    static var exportDirectoryURL: URL {
        if let path = UserDefaults.standard.string(forKey: exportDirectoryKey),
           !path.isEmpty,
           FileManager.default.fileExists(atPath: path) {
            return URL(fileURLWithPath: path, isDirectory: true)
        }
        let movies = FileManager.default.urls(
            for: .moviesDirectory,
            in: .userDomainMask
        ).first ?? FileManager.default.temporaryDirectory
        return movies
            .appendingPathComponent("DogSC", isDirectory: true)
            .appendingPathComponent("导出", isDirectory: true)
    }

    static func rememberExportDirectory(_ url: URL) {
        UserDefaults.standard.set(
            url.standardizedFileURL.path,
            forKey: exportDirectoryKey
        )
    }

    static func setExportDirectory(_ url: URL) throws {
        let folder = url.standardizedFileURL
        try FileManager.default.createDirectory(
            at: folder,
            withIntermediateDirectories: true
        )
        rememberExportDirectory(folder)
    }

    static func playExportCompletionSound() {
        guard isExportCompletionSoundEnabled else { return }
        NSSound(named: NSSound.Name("Glass"))?.play()
    }

    static func resetRememberedEditorWindowState() {
        let defaults = UserDefaults.standard
        defaults.removeObject(
            forKey: "NSWindow Frame \(editorWindowFrameAutosaveName)"
        )
        defaults.removeObject(forKey: editorWindowFullScreenKey)
    }
}
