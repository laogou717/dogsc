import Foundation
import RecorderCore

/// A reusable visual setup, deliberately excluding source-specific edits and
/// timeline content. Applying a style never replaces media, cuts, animations,
/// audio levels, or export settings.
struct EditorStylePreset: Codable, Equatable, Identifiable {
    var id: UUID
    var name: String
    var canvas: CanvasStyle
    var camera: CameraStyle
    var motion: MotionStyle
    var cursor: CursorStyle
    var includesBackground: Bool

    init(id: UUID = UUID(), name: String, project: RecorderProject) {
        self.id = id
        self.name = name

        var canvas = project.canvas
        // Crop belongs to one source recording. Reusing it on another episode
        // can silently cut off content, so presets retain the target crop.
        canvas.crop = .full
        self.canvas = canvas

        var camera = project.camera
        // Visibility is an editing decision, not an appearance preset.
        camera.isHidden = false
        self.camera = camera
        motion = project.motion
        cursor = project.cursorStyle

        // A project-relative image only exists inside the current package.
        // Keep the rest of the look reusable and leave the next project's
        // current background untouched instead of saving a broken reference.
        if case .projectImage = project.canvas.backgroundSource {
            includesBackground = false
        } else {
            includesBackground = true
        }
    }

    func applying(to baseline: RecorderProject) -> RecorderProject {
        var result = baseline

        var appliedCanvas = canvas
        appliedCanvas.crop = baseline.canvas.crop
        if !includesBackground || !backgroundIsAvailable(appliedCanvas.backgroundSource) {
            appliedCanvas.backgroundSource = baseline.canvas.backgroundSource
        }
        result.canvas = appliedCanvas

        var appliedCamera = camera
        appliedCamera.isHidden = baseline.camera.isHidden
        result.camera = appliedCamera
        result.motion = motion
        result.cursorStyle = cursor
        return result
    }

    private func backgroundIsAvailable(_ source: BackgroundSource) -> Bool {
        switch source {
        case let .systemImage(absolutePath):
            return FileManager.default.fileExists(atPath: absolutePath)
        case .projectImage:
            return false
        case .gradient, .solidColor, .bundledImage:
            return true
        }
    }
}

@MainActor
enum EditorStylePresetStore {
    private static let key = "editor-style-presets-v1"
    private static let lastUsedKey = "editor-last-used-style-v1"
    private static var defaults: UserDefaults {
        // The suite is shared by DogSC Dev and the eventual signed release, so
        // a user's local presets survive the transition without sharing TCC.
        UserDefaults(suiteName: "cn.laogou.dogsc") ?? .standard
    }

    static func load() -> [EditorStylePreset] {
        guard let data = defaults.data(forKey: key),
              let presets = try? JSONDecoder().decode([EditorStylePreset].self, from: data)
        else { return [] }
        return presets
    }

    static func save(_ presets: [EditorStylePreset]) {
        guard let data = try? JSONEncoder().encode(presets) else { return }
        defaults.set(data, forKey: key)
    }

    /// Remembers the visual setup from the most recently finished editing
    /// session. A fresh recording can therefore start from the user's actual
    /// working layout without requiring a preset click every episode.
    static func rememberLastUsedStyle(from project: RecorderProject) {
        let snapshot = EditorStylePreset(name: "上次使用", project: project)
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        defaults.set(data, forKey: lastUsedKey)
    }

    static func applyingLastUsedStyle(to project: RecorderProject) -> RecorderProject {
        guard let data = defaults.data(forKey: lastUsedKey),
              let snapshot = try? JSONDecoder().decode(EditorStylePreset.self, from: data)
        else { return project }
        return snapshot.applying(to: project)
    }
}
