import AppKit
import AVFoundation
import Combine
import Foundation
import OSLog
import RecorderCore
import UniformTypeIdentifiers

private struct CameraPreviewReadinessTimeout: LocalizedError {
    var errorDescription: String? {
        "没有收到摄像头画面，已暂时关闭摄像头。请在摄像头菜单中重新选择后再试。"
    }
}

/// Resolves the UI-facing startup wait once without forcing it to remain
/// structured under an AVCaptureSession.startRunning() call that can block its
/// private queue. Cancelling the losing start task still schedules the
/// recorder's normal generation-safe teardown.
private final class CameraPreviewStartGate: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, any Error>?
    private var pendingResult: Result<Void, any Error>?
    private var tasks: [Task<Void, Never>] = []
    private var isResolved = false

    func wait() async throws {
        try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<Void, any Error>) in
            lock.lock()
            if let pendingResult {
                self.pendingResult = nil
                lock.unlock()
                continuation.resume(with: pendingResult)
            } else {
                self.continuation = continuation
                lock.unlock()
            }
        }
    }

    func register(_ task: Task<Void, Never>) {
        lock.lock()
        if isResolved {
            lock.unlock()
            task.cancel()
        } else {
            tasks.append(task)
            lock.unlock()
        }
    }

    func resolve(_ result: Result<Void, any Error>) {
        lock.lock()
        guard !isResolved else {
            lock.unlock()
            return
        }
        isResolved = true
        let continuation = self.continuation
        self.continuation = nil
        if continuation == nil {
            pendingResult = result
        }
        let tasks = self.tasks
        self.tasks.removeAll(keepingCapacity: false)
        lock.unlock()

        tasks.forEach { $0.cancel() }
        continuation?.resume(with: result)
    }
}

extension AppModel {
    private func startCameraPreviewSession(
        recorder: CameraRecorder,
        deviceUniqueID: String,
        captureResolution: CameraCaptureResolution?,
        timeout: Duration
    ) async throws {
        let gate = CameraPreviewStartGate()
        try await withTaskCancellationHandler {
            let startTask = Task {
                do {
                    try await recorder.startPreview(
                        deviceUniqueID: deviceUniqueID,
                        captureResolution: captureResolution
                    )
                    gate.resolve(.success(()))
                } catch {
                    gate.resolve(.failure(error))
                }
            }
            gate.register(startTask)
            let timeoutTask = Task {
                do {
                    try await Task.sleep(for: timeout)
                } catch {
                    return
                }
                gate.resolve(.failure(CameraPreviewReadinessTimeout()))
            }
            gate.register(timeoutTask)
            try await gate.wait()
        } onCancel: {
            gate.resolve(.failure(CancellationError()))
        }
    }

    func startCameraPreview(
        _ device: CaptureDeviceInfo,
        operation: CaptureDeviceOperationToken
    ) {
        // Bind runtime samples to this exact selection generation. A callback
        // queued by the old format/device must never turn a newly restarted
        // camera green or allow recording before its own first sample arrives.
        cameraRecorder.onRuntimeFormatChange = { @MainActor [weak self] format in
            guard let self,
                  self.captureDeviceLifecycle.isCurrent(operation),
                  self.configuration.recordsCamera,
                  self.configuration.cameraDeviceID == device.id,
                  self.phase == .setup || self.phase == .preparing || self.phase == .recording
            else { return }
            self.cameraRuntimeFormat = format
            self.cameraPreviewController.updateSourceSize(
                width: format.width,
                height: format.height
            )
        }
        if phase == .setup || phase == .preparing || phase == .recording {
            cameraPreviewController.showConnecting(deviceName: device.name)
        }
        cameraPreviewTask = Task { @MainActor [weak self, recorder = cameraRecorder] in
            do {
                let startupDeadline = ContinuousClock.now.advanced(by: .seconds(12))
                try await self?.startCameraPreviewSession(
                    recorder: recorder,
                    deviceUniqueID: device.id,
                    captureResolution: self?.configuration.cameraCaptureResolution,
                    timeout: .seconds(12)
                )
                guard let self,
                      !Task.isCancelled,
                      self.captureDeviceLifecycle.isCurrent(operation),
                      self.configuration.recordsCamera,
                      self.configuration.cameraDeviceID == device.id,
                      self.phase == .setup || self.phase == .preparing || self.phase == .recording else {
                    // Selection/phase changes already enqueue the replacement or
                    // teardown. A stale task must not stop the new live session.
                    return
                }
                // A running AVCaptureSession is not yet a usable camera. Some
                // disconnected or externally occupied devices report that the
                // session started but never deliver a first sample, which used
                // to leave the recorder bar in "正在检测…" forever and
                // permanently disable Start. Wait for the same real sample
                // contract used by recording readiness, then fail back to the
                // no-camera state instead of creating another UI layer.
                while self.cameraRuntimeFormat == nil {
                    guard !Task.isCancelled,
                          self.captureDeviceLifecycle.isCurrent(operation),
                          self.configuration.recordsCamera,
                          self.configuration.cameraDeviceID == device.id,
                          self.phase == .setup || self.phase == .preparing || self.phase == .recording else {
                        return
                    }
                    guard ContinuousClock.now < startupDeadline else {
                        throw CameraPreviewReadinessTimeout()
                    }
                    try await Task.sleep(for: .milliseconds(100))
                }
                self.cameraPreviewController.showPreview()
            } catch {
                guard let self,
                      !Task.isCancelled,
                      self.captureDeviceLifecycle.isCurrent(operation),
                      self.configuration.cameraDeviceID == device.id else {
                    return
                }
                let didTimeOut = error is CameraPreviewReadinessTimeout
                if didTimeOut {
                    // startRunning itself may still occupy the recorder queue;
                    // enqueue teardown without making the UI wait for it.
                    recorder.requestPreviewStop()
                } else {
                    await recorder.stopPreview()
                }
                _ = self.captureSetup.clearCamera(ifMatching: device.id)
                self.cameraRuntimeFormat = nil
                self.cameraPreviewController.hide()
                // The control itself immediately returns to "无摄像头". A
                // no-frame timeout is deliberately silent so the fallback
                // remains non-blocking; real permission and device failures
                // still use the existing recorder alert.
                self.errorMessage = didTimeOut ? nil : error.localizedDescription
            }
        }
    }

    func startMicrophoneMeter(
        _ device: CaptureDeviceInfo,
        operation: CaptureDeviceOperationToken? = nil
    ) {
        let operation = operation ?? captureDeviceLifecycle.begin(.microphone)
        microphoneMeterTask = Task { @MainActor [weak self, recorder = microphoneRecorder] in
            do {
                try await recorder.startMonitoring(deviceUniqueID: device.id)
                guard !Task.isCancelled,
                      self?.captureDeviceLifecycle.isCurrent(operation) == true,
                      self?.configuration.recordsMicrophone == true,
                      self?.configuration.microphoneDeviceID == device.id else {
                    // The current selection owns start/stop. The recorder's
                    // cancellation path is already scoped to its own request ID.
                    return
                }
                while !Task.isCancelled {
                    guard let self,
                          self.captureDeviceLifecycle.isCurrent(operation),
                          self.configuration.recordsMicrophone,
                          self.configuration.microphoneDeviceID == device.id else { return }
                    let liveLevel = recorder.normalizedInputLevel()
                    self.microphoneInputLevel.update(
                        max(liveLevel, self.microphoneInputLevel.value * 0.72)
                    )
                    try? await Task.sleep(for: .milliseconds(55))
                }
            } catch {
                guard let self,
                      !Task.isCancelled,
                      self.captureDeviceLifecycle.isCurrent(operation),
                      self.configuration.microphoneDeviceID == device.id else { return }
                _ = self.captureSetup.clearMicrophone(ifMatching: device.id)
                self.microphoneInputLevel.update(0)
                self.errorMessage = error.localizedDescription
            }
        }
    }

    func suspendLiveInputIndicators() {
        _ = captureDeviceLifecycle.begin(.camera)
        _ = captureDeviceLifecycle.begin(.microphone)
        // The editor consumes recorded files only. Stop connection observers
        // as well as the active sessions so a USB reconnect cannot enumerate
        // formats or briefly reacquire a preferred camera behind the editor.
        // `resumeLiveInputIndicatorsForSetup()` reinstalls the observer and
        // performs one fresh catalog read before the recorder UI is reused.
        captureDeviceLifecycle.stop()
        captureCatalogTask?.cancel()
        captureCatalogTask = nil
        cameraResolutionTask?.cancel()
        cameraResolutionTask = nil
        cameraPreviewTask?.cancel()
        cameraPreviewTask = nil
        cameraRuntimeFormat = nil
        cameraRecorder.onRuntimeFormatChange = nil
        cameraPreviewController.releaseResources()
        microphoneMeterTask?.cancel()
        microphoneMeterTask = nil
        microphoneInputLevel.update(0)
        // Cancelling a Task that already completed startPreview/startMonitoring
        // does not run its cancellation handler. Explicitly stop both idle
        // capture sessions; otherwise opening a saved project merely hides the
        // UI while macOS correctly keeps showing the camera privacy light.
        cameraRecorder.requestIdleResourceRelease()
        microphoneRecorder.requestIdleResourceRelease()
        deviceRecorder.requestIdleResourceRelease()
    }

    /// Final process shutdown is an explicit lifecycle boundary. macOS will
    /// ultimately reclaim a dead process, but closing device graphs and view
    /// resources first prevents CoreMediaIO/VideoToolbox helpers from carrying
    /// stale work into the next foreground video application.
    func shutdownForApplicationTermination() {
        if phase == .editor {
            EditorStylePresetStore.rememberLastUsedStyle(from: project)
        }
        projectOpenTask?.cancel()
        projectOpenTask = nil
        projectCatalogRefreshGeneration &+= 1
        projectCatalogRefreshTask?.cancel()
        projectCatalogRefreshTask = nil
        recoveryHeartbeatTask?.cancel()
        recoveryHeartbeatTask = nil
        surfaceVisibilityTask?.cancel()
        surfaceVisibilityTask = nil
        preparationTask?.cancel()
        preparationTask = nil
        finishingTask?.cancel()
        finishingTask = nil
        exporter.cancelExport()
        captureDeviceLifecycle.stop()
        captureCatalogTask?.cancel()
        captureCatalogTask = nil
        cameraResolutionTask?.cancel()
        cameraResolutionTask = nil
        captureSetup.stopPresentation()
        cameraPreviewTask?.cancel()
        cameraPreviewTask = nil
        microphoneMeterTask?.cancel()
        microphoneMeterTask = nil
        cameraPreviewController.releaseResources()
        _ = pointerRecorder.stop()
        cameraRecorder.releaseIdleResourcesSynchronously()
        microphoneRecorder.releaseIdleResourcesSynchronously()
        deviceRecorder.releaseIdleResourcesSynchronously()
        cameraRecorder.onPreviewSampleBuffer = nil
        cameraRecorder.onRuntimeFormatChange = nil
        cameraRecorder.onUnexpectedStop = nil
        microphoneRecorder.onUnexpectedStop = nil
        deviceRecorder.onUnexpectedStop = nil
    }

    func resumeLiveInputIndicatorsForRecording(plan: RecordingPlan) {
        if plan.configuration.recordsCamera {
            cameraPreviewController.showPreview()
        }
    }

    /// During a recording the same PCM sample stream drives both the AAC writer
    /// and this meter. Do not call `startMonitoring` again here: that would
    /// compete with the writer for the capture-session lifecycle. This task is
    /// deliberately observation-only and dies with the recording generation.
    func startRecordingMicrophoneLevelObservation(
        runID: RecordingRunID,
        deviceUniqueID: String,
        operation: CaptureDeviceOperationToken
    ) {
        microphoneMeterTask = Task { @MainActor [weak self, recorder = microphoneRecorder] in
            while !Task.isCancelled {
                guard let self,
                      self.captureDeviceLifecycle.isCurrent(operation),
                      self.recordingRuns.isCurrent(runID),
                      self.configuration.recordsMicrophone,
                      self.configuration.microphoneDeviceID == deviceUniqueID,
                      self.phase == .preparing || self.phase == .recording else { return }
                let liveLevel = recorder.normalizedInputLevel()
                self.microphoneInputLevel.update(
                    max(liveLevel, self.microphoneInputLevel.value * 0.72)
                )
                try? await Task.sleep(for: .milliseconds(55))
            }
        }
    }

    func startRecoveryHeartbeat(
        session: RecordingSession,
        runID: RecordingRunID,
        plan: RecordingPlan
    ) {
        recoveryHeartbeatTask?.cancel()
        recoveryHeartbeatTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                guard !Task.isCancelled,
                      let self,
                      self.phase == .recording,
                      self.recordingRuns.isCurrent(runID) else { break }
                let systemAudioDiagnostics = plan.configuration.recordsSystemAudio
                    ? await self.recorder.systemAudioDiagnostics() : nil
                let cameraDiagnostics = plan.configuration.recordsCamera
                    ? await self.cameraRecorder.captureDiagnosticsSnapshot() : nil
                let microphoneDiagnostics = plan.configuration.recordsMicrophone
                    ? await self.microphoneRecorder.captureDiagnosticsSnapshot() : nil
                guard !Task.isCancelled,
                      self.phase == .recording,
                      self.recordingRuns.isCurrent(runID) else { break }
                do {
                    try await self.recordingRecoveryJournal.persist(
                        RecordingRecoverySnapshot(
                            state: self.isRecordingPaused ? "paused" : "recording",
                            session: session,
                            frameRate: plan.configuration.captureFrameRate,
                            measurement: plan.configuration.source == .device
                                ? nil : self.recorder.liveMeasurement,
                            cameraDiagnostics: cameraDiagnostics,
                            systemAudioDiagnostics: systemAudioDiagnostics,
                            microphoneDiagnostics: microphoneDiagnostics,
                            performanceMonitor: self.recordingPerformanceMonitor,
                            appendsPerformanceSample: true,
                            screenRelativePath: plan.primaryRecordingRelativePath
                        )
                    )
                } catch {
                    guard !Task.isCancelled,
                          self.phase == .recording,
                          self.recordingRuns.isCurrent(runID) else { break }
                    self.errorMessage = error.localizedDescription
                }
            }
        }
    }

    func makeEditorWallpaperResolver() -> EditorWallpaperResolver {
        EditorWallpaperResolver(projectSession: currentSession)
    }

    func isNonemptyFile(_ url: URL) -> Bool {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attributes[.size] as? NSNumber else { return false }
        return size.int64Value > 0
    }

    func isUsableVideoFile(_ url: URL) async -> Bool {
        guard isNonemptyFile(url) else { return false }
        let asset = AVURLAsset(url: url)
        do {
            let tracks = try await asset.loadTracks(withMediaType: .video)
            let duration = try await asset.load(.duration)
            return !tracks.isEmpty && duration.isNumeric && duration.seconds > 0.01
        } catch {
            return false
        }
    }

    func displayedVideoSize(at url: URL) async -> CGSize? {
        let asset = AVURLAsset(url: url)
        guard let tracks = try? await asset.loadTracks(withMediaType: .video),
              let track = tracks.first,
              let naturalSize = try? await track.load(.naturalSize),
              let preferredTransform = try? await track.load(.preferredTransform)
        else { return nil }
        let size = VideoExporter.displayedVideoSize(
            naturalSize: naturalSize,
            preferredTransform: preferredTransform
        )
        guard size.width.isFinite, size.height.isFinite,
              size.width > 0, size.height > 0 else { return nil }
        return size
    }


    func chooseProjectSaveDestination() -> URL? {
        guard currentSession != nil else { return nil }
        try? FileManager.default.createDirectory(
            at: ProjectStore.savedProjectsFolder,
            withIntermediateDirectories: true
        )
        let panel = NSSavePanel()
        panel.title = "保存 \(AppIdentity.displayName) 项目"
        panel.prompt = "保存项目"
        panel.directoryURL = ProjectStore.savedProjectsFolder
        panel.nameFieldStringValue = sanitizedProjectFilename(project.title) + ".dogscproject"
        panel.allowedContentTypes = [UTType(
            exportedAs: "cn.laogou.dogsc-project",
            conformingTo: .package
        )]
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK else { return nil }
        return panel.url
    }

    func saveCurrentProject(to destination: URL, closeAfterSave: Bool) {
        if closeAfterSave {
            guard phase == .editor else { return }
            // 同步关闭编辑器窗口：flush 是异步的，期间的新编辑既不能落盘
            // （invalidate 后 autosave 被拒收）也不应被静默丢弃。
            recorderTransitionStage = .savingProject
            phase = .finishing
        }
        let projectSnapshot = project
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let result = if closeAfterSave {
                    try await workspace.moveAndInvalidate(projectSnapshot, to: destination)
                } else {
                    try await workspace.move(projectSnapshot, to: destination)
                }
                guard let result else { return }

                let moved = result.session
                if !closeAfterSave {
                    relocateEditorMedia(
                        for: projectSnapshot,
                        to: moved
                    )
                }
                ProjectStore.registerRecentProject(moved.packageURL)
                try? ProjectStore.setSavedProjectsFolder(
                    moved.packageURL.deletingLastPathComponent()
                )
                refreshRecentProjects()

                if closeAfterSave {
                    closeProject()
                }
            } catch {
                errorMessage = "保存项目失败：\(error.localizedDescription)"
                if closeAfterSave {
                    recorderTransitionStage = .idle
                    phase = .editor
                }
            }
        }
    }

    func flushCurrentProjectAndClose() {
        guard currentSession != nil else {
            closeProject()
            return
        }
        guard phase == .editor else { return }
        // 同步置 .finishing 关掉编辑器窗口，阻止 flush 期间产生会被丢弃的新编辑。
        recorderTransitionStage = .savingProject
        phase = .finishing
        let projectSnapshot = project
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                guard try await workspace.flushAndInvalidate(projectSnapshot) != nil else {
                    recorderTransitionStage = .idle
                    phase = .editor
                    return
                }
                closeProject()
            } catch {
                errorMessage = "保存项目失败：\(error.localizedDescription)"
                recorderTransitionStage = .idle
                phase = .editor
            }
        }
    }

    func deleteCurrentProjectAndClose() {
        guard currentSession != nil else {
            closeProject()
            return
        }
        guard phase == .editor else { return }
        // 删除同样是最终屏障：同步关窗，避免等待窗口期内继续编辑。
        recorderTransitionStage = .discardingRecording
        phase = .finishing
        let wasSaved = isCurrentProjectSaved
        Task { @MainActor [weak self] in
            guard let self else { return }
            guard let session = await workspace.invalidateCurrentSession() else {
                recorderTransitionStage = .idle
                phase = .editor
                return
            }
            do {
                try await ProjectPackageDisposal.moveToTrash(session.packageURL)
                ProjectStore.forgetRecentProject(session.packageURL)
                closeProject()
            } catch {
                workspace.activate(session: session, isSaved: wasSaved)
                errorMessage = "无法删除项目：\(error.localizedDescription)"
                recorderTransitionStage = .idle
                phase = .editor
            }
        }
    }

    func sanitizedProjectFilename(_ title: String) -> String {
        let invalid = CharacterSet(charactersIn: "/:")
        let parts = title.components(separatedBy: invalid)
        let value = parts.joined(separator: "-").trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? "未命名录制" : value
    }

    func detailedErrorDescription(_ error: any Error) -> String {
        let nsError = error as NSError
        var details = [nsError.localizedDescription]
        details.append("\(nsError.domain) \(nsError.code)")
        if let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? NSError {
            details.append("底层错误：\(underlying.domain) \(underlying.code)")
        }
        return details.joined(separator: " · ")
    }

    func beginPauseAccounting() {
        guard pauseStartedAt == nil else { return }
        pauseStartedAt = Date()
    }

    func resumePauseAccounting() {
        guard let pauseStartedAt else { return }
        accumulatedPausedDuration += Date().timeIntervalSince(pauseStartedAt)
        self.pauseStartedAt = nil
    }

    func finishPauseAccounting() {
        resumePauseAccounting()
    }

    func abandonCurrentRecording(restart: Bool) {
        guard phase == .recording,
              !isPauseTransitioning,
              let run = recordingRuns.active else { return }
        suspendLiveInputIndicators()
        captureSetup.stopPresentation()
        surfaceVisibilityTask?.cancel()
        surfaceVisibilityTask = nil
        finishPauseAccounting()
        isRecordingPaused = false
        recorderTransitionStage = .discardingRecording
        phase = .finishing
        recoveryHeartbeatTask?.cancel()
        recoveryHeartbeatTask = nil

        finishingTask = Task { @MainActor [weak self] in
            guard let self else { return }
            let stopResult: RecordingTrackFinalizationResult
            do {
                stopResult = try await trackFinalizer.finalize(
                    RecordingTrackFinalizationRequest(
                        runID: run.id,
                        startedTracks: run.startedTracks,
                        intent: .discard(restart: restart)
                    ),
                    currentRunID: recordingRuns.active?.id
                )
            } catch {
                guard recordingRuns.isCurrent(run.id) else { return }
                await recoverFromFinalizeFailure(
                    run: run,
                    error: error,
                    resetCapture: !restart,
                    restart: restart
                )
                return
            }
            guard recordingRuns.isCurrent(run.id) else { return }
            var finalizationErrors = stopResult.failures.compactMap(\.errorDescription)

            if currentSession != nil {
                let discardedSession = await workspace.invalidateCurrentSession()
                guard recordingRuns.isCurrent(run.id) else { return }
                if let discardedSession {
                    try? await recordingRecoveryJournal.persist(
                        RecordingRecoverySnapshot(
                            state: "discarded",
                            session: discardedSession,
                            frameRate: run.plan.configuration.captureFrameRate,
                            screenRelativePath: run.plan.primaryRecordingRelativePath
                        )
                    )
                    do {
                        try await ProjectPackageDisposal.moveToTrash(
                            discardedSession.packageURL
                        )
                    } catch {
                        finalizationErrors.append(error.localizedDescription)
                    }
                }
            }

            guard recordingRuns.end(run.id) != nil else { return }
            finishingTask = nil
            resetTransientRecordingState()
            if !restart { captureSetup.reset() }
            refreshRecentProjects()
            if !finalizationErrors.isEmpty {
                errorMessage = finalizationErrors.joined(separator: "；")
            }
            // 丢弃/放弃录制回悬浮窗同样恢复麦克风监听与摄像头预览。
            resumeLiveInputIndicatorsForSetup()
            recorderTransitionStage = .idle
            phase = .setup
            if restart { startRecording() }
        }
    }

    /// A finalizer failure must not strand the state machine in `.finishing`
    /// (every entry point is phase-guarded, so the app would otherwise be
    /// stuck until the user kills the process). End the run, invalidate the
    /// session with a recovery manifest, and return to setup.
    func recoverFromFinalizeFailure(
        run: RecordingRun,
        error: any Error,
        resetCapture: Bool,
        restart: Bool
    ) async {
        finishingTask = nil
        errorMessage = error.localizedDescription
        if let session = await workspace.invalidateCurrentSession() {
            let systemAudioDiagnostics = run.plan.configuration.recordsSystemAudio
                ? await recorder.systemAudioDiagnostics() : nil
            let cameraDiagnostics = run.plan.configuration.recordsCamera
                ? await cameraRecorder.captureDiagnosticsSnapshot() : nil
            let microphoneDiagnostics = run.plan.configuration.recordsMicrophone
                ? await microphoneRecorder.captureDiagnosticsSnapshot() : nil
            try? await recordingRecoveryJournal.persist(
                RecordingRecoverySnapshot(
                    state: "failed",
                    session: session,
                    frameRate: run.plan.configuration.captureFrameRate,
                    measurement: run.plan.configuration.source == .device
                        ? nil : recorder.lastMeasurement,
                    cameraDiagnostics: cameraDiagnostics,
                    systemAudioDiagnostics: systemAudioDiagnostics,
                    microphoneDiagnostics: microphoneDiagnostics,
                    performanceMonitor: recordingPerformanceMonitor,
                    appendsPerformanceSample: true,
                    screenRelativePath: run.plan.primaryRecordingRelativePath
                )
            )
        }
        _ = recordingRuns.end(run.id)
        resetTransientRecordingState()
        if resetCapture { captureSetup.reset() }
        refreshRecentProjects()
        // 录制失败回悬浮窗同样要恢复麦克风监听/摄像头预览，
        // 否则拾音条要等手动切换设备才恢复。
        resumeLiveInputIndicatorsForSetup()
        recorderTransitionStage = .idle
        phase = .setup
        if restart { startRecording() }
    }

    func resetTransientRecordingState() {
        recordingPerformanceMonitor = nil
        recordingURL = nil
        cameraRecordingURL = nil
        microphoneRecordingURL = nil
        pointerEvents = []
        startedAt = nil
        isRecordingPaused = false
        isPauseTransitioning = false
        stopRequestedDuringPauseTransition = false
        pauseStartedAt = nil
        accumulatedPausedDuration = 0
        recorderTransitionStage = .idle
        project.media = nil
        project.zoomAnimations = []
    }

    func discardFailedPreparationSessionIfNeeded(
        runID: RecordingRunID,
        plan: RecordingPlan
    ) async -> Bool {
        guard recordingRuns.isCurrent(runID) else { return false }
        if currentSession != nil {
            let failedSession = await workspace.invalidateCurrentSession()
            guard recordingRuns.isCurrent(runID) else { return false }
            if let failedSession {
                try? await recordingRecoveryJournal.persist(
                    RecordingRecoverySnapshot(
                        state: "failed-to-start",
                        session: failedSession,
                        frameRate: plan.configuration.captureFrameRate,
                        performanceMonitor: recordingPerformanceMonitor,
                        screenRelativePath: plan.primaryRecordingRelativePath
                    )
                )
                try? await ProjectPackageDisposal.moveToTrash(
                    failedSession.packageURL
                )
            }
        }
        guard recordingRuns.end(runID) != nil else { return false }
        resetTransientRecordingState()
        refreshRecentProjects()
        return true
    }

    func zoomAnimationsClippedToRecording(
        _ animations: [ZoomAnimationClip],
        recordingURL: URL?
    ) async -> [ZoomAnimationClip] {
        guard let recordingURL,
              let duration = try? await AVURLAsset(url: recordingURL).load(.duration).seconds,
              duration.isFinite,
              duration > 0 else { return animations }
        return AutoZoomPlanner.clipped(animations, to: duration)
    }

    func handleUnexpectedCaptureStop(runID: RecordingRunID, error: any Error) {
        guard recordingRuns.isCurrent(runID) else { return }
        if phase == .preparing {
            // 屏幕流在准备期间已死亡（markStarted 之后、phase 切换之前）。
            // preparation 尾段会抛出该错误走 rollback，避免 UI 显示录制中
            // 但录屏流已死，直到用户手动停止才发现没有可用视频轨。
            preparingInterruptedError = error
            errorMessage = "录制意外停止，正在安全结束并保留已经写入的素材："
                + detailedErrorDescription(error)
            return
        }
        guard phase == .recording else { return }
        errorMessage = "录制意外停止，正在安全结束并保留已经写入的素材："
            + detailedErrorDescription(error)
        stopRecording()
    }
}
