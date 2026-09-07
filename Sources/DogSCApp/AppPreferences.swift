import AppKit
import Foundation
import RecorderCore
import SwiftUI

/// Localizes labels that are assembled as `String` values rather than passed
/// to SwiftUI as localization keys. Keeping this at the app boundary also
/// avoids coupling RecorderCore's persisted raw values to the UI language.
func appLocalized(_ key: String) -> String {
    Bundle.main.localizedString(forKey: key, value: key, table: nil)
}

enum AppAppearancePreference: String, CaseIterable, Identifiable {
    case system
    case light
    case dark

    var id: Self { self }

    var label: String {
        switch self {
        case .system: appLocalized("跟随系统")
        case .light: appLocalized("浅色")
        case .dark: appLocalized("深色")
        }
    }

    var colorScheme: ColorScheme? {
        switch self {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
    }

    var appKitAppearance: NSAppearance? {
        switch self {
        case .system: nil
        case .light: NSAppearance(named: .aqua)
        case .dark: NSAppearance(named: .darkAqua)
        }
    }
}

enum RecordingCameraPreviewShape: String, CaseIterable, Identifiable {
    case circle
    case roundedSquare
    case sourceAspect

    var id: String { rawValue }

    var label: String {
        switch self {
        case .circle: return appLocalized("圆形")
        case .roundedSquare: return appLocalized("圆角方形")
        case .sourceAspect: return appLocalized("画面比例")
        }
    }
}

/// App-level creation preferences for newly pasted/imported stickers. These
/// are deliberately limited to authoring intent that is useful across assets;
/// geometry, timing and layer order remain unique to every new sticker.
private struct RememberedStickerCreationDefaults: Codable, Equatable {
    var version = 1
    var animation: StickerAnimationPreset
    /// Optional only for decoding creation defaults written before the shared
    /// motion model existed. New snapshots always store an explicit value.
    var animationCurve: ElementMotionCurve?
    var exitAnimation: StickerAnimationPreset?
    var enterDuration: TimeInterval
    var exitDuration: TimeInterval
    var backdropBlur: Double
    var backdropBlurIncludesCamera: Bool
    var hidesScreen: Bool
    var hidesCamera: Bool

    static let standard = Self(
        animation: .pop,
        animationCurve: .swift,
        exitAnimation: nil,
        enterDuration: 0.7,
        exitDuration: 0.22,
        backdropBlur: 20,
        backdropBlurIncludesCamera: false,
        hidesScreen: false,
        hidesCamera: false
    )

    init(
        animation: StickerAnimationPreset,
        animationCurve: ElementMotionCurve? = .swift,
        exitAnimation: StickerAnimationPreset?,
        enterDuration: TimeInterval,
        exitDuration: TimeInterval,
        backdropBlur: Double,
        backdropBlurIncludesCamera: Bool,
        hidesScreen: Bool,
        hidesCamera: Bool
    ) {
        self.animation = animation
        self.animationCurve = animationCurve
        self.exitAnimation = exitAnimation
        self.enterDuration = enterDuration
        self.exitDuration = exitDuration
        self.backdropBlur = backdropBlur
        self.backdropBlurIncludesCamera = backdropBlurIncludesCamera
        self.hidesScreen = hidesScreen
        self.hidesCamera = hidesCamera
        normalize()
    }

    init(sticker: StickerClip) {
        self.init(
            animation: sticker.animation,
            animationCurve: sticker.animationCurve,
            exitAnimation: sticker.exitAnimation,
            enterDuration: sticker.enterDuration,
            exitDuration: sticker.exitDuration,
            backdropBlur: sticker.backdropBlur,
            backdropBlurIncludesCamera: sticker.backdropBlurIncludesCamera,
            hidesScreen: sticker.hidesScreen,
            hidesCamera: sticker.hidesCamera
        )
    }

    mutating func normalize() {
        enterDuration = min(max(enterDuration.isFinite ? enterDuration : 0.7, 0), 2)
        exitDuration = min(max(exitDuration.isFinite ? exitDuration : 0.22, 0), 2)
        backdropBlur = min(max(backdropBlur.isFinite ? backdropBlur : 20, 0), 60)
    }

    func apply(to sticker: inout StickerClip) {
        sticker.animation = animation
        sticker.animationCurve = animationCurve ?? .swift
        sticker.exitAnimation = exitAnimation
        sticker.enterDuration = enterDuration
        sticker.exitDuration = exitDuration
        sticker.backdropBlur = backdropBlur
        sticker.backdropBlurIncludesCamera = backdropBlurIncludesCamera
        sticker.hidesScreen = hidesScreen
        sticker.hidesCamera = hidesCamera
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
    static let appearancePreferenceKey = "app.appearance"
    static let exportCompletionSoundEnabledKey =
        "cn.laogou.dogsc.export-completion-sound-enabled"
    static let previewResolutionModeKey = "editor.previewResolutionMode"
    static let editorTimelinePrimaryLaneHeightKey =
        "editor.timeline.primary-lane-height"
    private static let editorTimelinePrimaryLaneHeightPrefix =
        "editor.timeline.primary-lane-height.v2"
    static let editorTimelineHoverPreviewEnabledKey =
        "editor.timeline.hover-preview-enabled"
    private static let editorTimelineTrackVisibilityPrefix =
        "editor.timeline.visible-tracks"
    private static let editorTimelineTrackVisibilityStablePrefix =
        "editor.timeline.visible-tracks.v2"
    private static let editorTimelineZoomPrefix =
        "editor.timeline.zoom.v1"
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
    private static let stickerCreationDefaultsKey =
        "editor.sticker.last-used-creation-defaults.v1"
    private static let zoomCreationScaleKey =
        "editor.zoom.last-used-creation-scale.v1"

    static var appearancePreference: AppAppearancePreference {
        AppAppearancePreference(
            rawValue: UserDefaults.standard.string(forKey: appearancePreferenceKey) ?? ""
        ) ?? .system
    }

    @MainActor
    static func applyAppearancePreferenceToOpenWindows() {
        let appearance = appearancePreference.appKitAppearance
        let supportedIdentifiers: Set<String> = [
            "cn.laogou.dogsc.editor-window",
            "cn.laogou.dogsc.settings-window",
            "cn.laogou.dogsc.main-window",
        ]
        for window in NSApplication.shared.windows where
            supportedIdentifiers.contains(window.identifier?.rawValue ?? "") {
            WindowAppearanceTransition.apply(appearance, to: window)
        }
    }

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
        let stableKey = timelineTrackVisibilityKey(for: project)
        if defaults.object(forKey: stableKey) != nil {
            return EditorTimelineTrackVisibility(
                rawValue: defaults.integer(forKey: stableKey)
            )
        }

        // The original key used in-memory millisecond precision, but
        // JSONEncoder's ISO-8601 project date is restored at whole-second
        // precision. A project therefore received one key while recording and
        // a different key after reopening. Migrate any matching legacy value
        // once, then keep using the serialized-stable identity below.
        if let legacyKey = legacyTimelineTrackVisibilityKey(for: project) {
            let visibility = EditorTimelineTrackVisibility(
                rawValue: defaults.integer(forKey: legacyKey)
            )
            defaults.set(visibility.rawValue, forKey: stableKey)
            return visibility
        }
        return .initial(for: project)
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

    static func timelineZoom(for project: RecorderProject) -> Double {
        let defaults = UserDefaults.standard
        let key = "\(editorTimelineZoomPrefix).\(projectPresentationIdentity(for: project))"
        guard defaults.object(forKey: key) != nil else { return 1 }
        let value = defaults.double(forKey: key)
        return EditorTimelineZoomPolicy.clamped(value)
    }

    static func rememberTimelineZoom(_ zoom: Double, for project: RecorderProject) {
        let value = EditorTimelineZoomPolicy.clamped(zoom)
        UserDefaults.standard.set(
            value,
            forKey: "\(editorTimelineZoomPrefix).\(projectPresentationIdentity(for: project))"
        )
    }

    /// Newly drawn zoom clips inherit the last scale the user deliberately
    /// committed on an existing clip. Timing and focus remain unique to the
    /// new range, so reusing a scale never moves an older composition choice
    /// into an unrelated part of the recording.
    static var rememberedZoomCreationScale: Double {
        let defaults = UserDefaults.standard
        guard defaults.object(forKey: zoomCreationScaleKey) != nil else {
            return 1.6
        }
        let stored = defaults.double(forKey: zoomCreationScaleKey)
        guard stored.isFinite else { return 1.6 }
        return min(max(stored, 1), 6)
    }

    static func rememberZoomCreationScale(_ scale: Double) {
        guard scale.isFinite else { return }
        UserDefaults.standard.set(
            min(max(scale, 1), 6),
            forKey: zoomCreationScaleKey
        )
    }

    static func timelinePrimaryLaneHeight(for project: RecorderProject) -> Double {
        let defaults = UserDefaults.standard
        let key = "\(editorTimelinePrimaryLaneHeightPrefix).\(projectPresentationIdentity(for: project))"
        let stored: Double
        if defaults.object(forKey: key) != nil {
            stored = defaults.double(forKey: key)
        } else if defaults.object(forKey: editorTimelinePrimaryLaneHeightKey) != nil {
            // One-time compatibility with the previous global workspace value.
            stored = defaults.double(forKey: editorTimelinePrimaryLaneHeightKey)
        } else {
            stored = Double(EditorTimelineSizing.defaultPrimaryLaneHeight)
        }
        return Double(EditorTimelineSizing.clampedPrimaryLaneHeight(CGFloat(stored)))
    }

    static func rememberTimelinePrimaryLaneHeight(
        _ height: Double,
        for project: RecorderProject
    ) {
        let value = Double(
            EditorTimelineSizing.clampedPrimaryLaneHeight(CGFloat(height))
        )
        UserDefaults.standard.set(
            value,
            forKey: "\(editorTimelinePrimaryLaneHeightPrefix).\(projectPresentationIdentity(for: project))"
        )
    }

    /// `createdAt` survives package renames and keeps editor chrome outside
    /// project.json. Use the precision that actually survives the project's
    /// ISO-8601 round trip; in-memory sub-second precision is not a stable ID.
    static func projectPresentationIdentity(for project: RecorderProject) -> String {
        String(Int64(floor(project.createdAt.timeIntervalSinceReferenceDate)))
    }

    private static func timelineTrackVisibilityKey(for project: RecorderProject) -> String {
        "\(editorTimelineTrackVisibilityStablePrefix).\(projectPresentationIdentity(for: project))"
    }

    private static func legacyTimelineTrackVisibilityKey(
        for project: RecorderProject
    ) -> String? {
        let defaults = UserDefaults.standard
        let createdSecond = Int64(floor(project.createdAt.timeIntervalSinceReferenceDate))
        let candidates = defaults.dictionaryRepresentation().keys.compactMap { key -> (String, Int64)? in
            let prefix = editorTimelineTrackVisibilityPrefix + "."
            guard key.hasPrefix(prefix),
                  let milliseconds = Int64(key.dropFirst(prefix.count)),
                  milliseconds / 1_000 == createdSecond else { return nil }
            return (key, milliseconds)
        }
        return candidates.max { lhs, rhs in lhs.1 < rhs.1 }?.0
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

    static func applyRememberedStickerCreationDefaults(to sticker: inout StickerClip) {
        var defaults = rememberedStickerCreationDefaults
        defaults.normalize()
        defaults.apply(to: &sticker)
    }

    /// Save only after an existing sticker's inheritable fields actually
    /// changed. Merely selecting, moving, resizing or rotating an old sticker
    /// must never replace the user's next-sticker creation preference.
    static func rememberStickerCreationDefaultsIfChanged(
        before: StickerClip,
        after: StickerClip
    ) {
        let previous = RememberedStickerCreationDefaults(sticker: before)
        let updated = RememberedStickerCreationDefaults(sticker: after)
        guard previous != updated,
              let data = try? JSONEncoder().encode(updated) else { return }
        UserDefaults.standard.set(data, forKey: stickerCreationDefaultsKey)
    }

    private static var rememberedStickerCreationDefaults: RememberedStickerCreationDefaults {
        guard let data = UserDefaults.standard.data(forKey: stickerCreationDefaultsKey),
              var decoded = try? JSONDecoder().decode(
                  RememberedStickerCreationDefaults.self,
                  from: data
              ),
              decoded.version == 1 else {
            return .standard
        }
        decoded.normalize()
        return decoded
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
