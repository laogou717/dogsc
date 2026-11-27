import AppKit
import AVFoundation
import Combine
import Foundation
import OSLog
import RecorderCore
import UniformTypeIdentifiers

let preparationLogger = Logger(
    subsystem: "cn.laogou.dogsc",
    category: "recording-preparation"
)

enum AppPhase: Equatable {
    case setup
    case preparing
    case recording
    case finishing
    case recordingComplete
    case editor

    /// Device preferences may create live camera/microphone sessions. Only the
    /// setup surface is allowed to restore them automatically; reconnect
    /// notifications received while editing must remain catalog-only state.
    var allowsAutomaticLiveInputRestoration: Bool {
        self == .setup
    }
}

enum AppModelPurpose {
    case recording
    case editing
}

enum RecorderTransitionStage: Equatable, Sendable {
    case idle
    case checkingPermissions
    case creatingProject
    case startingCamera
    case startingMicrophone
    case startingPrimaryCapture
    case aligningTimeline
    case finalizingTracks
    case validatingRecording
    case savingProject
    case discardingRecording
    case openingEditor

    var title: String {
        switch self {
        case .idle: appLocalized("正在处理…")
        case .checkingPermissions: appLocalized("正在检查设备与权限…")
        case .creatingProject: appLocalized("正在创建录制项目…")
        case .startingCamera: appLocalized("正在启动摄像头…")
        case .startingMicrophone: appLocalized("正在启动麦克风…")
        case .startingPrimaryCapture: appLocalized("正在等待首个屏幕帧…")
        case .aligningTimeline: appLocalized("正在对齐各轨时间轴…")
        case .finalizingTracks: appLocalized("正在结束所有录制轨道…")
        case .validatingRecording: appLocalized("正在校验录制素材…")
        case .savingProject: appLocalized("正在保存项目…")
        case .discardingRecording: appLocalized("正在安全丢弃录制…")
        case .openingEditor: appLocalized("正在打开编辑器…")
        }
    }
}

enum CaptureDevicePreferenceKey {
    static let cameraEnabled = "capture.camera.enabled"
    static let cameraID = "capture.camera.device-id"
    static let cameraName = "capture.camera.device-name"
    static let systemAudioEnabled = "capture.system-audio.enabled"
    static let systemAudioScope = "capture.system-audio.scope"
    static let microphoneEnabled = "capture.microphone.enabled"
    static let microphoneID = "capture.microphone.device-id"
    static let microphoneName = "capture.microphone.device-name"
}

/// Fast microphone-meter updates live outside AppModel.objectWillChange.
/// Otherwise every 55 ms level sample invalidates the complete setup toolbar,
/// including camera menus and device-format discovery.
@MainActor
final class LiveMicrophoneLevelState: ObservableObject {
    @Published private(set) var value: Double = 0

    func update(_ value: Double) {
        let normalized = min(max(value, 0), 1)
        guard abs(normalized - self.value) >= 0.002 || normalized == 0 else { return }
        self.value = normalized
    }
}

/// Upgrades only the untouched legacy motion preset. User-authored spring
/// values remain authoritative. The new values form separate near-critically
/// damped cursor and screen systems, so the cursor can lead while the camera
/// settles without oscillation or locking onto each input sample.
enum LegacyMotionDefaultsUpgrade {
    static func upgraded(_ motion: MotionStyle) -> MotionStyle {
        var result = motion
        let tolerance = 0.000_001
        if abs(motion.screenSpringMass - 1) < tolerance,
           abs(motion.screenSpringStiffness - 180) < tolerance,
           abs(motion.screenSpringDamping - 24) < tolerance {
            result.screenSpringMass = 2.4
            result.screenSpringStiffness = 210
            result.screenSpringDamping = 42
        }
        if abs(motion.cursorSpringMass - 1) < tolerance,
           abs(motion.cursorSpringStiffness - 260) < tolerance,
           abs(motion.cursorSpringDamping - 30) < tolerance {
            result.cursorSpringMass = 2.8
            result.cursorSpringStiffness = 450
            result.cursorSpringDamping = 66
        }
        if motion.defaultZoomEasing == .cubic,
           abs(motion.defaultZoomTransitionDuration - 0.55) < tolerance {
            result.defaultZoomEasing = .spring
            result.defaultZoomTransitionDuration = 0.7
        } else if motion.defaultZoomEasing == .spring,
                  abs(motion.defaultZoomTransitionDuration - 0.6) < tolerance {
            // Upgrade the immediately preceding untouched default without
            // changing any user-authored duration.
            result.defaultZoomTransitionDuration = 0.7
        }
        return result
    }
}

@MainActor
final class AppModel: ObservableObject {
    let purpose: AppModelPurpose
    @Published var phase: AppPhase = .setup
    @Published var recorderTransitionStage = RecorderTransitionStage.idle
    let workspace: ProjectWorkspace
    let captureSetup: CaptureSetupController
    var projectDocument: ProjectDocument { workspace.document }
    var project: RecorderProject {
        get { projectDocument.project }
        set { projectDocument.replace(with: newValue) }
    }
    @Published var recordingURL: URL?
    @Published var cameraRecordingURL: URL?
    @Published var microphoneRecordingURL: URL?
    @Published var pointerEvents: [PointerEventRecord] = []
    @Published var recentProjects: [URL] = []
    @Published var recoverableProjects: [URL] = []
    @Published var availableCameras: [CaptureDeviceInfo] = []
    @Published var availableMicrophones: [CaptureDeviceInfo] = []
    @Published var availableCameraResolutions: [CameraCaptureResolution] = []
    @Published var cameraRuntimeFormat: CameraRuntimeFormat?
    @Published var errorMessage: String?
    /// Completion decisions own the current project until their persistence
    /// barrier finishes. Keep the completion card present and disable repeat
    /// actions instead of briefly opening an editor or another recording.
    @Published var isResolvingCompletedRecording = false
    /// Where the last completed take was saved (the completion card's
    /// "Saved" strip opens it from there).
    var lastSavedRecordingURL: URL?
    /// Non-fatal mid-recording interruptions (e.g. microphone unplugged).
    /// Merged into the stop-reporting message once recording finalizes.
    var recordingInterruptionWarnings: [String] = []
    /// A stream terminal error that arrived while preparation was still in
    /// flight. Checked right before `.recording` so a dead stream surfaces as
    /// a preparation rollback instead of a silent "recording" phase.
    var preparingInterruptedError: (any Error)?
    @Published var startedAt: Date?
    @Published var isRecordingPaused = false
    @Published var isPauseTransitioning = false
    @Published var recordingMarkerShortcutAvailable = false
    let microphoneInputLevel = LiveMicrophoneLevelState()
    let configurationCameraFrameSink = ImmediateCameraPreviewFrameSink()
    let studioCameraFrameSink = ImmediateCameraPreviewFrameSink()
    @Published var cameraStudioIsPresented = false
    var cameraBeforeStudio: CaptureDeviceInfo?
    var resolutionBeforeStudio: CameraCaptureResolution?
    @Published var recordingDestinationName = ProjectStore.savedProjectsFolder.lastPathComponent
    @Published var recordingTitleDraft = ""
    @Published var recordingCameraMirrored = UserDefaults.standard.object(forKey: "recording.camera-mirrored") as? Bool ?? true {
        didSet {
            UserDefaults.standard.set(recordingCameraMirrored, forKey: "recording.camera-mirrored")
            cameraPreviewController.setMirrored(recordingCameraMirrored)
        }
    }
    @Published var recordingCameraBeauty = UserDefaults.standard.data(forKey: "recording.camera-beauty")
        .flatMap { try? JSONDecoder().decode(CameraBeautySettings.self, from: $0) } ?? CameraBeautySettings() {
        didSet {
            UserDefaults.standard.set(try? JSONEncoder().encode(recordingCameraBeauty), forKey: "recording.camera-beauty")
            cameraBeautyPreviewProcessor.setSettings(recordingCameraBeauty)
            if phase == .recording || phase == .preparing { project.camera.beauty = recordingCameraBeauty }
        }
    }
    @Published var editorSessionID = UUID()
    @Published var editorContextRevision: UInt64 = 0
    @Published var isMediaExchangeRunning = false
    @Published var hasVerifiedScreenRecordingPermission = false
    @Published var hasAccessibilityPermission = AXIsProcessTrusted()
    @Published var isCheckingRequiredPermissions = false
    @Published var hasCompletedRequiredPermissionOnboarding = UserDefaults.standard.bool(
        forKey: "permissions.required-onboarding-completed"
    )

    /// A freshly recorded project may be discarded from its first editor
    /// session only while the user has not authored any edit. The project is
    /// already archived on disk; this flag controls close UX, not durability.
    var offersDiscardForUntouchedRecording = false
    var currentRecordingHasEditorChanges = false

    var isCurrentProjectSaved: Bool { workspace.isSaved }
    var persistenceStatus: ProjectPersistenceStatus { workspace.status }
    var configuration: CaptureConfiguration { captureSetup.configuration }
    var availableDisplays: [CaptureDisplay] { captureSetup.availableDisplays }
    var availableWindows: [CaptureWindowInfo] { captureSetup.availableWindows }
    var availableScreenDevices: [CaptureDeviceInfo] { captureSetup.availableScreenDevices }
    var captureReadiness: CaptureReadiness { captureSetup.readiness }

    var hasScreenRecordingPermissionForOnboarding: Bool {
        hasVerifiedScreenRecordingPermission
            || (hasCompletedRequiredPermissionOnboarding
                && captureReadiness.hasScreenRecordingPermission)
    }

    var hasRequiredRecordingPermissions: Bool {
        hasScreenRecordingPermissionForOnboarding && hasAccessibilityPermission
    }

    var showsRequiredPermissionGate: Bool {
        phase == .setup && !cameraStudioIsPresented
            && (!hasRequiredRecordingPermissions
                || !hasCompletedRequiredPermissionOnboarding)
    }

    lazy var recorder = ScreenRecorder()
    let exporter = VideoExporter()
    lazy var cameraRecorder = CameraRecorder()
    lazy var deviceRecorder = CameraRecorder(role: .iosDevice)
    lazy var microphoneRecorder = MicrophoneRecorder()
    lazy var cameraPreviewController = CameraPreviewWindowController()
    lazy var cameraBeautyPreviewProcessor = CameraBeautyPreviewProcessor(
        sinks: [cameraPreviewController.frameSink, configurationCameraFrameSink, studioCameraFrameSink], settings: recordingCameraBeauty
    )
    lazy var pointerRecorder = PointerEventRecorder()
    lazy var trackFinalizer = RecordingTrackFinalizer(operations: .live(
        screenRecorder: recorder,
        iosDeviceRecorder: deviceRecorder,
        cameraRecorder: cameraRecorder,
        microphoneRecorder: microphoneRecorder,
        pointerRecorder: pointerRecorder
    ))
    var workspaceSubscriptions = Set<AnyCancellable>()
    var projectOpenTask: Task<Void, Never>?
    var projectCatalogRefreshTask: Task<Void, Never>?
    var projectCatalogRefreshGeneration: UInt64 = 0
    var currentSession: RecordingSession? { workspace.session }
    var recoveryHeartbeatTask: Task<Void, Never>?
    let recordingRecoveryJournal = RecordingRecoveryJournal()
    var recordingPerformanceMonitor: RecordingPerformanceMonitor?
    var surfaceVisibilityTask: Task<Void, Never>?
    var captureCatalogTask: Task<Void, Never>?
    var cameraResolutionTask: Task<Void, Never>?
    var cameraResolutionDeviceID: String?
    var cameraPreviewTask: Task<Void, Never>?
    var pendingRecordingRestartTask: Task<Void, Never>?
    var pendingRecordingRestartGeneration: UInt64 = 0
    var microphoneMeterTask: Task<Void, Never>?
    var recordingRuns = RecordingRunState()
    var preparationTask: Task<Void, Never>?
    var finishingTask: Task<Void, Never>?
    lazy var captureDeviceLifecycle = CaptureDeviceLifecycle { [weak self] in
        self?.refreshCaptureDevicesInBackground()
    }
    var stopRequestedDuringPauseTransition = false
    var pauseStartedAt: Date?
    var accumulatedPausedDuration: TimeInterval = 0
    convenience init() {
        self.init(
            workspace: ProjectWorkspace(),
            captureSetup: CaptureSetupController()
        )
        project = EditorStylePresetStore.applyingLastUsedStyle(to: project)
        if EditorStylePresetStore.defaultPresetID == nil,
           let currentDesktop = SystemWallpaperLibrary.currentBackgroundSource() {
            project.canvas.backgroundSource = currentDesktop
        }
        applySavedSystemAudioPreference()
    }

    init(
        workspace: ProjectWorkspace,
        captureSetup: CaptureSetupController? = nil,
        purpose: AppModelPurpose = .recording
    ) {
        self.purpose = purpose
        self.workspace = workspace
        self.captureSetup = captureSetup ?? CaptureSetupController()
        workspace.objectWillChange
            .sink { [weak self] in self?.objectWillChange.send() }
            .store(in: &workspaceSubscriptions)
        projectDocument.$project
            .dropFirst()
            .sink { [weak self] _ in
                guard let self,
                      self.phase == .editor,
                      self.offersDiscardForUntouchedRecording else { return }
                self.currentRecordingHasEditorChanges = true
            }
            .store(in: &workspaceSubscriptions)
        self.captureSetup.objectWillChange
            .sink { [weak self] in self?.objectWillChange.send() }
            .store(in: &workspaceSubscriptions)
        workspace.onFailure = { [weak self] message in
            self?.errorMessage = message
        }
        // A saved-project editor owns persistence and file playback only. It
        // must never install a second set of live-input/device callbacks.
        guard purpose == .recording else { return }
        recorder.onUnexpectedStop = { [weak self] runID, error in
            self?.handleUnexpectedCaptureStop(runID: runID, error: error)
        }
        recorder.onNativeStreamWillPause = { [weak self] runID in
            guard let self, let run = recordingRuns.active, run.id == runID else { return }
            pauseAuxiliaryTracks(for: run)
            beginPauseAccounting()
        }
        recorder.onNativeStreamDidResume = { [weak self] runID, timing in
            guard let self, let run = recordingRuns.active, run.id == runID else { return }
            resumeAuxiliaryTracks(for: run, at: timing)
            resumePauseAccounting()
        }
        deviceRecorder.onUnexpectedStop = { [weak self] error in
            guard let self, let runID = self.recordingRuns.active?.id else { return }
            self.handleUnexpectedCaptureStop(runID: runID, error: error)
        }
        cameraRecorder.onUnexpectedStop = { [weak self] error in
            guard let self, let runID = self.recordingRuns.active?.id else { return }
            self.handleUnexpectedCaptureStop(runID: runID, error: error)
        }
        microphoneRecorder.onUnexpectedStop = { [weak self] error in
            // 麦克风中途断连只丢失一条音轨：提示但不终止整段录制。
            guard let self,
                  self.recordingRuns.active?.startedTracks.contains(.microphone) == true
            else { return }
            self.recordingInterruptionWarnings.append(
                String(format: appLocalized("麦克风连接已中断：%@"), appErrorDescription(error))
            )
        }
        // REC-PRE-001: present the newest capture sample immediately. The sink
        // is thread-safe and intentionally receives samples on the capture
        // queue, avoiding a per-frame MainActor task that could itself backlog.
        let cameraPreviewProcessor = cameraBeautyPreviewProcessor
        cameraRecorder.onPreviewSampleBuffer = { sampleBuffer in
            cameraPreviewProcessor.enqueue(sampleBuffer)
        }
        self.captureSetup.onError = { [weak self] message in self?.errorMessage = message }
        self.captureSetup.onStartRequested = { [weak self] in self?.startRecording() }
        self.captureSetup.onSelectionPresentationStarted = { source in
            WindowCoordinator.beginCaptureSourceSelection(source: source)
        }
        self.captureSetup.onSelectionPresentationEnded = {
            WindowCoordinator.endCaptureSourceSelection(restoringRecorder: false)
        }
        self.captureSetup.onFocusRestorationRequested = { [weak self] in
            guard let self, phase == .setup else { return }
            WindowCoordinator.restoreCaptureSourceSelectionFocus()
        }
        self.captureSetup.recorderDisplayID = {
            WindowCoordinator.recorderDisplayID()
        }
        captureDeviceLifecycle.start()
        refreshRecentProjects()
    }

    var cameraReadiness: RecorderCameraReadiness {
        RecorderCameraReadiness(
            recordsCamera: configuration.recordsCamera,
            runtimeFormat: cameraRuntimeFormat
        )
    }

    var recorderStartAvailability: RecorderStartAvailability {
        RecorderStartAvailability(
            hasCaptureTarget: cameraStudioIsPresented ? configuration.recordsCamera : captureSetup.canStartRecording,
            cameraReadiness: cameraReadiness
        )
    }

    func startRecording() {
        guard purpose == .recording, phase == .setup else { return }
        cancelPendingRecordingRestart()
        defer {
            if phase == .setup && !cameraStudioIsPresented { captureSetup.recordingStartDidNotProceed() }
        }
        switch recorderStartAvailability {
        case .needsCaptureTarget:
            errorMessage = cameraStudioIsPresented ? "未发现设备" : "请先选择显示器、窗口、区域或设备。"
            return
        case .preparingCamera:
            errorMessage = "摄像头正在建立实时画面并确认分辨率与帧率，请稍候再开始录制。"
            return
        case .ready:
            break
        }
        let plan: RecordingPlan
        do {
            if cameraStudioIsPresented {
                plan = try RecordingPlan(cameraOnly: configuration)
            } else {
                if captureSetup.target?.source == .device { refreshCaptureDevices() }
                refreshCaptureReadiness()
                let candidate = try captureSetup.makeRecordingPlan(
                    pointerCaptureFrame: try pointerCaptureFrame(
                        for: configuration,
                        availableWindows: availableWindows
                    )
                )
                try candidate.validateAvailability(
                    displayIDs: Set(availableDisplays.map(\.id)),
                    windowIDs: candidate.configuration.source == .window ? currentCaptureWindowIDs() : [],
                    deviceIDs: Set(availableScreenDevices.map(\.id))
                )
                plan = candidate
            }
        } catch {
            errorMessage = appErrorDescription(error)
            return
        }
        if let message = captureReadiness.insufficientDiskMessage {
            errorMessage = message
            return
        }
        guard plan.configuration.source == .cameraOnly || hasRequiredRecordingPermissions else {
            // The permission gate owns authorization. Recording preparation
            // must never prompt after an area/window overlay is already live.
            captureSetup.stopPresentation()
            errorMessage = nil
            refreshRequiredRecordingPermissions()
            return
        }
        resumeLiveInputIndicatorsForRecording(plan: plan)
        var recordingMicrophoneOperation: CaptureDeviceOperationToken?
        if plan.configuration.recordsMicrophone {
            // Atomically hand the shared microphone sample stream from the
            // setup meter to the recording writer. Cancelling only the UI task
            // leaves its AVCaptureSession alive; stopping it here would also
            // stop the exact session that the writer is about to reuse.
            recordingMicrophoneOperation = captureDeviceLifecycle.begin(.microphone)
            microphoneMeterTask?.cancel()
            microphoneMeterTask = nil
            microphoneInputLevel.update(0)
        }
        if plan.target != nil { captureSetup.beginRecordingPresentation(for: plan) }
        recorderTransitionStage = .checkingPermissions
        phase = .preparing
        errorMessage = nil
        isRecordingPaused = false
        pauseStartedAt = nil
        accumulatedPausedDuration = 0
        let run = recordingRuns.begin(plan)
        // Capture the run before starting any track. Recorder callbacks copy
        // these handlers before dispatching to MainActor, so a queued failure
        // from an old run keeps its original identity after a restart.
        deviceRecorder.onUnexpectedStop = { [weak self, runID = run.id] error in
            self?.handleUnexpectedCaptureStop(runID: runID, error: error)
        }
        cameraRecorder.onUnexpectedStop = { [weak self, runID = run.id] error in
            self?.handleUnexpectedCaptureStop(runID: runID, error: error)
        }
        microphoneRecorder.onUnexpectedStop = { [weak self, runID = run.id] error in
            // 麦克风中途断连只丢失一条音轨：提示但不终止整段录制。
            guard let self,
                  self.recordingRuns.isCurrent(runID),
                  self.recordingRuns.active?.startedTracks.contains(.microphone) == true
            else { return }
            self.recordingInterruptionWarnings.append(
                String(format: appLocalized("麦克风连接已中断：%@"), appErrorDescription(error))
            )
        }
        if let operation = recordingMicrophoneOperation,
           let microphoneID = plan.configuration.microphoneDeviceID {
            startRecordingMicrophoneLevelObservation(
                runID: run.id,
                deviceUniqueID: microphoneID,
                operation: operation
            )
        }

        preparationTask?.cancel()
        preparationTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                preparationLogger.notice("prepare: begin")
                if plan.configuration.source == .device {
                    let permitted = await deviceRecorder.requestPermission()
                    guard recordingRuns.isCurrent(run.id) else { return }
                    guard permitted else {
                        throw CameraRecorderError.permissionDenied("iPhone/iPad 屏幕")
                    }
                } else if plan.configuration.source.capturesDesktop && !hasRequiredRecordingPermissions {
                    throw ScreenRecorderError.permissionDenied
                }
                preparationLogger.notice("prepare: screen permission ok")
                if plan.configuration.recordsCamera {
                    let permitted = await cameraRecorder.requestPermission()
                    guard recordingRuns.isCurrent(run.id) else { return }
                    guard permitted else {
                        throw CameraRecorderError.permissionDenied("摄像头")
                    }
                    preparationLogger.notice("prepare: camera permission ok")
                }
                if plan.configuration.recordsMicrophone {
                    let permitted = await microphoneRecorder.requestPermission()
                    guard recordingRuns.isCurrent(run.id) else { return }
                    guard permitted else { throw MicrophoneRecorderError.permissionDenied }
                    preparationLogger.notice("prepare: microphone permission ok")
                }
                // REC-001 / REC-004: 正常录制不能先暗中启动一条完整的三秒
                // SCK + VideoToolbox 试录。那会连续创建两套高负载采集链路，
                // 让 WindowServer 和编码器刚释放资源就立刻再次抢占，用户按下
                // 录制后也会白等三秒。真实试录保留为显式诊断入口；正常入口
                // 只做上面的权限/设备预检，运行期错误由录制状态机即时上报。
                recorderTransitionStage = .creatingProject
                let recordingCreatedAt = Date()
                project.createdAt = recordingCreatedAt
                project.recordingMarkers = []
                project.capture = plan.configuration
                project.title = RecordingProjectNaming.title(
                    for: plan.configuration,
                    createdAt: recordingCreatedAt
                )
                let customTitle = recordingTitleDraft.trimmingCharacters(in: .whitespacesAndNewlines)
                if !customTitle.isEmpty { project.title = String(customTitle.prefix(120)) }
                if plan.configuration.source == .cameraOnly {
                    project.canvas.aspectRatio = .adaptive
                    project.canvas.crop = .full
                    project.camera.contentScale = 1
                    project.camera.contentPosition = NormalizedPoint(x: 0.5, y: 0.5)
                    project.camera.isFullscreen = true
                    project.camera.isHidden = false
                }
                project.camera.isMirrored = recordingCameraMirrored
                project.camera.beauty = recordingCameraBeauty
                let session = try ProjectStore.createSession(
                    preferredTitle: project.title,
                    createdAt: recordingCreatedAt
                )
                workspace.activate(session: session, isSaved: false)
                recordingPerformanceMonitor = RecordingPerformanceMonitor(
                    volumeURL: session.packageURL
                )
                if plan.configuration.source == .device {
                    project.canvas.crop = .full
                    project.canvas.applyScreenFrameStyle(.devicePhone)
                }
                project.media = plan.initialMediaManifest
                _ = try await workspace.flush(project)
                preparationLogger.notice("prepare: session created and flushed")
                guard recordingRuns.isCurrent(run.id) else { return }
                try await recordingRecoveryJournal.persist(
                    RecordingRecoverySnapshot(
                        state: "recording",
                        session: session,
                        frameRate: plan.configuration.captureFrameRate,
                        performanceMonitor: recordingPerformanceMonitor,
                        appendsPerformanceSample: true,
                        screenRelativePath: plan.primaryRecordingRelativePath
                    )
                )
                preparationLogger.notice("prepare: recovery manifest written")
                // CUR-001/PTR-001: begin the independent host-clock pointer
                // track before starting camera/microphone/screen writers. The
                // primary ScreenCaptureKit stream may need several hundred
                // milliseconds to publish its first frame; starting the event
                // tap afterwards created a real hole at the beginning of the
                // saved pointer track. PointerTimelineAlignment trims this
                // pre-roll against the exact first video PTS and converts its
                // last position into a non-clicking t=0 seed.
                let pointerStartedAt: PointerRecordingStart?
                if plan.configuration.source.capturesDesktop {
                    pointerStartedAt = await pointerRecorder.start(
                        frameSource: captureSetup.pointerFrameSource(for: plan)
                    )
                    if pointerStartedAt != nil {
                        recordingRuns.markStarted(.pointer, for: run.id)
                    }
                } else {
                    pointerStartedAt = nil
                }
                guard recordingRuns.isCurrent(run.id), !Task.isCancelled else {
                    // 本 run 已失效时指针轨不需要、也不允许在这里直接停：
                    // 放弃/提交路径都经类型化 finalizer 冻结指针（.pointer 已
                    // markStarted）；新 run 的 pointerRecorder.start 会整体重
                    // 置记录器；进程退出由 shutdown 路径统一停。直接 stop 反而
                    // 可能落在下一次 start 之后，误杀新 run 的指针轨。
                    return
                }
                do {
                    // A primary camera's first sample is project time zero.
                    if plan.configuration.source == .cameraOnly, plan.configuration.recordsMicrophone {
                        try await startMicrophoneTrack(for: run, session: session)
                        guard recordingRuns.isCurrent(run.id) else { return }
                    }
                    if plan.configuration.recordsCamera {
                        recorderTransitionStage = .startingCamera
                        try await cameraRecorder.start(
                            to: session.cameraRecordingURL,
                            deviceUniqueID: plan.configuration.cameraDeviceID,
                            captureResolution: plan.configuration.cameraCaptureResolution,
                            captureCodec: plan.configuration.source == .cameraOnly ? plan.configuration.captureCodec : .h264
                        )
                        guard recordingRuns.isCurrent(run.id) else { return }
                        recordingRuns.markStarted(.camera, for: run.id)
                        cameraRecordingURL = session.cameraRecordingURL
                        preparationLogger.notice("prepare: camera track started")
                    }
                    if plan.configuration.source != .cameraOnly, plan.configuration.recordsMicrophone {
                        try await startMicrophoneTrack(for: run, session: session)
                        guard recordingRuns.isCurrent(run.id) else { return }
                    }
                    if plan.configuration.source != .cameraOnly { recorderTransitionStage = .startingPrimaryCapture }
                    if plan.configuration.source == .device {
                        try await deviceRecorder.start(
                            to: session.deviceRecordingURL,
                            deviceUniqueID: plan.configuration.deviceID,
                            capturesDeviceAudio: plan.configuration.recordsSystemAudio,
                            captureCodec: plan.configuration.captureCodec
                        )
                        guard recordingRuns.isCurrent(run.id) else { return }
                        recordingRuns.markStarted(.device, for: run.id)
                        project.canvas.applyScreenFrameStyle(.devicePhone)
                    } else if plan.configuration.source.capturesDesktop {
                        try await recorder.start(
                            runID: run.id, configuration: plan.configuration,
                            outputURL: session.recordingURL(relativePath: plan.primaryRecordingRelativePath)
                        )
                        guard recordingRuns.isCurrent(run.id) else { return }
                        recordingRuns.markStarted(.screen, for: run.id)
                        if let error = recorder.terminalError(for: run.id) { throw error }
                    }
                    if let preparingInterruptedError {
                        self.preparingInterruptedError = nil
                        throw preparingInterruptedError
                    }
                    preparationLogger.notice("prepare: primary video started")
                } catch {
                    guard recordingRuns.isCurrent(run.id) else { return }
                    let startError = error
                    surfaceVisibilityTask?.cancel()
                    surfaceVisibilityTask = nil
                    recoveryHeartbeatTask?.cancel()
                    recoveryHeartbeatTask = nil
                    captureSetup.stopPresentation()
                    let tracks = recordingRuns.active?.startedTracks ?? []
                    let stopResult = try await trackFinalizer.finalize(
                        RecordingTrackFinalizationRequest(
                            runID: run.id,
                            startedTracks: tracks,
                            intent: .rollbackFailedPreparation
                        ),
                        currentRunID: recordingRuns.active?.id
                    )
                    guard recordingRuns.isCurrent(run.id) else { return }
                    guard !stopResult.failures.isEmpty else { throw startError }
                    throw RecordingPreparationRollbackError(
                        startError: startError,
                        stopFailures: stopResult.failures
                    )
                }
                recorderTransitionStage = .aligningTimeline
                let mediaTimelineOrigin: Date
                let primaryHostTime: TimeInterval?
                switch plan.configuration.source {
                case .device:
                    mediaTimelineOrigin = deviceRecorder.recordingStartedAt ?? Date()
                    primaryHostTime = nil
                case .cameraOnly:
                    mediaTimelineOrigin = cameraRecorder.recordingStartedAt ?? Date()
                    primaryHostTime = cameraRecorder.firstFrameHostTime
                default:
                    mediaTimelineOrigin = recorder.firstFrameStartedAt ?? Date()
                    primaryHostTime = recorder.firstFrameStartedAtHostTime
                }
                if var media = project.media {
                    if var camera = media.camera {
                        if let videoHostTime = primaryHostTime,
                           let sourceTime = cameraRecorder.recordedSourceTime(
                            atHostTime: videoHostTime
                           ) {
                            camera.startOffset = 0
                            camera.sourceStartTime = sourceTime
                        } else {
                            let delta = cameraRecorder.recordingStartedAt?
                                .timeIntervalSince(mediaTimelineOrigin) ?? 0
                            camera.startOffset = max(delta, 0)
                            camera.sourceStartTime = max(-delta, 0)
                        }
                        media.camera = camera
                    }
                    if var microphone = media.microphone {
                        if let videoHostTime = primaryHostTime,
                           let sourceTime = microphoneRecorder.recordedSourceTime(
                            atHostTime: videoHostTime
                           ) {
                            microphone.startOffset = 0
                            microphone.sourceStartTime = sourceTime
                        } else {
                            let delta = microphoneRecorder.recordingStartedAt?
                                .timeIntervalSince(mediaTimelineOrigin) ?? 0
                            microphone.startOffset = max(delta, 0)
                            microphone.sourceStartTime = max(-delta, 0)
                        }
                        media.microphone = microphone
                    }
                    if var pointer = media.pointerEvents {
                        let pointerDelta: TimeInterval
                        if let pointerStartedAt,
                           let videoHostTime = recorder.firstFrameStartedAtHostTime {
                            pointerDelta = pointerStartedAt.hostTime - videoHostTime
                        } else {
                            pointerDelta = pointerStartedAt?.wallTime
                                .timeIntervalSince(mediaTimelineOrigin) ?? 0
                        }
                        pointer.startOffset = max(pointerDelta, 0)
                        pointer.sourceStartTime = max(-pointerDelta, 0)
                        media.pointerEvents = pointer
                    }
                    project.media = media
                }
                startedAt = mediaTimelineOrigin
                recorderTransitionStage = .idle
                phase = .recording
                preparationTask = nil
                startRecoveryHeartbeat(session: session, runID: run.id, plan: plan)
            } catch {
                guard recordingRuns.isCurrent(run.id) else { return }
                let message = appErrorDescription(error)
                captureSetup.stopPresentation()
                recoveryHeartbeatTask?.cancel()
                recoveryHeartbeatTask = nil
                guard await discardFailedPreparationSessionIfNeeded(
                    runID: run.id,
                    plan: plan
                ) else { return }
                preparationTask = nil
                errorMessage = message
                recorderTransitionStage = .idle
                microphoneMeterTask?.cancel()
                microphoneMeterTask = nil
                microphoneInputLevel.update(0)
                resumeLiveInputIndicatorsForSetup()
                phase = .setup
            }
        }
    }
    private func startMicrophoneTrack(for run: RecordingRun, session: RecordingSession) async throws {
        recorderTransitionStage = .startingMicrophone
        // Own the writer during preparation too, so a partial start is finalized.
        recordingRuns.markStarted(.microphone, for: run.id)
        try await microphoneRecorder.start(to: session.microphoneRecordingURL,
            deviceUniqueID: run.plan.configuration.microphoneDeviceID)
        guard recordingRuns.isCurrent(run.id) else { return }
        microphoneRecordingURL = session.microphoneRecordingURL
        preparationLogger.notice("prepare: microphone track started")
    }

    func stopRecording() {
        guard phase == .recording, let run = recordingRuns.active else { return }
        guard !isPauseTransitioning else {
            stopRequestedDuringPauseTransition = true
            return
        }
        stopRequestedDuringPauseTransition = false
        // Freeze one common stop epoch before any writer receives its async
        // stop request. Camera/microphone may flush later, but their project
        // references end at this exact host-clock boundary.
        let sharedStopHostTime = CMClockGetTime(CMClockGetHostTimeClock()).seconds
        if var media = project.media {
            if var camera = media.camera,
               let sourceEnd = cameraRecorder.recordedSourceTime(
                atHostTime: sharedStopHostTime
               ) {
                camera.sourceEndTime = sourceEnd
                media.camera = camera
            }
            if var microphone = media.microphone,
               let sourceEnd = microphoneRecorder.recordedSourceTime(
                atHostTime: sharedStopHostTime
               ) {
                microphone.sourceEndTime = sourceEnd
                media.microphone = microphone
            }
            project.media = media
        }
        suspendLiveInputIndicators()
        captureSetup.stopPresentation()
        surfaceVisibilityTask?.cancel()
        surfaceVisibilityTask = nil
        finishPauseAccounting()
        isRecordingPaused = false
        recorderTransitionStage = .finalizingTracks
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
                        intent: .commit
                    ),
                    currentRunID: recordingRuns.active?.id
                )
            } catch {
                guard recordingRuns.isCurrent(run.id) else { return }
                await recoverFromFinalizeFailure(
                    run: run,
                    error: error,
                    resetCapture: false
                )
                return
            }
            guard recordingRuns.isCurrent(run.id) else { return }
            var finalizationErrors = stopResult.failures.compactMap(\.errorDescription)
            if run.startedTracks.contains(.device) {
                if let candidate = currentSession?.deviceRecordingURL,
                   isNonemptyFile(candidate) {
                    recordingURL = candidate
                }
            } else if run.plan.configuration.source == .cameraOnly {
                recordingURL = cameraRecordingURL
            } else if run.startedTracks.contains(.screen) {
                recordingURL = stopResult.outputURL(for: .screen)
                if recordingURL == nil {
                    if let candidate = currentSession?.recordingURL(relativePath: run.plan.primaryRecordingRelativePath),
                       isNonemptyFile(candidate) {
                        recordingURL = candidate
                    }
                }
            }
            let pointerReference = self.project.media?.pointerEvents
            let rawPointerEvents = stopResult.pointerEvents
            let pointerStartOffset = pointerReference?.startOffset ?? 0
            let pointerSourceStartTime = pointerReference?.sourceStartTime ?? 0
            let zoomEasing = project.motion.defaultZoomEasing
            let zoomTransitionDuration = project.motion.defaultZoomTransitionDuration
            let pointerWorker = Task.detached(priority: .userInitiated) {
                try RecordingPointerFinalization.prepare(
                    events: rawPointerEvents,
                    startOffset: pointerStartOffset,
                    sourceStartTime: pointerSourceStartTime,
                    easing: zoomEasing,
                    transitionDuration: zoomTransitionDuration
                )
            }
            let pointerFinalization: RecordingPointerFinalizationResult
            do {
                pointerFinalization = try await withTaskCancellationHandler {
                    try await pointerWorker.value
                } onCancel: {
                    pointerWorker.cancel()
                }
            } catch is CancellationError {
                return
            } catch {
                guard recordingRuns.isCurrent(run.id) else { return }
                await recoverFromFinalizeFailure(
                    run: run,
                    error: error,
                    resetCapture: false
                )
                return
            }
            guard recordingRuns.isCurrent(run.id) else { return }
            let pointerEvents = pointerFinalization.events
            self.pointerEvents = pointerEvents
            recorderTransitionStage = .validatingRecording
            project.capture = run.plan.configuration
            if var media = project.media, var pointer = media.pointerEvents {
                // Event timestamps now use the primary video clock. Keeping
                // the old placement metadata would apply the offset twice if
                // pointer references become first-class timeline media later.
                pointer.startOffset = 0
                pointer.sourceStartTime = 0
                media.pointerEvents = pointer
                project.media = media
            }
            let clippedZoom = await zoomAnimationsClippedToRecording(
                pointerFinalization.automaticZoomAnimations,
                recordingURL: recordingURL
            )
            guard recordingRuns.isCurrent(run.id) else { return }
            project.zoomAnimations = clippedZoom
            let recordingIsUsable: Bool
            if let recordingURL {
                recordingIsUsable = await isUsableVideoFile(recordingURL)
                guard recordingRuns.isCurrent(run.id) else { return }
            } else {
                recordingIsUsable = false
            }
            if !recordingIsUsable {
                recordingURL = nil
            }
            if recordingIsUsable, run.plan.configuration.source == .device {
                project.canvas.applyScreenFrameStyle(.devicePhone)
            }
            if var media = project.media {
                if cameraRecordingURL.map(isNonemptyFile) != true {
                    media.camera = nil
                }
                if microphoneRecordingURL.map(isNonemptyFile) != true {
                    media.microphone = nil
                }
                project.media = recordingIsUsable ? media : nil
            }
            if let currentSession {
                do {
                    recorderTransitionStage = .savingProject
                    let pointerSaveWorker = Task.detached(priority: .userInitiated) {
                        try RecordingPointerFinalization.persist(
                            pointerEvents,
                            session: currentSession
                        )
                    }
                    try await withTaskCancellationHandler {
                        try await pointerSaveWorker.value
                    } onCancel: {
                        pointerSaveWorker.cancel()
                    }
                    _ = try await workspace.flush(project)
                    guard recordingRuns.isCurrent(run.id) else { return }
                    if recordingIsUsable {
                        let systemAudioDiagnostics = run.plan.configuration.recordsSystemAudio
                            ? await recorder.systemAudioDiagnostics() : nil
                        let cameraDiagnostics = run.plan.configuration.recordsCamera
                            ? await cameraRecorder.captureDiagnosticsSnapshot() : nil
                        let microphoneDiagnostics = run.plan.configuration.recordsMicrophone
                            ? await microphoneRecorder.captureDiagnosticsSnapshot() : nil
                        try await recordingRecoveryJournal.persist(
                            RecordingRecoverySnapshot(
                                state: "complete",
                                session: currentSession,
                                frameRate: run.plan.configuration.captureFrameRate,
                                measurement: run.plan.configuration.source.capturesDesktop
                                    ? recorder.lastMeasurement : nil,
                                cameraDiagnostics: cameraDiagnostics,
                                systemAudioDiagnostics: systemAudioDiagnostics,
                                microphoneDiagnostics: microphoneDiagnostics,
                                performanceMonitor: recordingPerformanceMonitor,
                                appendsPerformanceSample: true,
                                screenRelativePath: run.plan.primaryRecordingRelativePath
                            )
                        )
                    }

                    // A completed recording is a durable project before the
                    // editor appears. Keep the private working folder only as
                    // a crash-recovery staging area; normal recordings move to
                    // the configured project folder without another save
                    // panel. The first editor session can still explicitly
                    // delete an untouched take.
                    var completedProjectURL = currentSession.packageURL
                    if recordingIsUsable,
                       ProjectStore.isWorkingProject(currentSession.packageURL) {
                        let destination = try ProjectStore.automaticSaveDestination(
                            for: project,
                            session: currentSession
                        )
                        guard let moved = try await workspace.move(
                            project,
                            to: destination
                        ) else {
                            throw CocoaError(.fileWriteUnknown)
                        }
                        recordingURL = ProjectStore.resolve(
                            relativePath: project.media?.screen.relativePath,
                            session: moved.session
                        )
                        cameraRecordingURL = ProjectStore.resolve(
                            relativePath: project.media?.camera?.relativePath,
                            session: moved.session
                        )
                        microphoneRecordingURL = ProjectStore.resolve(
                            relativePath: project.media?.microphone?.relativePath,
                            session: moved.session
                        )
                        completedProjectURL = moved.session.packageURL
                    }
                    if recordingIsUsable {
                        ProjectStore.registerRecentProject(completedProjectURL)
                        refreshRecentProjects()
                    }
                } catch {
                    finalizationErrors.append(detailedErrorDescription(error))
                }
            }
            var missingTracks: [String] = []
            if run.startedTracks.contains(.camera),
               cameraRecordingURL.map(isNonemptyFile) != true {
                missingTracks.append("摄像头")
            }
            if run.startedTracks.contains(.microphone),
               microphoneRecordingURL.map(isNonemptyFile) != true {
                missingTracks.append("麦克风")
            }
            if !recordingInterruptionWarnings.isEmpty {
                finalizationErrors.append(contentsOf: recordingInterruptionWarnings)
                recordingInterruptionWarnings.removeAll()
            }
            if recordingIsUsable {
                if !missingTracks.isEmpty {
                    let warning = run.plan.configuration.source == .cameraOnly
                        ? "摄像头录制已保存，但%@轨道未成功写入。" : "屏幕录制已保存，但%@轨道未成功写入。"
                    finalizationErrors.insert(
                        String(format: appLocalized(warning),
                               missingTracks.map(appLocalized).joined(separator: appLocalized("和"))),
                        at: 0
                    )
                }
                errorMessage = finalizationErrors.isEmpty
                    ? nil : finalizationErrors.joined(separator: appLocalized("；"))
            } else if !finalizationErrors.isEmpty {
                errorMessage = finalizationErrors.joined(separator: appLocalized("；"))
            } else {
                errorMessage = "录制文件没有可播放的视频轨道，已保留临时项目供恢复。"
            }
            guard recordingRuns.end(run.id) != nil else { return }
            finishingTask = nil
            if recordingURL != nil {
                // REC-005: finalization normally stops the recording session;
                // run the idle-preview stop again at the phase boundary so no
                // fallback/stale preview can keep the privacy light active.
                suspendLiveInputIndicators()
                offersDiscardForUntouchedRecording = true
                currentRecordingHasEditorChanges = false
                exporter.resetResultForNewEditorSession()
                editorSessionID = UUID()
                recorderTransitionStage = .idle
                phase = .recordingComplete
            } else {
                refreshRecentProjects()
                resumeLiveInputIndicatorsForSetup()
                recorderTransitionStage = .idle
                phase = .setup
            }
        }
    }

    func toggleRecordingPause() {
        guard phase == .recording,
              !isPauseTransitioning,
              let run = recordingRuns.active else { return }

        isPauseTransitioning = true
        Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                if recordingRuns.isCurrent(run.id) {
                    isPauseTransitioning = false
                    if stopRequestedDuringPauseTransition {
                        stopRequestedDuringPauseTransition = false
                        stopRecording()
                    }
                }
            }
            guard phase == .recording, recordingRuns.isCurrent(run.id) else { return }
            let renewsNativeStream = run.startedTracks.contains(.screen)
                && recorder.usesNativePauseSessions
            if isRecordingPaused {
                if renewsNativeStream {
                    // A replacement SCK stream has a real startup interval.
                    // Keep auxiliary tracks paused until its first frame, then
                    // use the video media clock rather than callback wall time.
                    guard await recorder.resume(runID: run.id) != nil,
                          recordingRuns.isCurrent(run.id), recorder.isCapturing,
                          !recorder.isPaused else { return }
                } else {
                    let timing: RecordingResumeTiming?
                    let now = CMClockGetTime(CMClockGetHostTimeClock()).seconds
                    if run.plan.configuration.source == .cameraOnly,
                       let start = cameraRecorder.firstFrameHostTime,
                       let duration = cameraRecorder.recordedSourceTime(atHostTime: now) {
                        timing = RecordingResumeTiming(videoStartedAtHostTime: start,
                            resumedAtHostTime: now, completedVideoDuration: duration)
                    } else {
                        timing = nil
                    }
                    resumeAuxiliaryTracks(for: run, at: timing)
                    if run.startedTracks.contains(.device) {
                        deviceRecorder.resume()
                    } else if run.startedTracks.contains(.screen) {
                        await recorder.resume(runID: run.id)
                        guard recordingRuns.isCurrent(run.id), !recorder.isPaused else { return }
                    }
                }
                resumePauseAccounting()
                isRecordingPaused = false
            } else {
                if run.startedTracks.contains(.device) {
                    deviceRecorder.pause()
                } else if run.startedTracks.contains(.screen) {
                    await recorder.pause(runID: run.id)
                    guard recordingRuns.isCurrent(run.id), recorder.isPaused else { return }
                }
                if !renewsNativeStream { pauseAuxiliaryTracks(for: run) }
                beginPauseAccounting()
                isRecordingPaused = true
            }
        }
    }

    func setHidesDesktopFiles(_ hidden: Bool) {
        updateSurfaceVisibility(hidesDesktopFiles: hidden)
    }

    func setHidesDock(_ hidden: Bool) {
        updateSurfaceVisibility(hidesDock: hidden)
    }
}
