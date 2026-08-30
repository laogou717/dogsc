import AppKit
import Combine
import Foundation
import RecorderCore

/// Versioned, immutable media inputs captured when one editor generation is
/// opened. Replacing a project creates a new context instead of mutating these
/// values underneath an existing player or export request.
struct EditorSessionMediaInputs: Equatable, Sendable {
    let source: EditorMediaInput?
    let camera: EditorMediaInput?
    let microphone: EditorMediaInput?
    let pointerEvents: [PointerEventRecord]

    init(
        sourceURL: URL?,
        cameraURL: URL?,
        microphoneURL: URL?,
        pointerEvents: [PointerEventRecord]
    ) {
        source = EditorMediaInput(sourceURL)
        camera = EditorMediaInput(cameraURL)
        microphone = EditorMediaInput(microphoneURL)
        self.pointerEvents = pointerEvents
    }
}

/// The package name is the trustworthy identity for untouched/default-title
/// projects. It is presentation-only: opening `Sample Project.dogscproject` must not
/// silently rewrite project.json merely to replace `未命名录制`.
struct EditorProjectIdentity: Equatable, Sendable {
    static let defaultProjectTitle = "未命名录制"

    let packageTitle: String?

    init(packageURL: URL?) {
        let title = packageURL?
            .deletingPathExtension()
            .lastPathComponent
            .trimmingCharacters(in: .whitespacesAndNewlines)
        packageTitle = title.flatMap { $0.isEmpty ? nil : $0 }
    }

    func displayTitle(for projectTitle: String) -> String {
        let authored = projectTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        if !authored.isEmpty, authored != Self.defaultProjectTitle {
            return authored
        }
        return packageTitle ?? (authored.isEmpty ? Self.defaultProjectTitle : authored)
    }

    func titleDraft(for projectTitle: String) -> String {
        displayTitle(for: projectTitle)
    }
}

/// Resolves project resources against the package that belonged to this
/// editor generation. It never consults AppModel's later current session.
struct EditorWallpaperResolver: Sendable {
    let projectSession: RecordingSession?

    func resolve(_ source: BackgroundSource) -> URL? {
        switch source {
        case let .bundledImage(relativePath):
            return BundledWallpaperLibrary.resolve(relativePath: relativePath)
        case let .projectImage(relativePath):
            guard let projectSession else { return nil }
            return ProjectStore.resolve(
                relativePath: relativePath,
                session: projectSession
            )
        case let .systemImage(absolutePath):
            guard FileManager.default.fileExists(atPath: absolutePath) else { return nil }
            return URL(fileURLWithPath: absolutePath)
        case let .projectVideo(relativePath):
            guard let projectSession else { return nil }
            return ProjectStore.resolve(
                relativePath: relativePath,
                session: projectSession
            )
        case let .systemVideo(absolutePath):
            guard FileManager.default.fileExists(atPath: absolutePath) else { return nil }
            return URL(fileURLWithPath: absolutePath)
        case .gradient, .solidColor, .pattern, .dynamicFlow:
            return nil
        }
    }

    func resolve(relativePath: String) -> URL? {
        guard let projectSession else { return nil }
        return ProjectStore.resolve(
            relativePath: relativePath,
            session: projectSession
        )
    }
}

/// Narrow observable bridge for state and commands owned by the application
/// shell. Editor views observe this adapter, never the recording AppModel.
@MainActor
final class EditorHostActions: ObservableObject {
    @Published private(set) var persistenceStatus: ProjectPersistenceStatus
    @Published private(set) var errorMessage: String?

    private let openProjectAction: () -> Void
    private let deleteProjectAction: () -> Void
    private let chooseWallpaperAction: () -> BackgroundSource?
    private let importOverlayImageAction: () -> String?
    private let pasteOverlayImageAction: () -> String?
    private let setErrorAction: (String?) -> Void
    private let saveProjectAction: () -> Void
    private let revealProjectAction: () -> Void
    private let exportSourceMediaAction: () -> Void
    private let importCameraAction: () -> Void
    private let importDesktopWallpaperAction: () -> BackgroundSource?
    private let renameProjectAction: (String) -> URL?
    private var subscriptions = Set<AnyCancellable>()

    init(
        persistenceStatus: ProjectPersistenceStatus,
        errorMessage: String?,
        persistenceStatusUpdates: AnyPublisher<ProjectPersistenceStatus, Never>,
        errorMessageUpdates: AnyPublisher<String?, Never>,
        openProject: @escaping () -> Void,
        deleteProject: @escaping () -> Void,
        chooseWallpaper: @escaping () -> BackgroundSource?,
        importOverlayImage: @escaping () -> String? = { nil },
        pasteOverlayImage: @escaping () -> String? = { nil },
        setError: @escaping (String?) -> Void,
        saveProject: @escaping () -> Void = {},
        revealProject: @escaping () -> Void = {},
        exportSourceMedia: @escaping () -> Void = {},
        importCamera: @escaping () -> Void = {},
        importDesktopWallpaper: @escaping () -> BackgroundSource? = { nil },
        renameProject: @escaping (String) -> URL? = { _ in nil }
    ) {
        self.persistenceStatus = persistenceStatus
        self.errorMessage = errorMessage
        openProjectAction = openProject
        deleteProjectAction = deleteProject
        chooseWallpaperAction = chooseWallpaper
        importOverlayImageAction = importOverlayImage
        pasteOverlayImageAction = pasteOverlayImage
        setErrorAction = setError
        saveProjectAction = saveProject
        revealProjectAction = revealProject
        exportSourceMediaAction = exportSourceMedia
        importCameraAction = importCamera
        importDesktopWallpaperAction = importDesktopWallpaper
        renameProjectAction = renameProject

        persistenceStatusUpdates
            .removeDuplicates()
            .sink { [weak self] status in
                guard self?.persistenceStatus != status else { return }
                self?.persistenceStatus = status
            }
            .store(in: &subscriptions)
        errorMessageUpdates
            .removeDuplicates()
            .sink { [weak self] message in
                guard self?.errorMessage != message else { return }
                self?.errorMessage = message
            }
            .store(in: &subscriptions)
    }

    func openProject() {
        openProjectAction()
    }

    func deleteProject() {
        deleteProjectAction()
    }

    func chooseWallpaper() -> BackgroundSource? {
        chooseWallpaperAction()
    }

    func importOverlayImage() -> String? {
        importOverlayImageAction()
    }

    func pasteOverlayImage() -> String? {
        pasteOverlayImageAction()
    }

    func reportError(_ message: String) {
        setErrorAction(message)
    }

    func clearError() {
        setErrorAction(nil)
    }

    func saveProjectImmediately() {
        saveProjectAction()
    }

    func revealProjectInFinder() {
        revealProjectAction()
    }

    func exportProjectSourceMedia() {
        exportSourceMediaAction()
    }

    func importCameraReplacement() {
        importCameraAction()
    }

    func importDesktopWallpaper() -> BackgroundSource? {
        importDesktopWallpaperAction()
    }

    func renameProject(to title: String) -> URL? {
        renameProjectAction(title)
    }
}

/// One atomic editor generation. The document is intentionally the sole
/// mutable project owner; every other field is a dependency or immutable
/// identity captured at the AppModel -> editor composition boundary.
@MainActor
struct EditorSessionContext {
    typealias WallpaperURLResolver = (BackgroundSource) -> URL?
    typealias ProjectAssetURLResolver = (String) -> URL?

    let id: EditorSessionID
    let document: ProjectDocument
    let projectIdentity: EditorProjectIdentity
    let media: EditorSessionMediaInputs
    let exporter: VideoExporter
    let hostActions: EditorHostActions

    private let mediaPreparation: EditorMediaSession.Preparation
    private let wallpaperURLResolver: WallpaperURLResolver
    private let projectAssetURLResolver: ProjectAssetURLResolver

    init(
        id: EditorSessionID,
        document: ProjectDocument,
        projectIdentity: EditorProjectIdentity = EditorProjectIdentity(packageURL: nil),
        media: EditorSessionMediaInputs,
        exporter: VideoExporter,
        hostActions: EditorHostActions,
        mediaPreparation: @escaping EditorMediaSession.Preparation,
        wallpaperURLResolver: @escaping WallpaperURLResolver,
        projectAssetURLResolver: @escaping ProjectAssetURLResolver
    ) {
        self.id = id
        self.document = document
        self.projectIdentity = projectIdentity
        self.media = media
        self.exporter = exporter
        self.hostActions = hostActions
        self.mediaPreparation = mediaPreparation
        self.wallpaperURLResolver = wallpaperURLResolver
        self.projectAssetURLResolver = projectAssetURLResolver
    }

    /// Dynamic timeline/media-manifest state comes from the shared document;
    /// file identities and pointer records remain pinned to this generation.
    func mediaRequest(for project: RecorderProject) -> EditorMediaRequest {
        EditorMediaRequest(
            editorSessionID: id,
            source: media.source,
            camera: media.camera,
            microphone: media.microphone,
            sourceSequence: project.timeline.sourceSequence,
            mediaManifest: project.media,
            pointerEvents: media.pointerEvents
        )
    }

    func cameraTimingRequest(for project: RecorderProject) -> EditorCameraTimingRequest {
        EditorCameraTimingRequest(
            editorSessionID: id,
            sourceSequence: project.timeline.sourceSequence,
            cameraReference: project.media?.camera
        )
    }

    func makeMediaSession() -> EditorMediaSession {
        EditorMediaSession(preparation: mediaPreparation)
    }

    func wallpaperURL(for source: BackgroundSource) -> URL? {
        wallpaperURLResolver(source)
    }

    func projectAssetURL(for relativePath: String) -> URL? {
        projectAssetURLResolver(relativePath)
    }
}

/// Replaces the whole immutable context only when AppModel publishes an
/// editor-generation or atomic media-location revision. It deliberately does
/// not subscribe to AppModel.objectWillChange.
@MainActor
final class EditorSessionContextProvider: ObservableObject {
    @Published private(set) var context: EditorSessionContext

    private var subscription: AnyCancellable?

    init(model: AppModel) {
        context = EditorSessionContext(model: model)
        subscription = model.$editorSessionID
            .combineLatest(model.$editorContextRevision)
            .dropFirst()
            .removeDuplicates { $0 == $1 }
            .sink { [weak self, weak model] _ in
                guard let self, let model else { return }
                context = EditorSessionContext(model: model)
            }
    }
}

extension EditorSessionContext {
    /// The only AppModel-aware composition point. No editor view retains or
    /// observes AppModel after this immutable snapshot has been constructed.
    init(model: AppModel) {
        let id = EditorSessionID(rawValue: model.editorSessionID)
        let initialPersistenceStatus = model.persistenceStatus
        let persistenceStatusUpdates = model.objectWillChange
            .compactMap { [weak model] _ -> ProjectPersistenceStatus? in
                guard model?.editorSessionID == id.rawValue else { return nil }
                return model?.persistenceStatus
            }
            .removeDuplicates()
            .eraseToAnyPublisher()
        let hostActions = EditorHostActions(
            persistenceStatus: initialPersistenceStatus,
            errorMessage: model.errorMessage,
            persistenceStatusUpdates: persistenceStatusUpdates,
            errorMessageUpdates: model.$errorMessage
                .filter { [weak model] _ in model?.editorSessionID == id.rawValue }
                .removeDuplicates()
                .eraseToAnyPublisher(),
            openProject: { [weak model] in
                guard model?.editorSessionID == id.rawValue else { return }
                model?.openProjectPicker()
            },
            deleteProject: { [weak model] in
                guard model?.editorSessionID == id.rawValue else { return }
                model?.requestDeleteCurrentProject()
            },
            chooseWallpaper: { [weak model] in
                guard model?.editorSessionID == id.rawValue else { return nil }
                return model?.chooseWallpaperAsset()
            },
            importOverlayImage: { [weak model] in
                guard model?.editorSessionID == id.rawValue else { return nil }
                return model?.chooseOverlayImageAsset()?.relativePath
            },
            pasteOverlayImage: { [weak model] in
                guard model?.editorSessionID == id.rawValue else { return nil }
                return model?.importOverlayImageFromPasteboard()?.relativePath
            },
            setError: { [weak model] message in
                guard model?.editorSessionID == id.rawValue else { return }
                model?.errorMessage = message
            },
            saveProject: { [weak model] in
                guard model?.editorSessionID == id.rawValue else { return }
                model?.flushCurrentProjectInPlace()
            },
            revealProject: { [weak model] in
                guard model?.editorSessionID == id.rawValue,
                      let packageURL = model?.currentSession?.packageURL else { return }
                NSWorkspace.shared.activateFileViewerSelecting([packageURL])
            },
            exportSourceMedia: { [weak model] in
                guard model?.editorSessionID == id.rawValue else { return }
                model?.exportCurrentProjectSourceMedia()
            },
            importCamera: { [weak model] in
                guard model?.editorSessionID == id.rawValue else { return }
                model?.importCameraReplacement()
            },
            importDesktopWallpaper: { [weak model] in
                guard model?.editorSessionID == id.rawValue else { return nil }
                return model?.importCurrentDesktopWallpaper()
            },
            renameProject: { [weak model] newTitle in
                guard model?.editorSessionID == id.rawValue,
                      let currentURL = model?.currentSession?.packageURL else { return nil }
                do {
                    let newURL = try ProjectStore.renamePackage(at: currentURL, toTitle: newTitle)
                    if newURL != currentURL {
                        model?.updateSessionPackageURL(to: newURL)
                    }
                    return newURL
                } catch {
                    model?.errorMessage = "重命名项目包失败：\(error.localizedDescription)"
                    return nil
                }
            }
        )
        let wallpaperResolver = model.makeEditorWallpaperResolver()
        self.init(
            id: id,
            document: model.projectDocument,
            projectIdentity: EditorProjectIdentity(
                packageURL: model.currentSession?.packageURL
            ),
            media: EditorSessionMediaInputs(
                sourceURL: model.recordingURL,
                cameraURL: model.cameraRecordingURL,
                microphoneURL: model.microphoneRecordingURL,
                pointerEvents: model.pointerEvents
            ),
            exporter: model.exporter,
            hostActions: hostActions,
            mediaPreparation: { request in
                try await TimelinePreviewCompositionLoader.prepare(request: request)
            },
            wallpaperURLResolver: wallpaperResolver.resolve,
            projectAssetURLResolver: wallpaperResolver.resolve(relativePath:)
        )
    }
}
