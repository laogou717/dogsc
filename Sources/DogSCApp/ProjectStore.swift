import AppKit
import Foundation
import RecorderCore

struct RecordingSession: Sendable {
    let packageURL: URL
    let deviceRecordingURL: URL
    let cameraRecordingURL: URL
    let microphoneRecordingURL: URL
    let pointerEventsURL: URL
    let recoveryManifestURL: URL
    let recordingDiagnosticsURL: URL

    init(packageURL: URL) {
        self.packageURL = packageURL
        let mediaURL = packageURL.appendingPathComponent("media", isDirectory: true)
        let eventsURL = packageURL.appendingPathComponent("events", isDirectory: true)
        let recoveryURL = packageURL.appendingPathComponent("recovery", isDirectory: true)
        deviceRecordingURL = mediaURL.appendingPathComponent("device-0001.mov")
        cameraRecordingURL = mediaURL.appendingPathComponent("camera-0001.mov")
        microphoneRecordingURL = mediaURL.appendingPathComponent("microphone.m4a")
        pointerEventsURL = eventsURL.appendingPathComponent("pointer.jsonl")
        recoveryManifestURL = recoveryURL.appendingPathComponent("manifest.json")
        recordingDiagnosticsURL = recoveryURL.appendingPathComponent(
            "recording-performance.jsonl"
        )
    }

    func recordingURL(relativePath: String) -> URL {
        packageURL.appendingPathComponent(relativePath)
    }
}

/// One project-owned copy created from the persistent user asset library.
/// The value is kept until the matching timeline command commits so a failed
/// command can remove exactly the file created for that attempt.
struct ImportedProjectOverlayAsset: Equatable, Sendable {
    let relativePath: String
    let url: URL
}

enum ProjectAssetTransferError: LocalizedError, Equatable, Sendable {
    case unavailableProject
    case invalidImportedAsset

    var errorDescription: String? {
        switch self {
        case .unavailableProject:
            return appLocalized("请先打开一个可编辑项目。")
        case .invalidImportedAsset:
            return appLocalized("项目素材的回滚路径无效。")
        }
    }
}

/// Heavy library-to-project copies never run on MainActor. Regular file-panel
/// and pasteboard imports intentionally keep their existing synchronous API;
/// only the persistent library uses this transaction boundary.
struct EditorProjectAssetTransfer: Sendable {
    private let session: RecordingSession?

    init(session: RecordingSession?) {
        self.session = session
    }

    func importOverlayAsset(
        from sourceURL: URL
    ) async throws -> ImportedProjectOverlayAsset {
        guard let session else {
            throw ProjectAssetTransferError.unavailableProject
        }
        return try await Task.detached(priority: .userInitiated) {
            let imported = try ProjectStore.importOverlayImage(
                from: sourceURL,
                session: session
            )
            return ImportedProjectOverlayAsset(
                relativePath: imported.relativePath,
                url: imported.url
            )
        }.value
    }

    func discard(_ imported: ImportedProjectOverlayAsset) async throws {
        guard let session else {
            throw ProjectAssetTransferError.unavailableProject
        }
        try await Task.detached(priority: .utility) {
            try ProjectStore.discardImportedOverlayAsset(
                imported,
                session: session
            )
        }.value
    }

    func importBackgroundAsset(from sourceURL: URL, isVideo: Bool) async throws -> ImportedProjectOverlayAsset {
        guard let session else { throw ProjectAssetTransferError.unavailableProject }
        return try await Task.detached(priority: .userInitiated) {
            let imported = isVideo
                ? try ProjectStore.importBackgroundVideo(from: sourceURL, session: session)
                : try ProjectStore.importWallpaper(from: sourceURL, session: session)
            return ImportedProjectOverlayAsset(relativePath: imported.relativePath, url: imported.url)
        }.value
    }
}

/// A process-local identity for one open project session. The package URL is
/// deliberately not the identity because saving a project can move that
/// package while delayed autosaves are still waiting to run.
final class ProjectSessionEpoch: NSObject, Sendable {}

struct ProjectSaveReceipt: Equatable, Sendable {
    let committedRevision: Int
}

struct ProjectMoveReceipt: Sendable {
    let session: RecordingSession
    let save: ProjectSaveReceipt
}

struct ProjectLoadResult: Sendable {
    let project: RecorderProject
    let session: RecordingSession
    /// True only when `project.json` could not be read/decoded/validated and
    /// the last known-good rolling snapshot was used instead.
    let recoveredFromPreviousRevision: Bool
    /// Main-track segments dropped because their recording is gone from the
    /// project. Loading repairs them so the editor can still open.
    var droppedSourceSegments: Int = 0
}

enum ProjectRepositoryError: LocalizedError, Equatable, Sendable {
    case sessionMismatch
    case inactiveEpoch
    case projectWriteTimedOut

    var errorDescription: String? {
        switch self {
        case .sessionMismatch:
            return appLocalized("项目保存会话与当前项目不一致。")
        case .inactiveEpoch:
            return appLocalized("项目保存会话已经关闭。")
        case .projectWriteTimedOut:
            return appLocalized("项目文件写入超时，已终止本次保存；素材文件不会受影响。")
        }
    }
}

/// The staging write is deliberately outside ProjectRepository. This gate
/// gives the tiny project.json write a finite terminal state without waiting
/// for a misbehaving filesystem operation to observe Swift task cancellation.
private final class ProjectStageContinuationGate: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<URL, any Error>?
    private var isResolved = false

    init(continuation: CheckedContinuation<URL, any Error>) {
        self.continuation = continuation
    }

    func resolve(_ result: Result<URL, any Error>) {
        lock.lock()
        guard !isResolved else {
            lock.unlock()
            if case let .success(stagedURL) = result {
                ProjectStore.discardStagedProject(at: stagedURL)
            }
            return
        }
        isResolved = true
        let continuation = continuation
        self.continuation = nil
        lock.unlock()
        continuation?.resume(with: result)
    }
}

/// The only ordered writer used by AppModel for project.json.
///
/// Every mutation carries both a monotonically increasing revision and a
/// session epoch. The actor is also the move/delete barrier: once a final flush
/// or invalidation returns, an older autosave can no longer publish bytes for
/// that epoch.
actor ProjectRepository {
    private struct EpochState: Sendable {
        var packagePath: String
        var knownPackagePaths: Set<String>
        var highestCommittedRevision: Int = -1
    }

    private var epochs: [ProjectSessionEpoch: EpochState] = [:]
    // Keep a closed token recognizable as long as any delayed writer holds it.
    private let invalidatedEpochs = NSHashTable<ProjectSessionEpoch>.weakObjects()

    func save(
        project: RecorderProject,
        session: RecordingSession,
        epoch: ProjectSessionEpoch,
        revision: Int
    ) async throws -> ProjectSaveReceipt? {
        try await persist(
            project: project,
            session: session,
            epoch: epoch,
            revision: revision
        )
    }

    /// An explicit actor barrier used before closing or moving a project.
    func flush(
        project: RecorderProject,
        session: RecordingSession,
        epoch: ProjectSessionEpoch,
        revision: Int
    ) async throws -> ProjectSaveReceipt? {
        try await persist(
            project: project,
            session: session,
            epoch: epoch,
            revision: revision
        )
    }

    /// Flushes the final snapshot and moves the package in one actor turn, so
    /// no autosave can target the old package path between those operations.
    func flushAndMove(
        project: RecorderProject,
        session: RecordingSession,
        epoch: ProjectSessionEpoch,
        revision: Int,
        destinationURL: URL
    ) async throws -> ProjectMoveReceipt {
        guard let receipt = try await persist(
            project: project,
            session: session,
            epoch: epoch,
            revision: revision
        ) else {
            throw ProjectRepositoryError.inactiveEpoch
        }

        guard var state = epochs[epoch] else {
            throw ProjectRepositoryError.inactiveEpoch
        }
        let activeSession = RecordingSession(
            packageURL: URL(fileURLWithPath: state.packagePath, isDirectory: true)
        )
        let moved = try ProjectStore.moveSession(activeSession, to: destinationURL)
        state.packagePath = Self.canonicalPath(for: moved)
        state.knownPackagePaths.insert(Self.canonicalPath(for: moved))
        epochs[epoch] = state
        return ProjectMoveReceipt(session: moved, save: receipt)
    }

    func invalidate(epoch: ProjectSessionEpoch) {
        invalidatedEpochs.add(epoch)
        epochs.removeValue(forKey: epoch)
    }

    private func persist(
        project: RecorderProject,
        session: RecordingSession,
        epoch: ProjectSessionEpoch,
        revision: Int
    ) async throws -> ProjectSaveReceipt? {
        guard !invalidatedEpochs.contains(epoch) else { return nil }
        let requestedPath = Self.canonicalPath(for: session)
        let state = epochs[epoch] ?? EpochState(packagePath: requestedPath, knownPackagePaths: [requestedPath])
        guard state.knownPackagePaths.contains(requestedPath) else {
            throw ProjectRepositoryError.sessionMismatch
        }

        guard revision > state.highestCommittedRevision else {
            epochs[epoch] = state
            return ProjectSaveReceipt(
                committedRevision: state.highestCommittedRevision
            )
        }

        let activePackagePath = state.packagePath
        let activeSession = RecordingSession(
            packageURL: URL(fileURLWithPath: activePackagePath, isDirectory: true)
        )

        // SAV-001: validation/encoding and the temporary-file write must not
        // occupy the repository actor. A filesystem or encoder stall in one
        // debounced autosave previously blocked the final flush behind it,
        // leaving both the toolbar and “正在安全写入” phase running forever.
        // Each revision writes a private staging file while the actor remains
        // re-entrant; only the newest still-valid revision may atomically
        // publish that file as project.json.
        epochs[epoch] = state
        let stagedURL: URL
        do {
            stagedURL = try await Self.stageProjectWithTimeout(
                project,
                session: activeSession
            )
        } catch {
            guard let current = epochs[epoch] else { return nil }
            if revision <= current.highestCommittedRevision {
                return ProjectSaveReceipt(committedRevision: current.highestCommittedRevision)
            }
            if current.packagePath != activePackagePath {
                // The move may have removed the staging directory mid-write.
                return try await persist(project: project, session: session, epoch: epoch, revision: revision)
            }
            throw error
        }

        guard !invalidatedEpochs.contains(epoch),
              var currentState = epochs[epoch] else {
            ProjectStore.discardStagedProject(at: stagedURL)
            return nil
        }
        // A package move carries an already-written private staging file with
        // it. Publish or discard it at the current location, even if the old
        // path now belongs to another open project.
        let currentSession = RecordingSession(packageURL: URL(fileURLWithPath: currentState.packagePath, isDirectory: true))
        let stagedRevision = currentSession.packageURL.appendingPathComponent(stagedURL.lastPathComponent)
        defer { ProjectStore.discardStagedProject(at: stagedRevision) }
        guard revision > currentState.highestCommittedRevision else {
            return ProjectSaveReceipt(committedRevision: currentState.highestCommittedRevision)
        }
        if currentState.packagePath != activePackagePath && !FileManager.default.fileExists(atPath: stagedRevision.path) {
            ProjectStore.discardStagedProject(at: stagedURL)
            return try await persist(project: project, session: session, epoch: epoch, revision: revision)
        }
        try ProjectStore.commitStagedProject(at: stagedRevision, session: currentSession)
        currentState.highestCommittedRevision = revision
        epochs[epoch] = currentState
        return ProjectSaveReceipt(committedRevision: revision)
    }

    private nonisolated static func stageProjectWithTimeout(
        _ project: RecorderProject,
        session: RecordingSession
    ) async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            let gate = ProjectStageContinuationGate(continuation: continuation)
            DispatchQueue.global(qos: .utility).async {
                gate.resolve(Result {
                    try ProjectStore.stageProject(project, session: session)
                })
            }
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 10) {
                gate.resolve(.failure(ProjectRepositoryError.projectWriteTimedOut))
            }
        }
    }

    private static func canonicalPath(for session: RecordingSession) -> String {
        session.packageURL.standardizedFileURL.path
    }
}

struct RecoveryManifestInfo: Equatable, Sendable {
    let state: String
    let fileSize: Int64
}

private struct RecoveryManifest: Codable, Sendable {
    var state: String
    var updatedAt: String
    var screenFile: String
    var targetFrameRate: Int
    var containerMode: String
    var fragmentIntervalSeconds: Int
    var screenFileSize: Int64?
    var receivedFrames: Int?
    var deliveredFrames: Int?
    var estimatedDroppedFrames: Int?
    var actualFramesPerSecond: Double?
    var maxFrameInterval: Double?
    var frameIntervalP50: Double?
    var frameIntervalP95: Double?
    var frameIntervalP99: Double?
    var frameIntervalsOver25Milliseconds: Int?
    var frameIntervalsOver33Milliseconds: Int?
    var frameIntervalsOver50Milliseconds: Int?
    var maximumConsecutiveFrameIntervalsOver33Milliseconds: Int?
    var cameraDiagnostics: CameraCaptureDiagnostics?
    var systemAudioDiagnostics: AudioCaptureDiagnostics?
    var microphoneDiagnostics: AudioCaptureDiagnostics?
    var performanceDiagnosticsFile: String?
    var performanceSummary: RecordingPerformanceSummary?
}

private struct ProjectVersionHeader: Decodable {
    var version: Int?
}

struct RecentProjectSummary: Identifiable, Equatable, Sendable {
    let url: URL
    let title: String
    let hasAuthoredTitle: Bool
    let isEdited: Bool

    var id: String { url.path }

    var displayTitle: String {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if hasAuthoredTitle, !trimmed.isEmpty {
            return trimmed
        }
        let base = url.deletingPathExtension().lastPathComponent
        if base.hasPrefix("录屏-") || base.hasPrefix("录制-") {
            let stripped = base.replacingOccurrences(of: "录屏-", with: "").replacingOccurrences(of: "录制-", with: "")
            let components = stripped.split(separator: "-")
            if components.count >= 5 {
                return "录屏 \(components[1])-\(components[2]) \(components[3]):\(components[4])"
            }
        }
        return trimmed.isEmpty ? base : trimmed
    }

    var menuTitle: String {
        let statusTag = appLocalized(isEdited ? "已编辑" : "未编辑")
        let iconPrefix = isEdited ? "🎬" : "📄"
        return "\(iconPrefix) \(displayTitle) (\(statusTag))"
    }
}

/// One source of truth for automatic recording names. The human-facing title
/// and package filename intentionally share this value so Finder, the editor
/// and the Dock never describe the same take differently.
enum RecordingProjectNaming {
    static func title(
        for configuration: CaptureConfiguration,
        createdAt: Date
    ) -> String {
        "\(sourceName(for: configuration)) · \(timestamp(createdAt))"
    }

    static func isAutomaticTitle(
        _ title: String,
        configuration: CaptureConfiguration,
        createdAt: Date
    ) -> Bool {
        title.trimmingCharacters(in: .whitespacesAndNewlines)
            == self.title(for: configuration, createdAt: createdAt)
    }

    private static func sourceName(
        for configuration: CaptureConfiguration
    ) -> String {
        switch configuration.source {
        case .display:
            return "屏幕"
        case .window:
            return firstNonempty(
                configuration.selectedApplicationName,
                configuration.windowName
            ) ?? "窗口"
        case .area:
            return "区域"
        case .device:
            return firstNonempty(configuration.deviceName) ?? "iOS 设备"
        }
    }

    private static func firstNonempty(_ values: String?...) -> String? {
        values.lazy
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty }
    }

    private static func timestamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.dateFormat = "yyyy-MM-dd HH-mm-ss"
        return formatter.string(from: date)
    }
}

enum ProjectStore {
    private static let recentProjectsDefaultsKey = "cn.laogou.dogsc.recent-project-paths"
    @MainActor private static var systemRecentProjectsSynchronizationToken: UInt64 = 0
    private static var defaults: UserDefaults {
        UserDefaults(suiteName: "cn.laogou.dogsc") ?? .standard
    }

    static func createSession(
        preferredTitle: String? = nil,
        createdAt: Date = Date()
    ) throws -> RecordingSession {
        let projectsFolder = workingProjectsFolder

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.dateFormat = "yyyy-MM-dd-HH-mm-ss"
        let fallbackName = "录屏-\(formatter.string(from: createdAt))"
        let baseName = sanitizedPackageBaseName(preferredTitle) ?? fallbackName
        var packageURL = projectsFolder
            .appendingPathComponent("\(baseName).dogscproject", isDirectory: true)
        var suffix = 2
        while FileManager.default.fileExists(atPath: packageURL.path) {
            packageURL = projectsFolder
                .appendingPathComponent("\(baseName)-\(suffix).dogscproject", isDirectory: true)
            suffix += 1
        }
        let mediaURL = packageURL.appendingPathComponent("media", isDirectory: true)
        let eventsURL = packageURL.appendingPathComponent("events", isDirectory: true)
        let recoveryURL = packageURL.appendingPathComponent("recovery", isDirectory: true)

        try FileManager.default.createDirectory(at: mediaURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: eventsURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: recoveryURL, withIntermediateDirectories: true)

        return RecordingSession(packageURL: packageURL)
    }

    /// User-configurable destination for saved projects. When unset, the
    /// default is 影片/DogSC/项目.
    static let projectsFolderDefaultsKey = "cn.laogou.dogsc.projects-folder"

    static var savedProjectsFolder: URL {
        if let customPath = defaults.string(forKey: projectsFolderDefaultsKey),
           !customPath.isEmpty,
           FileManager.default.fileExists(atPath: customPath) {
            return URL(fileURLWithPath: customPath, isDirectory: true)
        }
        let movies = FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return movies
            .appendingPathComponent("DogSC", isDirectory: true)
            .appendingPathComponent("项目", isDirectory: true)
    }

    static func setSavedProjectsFolder(_ url: URL) throws {
        let folder = url.standardizedFileURL
        try FileManager.default.createDirectory(
            at: folder,
            withIntermediateDirectories: true
        )
        defaults.set(folder.path, forKey: projectsFolderDefaultsKey)
    }

    /// Fresh recordings are first finalized in the private recovery area and
    /// are then archived here before the editor opens. Automatic archival must
    /// never replace an existing project merely because two titles match.
    static func automaticSaveDestination(
        for project: RecorderProject,
        session: RecordingSession
    ) throws -> URL {
        let folder = savedProjectsFolder
        try FileManager.default.createDirectory(
            at: folder,
            withIntermediateDirectories: true
        )

        let authoredTitle = project.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let fallbackTitle = session.packageURL.deletingPathExtension().lastPathComponent
        let preferredTitle = authoredTitle.isEmpty || authoredTitle == "未命名录制"
            ? fallbackTitle
            : authoredTitle
        let invalid = CharacterSet(charactersIn: "/:")
        let sanitized = preferredTitle
            .components(separatedBy: invalid)
            .joined(separator: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let baseName = sanitized.isEmpty ? fallbackTitle : sanitized

        var destination = folder.appendingPathComponent(
            "\(baseName).dogscproject",
            isDirectory: true
        )
        var suffix = 2
        while FileManager.default.fileExists(atPath: destination.path) {
            destination = folder.appendingPathComponent(
                "\(baseName)-\(suffix).dogscproject",
                isDirectory: true
            )
            suffix += 1
        }
        return destination
    }

    static func moveSession(_ session: RecordingSession, to destinationURL: URL) throws -> RecordingSession {
        let destination = destinationURL.pathExtension == "dogscproject"
            ? destinationURL
            : destinationURL.appendingPathExtension("dogscproject")
        let fm = FileManager.default
        let source = session.packageURL.standardizedFileURL.resolvingSymlinksInPath()
        guard try source.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true else {
            throw CocoaError(.fileReadUnknown)
        }
        let target = destination.standardizedFileURL.resolvingSymlinksInPath()
        guard !ExportFileTransaction.collides(outputURL: target, inputURLs: [source]) else { return session }
        let exists = fm.fileExists(atPath: target.path)
        // Reject both directions before creating folders or moving anything
        // to the Trash, including paths reached through aliases.
        var relationship: FileManager.URLRelationship = .other
        if exists {
            try fm.getRelationship(&relationship, ofDirectoryAt: target, toItemAt: source)
        }
        guard relationship != .contains, !target.path.hasPrefix(source.path + "/") else {
            throw CocoaError(.fileWriteInvalidFileName)
        }
        let parent = target.deletingLastPathComponent()
        try fm.createDirectory(at: parent, withIntermediateDirectories: true)
        try fm.getRelationship(&relationship, ofDirectoryAt: source, toItemAt: parent)
        guard relationship == .other else { throw CocoaError(.fileWriteInvalidFileName) }

        var trashed: NSURL?
        if exists { try fm.trashItem(at: destination, resultingItemURL: &trashed) }
        do {
            try fm.moveItem(at: session.packageURL, to: destination)
        } catch {
            if let trashed, !fm.fileExists(atPath: destination.path) {
                try fm.moveItem(at: trashed as URL, to: destination)
            }
            throw error
        }
        return RecordingSession(packageURL: destination)
    }

    static func isWorkingProject(_ packageURL: URL) -> Bool {
        packageURL.standardizedFileURL.path.hasPrefix(
            workingProjectsFolder.standardizedFileURL.path + "/"
        )
    }


    /// Builds one revision in a private file beside project.json. The caller
    /// decides whether that revision is still current before publishing it.
    static func stageProject(_ project: RecorderProject, session: RecordingSession) throws -> URL {
        try ProjectValidator.validate(project)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(project)
        let stagedURL = session.packageURL.appendingPathComponent(
            ".project-save-\(UUID().uuidString).json.tmp"
        )
        try data.write(to: stagedURL, options: .atomic)
        return stagedURL
    }

    static func commitStagedProject(at stagedURL: URL, session: RecordingSession) throws {
        let destination = session.packageURL.appendingPathComponent("project.json")
        if FileManager.default.fileExists(atPath: destination.path) {
            // Preserve one known-good revision before publishing the next one.
            // A corrupt/truncated primary must never replace an older valid
            // recovery snapshot merely because autosave runs after opening it.
            if let currentData = try? Data(contentsOf: destination),
               (try? decodeProjectData(currentData)) != nil {
                let previousURL = session.packageURL.appendingPathComponent(
                    "project.previous.json"
                )
                try currentData.write(to: previousURL, options: .atomic)
            }
            _ = try FileManager.default.replaceItemAt(
                destination,
                withItemAt: stagedURL,
                backupItemName: nil,
                options: .usingNewMetadataOnly
            )
        } else {
            try FileManager.default.moveItem(at: stagedURL, to: destination)
        }
    }

    static func discardStagedProject(at stagedURL: URL) {
        try? FileManager.default.removeItem(at: stagedURL)
    }

    static func savePointerEvents(_ events: [PointerEventRecord], session: RecordingSession) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let fileManager = FileManager.default
        let destination = session.pointerEventsURL
        try fileManager.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let stagedURL = destination.deletingLastPathComponent().appendingPathComponent(
            ".pointer-save-\(UUID().uuidString).jsonl.tmp"
        )
        defer { try? fileManager.removeItem(at: stagedURL) }
        guard fileManager.createFile(atPath: stagedURL.path, contents: nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        let handle = try FileHandle(forWritingTo: stagedURL)
        var handleIsOpen = true
        defer {
            if handleIsOpen { try? handle.close() }
        }

        // Long recordings can contain hundreds of thousands of events. Keep a
        // bounded write buffer instead of retaining the complete JSONL file in
        // memory, while avoiding one filesystem write per event.
        let flushThreshold = 1_048_576
        var buffer = Data()
        buffer.reserveCapacity(flushThreshold + 1_024)
        for (index, event) in events.enumerated() {
            if index.isMultiple(of: 4_096) { try Task.checkCancellation() }
            buffer.append(try encoder.encode(event))
            buffer.append(0x0A)
            if buffer.count >= flushThreshold {
                try handle.write(contentsOf: buffer)
                buffer.removeAll(keepingCapacity: true)
            }
        }
        if !buffer.isEmpty {
            try handle.write(contentsOf: buffer)
        }
        try Task.checkCancellation()
        try handle.synchronize()
        try handle.close()
        handleIsOpen = false

        if fileManager.fileExists(atPath: destination.path) {
            _ = try fileManager.replaceItemAt(
                destination,
                withItemAt: stagedURL,
                backupItemName: nil,
                options: .usingNewMetadataOnly
            )
        } else {
            try fileManager.moveItem(at: stagedURL, to: destination)
        }
    }


    static func loadPointerEvents(
        project: RecorderProject,
        session: RecordingSession
    ) throws -> [PointerEventRecord] {
        guard let relativePath = project.media?.pointerEvents?.relativePath else { return [] }
        guard let url = resolve(relativePath: relativePath, session: session) else {
            throw CocoaError(.fileNoSuchFile)
        }
        return try decodePointerEvents(at: url)
    }

    static func decodePointerEvents(at url: URL) throws -> [PointerEventRecord] {
        let data = try Data(contentsOf: url)
        guard !data.isEmpty else { return [] }
        if let records = PointerEventJSONLScanner.decode(data) { return records }

        // JSONL's previous map decoded every line through a separately allocated
        // Data value. Long recordings can contain hundreds of thousands of
        // events; assemble one JSON array buffer and decode the complete track
        // once instead of creating that many temporary objects.
        var arrayData = Data()
        arrayData.reserveCapacity(data.count + 2)
        arrayData.append(0x5B) // [
        var lineStart = data.startIndex
        var wroteElement = false
        func appendLine(endingAt lineEnd: Data.Index) {
            guard lineStart < lineEnd else { return }
            if wroteElement { arrayData.append(0x2C) } // ,
            arrayData.append(contentsOf: data[lineStart..<lineEnd])
            wroteElement = true
        }
        var index = data.startIndex
        while index < data.endIndex {
            if data[index] == 0x0A {
                appendLine(endingAt: index)
                lineStart = data.index(after: index)
            }
            index = data.index(after: index)
        }
        appendLine(endingAt: data.endIndex)
        arrayData.append(0x5D) // ]
        let decoder = JSONDecoder()
        return try decoder.decode([PointerEventRecord].self, from: arrayData)
    }

    static func writeRecoveryManifest(
        state: String,
        session: RecordingSession,
        frameRate: OutputFrameRate,
        measurement: FrameRateMeasurement? = nil,
        cameraDiagnostics: CameraCaptureDiagnostics? = nil,
        systemAudioDiagnostics: AudioCaptureDiagnostics? = nil,
        microphoneDiagnostics: AudioCaptureDiagnostics? = nil,
        performanceSummary: RecordingPerformanceSummary? = nil,
        screenRelativePath: String = "media/screen-0001.mp4"
    ) throws {
        var screenFileSize: Int64?
        if let attributes = try? FileManager.default.attributesOfItem(
            atPath: session.packageURL.appendingPathComponent(screenRelativePath).path
        ), let size = attributes[.size] as? NSNumber {
            screenFileSize = size.int64Value
        }
        let manifest = RecoveryManifest(
            state: state,
            updatedAt: ISO8601DateFormatter().string(from: Date()),
            screenFile: screenRelativePath,
            targetFrameRate: frameRate.rawValue,
            containerMode: "fragmented-mp4",
            fragmentIntervalSeconds: 2,
            screenFileSize: screenFileSize,
            receivedFrames: measurement?.receivedFrames,
            deliveredFrames: measurement?.deliveredFrames,
            estimatedDroppedFrames: measurement?.estimatedDroppedFrames,
            actualFramesPerSecond: measurement?.actualFramesPerSecond,
            maxFrameInterval: measurement?.maxFrameInterval,
            frameIntervalP50: measurement?.intervalDiagnostics.p50,
            frameIntervalP95: measurement?.intervalDiagnostics.p95,
            frameIntervalP99: measurement?.intervalDiagnostics.p99,
            frameIntervalsOver25Milliseconds: measurement?
                .intervalDiagnostics.over25Milliseconds,
            frameIntervalsOver33Milliseconds: measurement?
                .intervalDiagnostics.over33Milliseconds,
            frameIntervalsOver50Milliseconds: measurement?
                .intervalDiagnostics.over50Milliseconds,
            maximumConsecutiveFrameIntervalsOver33Milliseconds: measurement?
                .intervalDiagnostics.maximumConsecutiveOver33Milliseconds,
            cameraDiagnostics: cameraDiagnostics,
            systemAudioDiagnostics: systemAudioDiagnostics,
            microphoneDiagnostics: microphoneDiagnostics,
            performanceDiagnosticsFile: performanceSummary == nil
                ? nil : "recovery/recording-performance.jsonl",
            performanceSummary: performanceSummary
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(manifest)
        try data.write(to: session.recoveryManifestURL, options: .atomic)
    }

    static func recoveryManifest(at packageURL: URL) -> RecoveryManifestInfo? {
        let session = RecordingSession(packageURL: packageURL)
        guard let data = try? Data(contentsOf: session.recoveryManifestURL),
              let manifest = try? JSONDecoder().decode(RecoveryManifest.self, from: data),
              !manifest.state.isEmpty,
              let screenURL = resolve(relativePath: manifest.screenFile, session: session)
        else { return nil }
        let attributes = try? FileManager.default.attributesOfItem(atPath: screenURL.path)
        let fileSize = (attributes?[.size] as? NSNumber)?.int64Value ?? 0
        return RecoveryManifestInfo(
            state: manifest.state,
            fileSize: fileSize
        )
    }

    /// Appends one low-frequency sample without rewriting the growing history.
    /// This runs from the two-second recovery heartbeat, never a media callback.
    static func appendRecordingPerformanceSample(
        _ sample: RecordingPerformanceSample,
        session: RecordingSession
    ) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        var line = try encoder.encode(sample)
        line.append(0x0A)
        let fileManager = FileManager.default
        if !fileManager.fileExists(atPath: session.recordingDiagnosticsURL.path) {
            try line.write(to: session.recordingDiagnosticsURL, options: .atomic)
            return
        }
        let handle = try FileHandle(forWritingTo: session.recordingDiagnosticsURL)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: line)
    }

    static func isRecoverableProject(at packageURL: URL) -> Bool {
        guard let manifest = recoveryManifest(at: packageURL) else { return false }
        let recoverableStates: Set<String> = ["recording", "paused", "failed"]
        return recoverableStates.contains(manifest.state) && manifest.fileSize > 1_024
    }

    static func recoverableProjectURLs(
        limit: Int = 8,
        recentCandidates: [URL]? = nil
    ) -> [URL] {
        (workingProjectURLs() + (recentCandidates ?? recentProjectURLs(limit: 50)))
            .filter(isRecoverableProject(at:))
            .prefix(max(limit, 0))
            .map { $0 }
    }

    static func importWallpaper(from sourceURL: URL, session: RecordingSession) throws -> (relativePath: String, url: URL) {
        try importImageAsset(
            from: sourceURL,
            prefix: "wallpaper",
            session: session
        )
    }

    static func importBackgroundVideo(
        from sourceURL: URL,
        session: RecordingSession
    ) throws -> (relativePath: String, url: URL) {
        try importImageAsset(
            from: sourceURL,
            prefix: "background-video",
            session: session
        )
    }

    static func importOverlayImage(
        from sourceURL: URL,
        session: RecordingSession
    ) throws -> (relativePath: String, url: URL) {
        try importImageAsset(from: sourceURL, prefix: "overlay", session: session)
    }

    static func importOverlayImage(
        data: Data,
        fileExtension: String,
        session: RecordingSession
    ) throws -> (relativePath: String, url: URL) {
        let assetsURL = session.packageURL.appendingPathComponent("assets", isDirectory: true)
        try FileManager.default.createDirectory(at: assetsURL, withIntermediateDirectories: true)
        let safeExtension = fileExtension.lowercased() == "jpg" ? "jpg" : "png"
        let filename = "overlay-\(UUID().uuidString).\(safeExtension)"
        let destinationURL = assetsURL.appendingPathComponent(filename)
        try data.write(to: destinationURL, options: .atomic)
        return ("assets/\(filename)", destinationURL)
    }

    static func discardImportedOverlayAsset(
        _ imported: ImportedProjectOverlayAsset,
        session: RecordingSession
    ) throws {
        let assetsURL = session.packageURL
            .appendingPathComponent("assets", isDirectory: true)
            .standardizedFileURL
        let destinationURL = session.packageURL
            .appendingPathComponent(imported.relativePath)
            .standardizedFileURL
        let components = imported.relativePath.split(separator: "/")
        guard !imported.relativePath.hasPrefix("/"),
              components.count == 2,
              components.first == "assets",
              destinationURL.deletingLastPathComponent() == assetsURL,
              destinationURL == imported.url.standardizedFileURL else {
            throw ProjectAssetTransferError.invalidImportedAsset
        }
        guard FileManager.default.fileExists(atPath: destinationURL.path) else {
            return
        }
        try FileManager.default.removeItem(at: destinationURL)
    }

    private static func importImageAsset(
        from sourceURL: URL,
        prefix: String,
        session: RecordingSession
    ) throws -> (relativePath: String, url: URL) {
        let assetsURL = session.packageURL.appendingPathComponent("assets", isDirectory: true)
        try FileManager.default.createDirectory(at: assetsURL, withIntermediateDirectories: true)
        let fileExtension = sourceURL.pathExtension.isEmpty
            ? "png"
            : sourceURL.pathExtension.lowercased()
        let filename = "\(prefix)-\(UUID().uuidString).\(fileExtension)"
        let destinationURL = assetsURL.appendingPathComponent(filename)
        try FileManager.default.copyItem(at: sourceURL, to: destinationURL)
        return ("assets/\(filename)", destinationURL)
    }

    static func resolve(relativePath: String?, session: RecordingSession) -> URL? {
        guard let relativePath, !relativePath.isEmpty else { return nil }
        guard !relativePath.hasPrefix("/"),
              !relativePath.split(separator: "/").contains("..") else {
            return nil
        }

        let packageURL = session.packageURL.standardizedFileURL.resolvingSymlinksInPath()
        let candidate = packageURL
            .appendingPathComponent(relativePath)
            .standardizedFileURL
            .resolvingSymlinksInPath()
        let packagePrefix = packageURL.path.hasSuffix("/")
            ? packageURL.path
            : packageURL.path + "/"
        guard candidate.path.hasPrefix(packagePrefix) else { return nil }
        return FileManager.default.fileExists(atPath: candidate.path) ? candidate : nil
    }

    /// Imported references may deliberately point outside the package. Keep
    /// the strict package-relative resolver above unchanged for legacy uses.
    static func resolveMediaPath(_ path: String, session: RecordingSession) -> URL? {
        if path.hasPrefix("/") {
            let url = URL(fileURLWithPath: path).standardizedFileURL
            return FileManager.default.isReadableFile(atPath: url.path) ? url : nil
        }
        return resolve(relativePath: path, session: session)
    }

    /// Repairs stale package-relative declarations without ever consulting an
    /// external directory. A relocation is accepted only when exactly one
    /// regular file with the same basename exists below the allowed package
    /// folders; ambiguous matches remain unresolved for explicit user action.
    static func relocatedRelativePath(
        for stalePath: String,
        session: RecordingSession,
        allowedDirectories: [String]
    ) -> String? {
        if resolve(relativePath: stalePath, session: session) != nil {
            return stalePath
        }
        let filename = URL(fileURLWithPath: stalePath).lastPathComponent
        guard !filename.isEmpty, filename != ".", filename != ".." else { return nil }
        let fileManager = FileManager.default
        let packageURL = session.packageURL.standardizedFileURL
        let packagePrefix = packageURL.path + "/"
        var matches = Set<String>()

        for directory in allowedDirectories where !directory.isEmpty {
            guard !directory.contains("/"), directory != ".", directory != ".." else {
                continue
            }
            let root = packageURL.appendingPathComponent(directory, isDirectory: true)
            guard let enumerator = fileManager.enumerator(
                at: root,
                includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
                options: [.skipsHiddenFiles, .skipsPackageDescendants]
            ) else { continue }
            for case let candidate as URL in enumerator where candidate.lastPathComponent == filename {
                let values = try? candidate.resourceValues(
                    forKeys: [.isRegularFileKey, .isSymbolicLinkKey]
                )
                guard values?.isRegularFile == true,
                      values?.isSymbolicLink != true else { continue }
                let standardized = candidate.standardizedFileURL
                guard standardized.path.hasPrefix(packagePrefix) else { continue }
                matches.insert(String(standardized.path.dropFirst(packagePrefix.count)))
                if matches.count > 1 { return nil }
            }
        }
        return matches.first
    }

    /// Collects the media of imported recordings that the project no longer
    /// references.
    ///
    /// Removing a recording only edits the model, because undo (and redo)
    /// must be able to bring its files back. Opening a package is the first
    /// moment at which no edit history can reach those files again, so the
    /// collection happens here rather than on save or on removal.
    ///
    /// Membership is decided on the encoded project, not on a hand-written
    /// list of path fields: an import also relocates wallpapers, stickers,
    /// audio and inserted videos into its directory, and a forgotten field
    /// would delete media that is still on the timeline.
    @discardableResult
    static func collectUnusedImportedSources(
        project: RecorderProject,
        session: RecordingSession
    ) -> Int {
        let fm = FileManager.default
        let package = session.packageURL.standardizedFileURL.resolvingSymlinksInPath()
        let root = package.appendingPathComponent("Sources", isDirectory: true)
        guard root.resolvingSymlinksInPath().path == root.path,
              let names = try? fm.contentsOfDirectory(atPath: root.path), !names.isEmpty,
              let packageFiles = try? fm.contentsOfDirectory(atPath: package.path) else { return 0 }

        // A rolling snapshot (or a pre-migration copy) can still be opened
        // after this visit. Preserve its imported files for as long as it exists.
        let snapshots = packageFiles.filter {
            $0 == "project.previous.json" || ($0.hasPrefix("project-v") && $0.hasSuffix("-before-migration.json"))
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        guard let data = try? encoder.encode(project), let current = String(data: data, encoding: .utf8) else { return 0 }
        var references = [current.lowercased()]
        for name in snapshots {
            guard let data = try? Data(contentsOf: package.appendingPathComponent(name)),
                  let json = try? JSONSerialization.jsonObject(with: data),
                  JSONSerialization.isValidJSONObject(json),
                  let normalized = try? JSONSerialization.data(withJSONObject: json, options: [.withoutEscapingSlashes]),
                  let text = String(data: normalized, encoding: .utf8) else { return 0 }
            references.append(text.lowercased())
        }
        var collected = 0
        for name in names {
            // `.import-*` is a staging directory an interrupted import left
            // behind; it is never referenced by a saved project.
            let isStaging = name.hasPrefix(".import-")
            guard isStaging || UUID(uuidString: name) != nil else { continue }
            let prefix = "sources/\(name.lowercased())/"
            guard !references.contains(where: { $0.contains(prefix) }) else { continue }
            let directory = root.appendingPathComponent(name, isDirectory: true)
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDirectory),
                  isDirectory.boolValue else { continue }
            // An import into this package could in principle still be staging
            // files while it is being reopened; only cold leftovers go.
            if isStaging {
                let modified = (try? directory.resourceValues(forKeys: [.contentModificationDateKey]))?
                    .contentModificationDate ?? .distantPast
                guard modified.timeIntervalSinceNow < -3_600 else { continue }
            }
            if (try? FileManager.default.removeItem(at: directory)) != nil { collected += 1 }
        }
        return collected
    }

    static func loadProject(at packageURL: URL, readOnly: Bool = false) throws -> ProjectLoadResult {
        let session = RecordingSession(packageURL: packageURL)
        let projectURL = packageURL.appendingPathComponent("project.json")
        var primaryFailure: (any Error)?
        do {
            let data = try Data(contentsOf: projectURL)
            let sourceVersion = (
                try? JSONDecoder().decode(ProjectVersionHeader.self, from: data).version
            ) ?? 1

            // 先保护原始字节再尝试解码：若未来 schema 不兼容导致 decode 失败，
            // 备份必须已经落盘，否则旧项目将完全无法恢复。
            if !readOnly, sourceVersion < ProjectSchema.currentVersion {
                let backupURL = packageURL.appendingPathComponent(
                    "project-v\(sourceVersion)-before-migration.json"
                )
                try writeMigrationBackupIfNeeded(data, to: backupURL)
            }
            let decoded = try decodeProjectData(data)
            return ProjectLoadResult(
                project: decoded.project,
                session: session,
                recoveredFromPreviousRevision: false,
                droppedSourceSegments: decoded.droppedSourceSegments
            )
        } catch let schemaError as ProjectSchemaError {
            // A project written by a newer DogSC is not corruption. Falling
            // back to an older snapshot would let the current app later
            // overwrite unknown future fields, exactly what the schema guard
            // exists to prevent.
            if case .unsupportedFutureVersion = schemaError {
                throw schemaError
            }
            primaryFailure = schemaError
        } catch {
            primaryFailure = error
        }

        let previousURL = packageURL.appendingPathComponent("project.previous.json")
        if let previousData = try? Data(contentsOf: previousURL),
           let previous = try? decodeProjectData(previousData) {
            return ProjectLoadResult(
                project: previous.project,
                session: session,
                recoveredFromPreviousRevision: true,
                droppedSourceSegments: previous.droppedSourceSegments
            )
        }
        throw primaryFailure ?? CocoaError(.fileReadCorruptFile)
    }

    private static func decodeProjectData(
        _ data: Data
    ) throws -> (project: RecorderProject, droppedSourceSegments: Int) {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        var project = try decoder.decode(RecorderProject.self, from: data)
        // EDT-072: Rive (.riv) and DogSC Motion JSON (.dmotion) are retired;
        // their clips and bin entries would only draw empty boxes. The file
        // on disk changes at the next save, like any edit.
        let retired: (String) -> Bool = { ["riv", "dmotion"].contains(URL(fileURLWithPath: $0).pathExtension.lowercased()) }
        project.timeline.animationClips.removeAll { retired($0.sourcePath) }
        project.timeline.mediaAssets.removeAll { retired($0.path) }
        // Validation rejects a main-track segment whose recording is missing,
        // so the repair must run before it: a dangling reference must not
        // make an otherwise healthy project unopenable.
        let repaired = RecordingSourceEditing.droppingMissingSources(from: project)
        project = repaired.project
        try ProjectValidator.validate(project)
        return (project, repaired.droppedSegments)
    }

    private static func writeMigrationBackupIfNeeded(_ data: Data, to backupURL: URL) throws {
        let fileManager = FileManager.default
        guard !fileManager.fileExists(atPath: backupURL.path) else { return }
        let temporaryURL = backupURL.deletingLastPathComponent().appendingPathComponent(
            ".migration-backup-\(UUID().uuidString).tmp"
        )
        defer { try? fileManager.removeItem(at: temporaryURL) }

        // Write complete bytes first, then atomically publish them with a
        // same-volume rename. If two opens race, the first completed backup
        // wins and the later one is intentionally discarded.
        try data.write(to: temporaryURL, options: .atomic)
        do {
            try fileManager.moveItem(at: temporaryURL, to: backupURL)
        } catch {
            guard fileManager.fileExists(atPath: backupURL.path) else { throw error }
        }
    }

    @MainActor
    static func registerRecentProject(_ packageURL: URL) {
        let path = packageURL.standardizedFileURL.path
        var paths = defaults.stringArray(forKey: recentProjectsDefaultsKey) ?? []
        paths.removeAll { rememberedPath in
            let rememberedURL = URL(
                fileURLWithPath: rememberedPath,
                isDirectory: true
            ).standardizedFileURL
            return !FileManager.default.fileExists(
                atPath: rememberedURL.appendingPathComponent("project.json").path
            )
        }
        paths.removeAll { URL(fileURLWithPath: $0).standardizedFileURL.path == path }
        paths.insert(path, at: 0)
        defaults.set(Array(paths.prefix(20)), forKey: recentProjectsDefaultsKey)

        // Opening/creating a project is the authoritative recency event. The
        // Rebuild once after the current transition; the menu itself remains
        // read-only and never guesses recency from package modification dates.
        scheduleSystemRecentProjectsSynchronization()
    }

    @MainActor
    static func forgetRecentProject(_ packageURL: URL) {
        let forgottenPath = packageURL.standardizedFileURL.path
        var paths = defaults.stringArray(forKey: recentProjectsDefaultsKey) ?? []
        paths.removeAll {
            URL(fileURLWithPath: $0).standardizedFileURL.path == forgottenPath
        }
        defaults.set(Array(paths.prefix(20)), forKey: recentProjectsDefaultsKey)
        scheduleSystemRecentProjectsSynchronization()
    }

    /// LaunchServices owns the Dock's recent-file section and may perform slow
    /// bookmark work while rebuilding it. Never put that work between a
    /// completed recording and `phase = .editor`; the app-owned recent list is
    /// already updated synchronously, while the system list can safely follow
    /// after the editor has been presented.
    @MainActor
    private static func scheduleSystemRecentProjectsSynchronization() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
            synchronizeSystemRecentProjects()
        }
    }

    /// The Dock's file-icon section is owned by macOS, independently from the
    /// app's own project catalog. Rebuild that list from valid project packages
    /// so deleted paths, old test packages and rename aliases cannot survive as
    /// stale or duplicate Dock entries. `noteNewRecentDocumentURL` promotes each
    /// URL to the front, so publish oldest first and the newest one last.
    @MainActor
    @discardableResult
    static func synchronizeSystemRecentProjects(limit: Int = 20) -> Bool {
        let validProjects = recentProjectURLs(limit: limit)
        let controller = NSDocumentController.shared
        // `NSDocumentController` may expose fewer Dock recent-document slots
        // than DogSC keeps in its own project history (five on current macOS).
        // Compare and publish only that visible prefix; otherwise the capped
        // result is mistaken for a failed rebuild and the fallback republishes
        // the list in the opposite order, leaving the oldest projects visible.
        let publishedProjects = Array(validProjects.prefix(controller.maximumRecentDocumentCount))
        systemRecentProjectsSynchronizationToken &+= 1
        let requestedSynchronization = systemRecentProjectsSynchronizationToken

        // `clearRecentDocuments` persists through LaunchServices rather than
        // completing synchronously. Publishing the newest project in the same
        // run-loop turn races that clear; field evidence showed exactly the
        // first URL missing from the resulting sfl4 while the following four
        // survived. Split clearing and publication into two phases. The token
        // prevents an older delayed phase from overwriting a newer recency
        // event.
        controller.clearRecentDocuments(nil)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            guard systemRecentProjectsSynchronizationToken == requestedSynchronization else {
                return
            }
            for projectURL in publishedProjects.reversed() {
                controller.noteNewRecentDocumentURL(projectURL)
            }
        }
        return true
    }

    static func recentProjectURLs(limit: Int = 8) -> [URL] {
        let remembered = (defaults.stringArray(forKey: recentProjectsDefaultsKey) ?? [])
            .map { URL(fileURLWithPath: $0, isDirectory: true).standardizedFileURL }
            .filter {
                FileManager.default.fileExists(
                    atPath: $0.appendingPathComponent("project.json").path
                )
            }
        let projectsFolder = savedProjectsFolder
        let keys: Set<URLResourceKey> = [.contentModificationDateKey, .isDirectoryKey]
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: projectsFolder,
            includingPropertiesForKeys: Array(keys),
            options: [.skipsHiddenFiles]
        )) ?? []

        let discovered = urls
            .filter { $0.pathExtension == "dogscproject" }
            .sorted {
                let left = (try? $0.resourceValues(forKeys: keys).contentModificationDate) ?? .distantPast
                let right = (try? $1.resourceValues(forKeys: keys).contentModificationDate) ?? .distantPast
                return left > right
            }
        var seen = Set<String>()
        return (remembered + discovered)
            .filter { seen.insert($0.standardizedFileURL.path).inserted }
            .prefix(max(limit, 0))
            .map { $0 }
    }

    static func projectSummary(at packageURL: URL) -> RecentProjectSummary {
        let projectURL = packageURL.appendingPathComponent("project.json")
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let data = try? Data(contentsOf: projectURL),
              let project = try? decoder.decode(RecorderProject.self, from: data) else {
            let base = packageURL.deletingPathExtension().lastPathComponent
            return RecentProjectSummary(
                url: packageURL,
                title: base,
                hasAuthoredTitle: false,
                isEdited: false
            )
        }
        let rawTitle = project.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let hasAutomaticSourceTitle = RecordingProjectNaming.isAutomaticTitle(
            rawTitle,
            configuration: project.capture,
            createdAt: project.createdAt
        )
        let hasAuthoredTitle = !rawTitle.isEmpty
            && rawTitle != "未命名录制"
            && !rawTitle.hasPrefix("录屏-")
            && !rawTitle.hasPrefix("录制-")
            && !hasAutomaticSourceTitle
        let isEdited = hasAuthoredTitle
            || project.timeline.sourceSequence != .fullRecording
            || !project.zoomAnimations.isEmpty
            || !project.timeline.screenMotionClips.isEmpty
            || !project.timeline.cameraMotionClips.isEmpty
        return RecentProjectSummary(
            url: packageURL,
            title: rawTitle.isEmpty ? packageURL.deletingPathExtension().lastPathComponent : rawTitle,
            hasAuthoredTitle: hasAuthoredTitle,
            isEdited: isEdited
        )
    }

    static func recentProjectSummaries(limit: Int = 8) -> [RecentProjectSummary] {
        recentProjectURLs(limit: limit).map { projectSummary(at: $0) }
    }

    @MainActor
    static func renamePackage(at currentURL: URL, toTitle newTitle: String) throws -> URL {
        let trimmed = newTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return currentURL }
        let invalid = CharacterSet(charactersIn: "/:\\?%*|\"<>")
        let sanitized = trimmed
            .components(separatedBy: invalid)
            .joined(separator: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !sanitized.isEmpty else { return currentURL }

        let parent = currentURL.deletingLastPathComponent()
        var destination = parent.appendingPathComponent("\(sanitized).dogscproject", isDirectory: true)
        guard destination.standardizedFileURL.path != currentURL.standardizedFileURL.path else {
            return currentURL
        }

        var suffix = 2
        while FileManager.default.fileExists(atPath: destination.path),
              destination.standardizedFileURL.path != currentURL.standardizedFileURL.path {
            destination = parent.appendingPathComponent("\(sanitized)-\(suffix).dogscproject", isDirectory: true)
            suffix += 1
        }

        guard destination.standardizedFileURL.path != currentURL.standardizedFileURL.path else {
            return currentURL
        }

        try FileManager.default.moveItem(at: currentURL, to: destination)

        let oldPath = currentURL.standardizedFileURL.path
        let newPath = destination.standardizedFileURL.path
        var paths = defaults.stringArray(forKey: recentProjectsDefaultsKey) ?? []
        paths.removeAll { $0 == oldPath }
        paths.removeAll { $0 == newPath }
        paths.insert(newPath, at: 0)
        defaults.set(Array(paths.prefix(20)), forKey: recentProjectsDefaultsKey)

        scheduleSystemRecentProjectsSynchronization()
        return destination
    }

    private static func sanitizedPackageBaseName(_ title: String?) -> String? {
        guard let title else { return nil }
        let invalid = CharacterSet(charactersIn: "/:\\?%*|\"<>")
        let sanitized = title
            .components(separatedBy: invalid)
            .joined(separator: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return sanitized.isEmpty ? nil : sanitized
    }

    static var workingProjectsFolder: URL {
        let applicationSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? FileManager.default.temporaryDirectory
        return applicationSupport
            .appendingPathComponent("DogSC", isDirectory: true)
            .appendingPathComponent("未保存项目", isDirectory: true)
    }

    private static func workingProjectURLs() -> [URL] {
        let keys: Set<URLResourceKey> = [.contentModificationDateKey, .isDirectoryKey]
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: workingProjectsFolder,
            includingPropertiesForKeys: Array(keys),
            options: [.skipsHiddenFiles]
        )) ?? []
        return urls
            .filter { $0.pathExtension == "dogscproject" }
            .sorted {
                let left = (try? $0.resourceValues(forKeys: keys).contentModificationDate) ?? .distantPast
                let right = (try? $1.resourceValues(forKeys: keys).contentModificationDate) ?? .distantPast
                return left > right
            }
    }
}

enum PointerEventJSONLScanner {
    static func decode(_ data: Data) -> [PointerEventRecord]? {
        data.withUnsafeBytes { raw -> [PointerEventRecord]? in
            guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { return [] }
            var scanner = Scanner(pointer: base, end: base + raw.count)
            var records: [PointerEventRecord] = []
            records.reserveCapacity(raw.count / 120)
            while true {
                scanner.skipWhitespace()
                guard scanner.pointer < scanner.end else { return records }
                guard let record = scanner.record() else { return nil }
                records.append(record)
            }
        }
    }

    private struct Scanner {
        var pointer: UnsafePointer<UInt8>
        let end: UnsafePointer<UInt8>
        var cursorIDs: [String: CursorAssetID] = [:]

        mutating func skipWhitespace() {
            while pointer < end {
                switch pointer.pointee {
                case 0x20, 0x0A, 0x0D, 0x09: pointer += 1
                default: return
                }
            }
        }

        mutating func consume(_ byte: UInt8) -> Bool {
            skipWhitespace()
            guard pointer < end, pointer.pointee == byte else { return false }
            pointer += 1
            return true
        }

        mutating func isNull() -> Bool {
            skipWhitespace()
            guard end - pointer >= 4, memcmp(pointer, "null", 4) == 0 else { return false }
            pointer += 4
            return true
        }

        mutating func stringBytes() -> UnsafeBufferPointer<UInt8>? {
            guard consume(0x22) else { return nil }
            let start = pointer
            while pointer < end, pointer.pointee != 0x22 {
                guard pointer.pointee != 0x5C, pointer.pointee >= 0x20 else { return nil }
                pointer += 1
            }
            guard pointer < end else { return nil }
            defer { pointer += 1 }
            return UnsafeBufferPointer(start: start, count: pointer - start)
        }

        mutating func string() -> String? {
            stringBytes().map { String(decoding: $0, as: UTF8.self) }
        }

        mutating func number() -> Double? {
            skipWhitespace()
            let start = pointer
            scan: while pointer < end {
                switch pointer.pointee {
                case 0x30...0x39, 0x2D, 0x2B, 0x2E, 0x45, 0x65: pointer += 1
                default: break scan
                }
            }
            guard pointer > start,
                  let value = Double(String(
                    decoding: UnsafeBufferPointer(start: start, count: pointer - start),
                    as: UTF8.self
                  )),
                  value.isFinite else { return nil }
            return value
        }

        mutating func location() -> NormalizedPoint? {
            guard consume(0x7B) else { return nil }
            var x: Double?
            var y: Double?
            repeat {
                guard let key = stringBytes(), key.count == 1, consume(0x3A) else { return nil }
                switch key[0] {
                case 0x78 where x == nil: x = number()
                case 0x79 where y == nil: y = number()
                default: return nil
                }
            } while consume(0x2C)
            guard consume(0x7D), let x, let y else { return nil }
            return NormalizedPoint(x: x, y: y)
        }

        mutating func modifiers() -> [PointerModifier]? {
            if isNull() { return [] }
            guard consume(0x5B) else { return nil }
            var result: [PointerModifier] = []
            if consume(0x5D) { return result }
            repeat {
                guard let raw = string(), let modifier = PointerModifier(rawValue: raw) else { return nil }
                result.append(modifier)
            } while consume(0x2C)
            return consume(0x5D) ? result : nil
        }

        mutating func cursorAssetID() -> CursorAssetID?? {
            if isNull() { return .some(nil) }
            guard let raw = string() else { return nil }
            if let cached = cursorIDs[raw] { return cached }
            let id = CursorAssetID(rawValue: raw)
            cursorIDs[raw] = id
            return id
        }

        mutating func record() -> PointerEventRecord? {
            guard consume(0x7B) else { return nil }
            var time: Double?
            var location: NormalizedPoint?
            var kind: PointerEventKind?
            var modifiers: [PointerModifier]?
            var cursor: CursorAssetID??
            repeat {
                guard let key = string(), consume(0x3A) else { return nil }
                switch key {
                case "time" where time == nil:
                    guard let value = number() else { return nil }
                    time = value
                case "location" where location == nil:
                    guard let value = self.location() else { return nil }
                    location = value
                case "kind" where kind == nil:
                    guard let value = string().flatMap(PointerEventKind.init(rawValue:)) else { return nil }
                    kind = value
                case "modifiers" where modifiers == nil:
                    guard let value = self.modifiers() else { return nil }
                    modifiers = value
                case "cursorAssetID" where cursor == nil:
                    guard let value = cursorAssetID() else { return nil }
                    cursor = .some(value)
                default:
                    return nil
                }
            } while consume(0x2C)
            guard consume(0x7D), let time, let location, let kind else { return nil }
            return PointerEventRecord(
                time: time,
                location: location,
                kind: kind,
                modifiers: modifiers ?? [],
                cursorAssetID: cursor ?? nil
            )
        }
    }
}
