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
    case editor

    /// Device preferences may create live camera/microphone sessions. Only the
    /// setup surface is allowed to restore them automatically; reconnect
    /// notifications received while editing must remain catalog-only state.
    var allowsAutomaticLiveInputRestoration: Bool {
        self == .setup
    }
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
        case .idle: "正在处理…"
        case .checkingPermissions: "正在检查设备与权限…"
        case .creatingProject: "正在创建录制项目…"
        case .startingCamera: "正在启动摄像头…"
        case .startingMicrophone: "正在启动麦克风…"
        case .startingPrimaryCapture: "正在等待首个屏幕帧…"
        case .aligningTimeline: "正在对齐各轨时间轴…"
        case .finalizingTracks: "正在结束所有录制轨道…"
        case .validatingRecording: "正在校验录制素材…"
        case .savingProject: "正在保存项目…"
        case .discardingRecording: "正在安全丢弃录制…"
        case .openingEditor: "正在打开编辑器…"
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

/// Bakes the pointer recorder's independent host-clock placement into the
/// saved event times. A pointer tap may start just before the first video
/// frame; in that case the last pre-roll position becomes a non-clicking seed
/// at t=0 instead of shifting the whole path late or creating a phantom click.
enum PointerTimelineAlignment {
    static func align(
        _ events: [PointerEventRecord],
        startOffset: TimeInterval,
        sourceStartTime: TimeInterval
    ) -> [PointerEventRecord] {
        let shift = max(startOffset, 0) - max(sourceStartTime, 0)
        var lastPreRoll: PointerEventRecord?
        var aligned: [PointerEventRecord] = []

        // The live recorder and project loader already preserve monotonic
        // order. Share that storage in the normal case; only imported or
        // damaged tracks pay for a repair sort.
        for event in PointerEventTimelineOrdering.normalized(events) {
            let time = event.time + shift
            guard time >= 0 else {
                lastPreRoll = event
                continue
            }
            if aligned.isEmpty, let lastPreRoll, time > 0.000_001 {
                aligned.append(PointerEventRecord(
                    time: 0,
                    location: lastPreRoll.location,
                    kind: .move,
                    modifiers: lastPreRoll.modifiers
                ))
            }
            aligned.append(PointerEventRecord(
                time: max(time, 0),
                location: event.location,
                kind: event.kind,
                modifiers: event.modifiers
            ))
        }

        if aligned.isEmpty, let lastPreRoll {
            aligned.append(PointerEventRecord(
                time: 0,
                location: lastPreRoll.location,
                kind: .move,
                modifiers: lastPreRoll.modifiers
            ))
        }
        return aligned
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
    let microphoneInputLevel = LiveMicrophoneLevelState()
    @Published var editorSessionID = UUID()
    @Published var editorContextRevision: UInt64 = 0
    @Published var isMediaExchangeRunning = false
    @Published var hasVerifiedScreenRecordingPermission = false
    @Published var hasAccessibilityPermission = AXIsProcessTrusted()
    @Published var isCheckingRequiredPermissions = false
    @Published var hasCompletedRequiredPermissionOnboarding = UserDefaults.standard.bool(
        forKey: "permissions.required-onboarding-completed"
    )
    var hasRequestedScreenPermissionThisLaunch = false
    var hasRequestedAccessibilityPermissionThisLaunch = false
    var hasStartedPermissionOnboardingThisLaunch = false

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
    var isRefreshingWindows: Bool { captureSetup.isRefreshingWindows }
    var captureReadiness: CaptureReadiness { captureSetup.readiness }

    var hasRequiredRecordingPermissions: Bool {
        let screenPermissionIsReady = hasVerifiedScreenRecordingPermission
            || (hasCompletedRequiredPermissionOnboarding
                && captureReadiness.hasScreenRecordingPermission)
        return screenPermissionIsReady && hasAccessibilityPermission
    }

    var showsRequiredPermissionGate: Bool {
        phase == .setup
            && (!hasRequiredRecordingPermissions
                || !hasCompletedRequiredPermissionOnboarding)
    }

    var requiredPermissionActionTitle: String {
        if isCheckingRequiredPermissions { return "正在检查…" }
        if !captureReadiness.hasScreenRecordingPermission {
            return hasRequestedScreenPermissionThisLaunch
                ? "打开录屏设置" : "授权屏幕录制"
        }
        if !hasVerifiedScreenRecordingPermission { return "检查录屏权限" }
        if !hasAccessibilityPermission {
            return hasRequestedAccessibilityPermissionThisLaunch
                ? "打开辅助功能设置" : "授权辅助功能"
        }
        return "进入 \(AppIdentity.displayName)"
    }

    let recorder = ScreenRecorder()
    let exporter = VideoExporter()
    let cameraRecorder = CameraRecorder()
    let deviceRecorder = CameraRecorder(role: .iosDevice)
    let microphoneRecorder = MicrophoneRecorder()
    lazy var cameraPreviewController = CameraPreviewWindowController(
        session: cameraRecorder.previewSession
    )
    let pointerRecorder = PointerEventRecorder()
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
    var cameraPreviewTask: Task<Void, Never>?
    var microphoneMeterTask: Task<Void, Never>?
    var recordingRuns = RecordingRunState()
    var preparationTask: Task<Void, Never>?
    var finishingTask: Task<Void, Never>?
    lazy var captureDeviceLifecycle = CaptureDeviceLifecycle { [weak self] in
        self?.refreshCaptureDevices()
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
        applySavedSystemAudioPreference()
    }

    init(
        workspace: ProjectWorkspace,
        captureSetup: CaptureSetupController? = nil
    ) {
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
        recorder.onUnexpectedStop = { [weak self] runID, error in
            self?.handleUnexpectedCaptureStop(runID: runID, error: error)
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
                "麦克风连接已中断：\(error.localizedDescription)"
            )
        }
        // REC-PRE-001: present the newest capture sample immediately. The sink
        // is thread-safe and intentionally receives samples on the capture
        // queue, avoiding a per-frame MainActor task that could itself backlog.
        let cameraPreviewFrameSink = cameraPreviewController.frameSink
        cameraRecorder.onPreviewSampleBuffer = { sampleBuffer in
            cameraPreviewFrameSink.enqueue(sampleBuffer)
        }
        self.captureSetup.onError = { [weak self] message in self?.errorMessage = message }
        self.captureSetup.onStartRequested = { [weak self] in self?.startRecording() }
        self.captureSetup.onSelectionPresentationStarted = {
            WindowCoordinator.beginCaptureSourceSelection()
        }
        self.captureSetup.onFocusRestorationRequested = { [weak self] in
            guard let self, phase == .setup else { return }
            WindowCoordinator.endCaptureSourceSelection()
            NSApplication.shared.activate(ignoringOtherApps: true)
            guard let window = NSApplication.shared.windows.first(where: {
                $0.identifier == recorderMainWindowIdentifier && $0.isVisible
            }) else { return }
            window.makeKeyAndOrderFront(nil)
            window.makeFirstResponder(nil)
        }
        self.captureSetup.recorderDisplayID = {
            WindowCoordinator.recorderDisplayID()
        }
        captureDeviceLifecycle.start()
        refreshRecentProjects()
    }
    var selectedCaptureSource: CaptureSource? {
        captureSetup.selectedSource
    }

    /// A source button can be active while its full-screen selector is still
    /// waiting for a concrete display/window/area/device. Do not present that
    /// transient mode as a confirmed recording target.
    var confirmedCaptureSource: CaptureSource? {
        captureSetup.target?.source
    }
    var cameraReadiness: RecorderCameraReadiness {
        RecorderCameraReadiness(
            recordsCamera: configuration.recordsCamera,
            runtimeFormat: cameraRuntimeFormat
        )
    }

    var recorderStartAvailability: RecorderStartAvailability {
        RecorderStartAvailability(
            hasCaptureTarget: captureSetup.canStartRecording,
            cameraReadiness: cameraReadiness
        )
    }

    var canStartRecording: Bool { recorderStartAvailability.permitsRecording }

    func startRecording() {
        guard phase == .setup else { return }
        switch recorderStartAvailability {
        case .needsCaptureTarget:
            errorMessage = "请先选择显示器、窗口、区域或设备。"
            return
        case .preparingCamera:
            errorMessage = "摄像头正在建立实时画面并确认分辨率与帧率，请稍候再开始录制。"
            return
        case .ready:
            break
        }
        guard let selectedTarget = captureSetup.target else {
            errorMessage = "请先选择显示器、窗口、区域或设备。"
            return
        }
        if selectedTarget.source == .device { refreshCaptureDevices() }
        refreshCaptureReadiness()
        let plan: RecordingPlan
        do {
            let candidate = try captureSetup.makeRecordingPlan(
                pointerCaptureFrame: try pointerCaptureFrame(
                    for: configuration,
                    availableWindows: availableWindows
                )
            )
            try candidate.validateAvailability(
                displayIDs: Set(availableDisplays.map(\.id)),
                windowIDs: currentCaptureWindowIDs(),
                deviceIDs: Set(availableScreenDevices.map(\.id))
            )
            plan = candidate
        } catch {
            errorMessage = error.localizedDescription
            return
        }
        guard captureReadiness.hasSufficientDisk else {
            errorMessage = "磁盘空间不足，无法保证 30 分钟录制安全完成。请先释放空间。"
            return
        }
        guard hasRequiredRecordingPermissions else {
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
        captureSetup.beginRecordingPresentation(for: plan)
        recorderTransitionStage = .checkingPermissions
        phase = .preparing
        errorMessage = nil
        isRecordingPaused = false
        pauseStartedAt = nil
        accumulatedPausedDuration = 0
        let run = recordingRuns.begin(plan)
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
                } else if !hasRequiredRecordingPermissions {
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
                // Start every new project from the intentionally chosen motion
                // defaults without inheriting the previous project's edits.
                project.motion = project.motion.preparedForNewRecording()
                recorderTransitionStage = .creatingProject
                let session = try ProjectStore.createSession()
                workspace.activate(session: session, isSaved: false)
                recordingPerformanceMonitor = RecordingPerformanceMonitor(
                    volumeURL: session.packageURL
                )
                project.capture = plan.configuration
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
                if plan.configuration.source != .device {
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
                    if plan.configuration.recordsCamera {
                        recorderTransitionStage = .startingCamera
                        try await cameraRecorder.start(
                            to: session.cameraRecordingURL,
                            deviceUniqueID: plan.configuration.cameraDeviceID,
                            captureResolution: plan.configuration.cameraCaptureResolution
                        )
                        guard recordingRuns.isCurrent(run.id) else { return }
                        recordingRuns.markStarted(.camera, for: run.id)
                        cameraRecordingURL = session.cameraRecordingURL
                        preparationLogger.notice("prepare: camera track started")
                    }
                    if plan.configuration.recordsMicrophone {
                        recorderTransitionStage = .startingMicrophone
                        // A track is owned as soon as start is requested, not
                        // only after the first sample. Failed preparation must
                        // therefore stop/cancel a half-started writer too.
                        recordingRuns.markStarted(.microphone, for: run.id)
                        try await microphoneRecorder.start(
                            to: session.microphoneRecordingURL,
                            deviceUniqueID: plan.configuration.microphoneDeviceID
                        )
                        guard recordingRuns.isCurrent(run.id) else { return }
                        microphoneRecordingURL = session.microphoneRecordingURL
                        preparationLogger.notice("prepare: microphone track started")
                    }
                    recorderTransitionStage = .startingPrimaryCapture
                    if plan.configuration.source == .device {
                        try await deviceRecorder.start(
                            to: session.deviceRecordingURL,
                            deviceUniqueID: plan.configuration.deviceID,
                            capturesDeviceAudio: plan.configuration.recordsSystemAudio
                        )
                        guard recordingRuns.isCurrent(run.id) else { return }
                        recordingRuns.markStarted(.device, for: run.id)
                    } else {
                        try await recorder.start(
                            runID: run.id, configuration: plan.configuration,
                            outputURL: session.recordingURL(relativePath: plan.primaryRecordingRelativePath)
                        )
                        guard recordingRuns.isCurrent(run.id) else { return }
                        recordingRuns.markStarted(.screen, for: run.id)
                        if let error = recorder.terminalError(for: run.id) { throw error }
                    }
                    preparationLogger.notice("prepare: screen track started")
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
                let mediaTimelineOrigin = plan.configuration.source == .device
                    ? (deviceRecorder.recordingStartedAt ?? Date())
                    : (recorder.firstFrameStartedAt ?? Date())
                if var media = project.media {
                    if var camera = media.camera {
                        if plan.configuration.source != .device,
                           let videoHostTime = recorder.firstFrameStartedAtHostTime,
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
                        if plan.configuration.source != .device,
                           let videoHostTime = recorder.firstFrameStartedAtHostTime,
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
                if let preparingInterruptedError {
                    // 流已在准备期间死亡：走 catch 的 rollback，而不是进入 .recording。
                    self.preparingInterruptedError = nil
                    throw preparingInterruptedError
                }
                startedAt = mediaTimelineOrigin
                recorderTransitionStage = .idle
                phase = .recording
                preparationTask = nil
                startRecoveryHeartbeat(session: session, runID: run.id, plan: plan)
            } catch {
                guard recordingRuns.isCurrent(run.id) else { return }
                let message = error.localizedDescription
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
                    resetCapture: false,
                    restart: false
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
            let createsAutomaticZooms = run.plan.automaticallyCreatesZooms
            let zoomEasing = project.motion.defaultZoomEasing
            let zoomTransitionDuration = project.motion.defaultZoomTransitionDuration
            let pointerWorker = Task.detached(priority: .userInitiated) {
                try RecordingPointerFinalization.prepare(
                    events: rawPointerEvents,
                    startOffset: pointerStartOffset,
                    sourceStartTime: pointerSourceStartTime,
                    createsAutomaticZooms: createsAutomaticZooms,
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
                    resetCapture: false,
                    restart: false
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

                    // A completed recording is a durable project before the
                    // editor appears. Keep the private working folder only as
                    // a crash-recovery staging area; normal recordings move to
                    // the configured project folder without another save
                    // panel. The first editor session can still explicitly
                    // delete an untouched take.
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
                        ProjectStore.registerRecentProject(moved.session.packageURL)
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
                    finalizationErrors.insert(
                        "屏幕录制已保存，但\(missingTracks.joined(separator: "和"))轨道未成功写入。",
                        at: 0
                    )
                }
                errorMessage = finalizationErrors.isEmpty
                    ? nil : finalizationErrors.joined(separator: "；")
            } else if !finalizationErrors.isEmpty {
                errorMessage = finalizationErrors.joined(separator: "；")
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
                recorderTransitionStage = .openingEditor
                phase = .editor
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
            if isRecordingPaused {
                if run.startedTracks.contains(.camera) { cameraRecorder.resume() }
                if run.startedTracks.contains(.microphone) { microphoneRecorder.resume() }
                if run.startedTracks.contains(.pointer) { pointerRecorder.resume() }
                if run.startedTracks.contains(.device) {
                    deviceRecorder.resume()
                } else {
                    await recorder.resume(runID: run.id)
                    guard recordingRuns.isCurrent(run.id), !recorder.isPaused else { return }
                }
                resumePauseAccounting()
                isRecordingPaused = false
            } else {
                if run.startedTracks.contains(.device) {
                    deviceRecorder.pause()
                } else {
                    await recorder.pause(runID: run.id)
                    guard recordingRuns.isCurrent(run.id), recorder.isPaused else { return }
                }
                if run.startedTracks.contains(.camera) { cameraRecorder.pause() }
                if run.startedTracks.contains(.microphone) { microphoneRecorder.pause() }
                if run.startedTracks.contains(.pointer) { pointerRecorder.pause() }
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
