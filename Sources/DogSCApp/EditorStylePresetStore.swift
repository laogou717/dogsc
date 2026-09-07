import Foundation
import RecorderCore

/// A reusable scene configuration. Media, cuts, timed animations and recording
/// clock corrections stay with the project; all static presentation defaults
/// travel together, including crop and camera visibility.
struct EditorStylePreset: Codable, Equatable, Identifiable, Sendable {
    var id: UUID
    var name: String
    var canvas: CanvasStyle
    var camera: CameraStyle
    var motion: MotionStyle
    var cursor: CursorStyle
    var includesBackground: Bool
    // Optional additions distinguish old, deliberately partial presets from
    // complete snapshots. Missing fields must not overwrite the target.
    var formatVersion: Int?
    var sourceDimensions: CanvasDimensions?
    var audio: AudioStyle?
    var opening: OpeningSequence?
    var backgroundAsset: ScenePresetBackgroundAsset?

    var includesCrop: Bool { (formatVersion ?? 1) >= 2 }

    init(
        id: UUID = UUID(),
        name: String,
        project: RecorderProject,
        sourceDimensions: CanvasDimensions? = nil,
        zoomCreationScale: Double? = nil
    ) {
        self.id = id
        self.name = name
        canvas = project.canvas
        camera = project.camera
        motion = project.motion
        motion.defaultZoomScale = project.motion.defaultZoomScale ?? zoomCreationScale
        cursor = project.cursorStyle
        audio = project.audio
        opening = project.openingSequence
        formatVersion = 2
        self.sourceDimensions = sourceDimensions
        switch canvas.backgroundSource {
        case .projectImage, .projectVideo: includesBackground = false
        default: includesBackground = true
        }
    }

    /// `backgroundOverride` is a project-owned copy made before committing the
    /// command. Callers surface unavailable resources; no broken path is applied.
    func applying(
        to baseline: RecorderProject,
        backgroundOverride: BackgroundSource? = nil
    ) -> RecorderProject {
        var result = baseline
        var appliedCanvas = canvas
        if !includesCrop { appliedCanvas.crop = baseline.canvas.crop }
        if let backgroundOverride {
            appliedCanvas.backgroundSource = backgroundOverride
        } else if !includesBackground || backgroundAsset != nil
                    || !backgroundIsAvailable(appliedCanvas.backgroundSource) {
            appliedCanvas.backgroundSource = baseline.canvas.backgroundSource
        }
        result.canvas = appliedCanvas
        result.camera = camera
        if !includesCrop { result.camera.isHidden = baseline.camera.isHidden }
        result.motion = motion
        if motion.defaultZoomScale == nil {
            result.motion.defaultZoomScale = baseline.motion.defaultZoomScale
        }
        result.cursorStyle = cursor
        if let audio { result.audio = audio }
        if let opening { result.openingSequence = opening }
        return result
    }

    func matchesConfiguration(of project: RecorderProject, zoomCreationScale: Double? = nil) -> Bool {
        let current = EditorStylePreset(name: name, project: project, zoomCreationScale: zoomCreationScale)
        return canvas == current.canvas && camera == current.camera
            && motion == current.motion && cursor == current.cursor
            && audio == current.audio && opening == current.opening
    }

    var hasAvailableBackground: Bool {
        if let backgroundAsset { return backgroundAsset.isAvailable }
        return includesBackground && backgroundIsAvailable(canvas.backgroundSource)
    }

    private func backgroundIsAvailable(_ source: BackgroundSource) -> Bool {
        switch source {
        case let .systemImage(path), let .systemVideo(path):
            return FileManager.default.fileExists(atPath: path)
        case .projectImage, .projectVideo: return false
        case .pattern, .dynamicFlow: return true
        }
    }
}

@MainActor
enum EditorStylePresetStore {
    // Keep the existing key so the user's presets survive the coverage upgrade.
    private static let key = "editor-style-presets-v1"
    private static let lastUsedKey = "editor-last-used-style-v1"
    private static let defaultIDKey = "editor-scene-preset.default-id"
    private static var defaults: UserDefaults {
        UserDefaults(suiteName: "cn.laogou.dogsc") ?? .standard
    }

    static func load() -> [EditorStylePreset] {
        guard let data = defaults.data(forKey: key),
              let presets = try? JSONDecoder().decode([EditorStylePreset].self, from: data)
        else { return [] }
        return presets
    }

    static func save(_ presets: [EditorStylePreset]) throws {
        defaults.set(try JSONEncoder().encode(presets), forKey: key)
    }

    static var defaultPresetID: UUID? {
        get { defaults.string(forKey: defaultIDKey).flatMap(UUID.init(uuidString:)) }
        set { defaults.set(newValue?.uuidString, forKey: defaultIDKey) }
    }

    /// Implicit "last used" inheritance remains source-safe. Crop travels only
    /// through an explicitly chosen scene preset, including an explicit default.
    static func rememberLastUsedStyle(from project: RecorderProject) {
        var snapshot = EditorStylePreset(name: "上次使用", project: project)
        snapshot.formatVersion = 1
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        defaults.set(data, forKey: lastUsedKey)
    }

    static func applyingLastUsedStyle(to project: RecorderProject) -> RecorderProject {
        if let selected = load().first(where: { $0.id == defaultPresetID }) {
            return selected.applying(
                to: project,
                backgroundOverride: selected.backgroundAsset?.availableSource
            )
        }
        guard let data = defaults.data(forKey: lastUsedKey),
              let snapshot = try? JSONDecoder().decode(EditorStylePreset.self, from: data)
        else { return project }
        return snapshot.applying(to: project)
    }
}
