import AppKit
import Foundation
import RecorderCore

struct RecordingSession: Sendable {
    let packageURL: URL
    let screenRecordingURL: URL
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
        screenRecordingURL = mediaURL.appendingPathComponent("screen-0001.mp4")
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

/// A process-local identity for one open project session. The package URL is
/// deliberately not the identity because saving a project can move that
/// package while delayed autosaves are still waiting to run.
struct ProjectSessionEpoch: Hashable, Sendable {
    let id: UUID

    init(id: UUID = UUID()) {
        self.id = id
    }
}

struct ProjectSaveReceipt: Equatable, Sendable {
    let committedRevision: Int
    let didWrite: Bool
}

struct ProjectMoveReceipt: Sendable {
    let session: RecordingSession
    let save: ProjectSaveReceipt
}

enum ProjectRepositoryError: LocalizedError, Equatable, Sendable {
    case sessionMismatch
    case inactiveEpoch
    case projectWriteTimedOut

    var errorDescription: String? {
        switch self {
        case .sessionMismatch:
            return "项目保存会话与当前项目不一致。"
        case .inactiveEpoch:
            return "项目保存会话已经关闭。"
        case .projectWriteTimedOut:
            return "项目文件写入超时，已终止本次保存；素材文件不会受影响。"
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
        var packagePath: String?
        var knownPackagePaths: Set<String> = []
        var highestCommittedRevision: Int = -1
        var isInvalidated = false
    }

    private var epochs: [ProjectSessionEpoch: EpochState] = [:]
    /// Epochs whose session has been invalidated. The per-epoch state is
    /// dropped on invalidation (bounded memory); this set only rejects late
    /// writers that were already in flight. Bounded below: one entry per
    /// closed session, and a handful covers the real scheduling window.
    private var invalidatedEpochs: Set<ProjectSessionEpoch> = []
    private var invalidatedEpochOrder: [ProjectSessionEpoch] = []

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

        guard var state = epochs[epoch],
              let currentPackagePath = state.packagePath else {
            throw ProjectRepositoryError.inactiveEpoch
        }
        let activeSession = RecordingSession(
            packageURL: URL(fileURLWithPath: currentPackagePath, isDirectory: true)
        )
        let moved = try ProjectStore.moveSession(activeSession, to: destinationURL)
        guard !state.isInvalidated else {
            throw ProjectRepositoryError.inactiveEpoch
        }
        state.packagePath = Self.canonicalPath(for: moved)
        // 旧路径已随包移走：不再接受指向它的写请求（见 persist 的路径检查）。
        state.knownPackagePaths.remove(currentPackagePath)
        state.knownPackagePaths.insert(Self.canonicalPath(for: moved))
        epochs[epoch] = state
        return ProjectMoveReceipt(session: moved, save: receipt)
    }

    /// Invalidating is a barrier. Calls already executing finish first; calls
    /// arriving later are ignored even if they carry a numerically newer
    /// revision. Per-epoch state is dropped (bounded memory); the epoch stays
    /// in `invalidatedEpochs` only long enough to reject late writers.
    func invalidate(epoch: ProjectSessionEpoch) {
        if invalidatedEpochs.insert(epoch).inserted {
            invalidatedEpochOrder.append(epoch)
        }
        epochs.removeValue(forKey: epoch)
        let overflow = invalidatedEpochOrder.count - 64
        if overflow > 0 {
            // A late writer can only be in flight for the few actor turns
            // right after invalidation. Remove only the oldest tombstones;
            // clearing the whole set also forgot the just-closed session and
            // allowed its next delayed autosave to recreate project.json.
            for expired in invalidatedEpochOrder.prefix(overflow) {
                invalidatedEpochs.remove(expired)
            }
            invalidatedEpochOrder.removeFirst(overflow)
        }
    }

    private func persist(
        project: RecorderProject,
        session: RecordingSession,
        epoch: ProjectSessionEpoch,
        revision: Int
    ) async throws -> ProjectSaveReceipt? {
        guard !invalidatedEpochs.contains(epoch) else { return nil }
        var state = epochs[epoch] ?? EpochState()

        let requestedPath = Self.canonicalPath(for: session)
        if state.packagePath == nil {
            state.packagePath = requestedPath
            state.knownPackagePaths.insert(requestedPath)
        } else if !state.knownPackagePaths.contains(requestedPath) {
            // 包已被 move 走（旧路径不再存在）：迟到的 autosave 应静默丢弃，
            // 不应制造虚假的"保存失败"。
            guard FileManager.default.fileExists(atPath: requestedPath) else {
                return ProjectSaveReceipt(
                    committedRevision: state.highestCommittedRevision,
                    didWrite: false
                )
            }
            throw ProjectRepositoryError.sessionMismatch
        }

        guard revision > state.highestCommittedRevision else {
            epochs[epoch] = state
            return ProjectSaveReceipt(
                committedRevision: state.highestCommittedRevision,
                didWrite: false
            )
        }

        guard let activePackagePath = state.packagePath else {
            throw ProjectRepositoryError.inactiveEpoch
        }
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
            if invalidatedEpochs.contains(epoch) {
                return nil
            }
            if !FileManager.default.fileExists(atPath: activePackagePath) {
                return ProjectSaveReceipt(
                    committedRevision: epochs[epoch]?.highestCommittedRevision
                        ?? state.highestCommittedRevision,
                    didWrite: false
                )
            }
            throw error
        }

        guard !invalidatedEpochs.contains(epoch),
              var currentState = epochs[epoch] else {
            ProjectStore.discardStagedProject(at: stagedURL)
            return nil
        }
        guard currentState.packagePath == activePackagePath else {
            ProjectStore.discardStagedProject(at: stagedURL)
            return ProjectSaveReceipt(
                committedRevision: currentState.highestCommittedRevision,
                didWrite: false
            )
        }
        guard revision > currentState.highestCommittedRevision else {
            ProjectStore.discardStagedProject(at: stagedURL)
            return ProjectSaveReceipt(
                committedRevision: currentState.highestCommittedRevision,
                didWrite: false
            )
        }

        do {
            try ProjectStore.commitStagedProject(at: stagedURL, session: activeSession)
        } catch {
            ProjectStore.discardStagedProject(at: stagedURL)
            throw error
        }
        currentState.highestCommittedRevision = revision
        epochs[epoch] = currentState
        return ProjectSaveReceipt(committedRevision: revision, didWrite: true)
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
    let updatedAt: String?
    let screenFile: String
    let fileSize: Int64
    let cameraDiagnostics: CameraCaptureDiagnostics?
    let systemAudioDiagnostics: AudioCaptureDiagnostics?
    let microphoneDiagnostics: AudioCaptureDiagnostics?
    let performanceDiagnosticsFile: String?
    let performanceSummary: RecordingPerformanceSummary?
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
    let modificationDate: Date?

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
        let statusTag = isEdited ? "已编辑" : "未编辑"
        let iconPrefix = isEdited ? "🎬" : "📄"
        return "\(iconPrefix) \(displayTitle) (\(statusTag))"
    }
}

enum ProjectStore {
    private static let recentProjectsDefaultsKey = "cn.laogou.dogsc.recent-project-paths"
    private static var defaults: UserDefaults {
        UserDefaults(suiteName: "cn.laogou.dogsc") ?? .standard
    }

    static func createSession() throws -> RecordingSession {
        let projectsFolder = workingProjectsFolder

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "yyyy-MM-dd-HH-mm-ss"
        let baseName = "录屏-\(formatter.string(from: Date()))"
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
        guard session.packageURL.standardizedFileURL != destination.standardizedFileURL else {
            return session
        }

        try FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        if FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.trashItem(at: destination, resultingItemURL: nil)
        }
        try FileManager.default.moveItem(at: session.packageURL, to: destination)
        return RecordingSession(packageURL: destination)
    }

    static func isWorkingProject(_ packageURL: URL) -> Bool {
        packageURL.standardizedFileURL.path.hasPrefix(
            workingProjectsFolder.standardizedFileURL.path + "/"
        )
    }

    static func saveProject(_ project: RecorderProject, session: RecordingSession) throws {
        let stagedURL = try stageProject(project, session: session)
        do {
            try commitStagedProject(at: stagedURL, session: session)
        } catch {
            discardStagedProject(at: stagedURL)
            throw error
        }
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

    static func loadPointerEvents(session: RecordingSession) throws -> [PointerEventRecord] {
        guard FileManager.default.fileExists(atPath: session.pointerEventsURL.path) else {
            return []
        }
        return try decodePointerEvents(at: session.pointerEventsURL)
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

    private static func decodePointerEvents(at url: URL) throws -> [PointerEventRecord] {
        let data = try Data(contentsOf: url)
        guard !data.isEmpty else { return [] }

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
            updatedAt: manifest.updatedAt,
            screenFile: manifest.screenFile,
            fileSize: fileSize,
            cameraDiagnostics: manifest.cameraDiagnostics,
            systemAudioDiagnostics: manifest.systemAudioDiagnostics,
            microphoneDiagnostics: manifest.microphoneDiagnostics,
            performanceDiagnosticsFile: manifest.performanceDiagnosticsFile,
            performanceSummary: manifest.performanceSummary
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

    static func recordingPerformanceSamples(
        session: RecordingSession
    ) throws -> [RecordingPerformanceSample] {
        guard FileManager.default.fileExists(atPath: session.recordingDiagnosticsURL.path) else {
            return []
        }
        let data = try Data(contentsOf: session.recordingDiagnosticsURL)
        let decoder = JSONDecoder()
        return try data.split(separator: 0x0A).filter { !$0.isEmpty }.map {
            try decoder.decode(RecordingPerformanceSample.self, from: Data($0))
        }
    }

    static func isRecoverableProject(at packageURL: URL) -> Bool {
        guard let manifest = recoveryManifest(at: packageURL) else { return false }
        return (manifest.state == "recording" || manifest.state == "paused") && manifest.fileSize > 1_024
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

    static func loadProject(at packageURL: URL) throws -> (project: RecorderProject, session: RecordingSession) {
        let session = RecordingSession(packageURL: packageURL)
        let projectURL = packageURL.appendingPathComponent("project.json")
        let data = try Data(contentsOf: projectURL)
        let sourceVersion = (
            try? JSONDecoder().decode(ProjectVersionHeader.self, from: data).version
        ) ?? 1

        // 先保护原始字节再尝试解码：若未来 schema 不兼容导致 decode 失败，
        // 备份必须已经落盘，否则旧项目将完全无法恢复。
        if sourceVersion < ProjectSchema.currentVersion {
            let backupURL = packageURL.appendingPathComponent(
                "project-v\(sourceVersion)-before-migration.json"
            )
            try writeMigrationBackupIfNeeded(data, to: backupURL)
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let project = try decoder.decode(RecorderProject.self, from: data)
        try ProjectValidator.validate(project)
        return (project, session)
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
        NSDocumentController.shared.noteNewRecentDocumentURL(packageURL)
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
        let fileManager = FileManager.default
        let projectURL = packageURL.appendingPathComponent("project.json")
        let modDate = (try? fileManager.attributesOfItem(atPath: packageURL.path)[.modificationDate]) as? Date
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let data = try? Data(contentsOf: projectURL),
              let project = try? decoder.decode(RecorderProject.self, from: data) else {
            let base = packageURL.deletingPathExtension().lastPathComponent
            return RecentProjectSummary(
                url: packageURL,
                title: base,
                hasAuthoredTitle: false,
                isEdited: false,
                modificationDate: modDate
            )
        }
        let rawTitle = project.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let hasAuthoredTitle = !rawTitle.isEmpty
            && rawTitle != "未命名录制"
            && !rawTitle.hasPrefix("录屏-")
            && !rawTitle.hasPrefix("录制-")
        let isEdited = hasAuthoredTitle
            || project.timeline.sourceSequence != .fullRecording
            || !project.zoomAnimations.isEmpty
            || !project.timeline.screenMotionClips.isEmpty
            || !project.timeline.cameraMotionClips.isEmpty
        return RecentProjectSummary(
            url: packageURL,
            title: rawTitle.isEmpty ? packageURL.deletingPathExtension().lastPathComponent : rawTitle,
            hasAuthoredTitle: hasAuthoredTitle,
            isEdited: isEdited,
            modificationDate: modDate
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

        NSDocumentController.shared.noteNewRecentDocumentURL(destination)
        return destination
    }

    private static var workingProjectsFolder: URL {
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
