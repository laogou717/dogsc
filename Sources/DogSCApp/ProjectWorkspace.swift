import Combine
import Foundation
import RecorderCore


/// Owns the one project document and its complete persistence epoch lifecycle.
/// UI policy, app phase transitions, media presentation, and recording control
/// deliberately remain in AppModel.
@MainActor
final class ProjectWorkspace: ObservableObject {
    let document: ProjectDocument
    var onFailure: ((String) -> Void)?

    var session: RecordingSession? { persistence.session }
    var isSaved: Bool { persistence.isSaved }
    var status: ProjectPersistenceStatus { persistence.status }

    private let persistence: ProjectSessionPersistenceController
    private var subscriptions = Set<AnyCancellable>()

    init(
        document: ProjectDocument,
        persistence: ProjectSessionPersistenceController
    ) {
        self.document = document
        self.persistence = persistence

        document.objectWillChange
            .sink { [weak self] in self?.objectWillChange.send() }
            .store(in: &subscriptions)
        document.$project
            .dropFirst()
            .sink { [weak self] project in
                self?.persistence.scheduleAutosave(project)
            }
            .store(in: &subscriptions)
        persistence.onStateChange = { [weak self] in
            self?.objectWillChange.send()
        }
        persistence.onFailure = { [weak self] message in
            self?.onFailure?(message)
        }
    }

    convenience init() {
        self.init(
            document: ProjectDocument(project: RecorderProject()),
            persistence: ProjectSessionPersistenceController()
        )
    }



    func activate(session: RecordingSession, isSaved: Bool) {
        persistence.activate(session: session, isSaved: isSaved)
    }

    @discardableResult
    func flush(_ project: RecorderProject) async throws -> ProjectSaveReceipt? {
        try await persistence.flush(project)
    }

    @discardableResult
    func move(
        _ project: RecorderProject,
        to destination: URL
    ) async throws -> ProjectMoveReceipt? {
        try await persistence.move(project, to: destination)
    }

    @discardableResult
    func moveAndInvalidate(
        _ project: RecorderProject,
        to destination: URL
    ) async throws -> ProjectMoveReceipt? {
        try await persistence.moveAndInvalidate(project, to: destination)
    }

    @discardableResult
    func flushAndInvalidate(_ project: RecorderProject) async throws -> RecordingSession? {
        try await persistence.flushAndInvalidate(project)
    }

    @discardableResult
    func invalidateCurrentSession() async -> RecordingSession? {
        await persistence.invalidateCurrentSession()
    }
}
