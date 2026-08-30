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
        guard phase == .recording,
              let run = recordingRuns.active,
              run.plan.configuration.source != .window,
              run.plan.configuration.source != .device else { return }
        let previous = configuration
        captureSetup.setSurfaceVisibility(
            hidesDesktopFiles: hidesDesktopFiles,
            hidesDock: hidesDock
        )
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
                self.errorMessage = "无法更新录制画面：\(error.localizedDescription)"
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

    func recordAgain() {
        requestCloseProject()
    }

    func requestCloseProject() {
        guard phase == .editor else { return }
        guard currentSession != nil else {
            closeProject()
            return
        }
        if offersDiscardForUntouchedRecording,
           !currentRecordingHasEditorChanges {
            let alert = NSAlert()
            alert.messageText = "保留这次录制吗？"
            alert.informativeText = "这次录制还没有做任何编辑。录制素材已经安全落盘，也可以直接移到废纸篓。"
            alert.alertStyle = .warning
            alert.addButton(withTitle: "保留项目")
            alert.addButton(withTitle: "删除项目")
            alert.addButton(withTitle: "取消")
            alert.buttons[1].hasDestructiveAction = true

            switch alert.runModal() {
            case .alertFirstButtonReturn:
                closePersistedProjectWithoutLocationPrompt()
            case .alertSecondButtonReturn:
                deleteCurrentProjectAndClose()
            default:
                break
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

        let alert = NSAlert()
        alert.messageText = "关闭项目前要保存吗？"
        alert.informativeText = "可以把录制保存为项目，或删除这次录制的所有素材。"
        alert.alertStyle = .warning
        alert.addButton(withTitle: "保存项目…")
        alert.addButton(withTitle: "删除项目")
        alert.addButton(withTitle: "取消")
        alert.buttons[1].hasDestructiveAction = true

        switch alert.runModal() {
        case .alertFirstButtonReturn:
            guard let destination = chooseProjectSaveDestination() else { return }
            saveCurrentProject(to: destination, closeAfterSave: true)
        case .alertSecondButtonReturn:
            deleteCurrentProjectAndClose()
        default:
            break
        }
    }

    func requestDeleteCurrentProject() {
        guard phase == .editor, currentSession != nil else { return }
        let alert = NSAlert()
        alert.messageText = "删除这个项目？"
        alert.informativeText = "项目包和其中的屏幕、摄像头及声音素材会移到废纸篓。"
        alert.alertStyle = .warning
        alert.addButton(withTitle: "删除项目")
        alert.addButton(withTitle: "取消")
        alert.buttons[0].hasDestructiveAction = true
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        deleteCurrentProjectAndClose()
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

    func saveCurrentProject() {
        guard let destination = chooseProjectSaveDestination() else { return }
        saveCurrentProject(to: destination, closeAfterSave: false)
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
                errorMessage = "保存项目失败：\(error.localizedDescription)"
            }
        }
    }

    func closeProject() {
        guard currentSession == nil else {
            errorMessage = "项目保存或关闭屏障尚未完成。"
            return
        }
        captureSetup.stopPresentation()
        let nextRecordingStyle = EditorStylePreset(name: "上次使用", project: project)
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
        // Use the same source-safe style boundary as a cold launch. Directly
        // copying the previous CanvasStyle carried that episode's crop (and a
        // project-relative background image) into the next recording even
        // though saved presets correctly exclude both.
        project = nextRecordingStyle.applying(to: nextRecordingBaseline)
        captureSetup.reset()
        resumeLiveInputIndicatorsForSetup()
        phase = .setup
        refreshRecentProjects()
    }

    /// Recording suspends camera preview and microphone metering. Returning
    /// to setup must restart them, otherwise the level bar stays dead until
    /// the user manually re-selects the microphone.
    func resumeLiveInputIndicatorsForSetup() {
        // start() is idempotent and refreshes the catalog immediately after an
        // editor-only suspension. This avoids retaining device observers while
        // editing without showing stale choices on return to setup.
        captureDeviceLifecycle.start()
        applySavedSystemAudioPreference()
        applySavedMicrophonePreferenceForSetup()
        if configuration.recordsCamera,
           let cameraID = configuration.cameraDeviceID,
           let device = availableCameras.first(where: { $0.id == cameraID }) {
            selectCamera(device)
        }
        if configuration.recordsMicrophone,
           microphoneMeterTask == nil,
           let microphoneID = configuration.microphoneDeviceID,
           let device = availableMicrophones.first(where: { $0.id == microphoneID }) {
            startMicrophoneMeter(device)
        }
    }

    func chooseWallpaperAsset() -> BackgroundSource? {
        guard let currentSession else {
            errorMessage = "请先完成一次真实录制，再把壁纸保存进项目。"
            return nil
        }
        let panel = NSOpenPanel()
        panel.title = "选择画布背景"
        panel.prompt = "使用这个背景"
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [
            .png, .jpeg, .heic, .tiff, .movie, .mpeg4Movie, .quickTimeMovie,
        ]
        guard panel.runModal() == .OK, let sourceURL = panel.url else { return nil }

        do {
            return try importBackgroundAsset(from: sourceURL, session: currentSession)
        } catch {
            errorMessage = error.localizedDescription
            return nil
        }
    }

    func chooseOverlayImageAsset() -> (relativePath: String, url: URL)? {
        guard let currentSession else {
            errorMessage = "请先打开一个可编辑项目。"
            return nil
        }
        let panel = NSOpenPanel()
        panel.title = "选择贴图"
        panel.prompt = "添加"
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.png, .jpeg, .heic, .tiff]
        guard panel.runModal() == .OK, let sourceURL = panel.url else { return nil }
        do {
            return try ProjectStore.importOverlayImage(
                from: sourceURL,
                session: currentSession
            )
        } catch {
            errorMessage = error.localizedDescription
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
                errorMessage = error.localizedDescription
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
            errorMessage = error.localizedDescription
            return nil
        }
    }

    /// 用户自己的桌面图片复制进项目以保证可移植；Apple 管理的系统
    /// 壁纸与屏保只保留本机引用，不把系统素材静默复制成项目资产。
    func importCurrentDesktopWallpaper() -> BackgroundSource? {
        guard let currentSession else {
            errorMessage = "请先完成一次真实录制，再把壁纸保存进项目。"
            return nil
        }
        guard let screen = NSScreen.screens.first,
              let desktopURL = NSWorkspace.shared.desktopImageURL(for: screen),
              let sourceURL = SystemWallpaperLibrary.resolvedMediaURL(
                  forDesktopImageURL: desktopURL
              ) else {
            errorMessage = "无法读取当前桌面壁纸。"
            return nil
        }
        guard FileManager.default.isReadableFile(atPath: sourceURL.path) else {
            errorMessage = "当前桌面资源不可读取。"
            return nil
        }
        if SystemWallpaperLibrary.isAppleManagedMediaURL(sourceURL) {
            return SystemWallpaperLibrary.isVideoURL(sourceURL)
                ? .systemVideo(absolutePath: sourceURL.path)
                : .systemImage(absolutePath: sourceURL.path)
        }
        do {
            return try importBackgroundAsset(from: sourceURL, session: currentSession)
        } catch {
            errorMessage = error.localizedDescription
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
        let panel = NSOpenPanel()
        panel.title = "选择源文件导出文件夹"
        panel.prompt = "导出到这里"
        panel.directoryURL = AppPreferences.exportDirectoryURL
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let destination = panel.url else { return }

        let sources = ProjectSourceMediaFiles(
            screen: screen,
            camera: cameraRecordingURL,
            microphone: microphoneRecordingURL
        )
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
                        into: destination
                    )
                }.value
                NSWorkspace.shared.activateFileViewerSelecting([folder])
            } catch {
                errorMessage = "导出源文件失败：\(error.localizedDescription)"
            }
        }
    }

    /// SRC-003: replace only the camera source with a file conformed/aligned in
    /// an external editor. Screen, microphone, cuts and effects remain exactly
    /// where they are; the new camera declares its own time zero.
    func importCameraReplacement() {
        guard phase == .editor,
              !isMediaExchangeRunning,
              !exporter.isExporting,
              let session = currentSession,
              project.media?.camera != nil else { return }
        guard let camera = chooseAlignedMediaFile(
            title: "选择替换用摄像头文件",
            prompt: "替换摄像头",
            contentType: .movie,
            initialURL: cameraRecordingURL
        ) else { return }

        let sessionPath = session.packageURL.standardizedFileURL.path
        let sessionID = editorSessionID
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
                guard editorSessionID == sessionID,
                      currentSession?.packageURL.standardizedFileURL.path == sessionPath,
                      var media = project.media else {
                    await ProjectPackageDisposal.removeIfPresent(imported.folderURL)
                    return
                }

                media.camera = ProjectMediaReference(
                    relativePath: imported.cameraRelativePath
                )
                var replacement = project
                replacement.media = media
                project = replacement
                cameraRecordingURL = imported.cameraURL
                editorContextRevision &+= 1
                _ = try await workspace.flush(replacement)
            } catch {
                errorMessage = "替换摄像头文件失败：\(error.localizedDescription)"
            }
        }
    }

    func chooseAlignedMediaFile(
        title: String,
        prompt: String,
        contentType: UTType,
        initialURL: URL?
    ) -> URL? {
        let panel = NSOpenPanel()
        panel.title = title
        panel.prompt = prompt
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [contentType]
        panel.directoryURL = initialURL?.deletingLastPathComponent()
        return panel.runModal() == .OK ? panel.url : nil
    }

    /// Lets the user choose where saved projects land (另存为/保存后的项目包).
    func chooseProjectsFolder() {
        let panel = NSOpenPanel()
        panel.title = "选择项目保存位置"
        panel.prompt = "选择"
        panel.message = "后续录制的项目会自动保存到所选文件夹。"
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
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try ProjectStore.setSavedProjectsFolder(url)
            refreshRecentProjects()
        } catch {
            errorMessage = "无法设置项目保存位置：\(error.localizedDescription)"
        }
    }

    func openProjectPicker() {
        let panel = NSOpenPanel()
        panel.title = "打开 \(AppIdentity.displayName) 项目"
        panel.prompt = "打开"
        panel.message = "选择要继续编辑的项目"
        panel.directoryURL = ProjectStore.savedProjectsFolder
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        if let projectContentType = UTType("cn.laogou.dogsc-project") {
            panel.allowedContentTypes = [projectContentType]
        }
        guard panel.runModal() == .OK, let selectedURL = panel.url else { return }
        let packageExtensions = ["dogscproject", "silkyproject"]
        let packageURL = packageExtensions.contains(selectedURL.pathExtension.lowercased())
            ? selectedURL
            : (selectedURL.lastPathComponent == "project.json"
                ? selectedURL.deletingLastPathComponent()
                : selectedURL)
        requestOpenProject(at: packageURL)
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
        switch phase {
        case .setup:
            beginProjectOpen(at: packageURL, projectToFlush: nil)
        case .editor:
            let projectSnapshot = project
            beginProjectOpen(
                at: packageURL,
                projectToFlush: currentSession == nil ? nil : projectSnapshot
            )
        case .preparing, .recording, .finishing:
            errorMessage = "录制准备、录制或写入期间不能打开其他项目。请先结束当前操作。"
        }
    }

    func openProject(at packageURL: URL) {
        requestOpenProject(at: packageURL)
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
                    errorMessage = "打开新项目前无法安全保存当前项目：\(error.localizedDescription)"
                    recorderTransitionStage = .idle
                    phase = .editor
                    return
                }
            }

            guard !Task.isCancelled else { return }
            suspendLiveInputIndicators()
            captureSetup.reset()
            let loader = Task.detached(priority: .userInitiated) {
                try ProjectOpenSnapshot.load(at: packageURL)
            }
            do {
                let loaded = try await withTaskCancellationHandler {
                    try await loader.value
                } onCancel: {
                    loader.cancel()
                }
                try Task.checkCancellation()
                try applyProjectOpenSnapshot(loaded)
                recorderTransitionStage = .idle
            } catch is CancellationError {
                return
            } catch {
                projectOpenLogger.error(
                    "project open failed url=\(packageURL.path, privacy: .private) error=\(String(reflecting: error), privacy: .public)"
                )
                errorMessage = error.localizedDescription
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
            : "项目已打开，但\(loaded.warnings.joined(separator: " "))"
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
        guard phase == .setup else { return }
        guard hasRequiredRecordingPermissions else {
            captureSetup.stopPresentation()
            beginRequiredPermissionOnboardingIfNeeded()
            return
        }
        captureSetup.selectSource(source)
    }

    func beginWindowSelection() {
        selectCaptureSource(.window)
    }

    func selectCaptureDisplay(_ display: CaptureDisplay) {
        guard phase == .setup else { return }
        guard hasRequiredRecordingPermissions else {
            captureSetup.stopPresentation()
            beginRequiredPermissionOnboardingIfNeeded()
            return
        }
        captureSetup.selectDisplay(display)
    }

    func chooseCaptureArea() {
        selectCaptureSource(.area)
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
            WindowCoordinator.endCaptureSourceSelection()
        }
        if hasRequiredRecordingPermissions,
           errorMessage?.contains("权限") == true {
            errorMessage = nil
        }
    }

    func beginRequiredPermissionOnboardingIfNeeded() {
        refreshRequiredRecordingPermissions()
        guard showsRequiredPermissionGate else { return }
        captureSetup.stopPresentation()
        WindowCoordinator.endCaptureSourceSelection()
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
        WindowCoordinator.endCaptureSourceSelection()
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

    func refreshCaptureDevices() {
        let screenDevices = CaptureDeviceCatalog.screenDevices()
        let cameras = CaptureDeviceCatalog.videoDevices()
        let microphones = CaptureDeviceCatalog.audioDevices()
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
        let operation = captureDeviceLifecycle.begin(.camera)
        cameraPreviewTask?.cancel()
        cameraPreviewTask = nil
        captureSetup.setCamera(device)
        cameraRuntimeFormat = nil
        refreshAvailableCameraResolutions(deviceUniqueID: device?.id)
        saveCameraPreference(device)
        errorMessage = nil
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
        let operation = captureDeviceLifecycle.begin(.camera)
        cameraPreviewTask?.cancel()
        cameraPreviewTask = nil
        captureSetup.setCameraCaptureResolution(resolution)
        cameraRuntimeFormat = nil
        errorMessage = nil
        startCameraPreview(device, operation: operation)
    }

    func selectMicrophone(_ device: CaptureDeviceInfo?) {
        let operation = captureDeviceLifecycle.begin(.microphone)
        microphoneMeterTask?.cancel()
        microphoneMeterTask = nil
        microphoneInputLevel.update(0)
        captureSetup.setMicrophone(device)
        saveMicrophonePreference(device)
        errorMessage = nil
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
                scope.rawValue,
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

    private func applySavedMicrophonePreferenceForSetup() {
        let enabled = AppPreferences.isDefaultMicrophoneRecordingEnabled
        guard enabled else {
            if configuration.recordsMicrophone {
                selectMicrophone(nil)
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
        selectMicrophone(device)
    }

    func restorePreferredCaptureDevicesIfAvailable() {
        guard phase.allowsAutomaticLiveInputRestoration else { return }
        let defaults = UserDefaults.standard
        if !configuration.recordsCamera,
           defaults.bool(forKey: CaptureDevicePreferenceKey.cameraEnabled),
           let preferredID = defaults.string(forKey: CaptureDevicePreferenceKey.cameraID),
           let device = availableCameras.first(where: { $0.id == preferredID }) {
            selectCamera(device)
        }
        if !configuration.recordsMicrophone,
           defaults.bool(forKey: CaptureDevicePreferenceKey.microphoneEnabled) {
            let preferredID = defaults.string(
                forKey: CaptureDevicePreferenceKey.microphoneID
            )
            let device = preferredID.flatMap { preferredID in
                availableMicrophones.first(where: { $0.id == preferredID })
            } ?? availableMicrophones.first
            if let device { selectMicrophone(device) }
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
        let resolutions = deviceUniqueID.map {
            CaptureDeviceCatalog.cameraResolutions(deviceUniqueID: $0)
        } ?? []
        if availableCameraResolutions != resolutions {
            availableCameraResolutions = resolutions
        }
    }
}
