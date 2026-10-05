import Foundation
import RecorderCore

enum ExportOutputKind: String, CaseIterable, Identifiable, Equatable, Sendable {
    case video
    case audio

    var id: Self { self }
    var fileExtension: String { self == .video ? "mp4" : "m4a" }
}

/// The visible export window chosen by the editor. A ranged export keeps the
/// project's authored timeline clock intact; only the encoded file is rebased
/// to start at zero.
enum EditorExportScope: Equatable, Sendable {
    case fullProject
    case timelineRange(MediaTimeRange, selectedSegmentCount: Int)

    var outputRange: MediaTimeRange? {
        guard case let .timelineRange(range, _) = self else { return nil }
        return range
    }

    var selectedSegmentCount: Int {
        guard case let .timelineRange(_, count) = self else { return 0 }
        return count
    }
}

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
    let stickers: [String: EditorExportAsset]

    fileprivate init(
        source: EditorExportAsset,
        camera: EditorExportAsset?,
        microphone: EditorExportAsset?,
        wallpaper: EditorExportAsset?,
        stickers: [String: EditorExportAsset]
    ) {
        self.source = source
        self.camera = camera
        self.microphone = microphone
        self.wallpaper = wallpaper
        self.stickers = stickers
    }

    /// Called once while building the request and again as the worker starts.
    /// The second check closes the gap between the editor snapshot and the
    /// background task opening its own AVAssets.
    func validateCurrentVersions() throws {
        try source.validateCurrentVersion(role: .screenRecording)
        try camera?.validateCurrentVersion(role: .cameraRecording)
        try microphone?.validateCurrentVersion(role: .microphoneRecording)
        try wallpaper?.validateCurrentVersion(role: .wallpaper)
        for sticker in stickers.values {
            try sticker.validateCurrentVersion(role: .sticker)
        }
    }

    fileprivate var inputURLs: [URL] {
        [source, camera, microphone, wallpaper]
            .compactMap { $0?.url.standardizedFileURL }
            + stickers.values.map { $0.url.standardizedFileURL }
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
    let outputKind: ExportOutputKind
    let outputRange: MediaTimeRange?

    fileprivate init(
        editorSessionID: EditorSessionID,
        mediaGeneration: UInt64,
        project: RecorderProject,
        mediaPlan: ProjectTimelineMediaPlan,
        assets: EditorExportAssets,
        outputURL: URL,
        outputKind: ExportOutputKind,
        outputRange: MediaTimeRange?
    ) {
        self.editorSessionID = editorSessionID
        self.mediaGeneration = mediaGeneration
        self.project = project
        self.mediaPlan = mediaPlan
        self.assets = assets
        self.outputURL = outputURL
        self.outputKind = outputKind
        self.outputRange = outputRange
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
    case invalidOutputRange

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
        case .invalidOutputRange:
            return "所选片段已经变化，无法确定有效的导出范围。请重新选择片段。"
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
        stickerURLs: [String: URL] = [:],
        outputURL: URL? = nil,
        outputKind: ExportOutputKind = .video,
        outputRange: MediaTimeRange? = nil
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
        let camera = try outputKind == .video && requiredMedia.cameraVideo
            ? requiredAsset(preparedRequest.camera, role: .cameraRecording)
            : nil
        let microphone = try requiredMedia.microphoneAudio
            ? requiredAsset(preparedRequest.microphone, role: .microphoneRecording)
            : nil
        let wallpaper = try outputKind == .video
            && (requiredMedia.backgroundImage || requiredMedia.backgroundVideo)
            ? requiredWallpaper(at: wallpaperURL)
            : nil
        let stickerPaths = outputKind == .video
            ? Set(project.timeline.stickerClips.map(\.relativePath))
            : []
        var stickers: [String: EditorExportAsset] = [:]
        stickers.reserveCapacity(stickerPaths.count)
        for relativePath in stickerPaths {
            guard let url = stickerURLs[relativePath] else {
                throw EditorExportRequestError.missingAssetReference(.sticker)
            }
            stickers[relativePath] = try EditorExportAsset(url: url, role: .sticker)
        }
        let assets = EditorExportAssets(
            source: source,
            camera: camera,
            microphone: microphone,
            wallpaper: wallpaper,
            stickers: stickers
        )

        // Reject a replacement that occurred after preview preparation.
        try assets.validateCurrentVersions()

        let resolvedOutputURL = try (outputURL ?? makeDefaultOutputURL(
            for: project,
            outputKind: outputKind
        ))
            .standardizedFileURL
        guard resolvedOutputURL.isFileURL else {
            throw EditorExportRequestError.invalidOutputURL(
                resolvedOutputURL.absoluteString
            )
        }
        guard resolvedOutputURL.pathExtension.lowercased()
            == outputKind.fileExtension else {
            throw EditorExportRequestError.invalidOutputURL(
                "音视频类型与扩展名不匹配：\(resolvedOutputURL.path)"
            )
        }
        guard !ExportFileTransaction.collides(
            outputURL: resolvedOutputURL,
            inputURLs: assets.inputURLs
        ) else {
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
        let validatedOutputRange: MediaTimeRange?
        if let outputRange {
            let tolerance = max(currentMediaPlan.outputDuration.ulp * 8, 0.000_001)
            let start = max(outputRange.start, 0)
            let end = min(outputRange.end, currentMediaPlan.outputDuration)
            guard outputRange.start >= -tolerance,
                  outputRange.end <= currentMediaPlan.outputDuration + tolerance,
                  let range = MediaTimeRange(start: start, duration: end - start) else {
                throw EditorExportRequestError.invalidOutputRange
            }
            validatedOutputRange = range
        } else {
            validatedOutputRange = nil
        }

        return EditorExportRequest(
            editorSessionID: editorSessionID,
            mediaGeneration: mediaGeneration,
            project: project,
            mediaPlan: currentMediaPlan,
            assets: assets,
            outputURL: resolvedOutputURL,
            outputKind: outputKind,
            outputRange: validatedOutputRange
        )
    }

    static func makeDefaultOutputURL(
        for project: RecorderProject,
        preferredProjectName: String? = nil,
        outputKind: ExportOutputKind = .video,
        directoryURL: URL? = nil
    ) throws -> URL {
        let folder = directoryURL ?? AppPreferences.exportDirectoryURL
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd-HH-mm-ss"
        let projectName = preferredProjectName.flatMap(exportFileNameComponent)
        let baseName: String
        switch outputKind {
        case .video:
            let frameRate = project.exportSettings.frameRate
            baseName = projectName.map {
                "\($0)-\(frameRate.rawValue)fps"
            } ?? "成片-\(formatter.string(from: Date()))-\(frameRate.rawValue)fps"
        case .audio:
            baseName = projectName.map { "\($0)-音频" }
                ?? "音频-\(formatter.string(from: Date()))"
        }
        return try makeOutputURL(
            in: folder,
            baseName: baseName,
            outputKind: outputKind
        )
    }

    /// Filename and folder are independent UI choices, sharing the existing
    /// non-overwriting suffix policy.
    static func makeOutputURL(
        in folder: URL,
        baseName: String,
        outputKind: ExportOutputKind
    ) throws -> URL {
        guard let baseName = exportFileNameComponent(baseName) else {
            throw EditorExportRequestError.invalidOutputURL(baseName)
        }
        try FileManager.default.createDirectory(
            at: folder,
            withIntermediateDirectories: true
        )
        var candidate = folder.appendingPathComponent(
            "\(baseName).\(outputKind.fileExtension)"
        )
        var suffix = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = folder.appendingPathComponent(
                "\(baseName)-\(suffix).\(outputKind.fileExtension)"
            )
            suffix += 1
        }
        return candidate
    }

    private static func exportFileNameComponent(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let forbidden = CharacterSet(charactersIn: "/:")
            .union(.newlines)
            .union(.controlCharacters)
        let pieces = trimmed.components(separatedBy: forbidden)
        let cleaned = pieces
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: "-")
        return cleaned.isEmpty ? nil : cleaned
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
