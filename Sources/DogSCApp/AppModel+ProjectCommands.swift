import AppKit
import AVFoundation
import Combine
import CoreGraphics
import Foundation
import OSLog
import RecorderCore
import ScreenCaptureKit
import UniformTypeIdentifiers

private let projectOpenLogger = Logger(
    subsystem: "cn.laogou.dogsc",
    category: "project-open"
)

extension AppModel {
    func updateSurfaceVisibility(
        hidesDesktopFiles: Bool? = nil,
        hidesDock: Bool? = nil
    ) {
        // The preparation popover edits the next recording's configuration.
        // Persist it even when no stream exists; only the live filter update
        // below depends on an active display/area recording.
        let previous = configuration
        captureSetup.setSurfaceVisibility(
            hidesDesktopFiles: hidesDesktopFiles,
            hidesDock: hidesDock
        )
        guard phase == .recording,
              let run = recordingRuns.active,
              run.plan.configuration.source != .window,
              run.plan.configuration.source != .device else { return }
        var updated = run.plan.configuration
        updated.hidesDesktopFiles = configuration.hidesDesktopFiles
        updated.hidesDock = configuration.hidesDock
        surfaceVisibilityTask?.cancel()
        surfaceVisibilityTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await self.recorder.updateSurfaceVisibility(
                    runID: run.id, configuration: updated
                )
                guard self.recordingRuns.isCurrent(run.id) else { return }
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled, self.recordingRuns.isCurrent(run.id) else { return }
                self.captureSetup.replaceConfiguration(previous)
                self.errorMessage = String(format: appLocalized("无法更新录制画面：%@"), appErrorDescription(error))
            }
        }
    }

    func restartCurrentRecording() {
        abandonCurrentRecording(restart: true)
    }

    func discardCurrentRecording() {
        abandonCurrentRecording(restart: false)
    }

    func elapsedRecordingTime(at date: Date) -> TimeInterval {
        guard let startedAt else { return 0 }
        let effectiveEnd = pauseStartedAt ?? date
        return max(effectiveEnd.timeIntervalSince(startedAt) - accumulatedPausedDuration, 0)
    }

    /// Choosing Edit is the only completion-card action that creates the
    /// editor. Media and the project already crossed the stop/save boundary.
    func editCompletedRecording() {
        guard phase == .recordingComplete,
              !isResolvingCompletedRecording,
              !AppDialogPresenter.isPresenting,
              currentSession != nil, recordingURL != nil else { return }
        if WindowCoordinator.hasRecordingProjectEditor {
            let sessionURL = currentSession?.packageURL
            isResolvingCompletedRecording = true
            Task { @MainActor [weak self] in
                guard let self else { return }
                defer { isResolvingCompletedRecording = false }
                guard await WindowCoordinator.closeRecordingProjectEditorForReplacement(),
                      phase == .recordingComplete,
                      currentSession?.packageURL == sessionURL else { return }
                recorderTransitionStage = .openingEditor
                phase = .editor
            }
            return
        }
        recorderTransitionStage = .openingEditor
        phase = .editor
    }

    @discardableResult
    func saveCompletedRecording() async -> Bool {
        await persistCompletedRecording(resumingLiveInputs: true)
    }

    /// Escape and the window-close command keep the take: closing the
    /// completion card is saving it. Deleting is its own, undoable action.
    func requestCloseCompletedRecording(relativeTo owner: NSWindow? = nil) async {
        _ = await saveCompletedRecording()
    }

    /// Quitting with a take still on the completion card keeps it.
    func confirmCompletedRecordingForTermination(relativeTo owner: NSWindow? = nil) async -> Bool {
        guard phase == .recordingComplete else { return true }
        return await persistCompletedRecording(resumingLiveInputs: false)
    }

    func requestCloseProject() {
        if phase == .recordingComplete {
            Task { @MainActor [weak self] in
                await self?.requestCloseCompletedRecording()
            }
            return
        }
        guard phase == .editor else { return }
        guard currentSession != nil else {
            closeProject()
            return
        }
        if offersDiscardForUntouchedRecording,
           !currentRecordingHasEditorChanges {
            let sessionURL = currentSession?.packageURL
            AppDialogPresenter.present(AppDialog(
                title: "保留这次录制吗？",
                message: "录制已安全保存，还没有进行编辑。保留项目，或将这次录制移到废纸篓。",
                symbol: "record.circle", itemTitle: project.title,
                layout: .projectDecision,
                actions: [
                    .init(id: "cancel", title: "取消", role: .cancel),
                    .init(id: "delete", title: "移到废纸篓", role: .destructive),
                    .init(id: "keep", title: "保留项目", role: .primary)
                ]
            )) { [weak self] response in
                guard let self, self.phase == .editor,
                      self.currentSession?.packageURL == sessionURL else { return }
                switch response.actionID {
                case "keep": self.closePersistedProjectWithoutLocationPrompt()
                case "delete": self.deleteCurrentProjectAndClose()
                default: break
                }
            }
            return
        }

        if isCurrentProjectSaved {
            flushCurrentProjectAndClose()
            return
        }

        // A normal edited recording should already have been archived before
        // the editor opened. If that move failed (for example an unavailable
        // external folder), retry the configured destination rather than
        // making the user choose a location during close.
        if offersDiscardForUntouchedRecording,
           let session = currentSession,
           let destination = try? ProjectStore.automaticSaveDestination(
                for: project,
                session: session
           ) {
            saveCurrentProject(to: destination, closeAfterSave: true)
            return
        }

        let sessionURL = currentSession?.packageURL
        AppDialogPresenter.present(AppDialog(
            title: "关闭项目前要保存吗？",
            message: "保存为项目，方便继续编辑；也可以将这次录制移到废纸篓。",
            symbol: "folder", itemTitle: project.title,
            layout: .projectDecision,
            actions: [
                .init(id: "cancel", title: "取消", role: .cancel),
                .init(id: "delete", title: "移到废纸篓", role: .destructive),
                .init(id: "save", title: "保存项目…", role: .primary)
            ]
        )) { [weak self] response in
            guard let self, self.phase == .editor,
                  self.currentSession?.packageURL == sessionURL else { return }
            switch response.actionID {
            case "save":
                Task { @MainActor [weak self] in
                    guard let self, let destination = await self.chooseProjectSaveDestination(),
                          self.phase == .editor, self.currentSession?.packageURL == sessionURL else { return }
                    self.saveCurrentProject(to: destination, closeAfterSave: true)
                }
            case "delete": self.deleteCurrentProjectAndClose()
            default: break
            }
        }
    }

    func requestDeleteCurrentProject() {
        guard phase == .editor, let sessionURL = currentSession?.packageURL else { return }
        AppDialogPresenter.present(AppDialog(
            title: "删除这个项目？",
            message: "项目和其中的录制素材将移到废纸篓，需要时可从废纸篓恢复。",
            symbol: "trash", itemTitle: project.title,
            actions: [
                .init(id: "cancel", title: "取消", role: .cancel),
                .init(id: "delete", title: "移到废纸篓", role: .destructive)
            ]
        )) { [weak self] response in
            guard let self, response.actionID == "delete", self.phase == .editor,
                  self.currentSession?.packageURL == sessionURL else { return }
            self.deleteCurrentProjectAndClose()
        }
    }

    private func closePersistedProjectWithoutLocationPrompt() {
        if isCurrentProjectSaved {
            flushCurrentProjectAndClose()
            return
        }
        guard let session = currentSession,
              let destination = try? ProjectStore.automaticSaveDestination(
                for: project,
                session: session
              ) else {
            errorMessage = "无法解析默认项目保存位置。"
            return
        }
        saveCurrentProject(to: destination, closeAfterSave: true)
    }

    /// Title submission is an explicit save gesture. Bypass the autosave
    /// debounce so pressing Return means the new project name is already on
    /// disk when the field leaves edit mode.
    func flushCurrentProjectInPlace() {
        guard phase == .editor, currentSession != nil else { return }
        let snapshot = project
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                _ = try await workspace.flush(snapshot)
            } catch {
                errorMessage = String(format: appLocalized("保存项目失败：%@"), appErrorDescription(error))
            }
        }
    }

    func closeProject(resumingLiveInputs: Bool = true) {
        guard currentSession == nil else {
            errorMessage = "项目保存或关闭屏障尚未完成。"
            return
        }
        cancelPendingRecordingRestart()
        captureSetup.stopPresentation()
        EditorStylePresetStore.rememberLastUsedStyle(from: project)
        let previousAudio = project.audio
        let previousExportSettings = project.exportSettings
        recoveryHeartbeatTask?.cancel()
        recoveryHeartbeatTask = nil
        recordingURL = nil
        cameraRecordingURL = nil
        microphoneRecordingURL = nil
        pointerEvents = []
        startedAt = nil
        isRecordingPaused = false
        pauseStartedAt = nil
        accumulatedPausedDuration = 0
        recorderTransitionStage = .idle
        offersDiscardForUntouchedRecording = false
        currentRecordingHasEditorChanges = false
        let nextRecordingBaseline = RecorderProject(
            capture: configuration,
            audio: previousAudio,
            exportSettings: previousExportSettings
        )
        // An explicit scene default includes crop. Implicit last-used styling
        // remains source-safe, matching the cold-launch choice.
        project = EditorStylePresetStore.applyingLastUsedStyle(to: nextRecordingBaseline)
        captureSetup.reset()
        if resumingLiveInputs { resumeLiveInputIndicatorsForSetup() }
        phase = .setup
        refreshRecentProjects()
    }

    /// Recording suspends camera preview and microphone metering. Returning
    /// to setup must restart them, otherwise the level bar stays dead until
    /// the user manually re-selects the microphone.
    func resumeLiveInputIndicatorsForSetup() {
        guard purpose == .recording else { return }
        // start() is idempotent and refreshes the catalog immediately after an
        // editor-only suspension. This avoids retaining device observers while
        // editing without showing stale choices on return to setup.
        captureDeviceLifecycle.start()
        applySavedSystemAudioPreference()
        applySavedMicrophonePreferenceForSetup(clearingError: false)
        if configuration.recordsCamera,
           let cameraID = configuration.cameraDeviceID,
           let device = availableCameras.first(where: { $0.id == cameraID }) {
            selectCamera(device, clearingError: false)
        }
        if configuration.recordsMicrophone,
           microphoneMeterTask == nil,
           let microphoneID = configuration.microphoneDeviceID,
           let device = availableMicrophones.first(where: { $0.id == microphoneID }) {
            startMicrophoneMeter(device)
        }
    }

    func chooseWallpaperAsset() async -> BackgroundSource? {
        guard let currentSession else {
            errorMessage = "请先完成一次真实录制，再把壁纸保存进项目。"
            return nil
        }
        let urls = await AppFilePanel.open { panel in
            panel.title = appLocalized("选择画布背景")
            panel.prompt = appLocalized("使用这个背景")
            panel.allowsMultipleSelection = false
            panel.canChooseDirectories = false
            panel.allowedContentTypes = [
                .png, .jpeg, .heic, .tiff, .movie, .mpeg4Movie, .quickTimeMovie,
            ]
        }
        guard let sourceURL = urls?.first,
              self.currentSession?.packageURL == currentSession.packageURL else { return nil }

        do {
            return try importBackgroundAsset(from: sourceURL, session: currentSession)
        } catch {
            errorMessage = appErrorDescription(error)
            return nil
        }
    }

    func chooseOverlayImageAsset() async -> (relativePath: String, url: URL)? {
        guard let currentSession else {
            errorMessage = "请先打开一个可编辑项目。"
            return nil
        }
        let urls = await AppFilePanel.open { panel in
            panel.title = appLocalized("选择贴图")
            panel.prompt = appLocalized("添加")
            panel.allowsMultipleSelection = false
            panel.canChooseDirectories = false
            panel.allowedContentTypes = [.png, .jpeg, .heic, .tiff]
        }
        guard let sourceURL = urls?.first,
              self.currentSession?.packageURL == currentSession.packageURL else { return nil }

        do {
            return try ProjectStore.importOverlayImage(
                from: sourceURL,
                session: currentSession
            )
        } catch {
            errorMessage = appErrorDescription(error)
            return nil
        }
    }

    func importOverlayImageFromPasteboard() -> (relativePath: String, url: URL)? {
        guard let currentSession else { return nil }
        let pasteboard = NSPasteboard.general
        if let urls = pasteboard.readObjects(forClasses: [NSURL.self]) as? [URL],
           let sourceURL = urls.first {
            do {
                return try ProjectStore.importOverlayImage(
                    from: sourceURL,
                    session: currentSession
                )
            } catch {
                errorMessage = appErrorDescription(error)
                return nil
            }
        }
        guard let image = NSImage(pasteboard: pasteboard),
              let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff),
              let png = bitmap.representation(using: .png, properties: [:]) else {
            return nil
        }
        do {
            return try ProjectStore.importOverlayImage(
                data: png,
                fileExtension: "png",
                session: currentSession
            )
        } catch {
            errorMessage = appErrorDescription(error)
            return nil
        }
    }

    private func importBackgroundAsset(
        from sourceURL: URL,
        session: RecordingSession
    ) throws -> BackgroundSource {
        if SystemWallpaperLibrary.isVideoURL(sourceURL) {
            let imported = try ProjectStore.importBackgroundVideo(
                from: sourceURL,
                session: session
            )
            return .projectVideo(relativePath: imported.relativePath)
        }
        let imported = try ProjectStore.importWallpaper(from: sourceURL, session: session)
        return .projectImage(relativePath: imported.relativePath)
    }

    /// SRC-001: copy the actual media files used by the current editor into a
    /// user-selected folder. This is intentionally not a rendered export: no
    /// timeline edits, scaling, color conversion or audio mixing are applied.
    func exportCurrentProjectSourceMedia() {
        guard phase == .editor,
              !isMediaExchangeRunning,
              let screen = recordingURL else { return }
        let sessionID = editorSessionID
        AppFilePanel.open(configure: { panel in
            panel.title = appLocalized("选择源文件导出文件夹")
            panel.prompt = appLocalized("导出到这里")
            panel.directoryURL = AppPreferences.exportDirectoryURL
            panel.canChooseFiles = false
            panel.canChooseDirectories = true
            panel.canCreateDirectories = true
            panel.allowsMultipleSelection = false
        }) { [weak self] urls in
            guard let self, let destination = urls?.first,
                  self.editorSessionID == sessionID else { return }
            self.exportCurrentProjectSourceMedia(into: destination, screen: screen)
        }
    }

    private func exportCurrentProjectSourceMedia(into destination: URL, screen: URL) {

        guard let session = currentSession else { return }
        let sources = ProjectSourceMediaFiles(screen: screen, camera: cameraRecordingURL,
            microphone: microphoneRecordingURL,
            pointer: project.media?.pointerEvents.flatMap { ProjectStore.resolveMediaPath($0.relativePath, session: session) })
        let additional: [(name: String, files: ProjectSourceMediaFiles)]
        do {
            additional = try project.additionalSources.map { source in
                func url(_ reference: ProjectMediaReference?) throws -> URL? {
                    guard let reference else { return nil }
                    guard let url = ProjectStore.resolveMediaPath(reference.relativePath, session: session) else {
                        throw RecordingImportError.missingFile(reference.relativePath)
                    }
                    return url
                }
                guard let screen = try url(source.media.screen) else { throw RecordingImportError.missingRecording }
                return try (source.name, ProjectSourceMediaFiles(screen: screen, camera: url(source.media.camera),
                    microphone: url(source.media.microphone), pointer: url(source.media.pointerEvents)))
            }
        } catch { errorMessage = appErrorDescription(error); return }
        let title = project.title
        isMediaExchangeRunning = true
        Task { @MainActor [weak self] in
            guard let self else { return }
            defer { isMediaExchangeRunning = false }
            do {
                let folder = try await Task.detached(priority: .userInitiated) {
                    try ProjectMediaExchange.exportSources(
                        sources,
                        projectTitle: title,
                        additionalRecordings: additional,
                        into: destination
                    )
                }.value
                NSWorkspace.shared.activateFileViewerSelecting([folder])
            } catch {
                errorMessage = String(format: appLocalized("导出源文件失败：%@"), appErrorDescription(error))
            }
        }
    }

    /// SRC-003: replace only the camera source with a file conformed/aligned in
    /// an external editor. Screen, microphone, cuts and effects remain exactly
    /// where they are; the new camera declares its own time zero.
    func importCameraReplacement(sourceID: UUID) {
        Task { @MainActor [weak self] in
            await self?.chooseCameraReplacement(sourceID: sourceID)
        }
    }

    private func chooseCameraReplacement(sourceID: UUID) async {
        guard phase == .editor,
              !isMediaExchangeRunning,
              !exporter.isExporting,
              let session = currentSession,
              project.source(sourceID)?.media.camera != nil else { return }
        let expectedSessionID = editorSessionID
        guard let camera = await chooseAlignedMediaFile(
            title: "选择替换用摄像头文件",
            prompt: "替换摄像头",
            contentType: .movie,
            initialURL: project.source(sourceID)?.media.camera.flatMap { ProjectStore.resolveMediaPath($0.relativePath, session: session) }
        ), editorSessionID == expectedSessionID else { return }

        let sessionPath = session.packageURL.standardizedFileURL.path
        let sessionURL = editorSessionID
        isMediaExchangeRunning = true
        Task { @MainActor [weak self] in
            guard let self else { return }
            defer { isMediaExchangeRunning = false }
            do {
                try await ProjectMediaExchange.inspectCameraReplacement(camera)
                let imported = try await Task.detached(priority: .userInitiated) {
                    try ProjectMediaExchange.importCameraReplacement(
                        camera: camera,
                        session: session
                    )
                }.value
                guard editorSessionID == sessionURL,
                      currentSession?.packageURL.standardizedFileURL.path == sessionPath,
                      var media = project.source(sourceID)?.media else {
                    await ProjectPackageDisposal.removeIfPresent(imported.folderURL)
                    return
                }

                media.camera = ProjectMediaReference(
                    relativePath: imported.cameraRelativePath
                )
                var replacement = project
                replacement.setMedia(media, for: sourceID)
                if let index = replacement.additionalSources.firstIndex(where: { $0.id == sourceID }) {
                    replacement.additionalSources[index].cameraContentCrop = nil
                }
                project = replacement
                if sourceID == RecordingSource.primaryID { cameraRecordingURL = imported.cameraURL }
                editorContextRevision &+= 1
                _ = try await workspace.flush(replacement)
            } catch {
                errorMessage = String(format: appLocalized("替换摄像头文件失败：%@"), appErrorDescription(error))
            }
        }
    }

    func chooseAlignedMediaFile(
        title: String,
        prompt: String,
        contentType: UTType,
        initialURL: URL?
    ) async -> URL? {
        await AppFilePanel.open { panel in
            panel.title = appLocalized(title)
            panel.prompt = appLocalized(prompt)
            panel.allowedContentTypes = [contentType]
            panel.directoryURL = initialURL?.deletingLastPathComponent()
        }?.first
    }

    /// Lets the user choose where saved projects land (另存为/保存后的项目包).
    func chooseProjectsFolder() {
        AppFilePanel.open(configure: { panel in
            panel.title = appLocalized("选择项目保存位置")
            panel.prompt = appLocalized("选择")
            panel.message = appLocalized("后续录制的项目会自动保存到所选文件夹。")
            panel.canChooseDirectories = true
            panel.canChooseFiles = false
            panel.canCreateDirectories = true
            if let customPath = UserDefaults.standard.string(
                forKey: ProjectStore.projectsFolderDefaultsKey
            ) {
                panel.directoryURL = URL(fileURLWithPath: customPath, isDirectory: true)
            } else {
                panel.directoryURL = ProjectStore.savedProjectsFolder
            }
        }) { [weak self] urls in
            guard let self, let url = urls?.first else { return }
            self.applyProjectsFolder(url)
        }
    }

    private func applyProjectsFolder(_ url: URL) {
        do {
            try ProjectStore.setSavedProjectsFolder(url)
            recordingDestinationName = ProjectStore.savedProjectsFolder.lastPathComponent
            refreshRecentProjects()
        } catch {
            errorMessage = String(format: appLocalized("无法设置项目保存位置：%@"), appErrorDescription(error))
        }
    }

    func openProjectPicker() {
        AppFilePanel.open(configure: { panel in
            panel.title = String(format: appLocalized("打开 %@ 项目"), AppIdentity.displayName)
            panel.prompt = appLocalized("打开")
            panel.message = appLocalized("选择要继续编辑的项目")
            panel.directoryURL = ProjectStore.savedProjectsFolder
            EditorImportFileTypes.configure(panel, extensions: ["dogscproject", "silkyproject"])
        }) { [weak self] urls in
            guard let self, let selectedURL = urls?.first else { return }
            let packageURL = selectedURL.lastPathComponent == "project.json"
                ? selectedURL.deletingLastPathComponent() : selectedURL
            self.requestOpenProject(at: packageURL)
        }
    }

    func openMostRecentProject() {
        guard let url = recentProjects.first else { return }
        requestOpenProject(at: url)
    }

    func recoverMostRecentProject() {
        guard let url = recoverableProjects.first else { return }
        requestOpenProject(at: url)
    }

    func openScreenRecordingSettings() {
        openPrivacySettings(section: "Privacy_ScreenCapture")
    }

    func openCameraPrivacySettings() {
        openPrivacySettings(section: "Privacy_Camera")
    }

    func openMicrophonePrivacySettings() {
        openPrivacySettings(section: "Privacy_Microphone")
    }

    private func openPrivacySettings(section: String) {
        guard let url = URL(
            string: "x-apple.systempreferences:com.apple.preference.security?\(section)"
        ) else { return }
        NSWorkspace.shared.open(url)
    }

    func requestOpenProject(at packageURL: URL) {
        if WindowCoordinator.routeProjectOpen(at: packageURL, from: self) { return }
        if purpose == .editing, exporter.isExporting || isMediaExchangeRunning {
            errorMessage = "请先完成当前项目的打开、保存或导出操作。"
            return
        }
        switch phase {
        case .setup:
            beginProjectOpen(at: packageURL, projectToFlush: nil)
        case .editor:
            let projectSnapshot = project
            beginProjectOpen(
                at: packageURL,
                projectToFlush: currentSession == nil ? nil : projectSnapshot
            )
        case .recordingComplete:
            // Finder, recent projects and menu commands must not replace a
            // take while its completion decision is still pending.
            WindowCoordinator.bringCurrentWindowFront()
        case .preparing, .recording, .finishing:
            errorMessage = "录制准备、录制或写入期间不能打开其他项目。请先结束当前操作。"
        }
    }

    func updateSessionPackageURL(to newURL: URL) {
        let updatedSession = RecordingSession(packageURL: newURL)
        workspace.activate(session: updatedSession, isSaved: workspace.isSaved)
        // Moving the package invalidates every absolute media URL captured by
        // the current editor generation. Resolve all project-owned tracks
        // against the new package before publishing the replacement context.
        // Otherwise a title edit rebuilds the preview with the old package
        // path and reports a missing screen recording even though it moved.
        relocateEditorMedia(for: project, to: updatedSession)
        refreshRecentProjects()
    }

    /// Rebinds immutable editor inputs after a project package move. Save As
    /// and in-place rename share this path so screen, camera, microphone and
    /// package-relative assets all switch generations together.
    func relocateEditorMedia(
        for project: RecorderProject,
        to session: RecordingSession
    ) {
        recordingURL = ProjectStore.resolve(
            relativePath: project.media?.screen.relativePath,
            session: session
        )
        cameraRecordingURL = ProjectStore.resolve(
            relativePath: project.media?.camera?.relativePath,
            session: session
        )
        microphoneRecordingURL = ProjectStore.resolve(
            relativePath: project.media?.microphone?.relativePath,
            session: session
        )
        editorContextRevision &+= 1
    }

    private func beginProjectOpen(
        at packageURL: URL,
        projectToFlush: RecorderProject?
    ) {
        guard projectOpenTask == nil else { return }
        recorderTransitionStage = .openingEditor
        phase = .finishing
        projectOpenTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { projectOpenTask = nil }

            if let projectToFlush {
                do {
                    guard try await workspace.flushAndInvalidate(projectToFlush) != nil else {
                        throw CocoaError(.fileWriteUnknown)
                    }
                } catch {
                    guard !Task.isCancelled else { return }
                    errorMessage = String(format: appLocalized("打开新项目前无法安全保存当前项目：%@"), appErrorDescription(error))
                    recorderTransitionStage = .idle
                    phase = .editor
                    return
                }
            }

            guard !Task.isCancelled else { return }
            suspendLiveInputIndicators()
            captureSetup.reset()
            let openStarted = ContinuousClock.now
            func milestone(_ name: String) {
                let elapsed = ContinuousClock.now - openStarted
                performanceLog.notice("open \(name, privacy: .public): \(Int(elapsed.components.seconds * 1000 + elapsed.components.attoseconds / 1_000_000_000_000_000), privacy: .public)ms")
            }
            let loader = Task.detached(priority: .userInitiated) {
                try ProjectOpenSnapshot.load(at: packageURL)
            }
            do {
                let loaded = try await withTaskCancellationHandler {
                    try await loader.value
                } onCancel: {
                    loader.cancel()
                }
                milestone("snapshot loaded")
                try Task.checkCancellation()
                let recorderSettleTime = WindowCoordinator.recorderTransitionSettleTime
                if recorderSettleTime > 0 {
                    try await Task.sleep(for: .seconds(recorderSettleTime))
                    milestone("settle wait \(recorderSettleTime)s")
                }
                try applyProjectOpenSnapshot(loaded)
                milestone("project applied")
                recorderTransitionStage = .idle
            } catch is CancellationError {
                return
            } catch {
                projectOpenLogger.error(
                    "project open failed url=\(packageURL.path, privacy: .private) error=\(String(reflecting: error), privacy: .public)"
                )
                errorMessage = appErrorDescription(error)
                resumeLiveInputIndicatorsForSetup()
                recorderTransitionStage = .idle
                phase = .setup
            }
        }
    }

    private func applyProjectOpenSnapshot(
        _ loaded: ProjectOpenSnapshot
    ) throws {
        ProjectStore.registerRecentProject(loaded.normalizedURL)
        workspace.activate(
            session: loaded.session,
            isSaved: loaded.isSaved
        )
        project = loaded.project
        offersDiscardForUntouchedRecording = false
        currentRecordingHasEditorChanges = false
        // REC-003: opening an old editing project must not silently switch the
        // next live recording back to its historical/missing codec.
        var nextCaptureConfiguration = loaded.project.capture
        nextCaptureConfiguration.captureCodec = captureSetup.configuration.captureCodec
        captureSetup.replaceConfiguration(nextCaptureConfiguration)
        recordingURL = loaded.recordingURL
        cameraRecordingURL = loaded.cameraRecordingURL
        microphoneRecordingURL = loaded.microphoneRecordingURL
        pointerEvents = loaded.pointerEvents
        errorMessage = loaded.warnings.isEmpty
            ? nil
            : String(format: appLocalized("项目已打开，但%@"), loaded.warnings.joined(separator: " "))
        exporter.resetResultForNewEditorSession()
        editorSessionID = UUID()
        phase = .editor
        if loaded.wasInterrupted, recordingURL != nil {
            try ProjectStore.writeRecoveryManifest(
                state: "recovered",
                session: loaded.session,
                frameRate: loaded.project.capture.captureFrameRate,
                screenRelativePath: loaded.project.media?.screen.relativePath
                    ?? "media/screen-0001.mp4"
            )
        }
        refreshRecentProjects()
    }

    func refreshRecentProjects() {
        projectCatalogRefreshGeneration &+= 1
        let generation = projectCatalogRefreshGeneration
        projectCatalogRefreshTask?.cancel()
        let loader = Task.detached(priority: .utility) {
            ProjectCatalogSnapshot.load()
        }
        projectCatalogRefreshTask = Task { @MainActor [weak self] in
            guard let self else {
                loader.cancel()
                return
            }
            defer {
                if projectCatalogRefreshGeneration == generation {
                    projectCatalogRefreshTask = nil
                }
            }
            let snapshot = await withTaskCancellationHandler {
                await loader.value
            } onCancel: {
                loader.cancel()
            }
            guard !Task.isCancelled,
                  projectCatalogRefreshGeneration == generation else { return }
            recentProjects = snapshot.recent
            recoverableProjects = snapshot.recoverable
        }
    }

    func selectCaptureSource(_ source: CaptureSource) {
        cancelPendingRecordingRestart()
        guard phase == .setup else { return }
        RecorderPopoverPresenter.shared.dismiss()
        guard hasRequiredRecordingPermissions else {
            captureSetup.stopPresentation()
            beginRequiredPermissionOnboardingIfNeeded()
            return
        }
        captureSetup.selectSource(source)
    }

    func refreshCaptureReadiness() {
        refreshRequiredRecordingPermissions()
    }

    func refreshRequiredRecordingPermissions() {
        captureSetup.refreshReadiness()
        let accessibilityGranted = AXIsProcessTrusted()
        if hasAccessibilityPermission != accessibilityGranted {
            hasAccessibilityPermission = accessibilityGranted
        }

        if !captureReadiness.hasScreenRecordingPermission {
            hasVerifiedScreenRecordingPermission = false
            setRequiredPermissionOnboardingCompleted(false)
        }
        if !hasAccessibilityPermission {
            setRequiredPermissionOnboardingCompleted(false)
        }
        if showsRequiredPermissionGate {
            captureSetup.stopPresentation()
            WindowCoordinator.endCaptureSourceSelection(restoringRecorder: false)
        }
        if hasRequiredRecordingPermissions,
           let message = errorMessage,
           RecorderSetupErrorRecovery.isPermissionMessage(message) {
            errorMessage = nil
        }
    }

    func beginRequiredPermissionOnboardingIfNeeded() {
        refreshRequiredRecordingPermissions()
        guard showsRequiredPermissionGate else { return }
        captureSetup.stopPresentation()
        WindowCoordinator.endCaptureSourceSelection(restoringRecorder: false)
    }

    func resumeRequiredPermissionOnboardingAfterActivation() {
        refreshRequiredRecordingPermissions()
        guard showsRequiredPermissionGate else { return }
        Task { @MainActor [weak self] in
            await self?.verifyRequiredRecordingPermissions()
        }
    }

    /// Refreshes both required permissions without showing another prompt or
    /// modal. The first-run page owns cadence; returning from System Settings
    /// and its one-second idle loop both converge on this same verification.
    func verifyRequiredRecordingPermissions() async {
        guard phase == .setup, !isCheckingRequiredPermissions else { return }
        captureSetup.refreshReadiness()
        let accessibilityGranted = AXIsProcessTrusted()
        if hasAccessibilityPermission != accessibilityGranted {
            hasAccessibilityPermission = accessibilityGranted
        }

        guard captureReadiness.hasScreenRecordingPermission else {
            hasVerifiedScreenRecordingPermission = false
            setRequiredPermissionOnboardingCompleted(false)
            return
        }

        guard !hasVerifiedScreenRecordingPermission else { return }
        isCheckingRequiredPermissions = true
        defer { isCheckingRequiredPermissions = false }
        do {
            _ = try await SCShareableContent.excludingDesktopWindows(
                false,
                onScreenWindowsOnly: true
            )
            hasVerifiedScreenRecordingPermission = true
        } catch {
            hasVerifiedScreenRecordingPermission = false
            setRequiredPermissionOnboardingCompleted(false)
        }
    }

    func openRequiredPermissionSettings(
        _ permission: RequiredRecordingPermissionKind
    ) {
        guard phase == .setup else { return }
        errorMessage = nil
        captureSetup.stopPresentation()
        WindowCoordinator.endCaptureSourceSelection(restoringRecorder: false)
        // This button has one job: open the exact settings page. Calling the
        // TCC request API here as well presents a second native alert over
        // System Settings and leaves two competing authorization paths.
        openPrivacySettings(section: permission.settingsSection)
        WindowCoordinator.showPermissionDragAssistant(for: permission)
    }

    func finishRequiredPermissionOnboarding() {
        guard phase == .setup, hasRequiredRecordingPermissions else { return }
        setRequiredPermissionOnboardingCompleted(true)
        WindowCoordinator.dismissPermissionDragAssistant()
    }

    private func setRequiredPermissionOnboardingCompleted(_ completed: Bool) {
        guard hasCompletedRequiredPermissionOnboarding != completed else { return }
        hasCompletedRequiredPermissionOnboarding = completed
        UserDefaults.standard.set(
            completed,
            forKey: "permissions.required-onboarding-completed"
        )
    }

    func refreshCaptureDevicesInBackground() {
        captureCatalogTask?.cancel()
        captureCatalogTask = Task { @MainActor [weak self] in
            let snapshot = await CaptureDeviceCatalog.snapshotForUI()
            guard !Task.isCancelled, let self else { return }
            self.applyCaptureDeviceCatalog(snapshot)
        }
    }

    // The recording-plan boundary keeps its synchronous identity validation.
    // Toolbar presentation and connection notifications use the async path.
    func refreshCaptureDevices() {
        captureCatalogTask?.cancel()
        applyCaptureDeviceCatalog(CaptureDeviceCatalog.Snapshot(
            screenDevices: CaptureDeviceCatalog.screenDevices(),
            cameras: CaptureDeviceCatalog.videoDevices(),
            microphones: CaptureDeviceCatalog.audioDevices()
        ))
    }

    private func applyCaptureDeviceCatalog(_ snapshot: CaptureDeviceCatalog.Snapshot) {
        let screenDevices = snapshot.screenDevices
        let cameras = snapshot.cameras
        let microphones = snapshot.microphones
        if availableCameras != cameras { availableCameras = cameras }
        if availableMicrophones != microphones { availableMicrophones = microphones }
        if captureSetup.updateScreenDevices(screenDevices) != nil {
            let operation = captureDeviceLifecycle.begin(.screenDevice)
            Task { @MainActor [weak self, recorder = deviceRecorder] in
                guard self?.captureDeviceLifecycle.isCurrent(operation) == true else { return }
                await recorder.releaseDisconnectedDevice()
            }
        }

        if configuration.recordsCamera,
           !availableCameras.contains(where: { $0.id == configuration.cameraDeviceID }) {
            let operation = captureDeviceLifecycle.begin(.camera)
            let disconnectedDeviceName = configuration.cameraDeviceName ?? "摄像头"
            let disconnectedDeviceID = configuration.cameraDeviceID
            cameraPreviewTask?.cancel()
            cameraPreviewTask = nil
            cameraRuntimeFormat = nil
            availableCameraResolutions = []
            _ = captureSetup.clearCamera(ifMatching: disconnectedDeviceID)
            if phase == .setup || phase == .preparing || phase == .recording {
                cameraPreviewController.showDisconnected(
                    deviceName: disconnectedDeviceName
                )
            }
            Task { @MainActor [weak self, recorder = cameraRecorder] in
                guard self?.captureDeviceLifecycle.isCurrent(operation) == true else { return }
                await recorder.releaseDisconnectedDevice()
            }
        }
        if configuration.recordsMicrophone,
           !availableMicrophones.contains(where: { $0.id == configuration.microphoneDeviceID }) {
            let operation = captureDeviceLifecycle.begin(.microphone)
            let disconnectedDeviceID = configuration.microphoneDeviceID
            microphoneMeterTask?.cancel()
            microphoneMeterTask = nil
            _ = captureSetup.clearMicrophone(ifMatching: disconnectedDeviceID)
            microphoneInputLevel.update(0)
            Task { @MainActor [weak self, recorder = microphoneRecorder] in
                guard self?.captureDeviceLifecycle.isCurrent(operation) == true else { return }
                await recorder.releaseDisconnectedDevice()
            }
        }

        restorePreferredCaptureDevicesIfAvailable()
        if phase == .setup,
           configuration.recordsCamera,
           let cameraID = configuration.cameraDeviceID,
           availableCameras.contains(where: { $0.id == cameraID }) {
            refreshAvailableCameraResolutions(deviceUniqueID: cameraID)
        } else if !configuration.recordsCamera, !availableCameraResolutions.isEmpty {
            availableCameraResolutions = []
        }
    }

    func selectCamera(_ device: CaptureDeviceInfo?) {
        selectCamera(device, clearingError: true)
    }

    private func selectCamera(_ device: CaptureDeviceInfo?, clearingError: Bool) {
        cancelPendingRecordingRestart()
        let operation = captureDeviceLifecycle.begin(.camera)
        cameraPreviewTask?.cancel()
        cameraPreviewTask = nil
        captureSetup.setCamera(device)
        cameraRuntimeFormat = nil
        refreshAvailableCameraResolutions(deviceUniqueID: device?.id)
        saveCameraPreference(device)
        if clearingError { errorMessage = nil }
        if let device {
            startCameraPreview(device, operation: operation)
        } else {
            cameraRecorder.onRuntimeFormatChange = nil
            cameraPreviewController.hide()
            Task { @MainActor [weak self, recorder = cameraRecorder] in
                guard self?.captureDeviceLifecycle.isCurrent(operation) == true else { return }
                await recorder.stopPreview()
            }
        }
    }

    func selectCameraCaptureResolution(_ resolution: CameraCaptureResolution?) {
        guard phase == .setup,
              let deviceID = configuration.cameraDeviceID,
              let device = availableCameras.first(where: { $0.id == deviceID }) else { return }
        cancelPendingRecordingRestart()
        let operation = captureDeviceLifecycle.begin(.camera)
        cameraPreviewTask?.cancel()
        cameraPreviewTask = nil
        captureSetup.setCameraCaptureResolution(resolution)
        cameraRuntimeFormat = nil
        errorMessage = nil
        startCameraPreview(device, operation: operation)
    }

    func selectMicrophone(_ device: CaptureDeviceInfo?) {
        selectMicrophone(device, clearingError: true)
    }

    private func selectMicrophone(_ device: CaptureDeviceInfo?, clearingError: Bool) {
        let operation = captureDeviceLifecycle.begin(.microphone)
        microphoneMeterTask?.cancel()
        microphoneMeterTask = nil
        microphoneInputLevel.update(0)
        captureSetup.setMicrophone(device)
        saveMicrophonePreference(device)
        if clearingError { errorMessage = nil }
        if let device {
            startMicrophoneMeter(device, operation: operation)
        } else {
            Task { @MainActor [weak self, recorder = microphoneRecorder] in
                guard self?.captureDeviceLifecycle.isCurrent(operation) == true else { return }
                await recorder.stopMonitoring()
            }
        }
    }

    /// One preference drives the recorder bar, Settings and the status menu.
    /// While editing, changing it only affects the next recording and never
    /// starts a microphone session behind the editor.
    func setDefaultMicrophoneRecordingEnabled(_ enabled: Bool) {
        UserDefaults.standard.set(
            enabled,
            forKey: CaptureDevicePreferenceKey.microphoneEnabled
        )
        guard phase == .setup else { return }
        applySavedMicrophonePreferenceForSetup()
    }

    func setDefaultSystemAudioRecordingEnabled(
        _ enabled: Bool,
        scope: SystemAudioScope? = nil
    ) {
        let defaults = UserDefaults.standard
        defaults.set(
            enabled,
            forKey: CaptureDevicePreferenceKey.systemAudioEnabled
        )
        if let scope {
            defaults.set(
                appLocalized(scope.rawValue),
                forKey: CaptureDevicePreferenceKey.systemAudioScope
            )
        }
        // System-audio selection owns no idle capture graph, so it is safe to
        // keep the setup snapshot current even while the editor is visible.
        guard phase == .setup || phase == .editor else { return }
        captureSetup.setSystemAudio(enabled: enabled, scope: scope)
    }

    func applySavedSystemAudioPreference() {
        var scope = AppPreferences.defaultSystemAudioScope
        if scope == .selectedApplication,
           configuration.selectedApplicationBundleIdentifier == nil {
            scope = .all
        }
        captureSetup.setSystemAudio(
            enabled: AppPreferences.isDefaultSystemAudioRecordingEnabled,
            scope: scope
        )
    }

    private func applySavedMicrophonePreferenceForSetup(clearingError: Bool = true) {
        let enabled = AppPreferences.isDefaultMicrophoneRecordingEnabled
        guard enabled else {
            if configuration.recordsMicrophone {
                selectMicrophone(nil, clearingError: clearingError)
            }
            return
        }
        if configuration.recordsMicrophone,
           let selectedID = configuration.microphoneDeviceID,
           availableMicrophones.contains(where: { $0.id == selectedID }) {
            return
        }
        let preferredID = UserDefaults.standard.string(
            forKey: CaptureDevicePreferenceKey.microphoneID
        )
        let device = preferredID.flatMap { preferredID in
            availableMicrophones.first(where: { $0.id == preferredID })
        } ?? availableMicrophones.first
        guard let device else { return }
        selectMicrophone(device, clearingError: clearingError)
    }

    func restorePreferredCaptureDevicesIfAvailable() {
        guard phase.allowsAutomaticLiveInputRestoration else { return }
        // Device restoration also runs after project-open failures. Keep that
        // pending notice until the user acknowledges it or chooses a device.
        let defaults = UserDefaults.standard
        if !configuration.recordsCamera,
           defaults.bool(forKey: CaptureDevicePreferenceKey.cameraEnabled),
           let preferredID = defaults.string(forKey: CaptureDevicePreferenceKey.cameraID),
           let device = availableCameras.first(where: { $0.id == preferredID }) {
            selectCamera(device, clearingError: false)
        }
        if !configuration.recordsMicrophone,
           defaults.bool(forKey: CaptureDevicePreferenceKey.microphoneEnabled) {
            let preferredID = defaults.string(
                forKey: CaptureDevicePreferenceKey.microphoneID
            )
            let device = preferredID.flatMap { preferredID in
                availableMicrophones.first(where: { $0.id == preferredID })
            } ?? availableMicrophones.first
            if let device { selectMicrophone(device, clearingError: false) }
        }
    }

    func saveCameraPreference(_ device: CaptureDeviceInfo?) {
        let defaults = UserDefaults.standard
        defaults.set(device != nil, forKey: CaptureDevicePreferenceKey.cameraEnabled)
        if let device {
            defaults.set(device.id, forKey: CaptureDevicePreferenceKey.cameraID)
            defaults.set(device.name, forKey: CaptureDevicePreferenceKey.cameraName)
        } else {
            defaults.removeObject(forKey: CaptureDevicePreferenceKey.cameraID)
            defaults.removeObject(forKey: CaptureDevicePreferenceKey.cameraName)
        }
    }

    func saveMicrophonePreference(_ device: CaptureDeviceInfo?) {
        let defaults = UserDefaults.standard
        defaults.set(device != nil, forKey: CaptureDevicePreferenceKey.microphoneEnabled)
        if let device {
            defaults.set(device.id, forKey: CaptureDevicePreferenceKey.microphoneID)
            defaults.set(device.name, forKey: CaptureDevicePreferenceKey.microphoneName)
        }
    }

    private func refreshAvailableCameraResolutions(deviceUniqueID: String?) {
        cameraResolutionTask?.cancel()
        cameraResolutionTask = nil
        if cameraResolutionDeviceID != deviceUniqueID {
            cameraResolutionDeviceID = deviceUniqueID
            availableCameraResolutions = []
        }
        guard let deviceUniqueID else { return }
        cameraResolutionTask = Task { @MainActor [weak self] in
            let resolutions = await CaptureDeviceCatalog.resolutionsForUI(deviceUniqueID: deviceUniqueID)
            guard !Task.isCancelled, let self,
                  self.configuration.recordsCamera,
                  self.configuration.cameraDeviceID == deviceUniqueID else { return }
            if self.availableCameraResolutions != resolutions {
                self.availableCameraResolutions = resolutions
            }
        }
    }
}
