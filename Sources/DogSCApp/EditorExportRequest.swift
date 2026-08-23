import Foundation
import RecorderCore

/// One export input frozen to the exact on-disk file generation inspected by
/// the editor. Keeping URL and version together prevents a path from silently
/// resolving to replacement media after the user presses Export.
struct EditorExportAsset: Equatable, Sendable {
    let url: URL
    let version: EditorMediaFileVersion

    fileprivate init(input: EditorMediaInput) {
        url = input.url.standardizedFileURL
        version = input.version
    }

    fileprivate init(url: URL, role: ExportAssetRole) throws {
        let standardizedURL = url.standardizedFileURL
        try Self.validateExistingLocalFile(at: standardizedURL, role: role)
        self.url = standardizedURL
        version = EditorMediaFileVersion(url: standardizedURL)
    }

    func validateCurrentVersion(role: ExportAssetRole) throws {
        try Self.validateExistingLocalFile(at: url, role: role)
        guard EditorMediaFileVersion(url: url) == version else {
            throw EditorExportRequestError.assetVersionChanged(
                role: role,
                path: url.path
            )
        }
    }

    private static func validateExistingLocalFile(
        at url: URL,
        role: ExportAssetRole
    ) throws {
        guard url.isFileURL else {
            throw EditorExportRequestError.nonFileAsset(
                role: role,
                value: url.absoluteString
            )
        }
        var isDirectory = ObjCBool(false)
        guard FileManager.default.fileExists(
            atPath: url.path,
            isDirectory: &isDirectory
        ) else {
            throw EditorExportRequestError.missingAssetFile(
                role: role,
                path: url.path
            )
        }
        guard !isDirectory.boolValue else {
            throw EditorExportRequestError.nonFileAsset(
                role: role,
                value: url.path
            )
        }
    }
}

/// Every URL needed by this particular project snapshot, paired with its file
/// version. Muted or hidden optional media is intentionally omitted so an
/// irrelevant file change cannot invalidate an otherwise deterministic job.
struct EditorExportAssets: Equatable, Sendable {
    let source: EditorExportAsset
    let camera: EditorExportAsset?
    let microphone: EditorExportAsset?
    let wallpaper: EditorExportAsset?

    fileprivate init(
        source: EditorExportAsset,
        camera: EditorExportAsset?,
        microphone: EditorExportAsset?,
        wallpaper: EditorExportAsset?
    ) {
        self.source = source
        self.camera = camera
        self.microphone = microphone
        self.wallpaper = wallpaper
    }

    /// Called once while building the request and again as the worker starts.
    /// The second check closes the gap between the editor snapshot and the
    /// background task opening its own AVAssets.
    func validateCurrentVersions() throws {
        try source.validateCurrentVersion(role: .screenRecording)
        try camera?.validateCurrentVersion(role: .cameraRecording)
        try microphone?.validateCurrentVersion(role: .microphoneRecording)
        try wallpaper?.validateCurrentVersion(role: .wallpaper)
    }

    fileprivate var inputURLs: [URL] {
        [source, camera, microphone, wallpaper]
            .compactMap { $0?.url.standardizedFileURL }
    }
}

/// Immutable value handed across the main-actor/worker boundary. It contains
/// only Sendable value snapshots: no AVAsset, AVAssetTrack or prepared preview
/// composition is allowed to escape into the export worker.
struct EditorExportRequest: Equatable, Sendable {
    let editorSessionID: EditorSessionID
    let mediaGeneration: UInt64
    let project: RecorderProject
    let mediaPlan: ProjectTimelineMediaPlan
    let assets: EditorExportAssets
    let outputURL: URL

    fileprivate init(
        editorSessionID: EditorSessionID,
        mediaGeneration: UInt64,
        project: RecorderProject,
        mediaPlan: ProjectTimelineMediaPlan,
        assets: EditorExportAssets,
        outputURL: URL
    ) {
        self.editorSessionID = editorSessionID
        self.mediaGeneration = mediaGeneration
        self.project = project
        self.mediaPlan = mediaPlan
        self.assets = assets
        self.outputURL = outputURL
    }
}

enum EditorExportRequestError: LocalizedError, Equatable, Sendable {
    case editorSessionMismatch(expected: EditorSessionID, actual: EditorSessionID)
    case mediaGenerationMismatch(expected: UInt64, actual: UInt64)
    case sourceSequenceMismatch
    case mediaManifestMismatch
    case missingAssetReference(ExportAssetRole)
    case missingAssetFile(role: ExportAssetRole, path: String)
    case nonFileAsset(role: ExportAssetRole, value: String)
    case assetVersionChanged(role: ExportAssetRole, path: String)
    case invalidOutputURL(String)
    case outputCollidesWithInput(String)

    var errorDescription: String? {
        switch self {
        case .editorSessionMismatch:
            return "导出素材不属于当前编辑会话，请等待预览重新准备。"
        case .mediaGenerationMismatch:
            return "导出素材已经被新的编辑代次取代，请重新导出。"
        case .sourceSequenceMismatch:
            return "剪辑时间线已变化，请等待预览更新后重试。"
        case .mediaManifestMismatch:
            return "项目素材清单已变化，请等待预览更新后重试。"
        case let .missingAssetReference(role):
            return "项目需要\(role.displayName)素材，但当前编辑会话没有对应文件。"
        case let .missingAssetFile(role, path):
            return "\(role.displayName)素材不存在：\(path)。"
        case let .nonFileAsset(role, value):
            return "\(role.displayName)素材不是可用的本地文件：\(value)。"
        case let .assetVersionChanged(role, path):
            return "\(role.displayName)素材在导出前已变化：\(path)。请重新打开或刷新项目。"
        case let .invalidOutputURL(value):
            return "导出位置不是本地文件路径：\(value)。"
        case let .outputCollidesWithInput(path):
            return "导出位置不能覆盖项目素材：\(path)。"
        }
    }
}

enum EditorExportRequestBuilder {
    static func make(
        editorSessionID: EditorSessionID,
        mediaGeneration: UInt64,
        project: RecorderProject,
        preparedMedia: EditorPreparedMedia,
        wallpaperURL: URL?,
        outputURL: URL? = nil
    ) throws -> EditorExportRequest {
        let preparedRequest = preparedMedia.request
        guard preparedRequest.editorSessionID == editorSessionID else {
            throw EditorExportRequestError.editorSessionMismatch(
                expected: editorSessionID,
                actual: preparedRequest.editorSessionID
            )
        }
        guard preparedMedia.generation == mediaGeneration else {
            throw EditorExportRequestError.mediaGenerationMismatch(
                expected: mediaGeneration,
                actual: preparedMedia.generation
            )
        }
        guard preparedRequest.sourceSequence == project.timeline.sourceSequence else {
            throw EditorExportRequestError.sourceSequenceMismatch
        }
        guard preparedRequest.matchesPreparationManifest(project.media) else {
            throw EditorExportRequestError.mediaManifestMismatch
        }
        guard project.media != nil else {
            throw EditorExportRequestError.missingAssetReference(.screenRecording)
        }

        let requiredMedia = RequiredProjectMedia(project: project)
        let source = try requiredAsset(
            preparedRequest.source,
            role: .screenRecording
        )
        let camera = try requiredMedia.cameraVideo
            ? requiredAsset(preparedRequest.camera, role: .cameraRecording)
            : nil
        let microphone = try requiredMedia.microphoneAudio
            ? requiredAsset(preparedRequest.microphone, role: .microphoneRecording)
            : nil
        let wallpaper = try requiredMedia.backgroundImage
            ? requiredWallpaper(at: wallpaperURL)
            : nil
        let assets = EditorExportAssets(
            source: source,
            camera: camera,
            microphone: microphone,
            wallpaper: wallpaper
        )

        // Reject a replacement that occurred after preview preparation.
        try assets.validateCurrentVersions()

        let resolvedOutputURL = try (outputURL ?? makeDefaultOutputURL(for: project))
            .standardizedFileURL
        guard resolvedOutputURL.isFileURL else {
            throw EditorExportRequestError.invalidOutputURL(
                resolvedOutputURL.absoluteString
            )
        }
        guard !assets.inputURLs.contains(resolvedOutputURL) else {
            throw EditorExportRequestError.outputCollidesWithInput(
                resolvedOutputURL.path
            )
        }

        guard let primaryVideoRange = preparedMedia.inventories.source.videoTimeRange else {
            throw EditorExportRequestError.mediaManifestMismatch
        }
        let currentMediaPlan = try ProjectTimelineMediaPlan(
            sourceSequence: project.timeline.sourceSequence,
            mediaManifest: project.media,
            primaryVideoRange: primaryVideoRange,
            systemAudioRange: preparedMedia.inventories.source.audioTimeRange,
            cameraRange: preparedMedia.inventories.camera.videoTimeRange,
            microphoneRange: preparedMedia.inventories.microphone.audioTimeRange,
            sourcePointerEvents: preparedRequest.pointerEvents
        )

        return EditorExportRequest(
            editorSessionID: editorSessionID,
            mediaGeneration: mediaGeneration,
            project: project,
            mediaPlan: currentMediaPlan,
            assets: assets,
            outputURL: resolvedOutputURL
        )
    }

    static func makeDefaultOutputURL(for project: RecorderProject) throws -> URL {
        let folder = AppPreferences.exportDirectoryURL
        try FileManager.default.createDirectory(
            at: folder,
            withIntermediateDirectories: true
        )

        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd-HH-mm-ss"
        let frameRate = project.exportSettings.frameRate
        let baseName = "成片-\(formatter.string(from: Date()))-\(frameRate.rawValue)fps"
        var candidate = folder.appendingPathComponent("\(baseName).mp4")
        var suffix = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = folder.appendingPathComponent("\(baseName)-\(suffix).mp4")
            suffix += 1
        }
        return candidate
    }

    private static func requiredAsset(
        _ input: EditorMediaInput?,
        role: ExportAssetRole
    ) throws -> EditorExportAsset {
        guard let input else {
            throw EditorExportRequestError.missingAssetReference(role)
        }
        return EditorExportAsset(input: input)
    }

    private static func requiredWallpaper(
        at url: URL?
    ) throws -> EditorExportAsset {
        guard let url else {
            throw EditorExportRequestError.missingAssetReference(.wallpaper)
        }
        return try EditorExportAsset(url: url, role: .wallpaper)
    }

}
