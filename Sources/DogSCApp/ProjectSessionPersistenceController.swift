import Foundation
import RecorderCore

enum ProjectPersistenceStatus: Equatable {
    case clean
    case saving
    case failed(String)
}

private enum ProjectPersistenceControllerError: LocalizedError {
    case autosaveInterrupted

    var errorDescription: String? {
        switch self {
        case .autosaveInterrupted:
            appLocalized("自动保存被意外中断；本次编辑仍保留在内存中，请继续编辑或手动保存。")
        }
    }
}

protocol ProjectSessionPersisting: Sendable {
    func save(
        project: RecorderProject,
        session: RecordingSession,
        epoch: ProjectSessionEpoch,
        revision: Int
    ) async throws -> ProjectSaveReceipt?

    func flush(
        project: RecorderProject,
        session: RecordingSession,
        epoch: ProjectSessionEpoch,
        revision: Int
    ) async throws -> ProjectSaveReceipt?

    func flushAndMove(
        project: RecorderProject,
        session: RecordingSession,
        epoch: ProjectSessionEpoch,
        revision: Int,
        destinationURL: URL
    ) async throws -> ProjectMoveReceipt

    func invalidate(epoch: ProjectSessionEpoch) async
}

struct ProjectRepositoryClient: ProjectSessionPersisting {
    private let repository: ProjectRepository

    init(repository: ProjectRepository = ProjectRepository()) {
        self.repository = repository
    }

    func save(
        project: RecorderProject,
        session: RecordingSession,
        epoch: ProjectSessionEpoch,
        revision: Int
    ) async throws -> ProjectSaveReceipt? {
        try await repository.save(
            project: project,
            session: session,
            epoch: epoch,
            revision: revision
        )
    }

    func flush(
        project: RecorderProject,
        session: RecordingSession,
        epoch: ProjectSessionEpoch,
        revision: Int
    ) async throws -> ProjectSaveReceipt? {
        try await repository.flush(
            project: project,
            session: session,
            epoch: epoch,
            revision: revision
        )
    }

    func flushAndMove(
        project: RecorderProject,
        session: RecordingSession,
        epoch: ProjectSessionEpoch,
        revision: Int,
        destinationURL: URL
    ) async throws -> ProjectMoveReceipt {
        try await repository.flushAndMove(
            project: project,
            session: session,
            epoch: epoch,
            revision: revision,
            destinationURL: destinationURL
        )
    }

    func invalidate(epoch: ProjectSessionEpoch) async {
        await repository.invalidate(epoch: epoch)
    }
}

/// Owns the persistence identity and ordered save lifecycle of one open project.
///
/// AppModel supplies immutable project snapshots and remains responsible for UI,
/// recording state, media URL presentation, and recovery heartbeat behavior.
/// Session epochs and revisions never escape this boundary.
@MainActor
final class ProjectSessionPersistenceController {
    private struct SaveRequest: Sendable {
        let project: RecorderProject
        let session: RecordingSession
        let epoch: ProjectSessionEpoch
        let revision: Int
    }

    var onStateChange: (() -> Void)?
    var onFailure: ((String) -> Void)?

    private(set) var session: RecordingSession? {
        didSet { notifyStateChangeIfNeeded(oldValue: oldValue?.packageURL, newValue: session?.packageURL) }
    }
    private(set) var isSaved = true {
        didSet { notifyStateChangeIfNeeded(oldValue: oldValue, newValue: isSaved) }
    }
    private(set) var status: ProjectPersistenceStatus = .clean {
        didSet { notifyStateChangeIfNeeded(oldValue: oldValue, newValue: status) }
    }

    private let repository: any ProjectSessionPersisting
    private let autosaveDelay: Duration
    private var epoch: ProjectSessionEpoch?
    private var revision = 0
    private var autosaveDebounceTask: Task<Void, Never>?
    private var autosaveWriteTask: Task<Void, Never>?
    private var pendingAutosaveRequest: SaveRequest?
    private var autosaveGeneration: UInt64 = 0
    private var terminatingEpoch: ProjectSessionEpoch?

    init(
        repository: any ProjectSessionPersisting = ProjectRepositoryClient(),
        autosaveDelay: Duration = .milliseconds(350)
    ) {
        self.repository = repository
        self.autosaveDelay = autosaveDelay
    }

    func activate(session: RecordingSession, isSaved: Bool) {
        let previousEpoch = epoch
        cancelAutosavePipeline()

        let newEpoch = ProjectSessionEpoch()
        self.session = session
        epoch = newEpoch
        revision = 0
        terminatingEpoch = nil
        self.isSaved = isSaved
        status = .clean

        guard let previousEpoch else { return }
        Task { [weak self, repository] in
            await repository.invalidate(epoch: previousEpoch)
            guard let self, self.epoch == newEpoch else { return }
        }
    }

    func scheduleAutosave(_ project: RecorderProject) {
        guard terminatingEpoch == nil,
              let request = makeSaveRequest(project: project) else { return }
        pendingAutosaveRequest = request
        status = .saving
        scheduleAutosaveDebounceIfNeeded()
    }

    @discardableResult
    func flush(_ project: RecorderProject) async throws -> ProjectSaveReceipt? {
        cancelAutosavePipeline()
        guard terminatingEpoch == nil,
              let request = makeSaveRequest(project: project) else { return nil }
        status = .saving

        do {
            guard let receipt = try await repository.flush(
                project: request.project,
                session: request.session,
                epoch: request.epoch,
                revision: request.revision
            ) else {
                throw ProjectRepositoryError.inactiveEpoch
            }
            guard isCurrent(request) else { return nil }
            if receipt.committedRevision >= revision {
                status = .clean
            }
            return receipt
        } catch {
            guard isCurrent(request) else { return nil }
            report(error)
            throw error
        }
    }

    @discardableResult
    func move(
        _ project: RecorderProject,
        to destination: URL
    ) async throws -> ProjectMoveReceipt? {
        try await move(project, to: destination, invalidatingAfterMove: false)
    }

    @discardableResult
    func moveAndInvalidate(
        _ project: RecorderProject,
        to destination: URL
    ) async throws -> ProjectMoveReceipt? {
        try await move(project, to: destination, invalidatingAfterMove: true)
    }

    /// Flushes the final snapshot, invalidates the epoch as an actor barrier,
    /// and detaches the session only after both awaits still belong to it.
    @discardableResult
    func flushAndInvalidate(_ project: RecorderProject) async throws -> RecordingSession? {
        cancelAutosavePipeline()
        guard terminatingEpoch == nil,
              let request = makeSaveRequest(project: project) else { return nil }
        terminatingEpoch = request.epoch
        status = .saving

        do {
            guard let receipt = try await repository.flush(
                project: request.project,
                session: request.session,
                epoch: request.epoch,
                revision: request.revision
            ) else {
                throw ProjectRepositoryError.inactiveEpoch
            }
            guard isTerminating(request.epoch) else { return nil }
            if receipt.committedRevision >= revision {
                status = .clean
            }

            await repository.invalidate(epoch: request.epoch)
            guard isTerminating(request.epoch) else { return nil }
            return detachSession(afterInvalidating: request.epoch)
        } catch {
            guard isTerminating(request.epoch) else { return nil }
            terminatingEpoch = nil
            report(error)
            throw error
        }
    }

    /// Invalidates pending and in-flight writes before handing the package to a
    /// destructive caller. The returned session is already detached.
    @discardableResult
    func invalidateCurrentSession() async -> RecordingSession? {
        cancelAutosavePipeline()
        guard let epoch, let session else {
            resetDetachedState()
            return nil
        }
        guard terminatingEpoch == nil else { return nil }
        terminatingEpoch = epoch

        await repository.invalidate(epoch: epoch)
        guard isTerminating(epoch) else { return nil }
        _ = detachSession(afterInvalidating: epoch)
        return session
    }

    private func move(
        _ project: RecorderProject,
        to destination: URL,
        invalidatingAfterMove: Bool
    ) async throws -> ProjectMoveReceipt? {
        cancelAutosavePipeline()
        guard terminatingEpoch == nil,
              let request = makeSaveRequest(project: project) else { return nil }
        if invalidatingAfterMove {
            terminatingEpoch = request.epoch
        }
        status = .saving

        do {
            let result = try await repository.flushAndMove(
                project: request.project,
                session: request.session,
                epoch: request.epoch,
                revision: request.revision,
                destinationURL: destination
            )
            guard invalidatingAfterMove
                    ? isTerminating(request.epoch)
                    : isCurrent(request) else { return nil }

            session = result.session
            isSaved = true
            if result.save.committedRevision >= revision {
                status = .clean
            }

            if invalidatingAfterMove {
                await repository.invalidate(epoch: request.epoch)
                guard isTerminating(request.epoch) else { return nil }
                _ = detachSession(afterInvalidating: request.epoch)
            }
            return result
        } catch {
            let operationIsCurrent = invalidatingAfterMove
                ? isTerminating(request.epoch)
                : isCurrent(request)
            guard operationIsCurrent else { return nil }
            if invalidatingAfterMove {
                terminatingEpoch = nil
            }
            report(error)
            throw error
        }
    }

    private func makeSaveRequest(project: RecorderProject) -> SaveRequest? {
        guard let session, let epoch else { return nil }
        revision += 1
        return SaveRequest(
            project: project,
            session: session,
            epoch: epoch,
            revision: revision
        )
    }

    /// Debounce only the pending snapshot. Once a filesystem write has begun,
    /// newer edits replace `pendingAutosaveRequest` instead of cancelling the
    /// task and launching another uninterruptible staging write beside it.
    /// This bounds autosave to one active write plus one latest snapshot; an
    /// explicit flush may still bypass that one writer as the safety barrier.
    private func scheduleAutosaveDebounceIfNeeded() {
        guard autosaveWriteTask == nil,
              pendingAutosaveRequest != nil else { return }
        autosaveDebounceTask?.cancel()
        let generation = autosaveGeneration
        autosaveDebounceTask = Task { [weak self, autosaveDelay] in
            do {
                try await Task.sleep(for: autosaveDelay)
            } catch {
                return
            }
            guard let self,
                  !Task.isCancelled,
                  self.autosaveGeneration == generation else { return }
            self.autosaveDebounceTask = nil
            self.beginAutosaveWriteIfReady(generation: generation)
        }
    }

    private func beginAutosaveWriteIfReady(generation: UInt64) {
        guard autosaveWriteTask == nil,
              autosaveGeneration == generation,
              let request = pendingAutosaveRequest,
              isCurrent(request) else { return }
        pendingAutosaveRequest = nil
        autosaveWriteTask = Task { [weak self, repository] in
            do {
                let receipt = try await repository.save(
                    project: request.project,
                    session: request.session,
                    epoch: request.epoch,
                    revision: request.revision
                )
                guard let self,
                      !Task.isCancelled,
                      self.autosaveGeneration == generation,
                      self.isCurrent(request) else { return }
                self.autosaveWriteTask = nil
                if self.pendingAutosaveRequest == nil,
                   let receipt,
                   receipt.committedRevision >= self.revision {
                    self.status = .clean
                }
                self.scheduleAutosaveDebounceIfNeeded()
            } catch is CancellationError {
                guard let self,
                      self.autosaveGeneration == generation,
                      self.isCurrent(request) else { return }
                // Session changes deliberately cancel the task and increment
                // `autosaveGeneration`; that path has already cleared the
                // pipeline. A cancellation from the repository itself is an
                // unexpected terminal result and must release the active slot,
                // otherwise status remains `.saving` and no later debounce can
                // ever start another write.
                self.autosaveWriteTask = nil
                self.report(ProjectPersistenceControllerError.autosaveInterrupted)
            } catch {
                guard let self,
                      !Task.isCancelled,
                      self.autosaveGeneration == generation,
                      self.isCurrent(request) else { return }
                self.autosaveWriteTask = nil
                self.report(error)
            }
        }
    }

    private func cancelAutosavePipeline() {
        autosaveGeneration &+= 1
        autosaveDebounceTask?.cancel()
        autosaveDebounceTask = nil
        autosaveWriteTask?.cancel()
        autosaveWriteTask = nil
        pendingAutosaveRequest = nil
    }

    private func isCurrent(_ request: SaveRequest) -> Bool {
        epoch == request.epoch && terminatingEpoch == nil
    }

    private func isTerminating(_ expectedEpoch: ProjectSessionEpoch) -> Bool {
        epoch == expectedEpoch && terminatingEpoch == expectedEpoch
    }

    private func detachSession(
        afterInvalidating expectedEpoch: ProjectSessionEpoch
    ) -> RecordingSession? {
        guard isTerminating(expectedEpoch) else { return nil }
        let detached = session
        resetDetachedState()
        return detached
    }

    private func resetDetachedState() {
        cancelAutosavePipeline()
        session = nil
        epoch = nil
        revision = 0
        terminatingEpoch = nil
        isSaved = true
        status = .clean
    }

    private func report(_ error: any Error) {
        let message = error.localizedDescription
        status = .failed(message)
        onFailure?(message)
    }

    private func notifyStateChangeIfNeeded<Value: Equatable>(
        oldValue: Value,
        newValue: Value
    ) {
        guard oldValue != newValue else { return }
        onStateChange?()
    }
}
