import AppKit
import Combine
import Foundation
import RecorderCore

// MARK: - Editor session state

/// Identifies one open editor session independently from the project on disk.
struct EditorSessionID: RawRepresentable, Hashable, Codable, Sendable {
    let rawValue: UUID

    init(rawValue: UUID = UUID()) {
        self.rawValue = rawValue
    }
}

enum EditorAudioTrack: String, CaseIterable, Codable, Hashable, Sendable {
    case system
    case microphone
}

/// The single source of truth for what the inspector and canvas are editing.
enum EditorSelection: Equatable, Hashable, Sendable {
    case canvas
    case screen
    case primarySegment(UUID)
    case crop
    case zoomTrack
    case zoom(UUID)
    case screenMotionTrack
    case screenMotion(UUID)
    case cursor
    case camera
    case cameraMotion(UUID)
    case audio(EditorAudioTrack)
    case mosaic(UUID)
    case sticker(UUID)
    case animation(UUID)
    case audioClip(UUID)
    case subtitle(UUID)
    case videoClip(UUID)
}

enum EditorTool: String, CaseIterable, Codable, Sendable {
    case select
    case crop
    case moveScreen
    case scaleScreen
    case editZoom
    case editScreenMotion
    case moveCamera
    case resizeCamera
    case editCameraMotion
}

/// Selects the persisted command domain for one interaction without changing
/// the user's precise UI selection. Most gestures commit through `.selection`;
/// Inspector controls use an explicit domain when the visible tab and edited
/// value differ (for example global motion settings inside the Zoom tab).
enum EditorInteractionCommandScope: Equatable, Hashable, Sendable {
    case selection
    case project
    case canvas
    case camera
    case audio
    case cursor
    case motion

    var fallbackSelection: EditorSelection {
        switch self {
        case .selection, .project, .canvas: return .canvas
        case .camera: return .camera
        case .audio: return .audio(.system)
        case .cursor: return .cursor
        case .motion: return .zoomTrack
        }
    }
}

/// Determines what happens when another selection or gesture replaces an
/// unfinished interaction. Direct-manipulation gestures remain cancellable;
/// controls such as the color picker can explicitly preserve their last live
/// preview as one undoable command.
enum EditorInteractionReplacementPolicy: Equatable, Sendable {
    case cancel
    case commit(actionName: String)
}

/// Exact domain edited by direct manipulation on the preview canvas.
///
/// Inspector tabs are presentation routing only: both `.screen` and
/// `.screenMotion` appear in the Screen tab, but they must never write to the
/// same model field. Keeping this typed scope beside `EditorSelection` makes
/// that distinction survive all the way from hit testing to the command
/// reducer.
enum EditorCanvasEditScope: Equatable, Hashable, Sendable {
    enum Screen: Equatable, Hashable, Sendable {
        case base
        case motion(UUID)
    }

    enum Camera: Equatable, Hashable, Sendable {
        case base
        case motion(UUID)
    }

    case screen(Screen)
    case camera(Camera)
    case unavailable

    init(selection: EditorSelection?) {
        switch selection {
        case .screen:
            self = .screen(.base)
        case let .screenMotion(id):
            self = .screen(.motion(id))
        case .camera:
            self = .camera(.base)
        case let .cameraMotion(id):
            self = .camera(.motion(id))
        default:
            self = .unavailable
        }
    }

    var isCameraMotion: Bool {
        if case .camera(.motion) = self { return true }
        return false
    }

    var selection: EditorSelection? {
        switch self {
        case .screen(.base): return .screen
        case let .screen(.motion(id)): return .screenMotion(id)
        case .camera(.base): return .camera
        case let .camera(.motion(id)): return .cameraMotion(id)
        case .unavailable: return nil
        }
    }

    func tool(for operation: EditorCanvasInteractionOperation) -> EditorTool? {
        switch (self, operation) {
        case (.screen(.base), .move): return .moveScreen
        case (.screen(.base), .resize): return .scaleScreen
        case (.screen(.motion), _): return .editScreenMotion
        case (.camera(.base), .move): return .moveCamera
        case (.camera(.base), .resize): return .resizeCamera
        case (.camera(.motion), _): return .editCameraMotion
        case (.unavailable, _): return nil
        }
    }

    func position(in project: RecorderProject) -> NormalizedPoint? {
        switch self {
        case .screen(.base):
            return project.canvas.contentPosition
        case let .screen(.motion(id)):
            return project.timeline.screenMotionClips.first { $0.id == id }?.target.position
        case .camera(.base):
            return project.camera.position
        case let .camera(.motion(id)):
            return project.timeline.cameraMotionClips.first { $0.id == id }?.target.position
        case .unavailable:
            return nil
        }
    }

    func scale(in project: RecorderProject) -> Double? {
        switch self {
        case .screen(.base):
            return project.canvas.contentScale
        case let .screen(.motion(id)):
            return project.timeline.screenMotionClips.first { $0.id == id }?.target.scale
        case .camera(.base):
            return project.camera.size
        case let .camera(.motion(id)):
            return project.timeline.cameraMotionClips.first { $0.id == id }?.target.size
        case .unavailable:
            return nil
        }
    }

    @discardableResult
    func setPosition(_ position: NormalizedPoint, in project: inout RecorderProject) -> Bool {
        switch self {
        case .screen(.base):
            project.canvas.contentPosition = position
        case let .screen(.motion(id)):
            guard let index = project.timeline.screenMotionClips.firstIndex(where: { $0.id == id })
            else { return false }
            project.timeline.screenMotionClips[index].target.position = position
        case .camera(.base):
            project.camera.position = position
        case let .camera(.motion(id)):
            guard let index = project.timeline.cameraMotionClips.firstIndex(where: { $0.id == id })
            else { return false }
            project.timeline.cameraMotionClips[index].target.position = position
        case .unavailable:
            return false
        }
        return true
    }

    @discardableResult
    func setScale(_ scale: Double, in project: inout RecorderProject) -> Bool {
        switch self {
        case .screen(.base):
            project.canvas.contentScale = scale
        case let .screen(.motion(id)):
            guard let index = project.timeline.screenMotionClips.firstIndex(where: { $0.id == id })
            else { return false }
            project.timeline.screenMotionClips[index].target.scale = scale
        case .camera(.base):
            project.camera.size = scale
        case let .camera(.motion(id)):
            guard let index = project.timeline.cameraMotionClips.firstIndex(where: { $0.id == id })
            else { return false }
            project.timeline.cameraMotionClips[index].target.size = scale
        case .unavailable:
            return false
        }
        return true
    }
}

enum EditorCanvasInteractionOperation: Equatable, Hashable, Sendable {
    case move
    case resize
}

/// Gesture edits live here until mouse-up. The persisted project is only
/// changed once, when the draft is committed as an atomic command.
struct EditorInteractionDraft: Equatable, Sendable {
    let id: UUID
    let tool: EditorTool
    let selection: EditorSelection
    let commandScope: EditorInteractionCommandScope
    var replacementPolicy: EditorInteractionReplacementPolicy
    let baselineProject: RecorderProject
    var previewProject: RecorderProject
    var sceneSegmentID: UUID?

    init(
        id: UUID = UUID(),
        tool: EditorTool,
        selection: EditorSelection,
        commandScope: EditorInteractionCommandScope = .selection,
        replacementPolicy: EditorInteractionReplacementPolicy = .cancel,
        project: RecorderProject
    ) {
        self.id = id
        self.tool = tool
        self.selection = selection
        self.commandScope = commandScope
        self.replacementPolicy = replacementPolicy
        self.baselineProject = project
        self.previewProject = project
    }
}

// MARK: - Reversible project commands

enum ProjectCommand: Equatable, Sendable {
    case replaceCanvas(before: CanvasStyle, after: CanvasStyle)
    case replaceCamera(before: CameraStyle, after: CameraStyle)
    case replaceAudio(before: AudioStyle, after: AudioStyle)
    case replaceCursor(before: CursorStyle, after: CursorStyle)
    case replaceMotion(before: MotionStyle, after: MotionStyle)
    case replaceOpening(before: OpeningSequence, after: OpeningSequence)
    case replaceExportSettings(before: ExportSettings, after: ExportSettings)
    case replaceTimeline(before: ProjectTimeline, after: ProjectTimeline)
    case replaceProject(before: RecorderProject, after: RecorderProject)
    case insertZoom(ZoomAnimationClip)
    case removeZoom(ZoomAnimationClip)
    case replaceZoom(before: ZoomAnimationClip, after: ZoomAnimationClip)
    indirect case batch([ProjectCommand])

    var inverse: ProjectCommand {
        switch self {
        case let .replaceCanvas(before, after):
            return .replaceCanvas(before: after, after: before)
        case let .replaceCamera(before, after):
            return .replaceCamera(before: after, after: before)
        case let .replaceAudio(before, after):
            return .replaceAudio(before: after, after: before)
        case let .replaceCursor(before, after):
            return .replaceCursor(before: after, after: before)
        case let .replaceMotion(before, after):
            return .replaceMotion(before: after, after: before)
        case let .replaceOpening(before, after):
            return .replaceOpening(before: after, after: before)
        case let .replaceExportSettings(before, after):
            return .replaceExportSettings(before: after, after: before)
        case let .replaceTimeline(before, after):
            return .replaceTimeline(before: after, after: before)
        case let .replaceProject(before, after):
            return .replaceProject(before: after, after: before)
        case let .insertZoom(clip):
            return .removeZoom(clip)
        case let .removeZoom(clip):
            return .insertZoom(clip)
        case let .replaceZoom(before, after):
            return .replaceZoom(before: after, after: before)
        case let .batch(commands):
            return .batch(commands.reversed().map(\.inverse))
        }
    }

    var defaultActionName: String {
        switch self {
        case .replaceCanvas:
            return "调整画布"
        case .replaceCamera:
            return "调整摄像头"
        case .replaceAudio:
            return "调整音频"
        case .replaceCursor:
            return "调整光标"
        case .replaceMotion:
            return "调整动画手感"
        case .replaceOpening:
            return "调整开场"
        case .replaceExportSettings:
            return "调整导出设置"
        case .replaceTimeline:
            return "调整时间线"
        case .replaceProject:
            return "调整项目"
        case .insertZoom:
            return "添加缩放"
        case .removeZoom:
            return "删除缩放"
        case .replaceZoom:
            return "调整缩放"
        case .batch:
            return "批量调整"
        }
    }

    static func replacingCanvas(in project: RecorderProject, with style: CanvasStyle) -> ProjectCommand? {
        guard project.canvas != style else { return nil }
        return .replaceCanvas(before: project.canvas, after: style)
    }

    static func replacingCamera(in project: RecorderProject, with style: CameraStyle) -> ProjectCommand? {
        guard project.camera != style else { return nil }
        return .replaceCamera(before: project.camera, after: style)
    }

    static func replacingAudio(in project: RecorderProject, with style: AudioStyle) -> ProjectCommand? {
        guard project.audio != style else { return nil }
        return .replaceAudio(before: project.audio, after: style)
    }

    static func replacingCursor(in project: RecorderProject, with style: CursorStyle) -> ProjectCommand? {
        guard project.cursorStyle != style else { return nil }
        return .replaceCursor(before: project.cursorStyle, after: style)
    }

    static func replacingMotion(in project: RecorderProject, with style: MotionStyle) -> ProjectCommand? {
        guard project.motion != style else { return nil }
        return .replaceMotion(before: project.motion, after: style)
    }

    static func replacingExportSettings(
        in project: RecorderProject,
        with settings: ExportSettings
    ) -> ProjectCommand? {
        guard project.exportSettings != settings else { return nil }
        return .replaceExportSettings(before: project.exportSettings, after: settings)
    }

    static func replacingTimeline(
        in project: RecorderProject,
        with timeline: ProjectTimeline
    ) -> ProjectCommand? {
        guard project.timeline != timeline else { return nil }
        return .replaceTimeline(before: project.timeline, after: timeline)
    }

    static func replacingProject(
        _ project: RecorderProject,
        with replacement: RecorderProject
    ) -> ProjectCommand? {
        guard project != replacement else { return nil }
        return .replaceProject(before: project, after: replacement)
    }

    /// Builds one atomic command from independently optional domain changes.
    /// Callers can therefore prepare every affected domain from the same
    /// baseline without manufacturing no-op commands. A single real change is
    /// returned directly; multiple changes preserve their authored order.
    static func batching(_ optionalCommands: [ProjectCommand?]) -> ProjectCommand? {
        let commands = optionalCommands.compactMap { $0 }.flatMap(flattenedCommands)
        switch commands.count {
        case 0:
            return nil
        case 1:
            return commands[0]
        default:
            return .batch(commands)
        }
    }

    private static func flattenedCommands(_ command: ProjectCommand) -> [ProjectCommand] {
        guard case let .batch(commands) = command else { return [command] }
        return commands.flatMap(flattenedCommands)
    }

    static func insertingZoom(_ clip: ZoomAnimationClip, in project: RecorderProject) throws -> ProjectCommand {
        guard !project.zoomAnimations.contains(where: { $0.id == clip.id }) else {
            throw ProjectCommandError.duplicateZoomID(clip.id)
        }
        return .insertZoom(clip)
    }

    static func removingZoom(id: UUID, from project: RecorderProject) throws -> ProjectCommand {
        let ordered = project.zoomAnimations.sorted {
            $0.startTime == $1.startTime
                ? $0.id.uuidString < $1.id.uuidString
                : $0.startTime < $1.startTime
        }
        guard let removedIndex = ordered.firstIndex(where: { $0.id == id }) else {
            throw ProjectCommandError.missingZoom(id)
        }
        let predecessorID = removedIndex > 0 ? ordered[removedIndex - 1].id : nil
        var timeline = project.timeline
        timeline.zoomClips.removeAll { $0.id == id }
        // 删除让前一段成为"结尾"：它没有显式退出时长时补上默认过渡（受剩余
        // 间隙限制），保持结尾自动回落的平滑语义；仍与后一段相接的片段不动。
        if let predecessorID,
           let index = timeline.zoomClips.firstIndex(where: { $0.id == predecessorID }),
           timeline.zoomClips[index].exitDuration <= 0.000_1 {
            let available = timeline.zoomClips.indices.contains(index + 1)
                ? timeline.zoomClips[index + 1].startTime - timeline.zoomClips[index].endTime
                : project.motion.defaultZoomTransitionDuration
            if available > ZoomInterpolator.adjacencyTolerance {
                timeline.zoomClips[index].exitDuration = min(
                    max(project.motion.defaultZoomTransitionDuration, 0),
                    max(available, 0)
                )
            }
        }
        // 整条时间线作为一个命令提交，撤销才能精确还原删除与回落修复。
        return replacingTimeline(in: project, with: timeline)
            ?? .removeZoom(ordered[removedIndex])
    }

    static func replacingZoom(
        id: UUID,
        in project: RecorderProject,
        with clip: ZoomAnimationClip
    ) throws -> ProjectCommand? {
        guard id == clip.id else {
            throw ProjectCommandError.mismatchedZoomID(expected: id, actual: clip.id)
        }
        guard let existing = project.zoomAnimations.first(where: { $0.id == id }) else {
            throw ProjectCommandError.missingZoom(id)
        }
        guard existing != clip else { return nil }
        return .replaceZoom(before: existing, after: clip)
    }

    /// Converts a transient gesture into one domain-specific command. Changes
    /// outside the selected domain are intentionally ignored.
    static func committing(_ draft: EditorInteractionDraft) throws -> ProjectCommand? {
        let before = draft.baselineProject
        let after = draft.previewProject
        if draft.sceneSegmentID != nil { return replacingProject(before, with: after) }

        switch draft.commandScope {
        case .project:
            return replacingProject(before, with: after)
        case .canvas:
            return replacingCanvas(in: before, with: after.canvas)
        case .camera:
            return replacingCamera(in: before, with: after.camera)
        case .audio:
            return replacingAudio(in: before, with: after.audio)
        case .cursor:
            return replacingCursor(in: before, with: after.cursorStyle)
        case .motion:
            return replacingMotion(in: before, with: after.motion)
        case .selection:
            break
        }

        switch draft.selection {
        case .canvas, .screen, .crop:
            return replacingCanvas(in: before, with: after.canvas)
        case .camera:
            return replacingCamera(in: before, with: after.camera)
        case .audio:
            return replacingAudio(in: before, with: after.audio)
        case .cursor:
            return replacingCursor(in: before, with: after.cursorStyle)
        case .zoomTrack, .screenMotionTrack:
            return nil
        case .primarySegment, .mosaic, .sticker, .animation, .audioClip, .subtitle, .videoClip:
            return replacingTimeline(in: before, with: after.timeline)
        case .zoom:
            // 缩放手势可能同时改动相邻片段（相接修复/回落时长归一），按整段
            // 数组比对并作为一次时间线替换提交，撤销才能精确还原全部改动。
            guard before.zoomAnimations != after.zoomAnimations else { return nil }
            var timeline = before.timeline
            timeline.zoomClips = after.zoomAnimations
            return replacingTimeline(in: before, with: timeline)
        case let .screenMotion(id):
            guard let edited = after.timeline.screenMotionClips.first(where: { $0.id == id }) else {
                throw ProjectCommandError.invalidTimeline(reason: "屏幕 3D 草稿不完整。")
            }
            let isolatedTimeline = try ProjectTimelineEditing.replacingScreenMotion(
                id: id,
                in: before.timeline,
                with: edited
            )
            return replacingTimeline(in: before, with: isolatedTimeline)
        case let .cameraMotion(id):
            guard let edited = after.timeline.cameraMotionClips.first(where: { $0.id == id }) else {
                throw ProjectCommandError.invalidTimeline(reason: "摄像运动草稿不完整。")
            }
            let isolatedTimeline = try ProjectTimelineEditing.replacingCameraMotion(
                id: id,
                in: before.timeline,
                with: edited
            )
            return replacingTimeline(in: before, with: isolatedTimeline)
        }
    }
}

enum ProjectCommandError: Error, Equatable, LocalizedError, Sendable {
    case staleState(domain: String)
    case duplicateZoomID(UUID)
    case missingZoom(UUID)
    case mismatchedZoomID(expected: UUID, actual: UUID)
    case invalidZoom(UUID, reason: String)
    case overlappingZoom(UUID, UUID)
    case invalidTimeline(reason: String)
    case invalidProjectDomain(String, reason: String)

    var errorDescription: String? {
        switch self {
        case let .staleState(domain):
            return String(format: appLocalized("无法应用命令：%@ 已被其他编辑修改。"), appLocalized(domain))
        case .duplicateZoomID:
            return appLocalized("无法添加缩放：轨道中已存在相同片段。")
        case .missingZoom:
            return appLocalized("无法修改缩放：片段已不存在，请重新选择后再试。")
        case .mismatchedZoomID:
            return appLocalized("无法替换缩放：片段已发生变化，请重新选择后再试。")
        case let .invalidZoom(_, reason):
            return String(format: appLocalized("缩放片段无效：%@"), appLocalized(reason))
        case .overlappingZoom:
            return appLocalized("缩放片段的生效区间发生重叠。")
        case let .invalidTimeline(reason):
            return String(format: appLocalized("时间线无效：%@"), appLocalized(reason))
        case let .invalidProjectDomain(domain, reason):
            return String(format: appLocalized("%@参数无效：%@"), appLocalized(domain), appLocalized(reason))
        }
    }
}

enum ProjectReducer {
    static func apply(_ command: ProjectCommand, to project: inout RecorderProject) throws {
        switch command {
        case let .replaceCanvas(before, after):
            guard project.canvas == before else {
                throw ProjectCommandError.staleState(domain: "画布")
            }
            try validateDomain { try ProjectValidator.validate(after) }
            project.canvas = after

        case let .replaceCamera(before, after):
            guard project.camera == before else {
                throw ProjectCommandError.staleState(domain: "摄像头")
            }
            try validateDomain { try ProjectValidator.validate(after) }
            project.camera = after

        case let .replaceAudio(before, after):
            guard project.audio == before else {
                throw ProjectCommandError.staleState(domain: "音频")
            }
            try validateDomain { try ProjectValidator.validate(after) }
            project.audio = after

        case let .replaceCursor(before, after):
            guard project.cursorStyle == before else {
                throw ProjectCommandError.staleState(domain: "光标")
            }
            try validateDomain { try ProjectValidator.validate(after) }
            project.cursorStyle = after

        case let .replaceMotion(before, after):
            guard project.motion == before else {
                throw ProjectCommandError.staleState(domain: "动画手感")
            }
            try validateDomain { try ProjectValidator.validate(after) }
            project.motion = after

        case let .replaceOpening(before, after):
            guard project.openingSequence == before else {
                throw ProjectCommandError.staleState(domain: "开场")
            }
            var candidate = project
            candidate.openingSequence = after
            try validateDomain { try ProjectValidator.validate(candidate) }
            project.openingSequence = after

        case let .replaceExportSettings(before, after):
            guard project.exportSettings == before else {
                throw ProjectCommandError.staleState(domain: "导出设置")
            }
            project.exportSettings = after

        case let .replaceTimeline(before, after):
            guard project.timeline == before else {
                throw ProjectCommandError.staleState(domain: "时间线")
            }
            try validateDomain { try ProjectValidator.validate(after) }
            project.timeline = after

        case let .replaceProject(before, after):
            guard project == before else {
                throw ProjectCommandError.staleState(domain: "项目")
            }
            try validateDomain { try ProjectValidator.validate(after) }
            project = after

        case let .insertZoom(clip):
            try validateDomain { try ProjectValidator.validate(clip) }
            guard !project.zoomAnimations.contains(where: { $0.id == clip.id }) else {
                throw ProjectCommandError.duplicateZoomID(clip.id)
            }
            var candidateTimeline = project.timeline
            candidateTimeline.zoomClips.append(clip)
            try validateDomain { try ProjectValidator.validate(candidateTimeline) }
            project.zoomAnimations.append(clip)
            sortZooms(in: &project)

        case let .removeZoom(clip):
            guard let index = project.zoomAnimations.firstIndex(where: { $0.id == clip.id }) else {
                throw ProjectCommandError.missingZoom(clip.id)
            }
            guard project.zoomAnimations[index] == clip else {
                throw ProjectCommandError.staleState(domain: "缩放片段")
            }
            var candidateTimeline = project.timeline
            candidateTimeline.zoomClips.remove(at: index)
            try validateDomain { try ProjectValidator.validate(candidateTimeline) }
            project.timeline = candidateTimeline

        case let .replaceZoom(before, after):
            guard before.id == after.id else {
                throw ProjectCommandError.mismatchedZoomID(expected: before.id, actual: after.id)
            }
            try validateDomain { try ProjectValidator.validate(after) }
            guard let index = project.zoomAnimations.firstIndex(where: { $0.id == before.id }) else {
                throw ProjectCommandError.missingZoom(before.id)
            }
            guard project.zoomAnimations[index] == before else {
                throw ProjectCommandError.staleState(domain: "缩放片段")
            }
            var candidateTimeline = project.timeline
            candidateTimeline.zoomClips[index] = after
            try validateDomain { try ProjectValidator.validate(candidateTimeline) }
            project.zoomAnimations[index] = after
            sortZooms(in: &project)

        case let .batch(commands):
            var candidate = project
            for command in commands {
                try apply(command, to: &candidate)
            }
            try validateDomain { try ProjectValidator.validate(candidate) }
            project = candidate
        }
    }

    private static func sortZooms(in project: inout RecorderProject) {
        project.zoomAnimations.sort { lhs, rhs in
            if lhs.startTime != rhs.startTime {
                return lhs.startTime < rhs.startTime
            }
            return lhs.id.uuidString < rhs.id.uuidString
        }
    }

    private static func validateDomain(_ operation: () throws -> Void) throws {
        do {
            try operation()
        } catch let error as ProjectValidationError {
            throw commandError(for: error)
        }
    }

    private static func commandError(
        for error: ProjectValidationError
    ) -> ProjectCommandError {
        switch error {
        case let .invalidCanvas(reason):
            return .invalidProjectDomain("画布", reason: reason)
        case let .invalidCamera(reason):
            return .invalidProjectDomain("摄像头", reason: reason)
        case let .invalidAudio(reason):
            return .invalidProjectDomain("音频", reason: reason)
        case let .invalidCursor(reason):
            return .invalidProjectDomain("光标", reason: reason)
        case let .invalidMotion(reason):
            return .invalidProjectDomain("动画", reason: reason)
        case let .invalidOpening(reason):
            return .invalidProjectDomain("开场编排", reason: reason)
        case let .invalidZoom(id, reason):
            return .invalidZoom(id, reason: reason)
        case let .duplicateZoomID(id):
            return .duplicateZoomID(id)
        case let .overlappingZoom(id, otherID):
            return .overlappingZoom(id, otherID)
        case let .invalidTimeline(reason):
            return .invalidTimeline(reason: reason)
        }
    }

}

// MARK: - Editor store

@MainActor
final class EditorStore: ObservableObject {
    /// EDT-054: places a bin asset at the playhead; installed by EditorView,
    /// which owns playback time, media duration and project file import.
    @Published var revealedRecordingID: UUID?
    /// Library keyboard commands must not delete/copy the last timeline selection.
    var mediaLibraryHasKeyboardFocus = false
    var isRemovingProjectMedia = false
    var recordingDurations: () -> [UUID: TimeInterval] = { [:] }
    /// Inserts a recording into the main track: at an output time (nil = the
    /// playhead) and, when the monitor marked one, only the span marked.
    var insertRecordingSourceHook: (UUID, TimeInterval?, ClosedRange<TimeInterval>?) -> Void = { _, _, _ in }
    var cropRecording: (UUID) -> Void = { _ in }
    var revealRecording: (UUID) -> Void = { _ in }
    var recordingImportGeneration: UInt64 = 0
    var requestRecordingImports: ([URL], TimeInterval?) -> Void = { _, _ in }
    /// Places a bin file as `EditorMediaPlacement` describes; installed by
    /// EditorView, which owns playback time, media duration and file import.
    var placeMedia: (EditorMediaPlacement) -> Void = { _ in }
    /// Current playhead and program length, installed by EditorView.
    var playheadTime: () -> TimeInterval = { 0 }
    /// Moves the playhead (set by the editor; used by lists that jump to an item).
    var seekPlayhead: (TimeInterval) -> Void = { _ in }
    /// Shows an error banner (installed by EditorView).
    var reportError: ((String) -> Void)?
    var outputDuration: () -> TimeInterval = { 0 }

    func insertRecording(_ id: UUID, at time: TimeInterval? = nil,
                         sourceRange: ClosedRange<TimeInterval>? = nil) {
        insertRecordingSourceHook(id, time, sourceRange)
    }

    func placeMediaAsset(_ asset: MediaAsset, at time: TimeInterval? = nil,
                         lane: EditorDropLane = .newLayer,
                         sourceRange: ClosedRange<TimeInterval>? = nil) {
        placeMedia(EditorMediaPlacement(asset: asset, time: time, lane: lane, sourceRange: sourceRange))
    }

    func placeMediaAssetAt(_ id: UUID, _ time: TimeInterval, lane: EditorDropLane = .newLayer,
                           sourceRange: ClosedRange<TimeInterval>? = nil) {
        guard let asset = project.timeline.mediaAssets.first(where: { $0.id == id }) else { return }
        placeMediaAsset(asset, at: time, lane: lane, sourceRange: sourceRange)
    }

    /// Puts a picture/motion/video clip on a stacking layer, or an audio clip
    /// on an audio row, as the drop target says (inside the current edit).
    func assign(_ selection: EditorSelection?, to lane: EditorDropLane, in timeline: inout ProjectTimeline) {
        let lowest = (timeline.stickerClips.map(\.layerIndex) + timeline.animationClips.map(\.layerIndex)
            + timeline.videoClips.map(\.layerIndex)).min() ?? 0
        let layer: Int? = switch lane {
        case let .layer(n): n
        case .newLayer: nil
        case .newLayerBelow: lowest - 1
        default: nil
        }
        switch selection {
        case let .sticker(id):
            if let layer, let i = timeline.stickerClips.firstIndex(where: { $0.id == id }) { timeline.stickerClips[i].layerIndex = layer }
        case let .animation(id):
            if let layer, let i = timeline.animationClips.firstIndex(where: { $0.id == id }) { timeline.animationClips[i].layerIndex = layer }
        case let .videoClip(id):
            if let layer, let i = timeline.videoClips.firstIndex(where: { $0.id == id }) { timeline.videoClips[i].layerIndex = layer }
        case let .audioClip(id):
            guard let i = timeline.audioClips.firstIndex(where: { $0.id == id }) else { return }
            switch lane {
            case let .audio(n): timeline.audioClips[i].lane = n
            case .newAudio: timeline.audioClips[i].lane = (timeline.audioClips.map(\.lane).max() ?? 0) + 1
            default: break
            }
        default:
            break
        }
    }
    let sessionID: EditorSessionID

    private let document: ProjectDocument
    var project: RecorderProject { document.project }
    /// EDT-079: clips picked together on the timeline (marquee or ⇧/⌘
    /// click). The inspector shows their shared properties when two or
    /// more are picked.
    @Published var scenePresetPreviewSegmentIDs: Set<UUID>?
    @Published var sceneEditingSegmentID: UUID?
    /// The clip appearance edits are routed *through* while an appearance page
    /// is open and something else is selected (the canvas, the camera bubble).
    /// The timeline marks it so the edit always has a visible target; it is
    /// deliberately not `selection`, which stays what the user picked.
    @Published var sceneEditingMarkerSegmentID: UUID?
    @Published var groupSelection: Set<EditorSelection> = []

    @Published var selection: EditorSelection? {
        willSet {
            guard newValue != selection, interaction != nil else { return }
            resolveInteractionBeforeReplacement()
        }
    }
    @Published private(set) var interaction: EditorInteractionDraft? {
        didSet {
            if interaction?.id != oldValue?.id { timelinePreview.clear() }
            previewRevision &+= 1
        }
    }
    let timelinePreview = EditorTimelineInteractionState()
    /// Bumps whenever `previewProject` may have changed: a draft update or a
    /// committed document change. Lets derived caches skip deep comparisons.
    private(set) var previewRevision: UInt64 = 0

    private(set) var revision: UInt64
    private weak var undoManager: UndoManager?
    private let projectSink: ((RecorderProject) -> Void)?
    private var documentSubscriptions = Set<AnyCancellable>()

    init(
        sessionID: EditorSessionID = EditorSessionID(),
        document: ProjectDocument,
        selection: EditorSelection? = nil,
        undoManager: UndoManager? = nil,
        projectSink: ((RecorderProject) -> Void)? = nil
    ) {
        self.sessionID = sessionID
        self.document = document
        self.selection = selection
        self.interaction = nil
        self.revision = 0
        self.undoManager = undoManager
        self.projectSink = projectSink

        document.objectWillChange
            .sink { [weak self] in
                self?.previewRevision &+= 1
                self?.objectWillChange.send()
            }
            .store(in: &documentSubscriptions)
        document.$project
            .dropFirst()
            .sink { [weak self] _ in
                guard let self, self.interaction != nil else { return }
                self.endInteraction()
            }
            .store(in: &documentSubscriptions)
    }


    /// Render this value while a gesture is active; serialize `project` only.
    var previewProject: RecorderProject {
        timelinePreview.project(for: interaction?.id) ?? interactionBaseProject
    }

    var interactionBaseProject: RecorderProject { interaction?.previewProject ?? project }

    var sceneEditingProject: RecorderProject { project.sceneProject(forSegmentID: sceneEditingSegmentID) }
    var sceneEditingPreviewProject: RecorderProject { previewProject.sceneProject(forSegmentID: sceneEditingSegmentID) }

    func attachUndoManager(_ manager: UndoManager?) {
        guard undoManager !== manager else { return }
        detachUndoManager()
        undoManager = manager
    }

    /// The application keeps one window-level UndoManager while editor stores
    /// are session-scoped. Remove this store's actions before SwiftUI releases
    /// it so UndoManager can never dispatch to a target from an older project.
    func detachUndoManager() {
        undoManager?.removeAllActions(withTarget: self)
        undoManager = nil
    }

    func beginInteraction(
        tool: EditorTool,
        selection: EditorSelection,
        commandScope: EditorInteractionCommandScope = .selection,
        replacementPolicy: EditorInteractionReplacementPolicy = .cancel
    ) {
        // Beginning a second gesture is an explicit replacement, even when it
        // targets the same selection. A stale preview must never become the
        // baseline of a newer gesture.
        resolveInteractionBeforeReplacement()
        self.selection = selection
        interaction = EditorInteractionDraft(
            tool: tool,
            selection: selection,
            commandScope: commandScope,
            replacementPolicy: replacementPolicy,
            project: project
        )
        let editsScene: Bool = switch commandScope {
        case .canvas, .camera, .cursor, .motion: true
        case .selection: selection == .screen || selection == .camera || selection == .cursor || selection == .canvas
        default: false
        }
        if editsScene, let id = sceneEditingSegmentID, project.timeline.recordingSegment(id: id) != nil {
            interaction?.sceneSegmentID = id
        }
    }

    /// Idempotent begin used by controls whose first value callback can arrive
    /// immediately before or after SwiftUI's `onEditingChanged(true)` callback.
    @discardableResult
    func beginContinuousInteraction(
        commandScope: EditorInteractionCommandScope,
        selection requestedSelection: EditorSelection? = nil,
        commitsWhenReplacedAs actionName: String? = nil
    ) -> Bool {
        let resolvedSelection = requestedSelection ?? selection ?? commandScope.fallbackSelection
        let replacementPolicy = actionName.map(EditorInteractionReplacementPolicy.commit(actionName:)) ?? .cancel
        if var interaction,
           interaction.commandScope == commandScope,
           interaction.selection == resolvedSelection {
            // A setter may create the same continuous interaction immediately
            // before SwiftUI delivers its editing callback. Upgrade the shared
            // draft instead of cancelling its first preview value.
            if case .commit = replacementPolicy,
               interaction.replacementPolicy != replacementPolicy {
                interaction.replacementPolicy = replacementPolicy
                self.interaction = interaction
            }
            return true
        }
        beginInteraction(
            tool: .select,
            selection: resolvedSelection,
            commandScope: commandScope,
            replacementPolicy: replacementPolicy
        )
        return true
    }

    /// Text drafts autosave only while valid. Keep their last valid preview,
    /// but cancel it if another window or control takes over an invalid draft.
    func setContinuousInteractionReplacementPolicy(
        commandScope: EditorInteractionCommandScope,
        selection requestedSelection: EditorSelection? = nil,
        commitsWhenReplacedAs actionName: String?
    ) {
        let resolvedSelection = requestedSelection ?? selection ?? commandScope.fallbackSelection
        guard var draft = interaction,
              draft.commandScope == commandScope,
              draft.selection == resolvedSelection else { return }
        let policy = actionName.map(EditorInteractionReplacementPolicy.commit(actionName:)) ?? .cancel
        guard draft.replacementPolicy != policy else { return }
        draft.replacementPolicy = policy
        interaction = draft
    }

    /// Starts a preview-canvas gesture without collapsing motion targets into
    /// their inspector tab. The same interaction draft and command reducer are
    /// used for base styles and timeline motion clips.
    @discardableResult
    func beginCanvasInteraction(
        scope: EditorCanvasEditScope,
        operation: EditorCanvasInteractionOperation
    ) -> Bool {
        guard let selection = scope.selection,
              let tool = scope.tool(for: operation),
              scope.position(in: project) != nil,
              scope.scale(in: project) != nil
        else { return false }
        beginInteraction(tool: tool, selection: selection)
        return true
    }

    func updateCanvasPosition(
        _ position: NormalizedPoint,
        scope: EditorCanvasEditScope
    ) {
        updateInteraction { project in
            _ = scope.setPosition(position, in: &project)
        }
    }

    func updateCanvasScale(_ scale: Double, scope: EditorCanvasEditScope) {
        updateInteraction { project in
            _ = scope.setScale(scale, in: &project)
        }
    }

    func updateInteraction(_ update: (inout RecorderProject) -> Void) {
        guard var draft = interaction else { return }
        draft.previewProject = previewProject
        timelinePreview.clear()
        if let id = draft.sceneSegmentID {
            var presented = draft.previewProject.sceneProject(forSegmentID: id)
            update(&presented)
            draft.previewProject = Self.storingSceneEdit(presented, in: draft.previewProject, segmentID: id)
        } else {
            update(&draft.previewProject)
        }
        interaction = draft
    }

    func updateTimelineInteraction(_ update: (inout RecorderProject) -> Void) {
        guard let draft = interaction else { return }
        timelinePreview.update(id: draft.id, base: draft.previewProject, update)
    }

    func cancelInteraction() {
        endInteraction()
    }

    /// Resolves transient editor state before work outside the current gesture
    /// lifecycle (for example export or window deactivation). Autosaving text
    /// and color inputs commit; interrupted positional gestures cancel.
    @discardableResult
    func prepareForExternalAction(
        _ action: EditorExternalAction
    ) -> EditorExternalActionPreparation {
        guard let interaction else { return .ready }
        // Text/color edits already promise autosave when focus moves. Apply
        // that same policy before sleep/export; only unfinished drags cancel.
        if case .commit = interaction.replacementPolicy {
            resolveInteractionBeforeReplacement()
            return .committedDraft
        }
        switch action.interactionPolicy {
        case .cancel:
            endInteraction()
            return .cancelledDraft
        }
    }

    @discardableResult
    func commitInteraction(actionName: String? = nil) throws -> Bool {
        guard var draft = interaction else { return false }
        draft.previewProject = previewProject
        guard let command = try ProjectCommand.committing(draft) else {
            endInteraction()
            return false
        }
        try perform(command, actionName: actionName)
        return true
    }

    func perform(_ command: ProjectCommand, actionName: String? = nil) throws {
        try apply(command, actionName: actionName ?? command.defaultActionName, registersUndo: true)
    }

    /// Applies several independently prepared domain commands as one document
    /// publication and one undo step. `ProjectReducer` owns failure atomicity.
    func performBatch(
        _ commands: [ProjectCommand?],
        actionName: String
    ) throws {
        guard let command = ProjectCommand.batching(commands) else { return }
        try perform(command, actionName: actionName)
    }

    func replaceCanvas(with style: CanvasStyle, actionName: String? = nil) throws {
        if let id = sceneEditingSegmentID, project.timeline.recordingSegment(id: id) != nil {
            var presented = sceneEditingProject
            presented.canvas = style
            try replaceProject(with: Self.storingSceneEdit(presented, in: project, segmentID: id), actionName: actionName)
            return
        }
        guard let command = ProjectCommand.replacingCanvas(in: project, with: style) else { return }
        try perform(command, actionName: actionName)
    }

    func replaceCamera(with style: CameraStyle, actionName: String? = nil) throws {
        if let id = sceneEditingSegmentID, project.timeline.recordingSegment(id: id) != nil {
            var presented = sceneEditingProject
            presented.camera = style
            try replaceProject(with: Self.storingSceneEdit(presented, in: project, segmentID: id), actionName: actionName)
            return
        }
        guard let command = ProjectCommand.replacingCamera(in: project, with: style) else { return }
        try perform(command, actionName: actionName)
    }

    func replaceAudio(with style: AudioStyle, actionName: String? = nil) throws {
        guard let command = ProjectCommand.replacingAudio(in: project, with: style) else { return }
        try perform(command, actionName: actionName)
    }

    func replaceCursor(with style: CursorStyle, actionName: String? = nil) throws {
        if let id = sceneEditingSegmentID, project.timeline.recordingSegment(id: id) != nil {
            var presented = sceneEditingProject
            presented.cursorStyle = style
            try replaceProject(with: Self.storingSceneEdit(presented, in: project, segmentID: id), actionName: actionName)
            return
        }
        guard let command = ProjectCommand.replacingCursor(in: project, with: style) else { return }
        try perform(command, actionName: actionName)
    }

    func replaceMotion(with style: MotionStyle, actionName: String? = nil) throws {
        if let id = sceneEditingSegmentID, project.timeline.recordingSegment(id: id) != nil {
            var presented = sceneEditingProject
            presented.motion = style
            try replaceProject(with: Self.storingSceneEdit(presented, in: project, segmentID: id), actionName: actionName)
            return
        }
        guard let command = ProjectCommand.replacingMotion(in: project, with: style) else { return }
        try perform(command, actionName: actionName)
    }

    func replaceExportSettings(
        with settings: ExportSettings,
        actionName: String? = nil
    ) throws {
        guard let command = ProjectCommand.replacingExportSettings(
            in: project,
            with: settings
        ) else { return }
        // Export choices are persisted with the project, but they are not an
        // edit to the video itself. Keeping them out of the document undo
        // stack means Cmd-Z still targets the user's last visible edit after
        // the export sheet closes.
        try apply(
            command,
            actionName: actionName ?? "调整导出设置",
            registersUndo: false
        )
    }

    func splitPrimarySegment(
        atOutputTime outputTime: TimeInterval,
        sourceDurations: [UUID: TimeInterval],
        newRightSegmentID: UUID = UUID(),
        actionName: String? = nil
    ) throws {
        let timeline = try ProjectTimelineEditing.splitPrimarySegment(
            in: project.timeline,
            atOutputTime: outputTime,
            newRightSegmentID: newRightSegmentID,
            sourceDurations: sourceDurations
        )
        try replaceTimeline(with: timeline, actionName: actionName ?? "拆分主片段")
    }

    func setPrimarySegmentPlaybackRate(
        id: UUID,
        rate: Double,
        sourceDurations: [UUID: TimeInterval],
        actionName: String? = nil
    ) throws {
        let timeline = try ProjectTimelineEditing.settingPlaybackRate(
            rate,
            for: id,
            in: project.timeline,
            sourceDurations: sourceDurations
        )
        try replaceTimeline(with: timeline, actionName: actionName ?? "调整片段速度")
    }

    @discardableResult
    func addMosaic(
        at time: TimeInterval,
        outputDuration: TimeInterval,
        actionName: String = "添加柔化"
    ) throws -> UUID {
        let safeStart = min(
            max(time, 0),
            max(outputDuration - min(0.25, max(outputDuration, 0)), 0)
        )
        let clip = MosaicClip(
            timing: OverlayTiming(
                startTime: safeStart,
                duration: max(
                    min(3, outputDuration - safeStart),
                    min(0.25, max(outputDuration, 0))
                )
            )
        )
        var timeline = project.timeline
        timeline.mosaicClips.append(clip)
        try replaceTimeline(with: timeline, actionName: actionName)
        selection = .mosaic(clip.id)
        return clip.id
    }

    @discardableResult
    func addSticker(
        relativePath: String,
        assetName: String? = nil,
        preferredDuration: TimeInterval? = nil,
        at time: TimeInterval,
        outputDuration: TimeInterval,
        actionName: String = "添加贴图"
    ) throws -> UUID {
        let safeStart = min(
            max(time, 0),
            max(outputDuration - min(0.25, max(outputDuration, 0)), 0)
        )
        let activeStickers = project.timeline.stickerClips.filter {
            $0.timing.contains(safeStart)
        }
        let candidatePositions = [
            NormalizedPoint(x: 0.5, y: 0.5),
            NormalizedPoint(x: 0.20, y: 0.22),
            NormalizedPoint(x: 0.80, y: 0.22),
            NormalizedPoint(x: 0.20, y: 0.78),
            NormalizedPoint(x: 0.80, y: 0.78),
            NormalizedPoint(x: 0.5, y: 0.20),
            NormalizedPoint(x: 0.5, y: 0.80),
            NormalizedPoint(x: 0.18, y: 0.5),
            NormalizedPoint(x: 0.82, y: 0.5),
        ]
        let position = candidatePositions.max { lhs, rhs in
            func clearance(_ candidate: NormalizedPoint) -> Double {
                guard !activeStickers.isEmpty else {
                    return candidate == candidatePositions[0] ? 1 : 0
                }
                return activeStickers.map {
                    hypot(
                        candidate.x - $0.position.x,
                        candidate.y - $0.position.y
                    )
                }.min() ?? 0
            }
            return clearance(lhs) < clearance(rhs)
        } ?? candidatePositions[0]
        var clip = StickerClip(
            timing: OverlayTiming(
                startTime: safeStart,
                duration: max(
                    min(
                        preferredDuration ?? 3,
                        outputDuration - safeStart
                    ),
                    min(0.25, max(outputDuration, 0))
                )
            ),
            relativePath: relativePath,
            position: position,
            width: activeStickers.isEmpty ? 0.38 : 0.28,
            layerIndex: 0
        )
        clip.layerIndex = project.timeline.visualLayer(for: clip.timing)
        AppPreferences.applyRememberedStickerCreationDefaults(to: &clip)
        var timeline = project.timeline
        timeline.stickerClips.append(clip)
        // The bin and the placed clip share one portable project file and
        // one undo step. Reusing a picture must not create another bin tile.
        let path = ProjectFiles.portable(ProjectFiles.resolve(relativePath))
        if !timeline.mediaAssets.contains(where: {
            $0.kind == .image && ProjectFiles.portable(ProjectFiles.resolve($0.path)) == path
        }) {
            timeline.mediaAssets.append(MediaAsset(path: path, kind: .image,
                name: assetName ?? URL(fileURLWithPath: relativePath).lastPathComponent))
        }
        try replaceTimeline(with: timeline, actionName: actionName)
        selection = .sticker(clip.id)
        return clip.id
    }

    /// HTML pages author their composition in the project canvas coordinate space.
    func addAnimation(
        sourcePath: String,
        at time: TimeInterval,
        outputDuration: TimeInterval,
        sourceRange: ClosedRange<TimeInterval>? = nil,
        requestedDuration: TimeInterval? = nil,
        position: NormalizedPoint = .init(x: 0.5, y: 0.5),
        width: Double? = nil,
        sound: URL? = nil,
        actionName: String = "添加动效"
    ) throws -> UUID {
        let safeStart = Self.animationStart(time, outputDuration: outputDuration)
        let isHTML = HTMLMotion.isHTMLMotion(sourcePath)
        let declared = isHTML ? HTMLMotion.declaredDuration(path: ProjectFiles.resolve(sourcePath)) : nil
        let wanted = sourceRange.map { max($0.upperBound - $0.lowerBound, 0.05) } ?? requestedDuration ?? declared ?? 3
        let timing = OverlayTiming(
            startTime: safeStart,
            duration: min(wanted, outputDuration - safeStart)
        )
        var clip = AnimationClip(
            timing: timing,
            sourcePath: sourcePath,
            position: position, width: width ?? (isHTML ? 1 : 0.5),
            layerIndex: project.timeline.visualLayer(for: timing)
        )
        // The marked in point is where the motion starts playing from.
        clip.soundtrack = try HTMLMotion.placementSound(at: sourcePath, override: sound)
        clip.cameraSlot = HTMLMotion.cameraSlot(at: sourcePath)
        clip.timeOffset = max(sourceRange?.lowerBound ?? 0, 0)
        var timeline = project.timeline
        timeline.animationClips.append(clip)
        try replaceTimeline(with: timeline, actionName: actionName)
        selection = .animation(clip.id)
        return clip.id
    }

    static func animationStart(_ time: TimeInterval, outputDuration: TimeInterval) -> TimeInterval {
        min(max(time, 0), max(outputDuration - 0.05, 0))
    }

    func removeSelectedOverlay(actionName: String = "删除叠加内容") throws {
        var timeline = project.timeline
        switch selection {
        case let .mosaic(id):
            timeline.mosaicClips.removeAll { $0.id == id }
        case let .sticker(id):
            timeline.stickerClips.removeAll { $0.id == id }
        case let .animation(id):
            timeline.animationClips.removeAll { $0.id == id }
        case let .audioClip(id):
            timeline.audioClips.removeAll { $0.id == id }
        case let .subtitle(id):
            timeline.subtitleCues.removeAll { $0.id == id }
        case let .videoClip(id):
            timeline.videoClips.removeAll { $0.id == id }
        default:
            return
        }
        try replaceTimeline(with: timeline, actionName: actionName)
        selection = .canvas
    }

    func trimPrimarySegment(
        id: UUID,
        edge: RecordingSegmentTrimEdge,
        toOutputTime outputTime: TimeInterval,
        sourceDurations: [UUID: TimeInterval],
        actionName: String? = nil
    ) throws {
        let timeline = try ProjectTimelineEditing.trimPrimarySegment(
            in: project.timeline,
            segmentID: id,
            edge: edge,
            toOutputTime: outputTime,
            sourceDurations: sourceDurations,
            defaultTransitionDuration: project.motion.defaultZoomTransitionDuration
        )
        try replaceTimeline(with: timeline, actionName: actionName ?? "裁切主片段")
    }

    func removePrimarySegment(
        id: UUID,
        sourceDurations: [UUID: TimeInterval],
        actionName: String? = nil
    ) throws {
        let timeline = try ProjectTimelineEditing.removePrimarySegment(
            from: project.timeline,
            segmentID: id,
            sourceDurations: sourceDurations,
            defaultTransitionDuration: project.motion.defaultZoomTransitionDuration
        )
        try replaceTimeline(with: timeline, actionName: actionName ?? "删除主片段")
    }

    func movePrimarySegment(
        id: UUID,
        toIndex: Int,
        sourceDurations: [UUID: TimeInterval],
        actionName: String? = nil
    ) throws {
        let timeline = try ProjectTimelineEditing.movePrimarySegment(
            in: project.timeline,
            segmentID: id,
            toIndex: toIndex,
            sourceDurations: sourceDurations
        )
        try replaceTimeline(with: timeline, actionName: actionName ?? "调整主片段顺序")
    }

    func restorePrimaryGap(
        previousSegmentID: UUID,
        nextSegmentID: UUID,
        restoredSegmentID: UUID = UUID(),
        sourceDurations: [UUID: TimeInterval],
        actionName: String? = nil
    ) throws {
        let timeline = try ProjectTimelineEditing.restorePrimaryGap(
            in: project.timeline,
            previousSegmentID: previousSegmentID,
            nextSegmentID: nextSegmentID,
            restoredSegmentID: restoredSegmentID,
            sourceDurations: sourceDurations
        )
        try replaceTimeline(with: timeline, actionName: actionName ?? "还原该处剪切")
    }

    func restorePrimaryLeadingGap(
        restoredSegmentID: UUID = UUID(),
        sourceDurations: [UUID: TimeInterval],
        actionName: String? = nil
    ) throws {
        let timeline = try ProjectTimelineEditing.restorePrimaryLeadingGap(
            in: project.timeline,
            restoredSegmentID: restoredSegmentID,
            sourceDurations: sourceDurations
        )
        try replaceTimeline(with: timeline, actionName: actionName ?? "还原开头剪切")
    }

    func restorePrimaryTrailingGap(
        restoredSegmentID: UUID = UUID(),
        sourceDurations: [UUID: TimeInterval],
        actionName: String? = nil
    ) throws {
        let timeline = try ProjectTimelineEditing.restorePrimaryTrailingGap(
            in: project.timeline,
            restoredSegmentID: restoredSegmentID,
            sourceDurations: sourceDurations
        )
        try replaceTimeline(with: timeline, actionName: actionName ?? "还原结尾剪切")
    }

    func mergeAdjacentPrimarySegments(
        previousSegmentID: UUID,
        nextSegmentID: UUID,
        sourceDurations: [UUID: TimeInterval],
        actionName: String? = nil
    ) throws {
        let timeline = try ProjectTimelineEditing.mergeAdjacentPrimarySegments(
            in: project.timeline,
            previousSegmentID: previousSegmentID,
            nextSegmentID: nextSegmentID,
            sourceDurations: sourceDurations
        )
        try replaceTimeline(with: timeline, actionName: actionName ?? "合并相邻主片段")
    }

    func insertScreenMotion(_ clip: ScreenMotionClip, actionName: String? = nil) throws {
        let timeline = try ProjectTimelineEditing.insertingScreenMotion(clip, in: project.timeline)
        try replaceTimeline(with: timeline, actionName: actionName ?? "添加屏幕 3D")
    }

    func removeScreenMotion(id: UUID, actionName: String? = nil) throws {
        let timeline = try ProjectTimelineEditing.removingScreenMotion(
            id: id,
            from: project.timeline,
            defaultReturn: project.motion.defaultZoomTransitionDuration
        )
        try replaceTimeline(with: timeline, actionName: actionName ?? "删除屏幕 3D")
    }

    func insertCameraMotion(_ clip: CameraMotionClip, actionName: String? = nil) throws {
        let timeline = try ProjectTimelineEditing.insertingCameraMotion(clip, in: project.timeline)
        try replaceTimeline(with: timeline, actionName: actionName ?? "添加摄像运动")
    }

    func removeCameraMotion(id: UUID, actionName: String? = nil) throws {
        let timeline = try ProjectTimelineEditing.removingCameraMotion(
            id: id,
            from: project.timeline,
            defaultReturn: project.motion.defaultZoomTransitionDuration
        )
        try replaceTimeline(with: timeline, actionName: actionName ?? "删除摄像运动")
    }

    func replaceCameraMotion(_ clip: CameraMotionClip, actionName: String? = nil) throws {
        let timeline = try ProjectTimelineEditing.replacingCameraMotion(
            id: clip.id,
            in: project.timeline,
            with: clip
        )
        try replaceTimeline(with: timeline, actionName: actionName ?? "调整摄像运动")
    }

    func replaceProject(with replacement: RecorderProject, actionName: String? = nil) throws {
        guard let command = ProjectCommand.replacingProject(project, with: replacement) else { return }
        try perform(command, actionName: actionName)
    }

    func insertZoom(_ clip: ZoomAnimationClip, actionName: String? = nil) throws {
        try perform(ProjectCommand.insertingZoom(clip, in: project), actionName: actionName)
    }

    func removeZoom(id: UUID, actionName: String? = nil) throws {
        try perform(ProjectCommand.removingZoom(id: id, from: project), actionName: actionName)
    }

    func replaceZoom(_ clip: ZoomAnimationClip, actionName: String? = nil) throws {
        guard let command = try ProjectCommand.replacingZoom(id: clip.id, in: project, with: clip) else { return }
        try perform(command, actionName: actionName)
    }

    @TaskLocal static var isAgentMutation = false

    private struct UndoBatchSnapshot {
        var project: RecorderProject
        var selection: EditorSelection?
    }

    private struct AgentUndoBatchState {
        var project: RecorderProject
        var selection: EditorSelection?
        let actionName: String
    }

    /// Short synchronous UI batch (for example multi-selection delete or media drop).
    private var undoBatchStart: UndoBatchSnapshot?
    /// Long-lived AI turn batch (`EDT-054`): coalesces AI tool mutations
    /// (`Self.isAgentMutation == true`) into one undo step while keeping manual
    /// user edits and undo/redo independent.
    private var agentUndoBatch: AgentUndoBatchState?

    var hasPendingAgentUndoChanges: Bool {
        guard let batch = agentUndoBatch else { return false }
        return batch.project != project
    }

    var pendingAgentUndoActionName: String? {
        hasPendingAgentUndoChanges ? agentUndoBatch?.actionName : nil
    }

    func beginUndoBatch() {
        guard undoBatchStart == nil else { return }
        let safeSelection: EditorSelection? = selection == .crop ? .screen : selection
        undoBatchStart = UndoBatchSnapshot(project: project, selection: safeSelection)
    }

    func endUndoBatch(actionName: String) {
        guard let start = undoBatchStart else { return }
        undoBatchStart = nil
        guard start.project != project else { return }
        if agentUndoBatch != nil && Self.isAgentMutation {
            return
        }
        if agentUndoBatch != nil {
            flushAgentUndoBatch(upTo: start.project)
        }
        if let undoManager {
            let inverse = ProjectCommand.replaceProject(before: start.project, after: project).inverse
            let restoredSelection = start.selection
            registerDiscreteUndoGroup(on: undoManager, actionName: actionName) { store in
                store.performFromUndo(
                    inverse,
                    actionName: actionName,
                    restoredSelection: restoredSelection
                )
            }
        }
        if agentUndoBatch != nil {
            let safeSelection: EditorSelection? = selection == .crop ? .screen : selection
            agentUndoBatch?.project = project
            agentUndoBatch?.selection = safeSelection
        }
        revision &+= 1
    }

    func beginAgentUndoBatch(actionName: String) {
        if agentUndoBatch != nil {
            endAgentUndoBatch()
        }
        let safeSelection: EditorSelection? = selection == .crop ? .screen : selection
        agentUndoBatch = AgentUndoBatchState(
            project: project,
            selection: safeSelection,
            actionName: actionName
        )
    }

    func prepareForUserUndoOrRedo() {
        flushAgentUndoBatch(upTo: project)
    }

    func endAgentUndoBatch() {
        guard agentUndoBatch != nil else { return }
        let flushed = hasPendingAgentUndoChanges
        flushAgentUndoBatch(upTo: project)
        agentUndoBatch = nil
        if flushed {
            revision &+= 1
        }
    }

    private func flushAgentUndoBatch(upTo targetProject: RecorderProject) {
        guard let batch = agentUndoBatch, batch.project != targetProject else { return }
        let safeSelection: EditorSelection? = selection == .crop ? .screen : selection
        agentUndoBatch?.project = targetProject
        agentUndoBatch?.selection = safeSelection
        guard let undoManager else { return }
        let inverse = ProjectCommand.replaceProject(before: batch.project, after: targetProject).inverse
        let actionName = batch.actionName
        let restoredSelection = batch.selection
        registerDiscreteUndoGroup(on: undoManager, actionName: actionName) { store in
            store.performFromUndo(
                inverse,
                actionName: actionName,
                restoredSelection: restoredSelection
            )
        }
    }

    private func registerDiscreteUndoGroup(
        on undoManager: UndoManager,
        actionName: String,
        handler: @escaping (EditorStore) -> Void
    ) {
        if undoManager.groupingLevel == 0 {
            let savedGroupsByEvent = undoManager.groupsByEvent
            undoManager.groupsByEvent = false
            undoManager.beginUndoGrouping()
            defer {
                undoManager.endUndoGrouping()
                undoManager.groupsByEvent = savedGroupsByEvent
            }
            undoManager.registerUndo(withTarget: self, handler: handler)
            undoManager.setActionName(actionName)
        } else {
            undoManager.registerUndo(withTarget: self, handler: handler)
            undoManager.setActionName(actionName)
        }
    }

    func replaceTimeline(
        with timeline: ProjectTimeline,
        actionName: String? = nil
    ) throws {
        guard let command = ProjectCommand.replacingTimeline(in: project, with: timeline) else { return }
        try perform(command, actionName: actionName)
    }

    private func apply(
        _ command: ProjectCommand,
        actionName: String,
        registersUndo: Bool,
        restoresSelection: Bool = false,
        restoredSelection: EditorSelection? = nil
    ) throws {
        // Crop is a transient tool, not a restorable document selection.
        // Undoing its command must return to screen settings without leaving
        // a stale crop header or hiding the frame subnavigation.
        let projectBeforeApply = project
        let selectionBeforeApply: EditorSelection? = selection == .crop ? .screen : selection
        var appliedCommand = command
        var nextProject = project
        try ProjectReducer.apply(command, to: &nextProject)

        if case let .sticker(id) = selectionBeforeApply,
           let previousSticker = project.timeline.stickerClips.first(
               where: { $0.id == id }
           ),
           let updatedSticker = nextProject.timeline.stickerClips.first(
               where: { $0.id == id }
           ) {
            AppPreferences.rememberStickerCreationDefaultsIfChanged(
                before: previousSticker,
                after: updatedSticker
            )
        }

        if !restoresSelection,
           case let .zoom(id) = selectionBeforeApply,
           let previousZoom = project.zoomAnimations.first(where: { $0.id == id }),
           let updatedZoom = nextProject.zoomAnimations.first(where: { $0.id == id }),
           abs(previousZoom.scale - updatedZoom.scale) > 0.000_001 {
            // The creation default is part of the same reversible edit. Undo
            // replays this command without remembering a fresh global value.
            let beforeMotion = nextProject.motion
            if beforeMotion.defaultZoomScale != updatedZoom.scale {
                var afterMotion = beforeMotion
                afterMotion.defaultZoomScale = updatedZoom.scale
                let defaults = ProjectCommand.replaceMotion(before: beforeMotion, after: afterMotion)
                try ProjectReducer.apply(defaults, to: &nextProject)
                appliedCommand = .batch([command, defaults])
            }
            AppPreferences.rememberZoomCreationScale(updatedZoom.scale)
        }

        if !restoresSelection,
           case let .screenMotion(id) = selectionBeforeApply,
           project.timeline.sourceSequence == nextProject.timeline.sourceSequence,
           let previous = project.timeline.screenMotionClips.first(where: { $0.id == id }),
           let updated = nextProject.timeline.screenMotionClips.first(where: { $0.id == id }) {
            let style = ScreenMotionCreationStyle(clip: updated)
            if style.isValid, style != ScreenMotionCreationStyle(clip: previous) {
                let before = nextProject.motion
                var after = before
                after.defaultScreenMotion = style
                let defaults = ProjectCommand.replaceMotion(before: before, after: after)
                try ProjectReducer.apply(defaults, to: &nextProject)
                appliedCommand = .batch([appliedCommand, defaults])
                AppPreferences.rememberScreenMotionCreationStyle(style)
            }
        }

        // End the preview transaction before publishing the persisted snapshot,
        // so observers can never render a new project through an old draft.
        endInteraction()
        document.replace(with: nextProject)
        projectSink?(nextProject)
        if restoresSelection {
            selection = restoredSelection
        }

        let isUndoOrRedo = undoManager?.isUndoing == true || undoManager?.isRedoing == true
        if isUndoOrRedo {
            if registersUndo, let undoManager {
                let inverse = appliedCommand.inverse
                undoManager.registerUndo(withTarget: self) { store in
                    store.performFromUndo(
                        inverse,
                        actionName: actionName,
                        restoredSelection: selectionBeforeApply
                    )
                }
                undoManager.setActionName(actionName)
            }
            if agentUndoBatch != nil {
                let safeSelection: EditorSelection? = selection == .crop ? .screen : selection
                agentUndoBatch?.project = nextProject
                agentUndoBatch?.selection = safeSelection
            }
        } else if undoBatchStart != nil {
            // Short synchronous UI batch registers one combined undo in endUndoBatch.
        } else if agentUndoBatch != nil {
            if Self.isAgentMutation {
                // Coalesce into the active AI turn's undo batch.
            } else if registersUndo {
                flushAgentUndoBatch(upTo: projectBeforeApply)
                if let undoManager {
                    let inverse = appliedCommand.inverse
                    undoManager.registerUndo(withTarget: self) { store in
                        store.performFromUndo(
                            inverse,
                            actionName: actionName,
                            restoredSelection: selectionBeforeApply
                        )
                    }
                    undoManager.setActionName(actionName)
                }
                let safeSelection: EditorSelection? = selection == .crop ? .screen : selection
                agentUndoBatch?.project = nextProject
                agentUndoBatch?.selection = safeSelection
            }
        } else if registersUndo, let undoManager {
            let inverse = appliedCommand.inverse
            undoManager.registerUndo(withTarget: self) { store in
                store.performFromUndo(
                    inverse,
                    actionName: actionName,
                    restoredSelection: selectionBeforeApply
                )
            }
            undoManager.setActionName(actionName)
        }

        revision &+= 1
    }

    private func performFromUndo(
        _ command: ProjectCommand,
        actionName: String,
        restoredSelection: EditorSelection?
    ) {
        do {
            try apply(
                command,
                actionName: actionName,
                registersUndo: true,
                restoresSelection: true,
                restoredSelection: restoredSelection
            )
        } catch {
            assertionFailure("Undo command failed: \(error)")
        }
    }

    private func endInteraction() {
        interaction = nil
    }

    /// Selection changes and new gestures must not silently discard controls
    /// whose UI promises automatic saving. Other transient canvas gestures
    /// retain the existing cancellation behavior.
    private func resolveInteractionBeforeReplacement() {
        guard let interaction else { return }
        switch interaction.replacementPolicy {
        case .cancel:
            endInteraction()
        case let .commit(actionName):
            do {
                _ = try commitInteraction(actionName: actionName)
            } catch {
                endInteraction()
                assertionFailure("Failed to preserve interaction before replacement: \(error)")
            }
        }
    }
}

/// Where a dragged clip or library item lands on the timeline.
/// Where a bin file lands and how much of it: the one request every placement
/// path shares — the bin's add button, a double-click, a drag onto a layer, a
/// drag onto the main track. A drop point and a source span are stated
/// together, so the in and out marks set in the monitor travel with the file
/// instead of being a property of the playhead.
struct EditorMediaPlacement {
    let asset: MediaAsset
    /// The output time it lands at; nil means wherever the playhead is.
    var time: TimeInterval?
    /// The row it lands on. `.mainTrack` inserts a segment and ripples.
    var lane: EditorDropLane = .newLayer
    /// The span of the source file to place; nil means the whole file. Every
    /// `add…`/`insert…` call takes it from here, so one missing file check and
    /// one clamp serve them all.
    var sourceRange: ClosedRange<TimeInterval>?
}

enum EditorDropLane: Equatable {
    case layer(Int)
    case newLayer
    case newLayerBelow
    case audio(Int)
    case newAudio
    case mainTrack
}
