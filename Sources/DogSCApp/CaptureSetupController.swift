import AppKit
import Combine
import CoreGraphics
import Foundation
import RecorderCore

/// The presentation-only surface used by `CaptureSetupController`.
///
/// Concrete AppKit selectors remain behind this surface. Capture target
/// identity and persisted configuration never live in a selector or overlay.
@MainActor
protocol CaptureSetupSelectorPresenting: AnyObject {
    var onDisplaySelect: ((CaptureDisplay, CaptureSelectionToken) -> Void)? { get set }
    var onDisplayStart: ((CaptureDisplay, CaptureSelectionToken) -> Void)? { get set }
    var onDisplayCancel: ((CaptureSelectionToken) -> Void)? { get set }
    var onWindowSelect: ((CaptureWindowInfo, CaptureSelectionToken) -> Void)? { get set }
    var onWindowUnlock: ((CaptureSelectionToken) -> Void)? { get set }
    var onWindowStart: ((CaptureWindowInfo, CaptureSelectionToken) -> Void)? { get set }
    var onWindowCancel: ((CaptureSelectionToken) -> Void)? { get set }
    var onDeviceSelect: ((CaptureDeviceInfo, CaptureSelectionToken) -> Void)? { get set }
    var onDeviceStart: ((CaptureDeviceInfo, CaptureSelectionToken) -> Void)? { get set }
    var onDeviceCancel: ((CaptureSelectionToken) -> Void)? { get set }
    var onDeviceRefresh: (() -> Void)? { get set }
    var onAutomaticallyCreatesZoomsChange: ((Bool) -> Void)? { get set }
    var onAreaSelectionChanged: ((NormalizedRect) -> Void)? { get set }

    func startDisplay(displays: [CaptureDisplay], token: CaptureSelectionToken)
    func startWindow(token: CaptureSelectionToken)
    func startArea(
        displayID: UInt32?,
        token: CaptureSelectionToken,
        completion: @escaping (CaptureSelectionToken, CaptureAreaSelectionOutcome) -> Void
    )
    func startDevice(
        devices: [CaptureDeviceInfo],
        displayID: UInt32?,
        token: CaptureSelectionToken
    )
    func updateScreenDevices(_ devices: [CaptureDeviceInfo])
    func setAutomaticallyCreatesZooms(_ enabled: Bool)
    func stopAll()
    func beginRecordingPresentation(configuration: CaptureConfiguration)
    func updateWindowRecordingGeometry(_ geometry: CaptureWindowGeometry?)
}

@MainActor
final class CaptureSetupSelectorPresenter: CaptureSetupSelectorPresenting {
    var onDisplaySelect: ((CaptureDisplay, CaptureSelectionToken) -> Void)?
    var onDisplayStart: ((CaptureDisplay, CaptureSelectionToken) -> Void)?
    var onDisplayCancel: ((CaptureSelectionToken) -> Void)?
    var onWindowSelect: ((CaptureWindowInfo, CaptureSelectionToken) -> Void)?
    var onWindowUnlock: ((CaptureSelectionToken) -> Void)?
    var onWindowStart: ((CaptureWindowInfo, CaptureSelectionToken) -> Void)?
    var onWindowCancel: ((CaptureSelectionToken) -> Void)?
    var onDeviceSelect: ((CaptureDeviceInfo, CaptureSelectionToken) -> Void)?
    var onDeviceStart: ((CaptureDeviceInfo, CaptureSelectionToken) -> Void)?
    var onDeviceCancel: ((CaptureSelectionToken) -> Void)?
    var onDeviceRefresh: (() -> Void)?
    var onAutomaticallyCreatesZoomsChange: ((Bool) -> Void)?
    /// Fired while the area selector's drag selection settles, before the
    /// explicit 开始录制 confirm. Lets the controller publish the area
    /// immediately so the start button is live without an extra step.
    var onAreaSelectionChanged: ((NormalizedRect) -> Void)?

    private let areaSelector: CaptureAreaSelector
    private let windowSelector: CaptureWindowSelector
    private let displaySelector: CaptureDisplaySelector
    private let deviceSelector: IOSDeviceCaptureSelector

    init(
        areaSelector: CaptureAreaSelector,
        windowSelector: CaptureWindowSelector,
        displaySelector: CaptureDisplaySelector,
        deviceSelector: IOSDeviceCaptureSelector
    ) {
        self.areaSelector = areaSelector
        self.windowSelector = windowSelector
        self.displaySelector = displaySelector
        self.deviceSelector = deviceSelector

        displaySelector.onSelect = { [weak self] in self?.onDisplaySelect?($0, $1) }
        displaySelector.onStart = { [weak self] in self?.onDisplayStart?($0, $1) }
        displaySelector.onCancel = { [weak self] in self?.onDisplayCancel?($0) }
        windowSelector.onSelect = { [weak self] in self?.onWindowSelect?($0, $1) }
        windowSelector.onUnlock = { [weak self] in self?.onWindowUnlock?($0) }
        windowSelector.onStart = { [weak self] in self?.onWindowStart?($0, $1) }
        windowSelector.onCancel = { [weak self] in self?.onWindowCancel?($0) }
        windowSelector.onAutomaticallyCreatesZoomsChange = { [weak self] in
            self?.onAutomaticallyCreatesZoomsChange?($0)
        }
        deviceSelector.onSelect = { [weak self] in self?.onDeviceSelect?($0, $1) }
        deviceSelector.onStart = { [weak self] in self?.onDeviceStart?($0, $1) }
        deviceSelector.onCancel = { [weak self] in self?.onDeviceCancel?($0) }
        deviceSelector.onRefresh = { [weak self] in self?.onDeviceRefresh?() }
        areaSelector.onSelectionChanged = { [weak self] in
            self?.onAreaSelectionChanged?($0)
        }
    }

    convenience init() {
        self.init(
            areaSelector: CaptureAreaSelector(),
            windowSelector: CaptureWindowSelector(),
            displaySelector: CaptureDisplaySelector(),
            deviceSelector: IOSDeviceCaptureSelector()
        )
    }

    func startDisplay(displays: [CaptureDisplay], token: CaptureSelectionToken) {
        displaySelector.start(displays: displays, token: token)
    }

    func startWindow(token: CaptureSelectionToken) {
        windowSelector.start(token: token)
    }

    func startArea(
        displayID: UInt32?,
        token: CaptureSelectionToken,
        completion: @escaping (CaptureSelectionToken, CaptureAreaSelectionOutcome) -> Void
    ) {
        areaSelector.start(
            on: displayID,
            token: token,
            completion: completion,
            onSelectionChanged: onAreaSelectionChanged
        )
    }

    func startDevice(
        devices: [CaptureDeviceInfo],
        displayID: UInt32?,
        token: CaptureSelectionToken
    ) {
        deviceSelector.start(devices: devices, on: displayID, token: token)
    }

    func updateScreenDevices(_ devices: [CaptureDeviceInfo]) {
        deviceSelector.updateDevices(devices)
    }

    func setAutomaticallyCreatesZooms(_ enabled: Bool) {
        windowSelector.setAutomaticallyCreatesZooms(enabled)
    }

    func stopAll() {
        windowSelector.stop()
        displaySelector.stop()
        deviceSelector.stop()
        areaSelector.cancel()
        areaSelector.hideRecordingOverlay()
    }

    func beginRecordingPresentation(configuration: CaptureConfiguration) {
        displaySelector.stop()
        deviceSelector.stop()
        if configuration.source == .window,
           let windowID = configuration.windowID {
            windowSelector.lockSelectionForRecording(windowID: windowID)
        } else {
            windowSelector.stop()
        }
        // 关闭选择器窗口（不触发取消回调），录制蒙版接管显示：确认选区后
        // 选框连续存在，不会等到录制开始才重新出现。
        areaSelector.dismissWithoutCompleting()
        if configuration.source == .area,
           let selection = configuration.area {
            areaSelector.showRecordingOverlay(
                selection: selection,
                on: configuration.displayID
            )
        } else {
            areaSelector.hideRecordingOverlay()
        }
    }

    func updateWindowRecordingGeometry(_ geometry: CaptureWindowGeometry?) {
        windowSelector.updateRecordingGeometry(geometry)
    }
}

@MainActor
struct CaptureSetupProviders {
    var displays: () -> [CaptureDisplay]
    var windows: () async throws -> [CaptureWindowInfo]
    var screenDevices: () -> [CaptureDeviceInfo]
    var readiness: (OutputFrameRate, CaptureCodec, UInt32?) -> CaptureReadiness
    var hasScreenRecordingPermission: () -> Bool

    static let live = CaptureSetupProviders(
        displays: { CaptureDisplay.available() },
        windows: { try await CaptureWindowInfo.available() },
        screenDevices: { CaptureDeviceCatalog.screenDevices() },
        readiness: { frameRate, codec, displayID in
            CaptureReadiness.current(
                targetFrameRate: frameRate,
                captureCodec: codec,
                displayID: displayID
            )
        },
        hasScreenRecordingPermission: { CGPreflightScreenCaptureAccess() }
    )
}

/// Sole owner of setup configuration, target selection and selector
/// presentation. AppModel supplies only application routing callbacks and takes
/// an immutable `RecordingPlan` snapshot at the setup -> preparing boundary.
@MainActor
final class CaptureSetupController: ObservableObject {
    @Published private(set) var configuration: CaptureConfiguration
    @Published private(set) var availableDisplays: [CaptureDisplay]
    @Published private(set) var availableWindows: [CaptureWindowInfo] = []
    @Published private(set) var availableScreenDevices: [CaptureDeviceInfo]
    @Published private(set) var isRefreshingWindows = false
    @Published private(set) var readiness: CaptureReadiness
    @Published private(set) var automaticallyCreatesZooms = true

    var onStartRequested: (() -> Void)?
    var onError: ((String?) -> Void)?
    var onSelectionPresentationStarted: (() -> Void)?
    var onFocusRestorationRequested: (() -> Void)?
    var recorderDisplayID: (() -> UInt32?)?

    var selectedSource: CaptureSource? { selection.state.selectedSource }
    var target: CaptureSelectionTarget? { selection.state.target }
    var canStartRecording: Bool { selection.state.canStartRecording }

    private let presenter: any CaptureSetupSelectorPresenting
    private let providers: CaptureSetupProviders
    private let isDesignReview: Bool
    private let selection = CaptureSelectionCoordinator()
    private let windowGeometryRuntime: CaptureWindowGeometryRuntime
    private var windowsRefreshToken: CaptureSelectionToken?
    private var focusRestorationGeneration: UInt64 = 0
    private var startRequestedToken: CaptureSelectionToken?
    private var selectionBaselineToken: CaptureSelectionToken?
    private var selectionBaselineConfiguration: CaptureConfiguration?
    private var selectionBaselineTarget: CaptureSelectionTarget?

    init(
        configuration: CaptureConfiguration = CaptureConfiguration(),
        presenter: (any CaptureSetupSelectorPresenting)? = nil,
        providers: CaptureSetupProviders? = nil,
        windowGeometryRuntime: CaptureWindowGeometryRuntime? = nil,
        isDesignReview: Bool = CommandLine.arguments.contains("--design-review")
    ) {
        let presenter = presenter ?? CaptureSetupSelectorPresenter()
        let providers = providers ?? .live
        let productConfiguration = Self.currentProductConfiguration(configuration)
        self.configuration = productConfiguration
        self.presenter = presenter
        self.providers = providers
        self.windowGeometryRuntime = windowGeometryRuntime ?? CaptureWindowGeometryRuntime()
        self.isDesignReview = isDesignReview
        availableDisplays = providers.displays()
        availableScreenDevices = providers.screenDevices()
        readiness = providers.readiness(
            productConfiguration.captureFrameRate,
            productConfiguration.captureCodec,
            productConfiguration.displayID
        )

        selection.onStateChange = { [weak self] _ in
            self?.objectWillChange.send()
        }
        wirePresenterCallbacks()
        self.windowGeometryRuntime.onChange = { [weak self] geometry in
            self?.presenter.updateWindowRecordingGeometry(geometry)
        }
        presenter.setAutomaticallyCreatesZooms(automaticallyCreatesZooms)
        presenter.updateScreenDevices(availableScreenDevices)
    }

    func selectSource(_ source: CaptureSource) {
        focusRestorationGeneration &+= 1
        let baselineConfiguration = configuration
        let baselineTarget = selection.state.target
        let session = selection.choose(source)
        selectionBaselineToken = session.token
        selectionBaselineConfiguration = baselineConfiguration
        selectionBaselineTarget = baselineTarget
        startRequestedToken = nil
        stopPresentation()
        onSelectionPresentationStarted?()

        var updated = configuration
        updated.source = source
        if source != .window {
            updated.selectedApplicationBundleIdentifier = nil
            updated.selectedApplicationName = nil
            if updated.systemAudioScope == .selectedApplication {
                updated.systemAudioScope = .all
            }
        }
        clearTarget(for: source, in: &updated)
        publishConfiguration(updated)
        onError?(nil)

        switch source {
        case .display:
            availableDisplays = providers.displays()
            presenter.startDisplay(displays: availableDisplays, token: session.token)
        case .window:
            refreshWindows(token: session.token)
            presenter.startWindow(token: session.token)
        case .area:
            availableDisplays = providers.displays()
            let requestedDisplayID = recorderDisplayID?()
            presenter.startArea(
                displayID: requestedDisplayID,
                token: session.token
            ) { [weak self] token, outcome in
                self?.completeAreaSelection(
                    token: token,
                    outcome: outcome
                )
            }
        case .device:
            refreshScreenDevices()
            presenter.startDevice(
                devices: availableScreenDevices,
                displayID: recorderDisplayID?(),
                token: session.token
            )
        }
    }

    /// Direct confirmation applies a display choice without opening a selector
    /// overlay.
    func selectDisplay(_ display: CaptureDisplay) {
        let session = selection.choose(.display)
        selectionBaselineToken = nil
        selectionBaselineConfiguration = nil
        selectionBaselineTarget = nil
        startRequestedToken = nil
        stopPresentation()
        var updated = configuration
        updated.source = .display
        clearTarget(for: .display, in: &updated)
        publishConfiguration(updated)
        _ = confirm(
            .display(id: display.id, name: display.name),
            token: session.token
        )
    }

    func replaceConfiguration(_ replacement: CaptureConfiguration) {
        publishConfiguration(replacement)
        refreshReadiness()
    }

    func setCaptureFrameRate(_ frameRate: OutputFrameRate) {
        var updated = configuration
        updated.captureFrameRate = frameRate
        publishConfiguration(updated)
        refreshReadiness()
    }

    func setResolutionLimit(_ limit: CaptureResolutionLimit) {
        var updated = configuration
        updated.captureResolutionLimit = limit
        publishConfiguration(updated)
        refreshReadiness()
    }

    func setCaptureCodec(_ codec: CaptureCodec) {
        var updated = configuration
        updated.captureCodec = codec
        publishConfiguration(updated)
        refreshReadiness()
    }

    func setSystemAudio(enabled: Bool, scope: SystemAudioScope? = nil) {
        var updated = configuration
        updated.recordsSystemAudio = enabled
        if let scope { updated.systemAudioScope = scope }
        publishConfiguration(updated)
    }

    func setCamera(_ device: CaptureDeviceInfo?) {
        var updated = configuration
        let deviceChanged = updated.cameraDeviceID != device?.id
        updated.recordsCamera = device != nil
        updated.cameraDeviceID = device?.id
        updated.cameraDeviceName = device?.name
        if device == nil || deviceChanged {
            updated.cameraCaptureResolution = nil
        }
        publishConfiguration(updated)
    }

    func setCameraCaptureResolution(_ resolution: CameraCaptureResolution?) {
        guard configuration.recordsCamera else { return }
        var updated = configuration
        updated.cameraCaptureResolution = resolution
        publishConfiguration(updated)
    }

    @discardableResult
    func clearCamera(ifMatching deviceID: String?) -> Bool {
        guard configuration.cameraDeviceID == deviceID else { return false }
        setCamera(nil)
        return true
    }

    func setMicrophone(_ device: CaptureDeviceInfo?) {
        var updated = configuration
        updated.recordsMicrophone = device != nil
        updated.microphoneDeviceID = device?.id
        updated.microphoneDeviceName = device?.name
        publishConfiguration(updated)
    }

    @discardableResult
    func clearMicrophone(ifMatching deviceID: String?) -> Bool {
        guard configuration.microphoneDeviceID == deviceID else { return false }
        setMicrophone(nil)
        return true
    }

    func setSurfaceVisibility(hidesDesktopFiles: Bool? = nil, hidesDock: Bool? = nil) {
        var updated = configuration
        if let hidesDesktopFiles { updated.hidesDesktopFiles = hidesDesktopFiles }
        if let hidesDock { updated.hidesDock = hidesDock }
        publishConfiguration(updated)
    }

    func refreshReadiness() {
        availableDisplays = providers.displays()
        readiness = providers.readiness(
            configuration.captureFrameRate,
            configuration.captureCodec,
            configuration.displayID
        )
    }

    func refreshScreenDevices() {
        _ = updateScreenDevices(providers.screenDevices())
    }

    /// Returns the disconnected selected device ID so the hardware owner can
    /// release that endpoint without making setup depend on a recorder.
    @discardableResult
    func updateScreenDevices(_ devices: [CaptureDeviceInfo]) -> String? {
        availableScreenDevices = devices
        presenter.updateScreenDevices(devices)
        guard let selectedID = configuration.deviceID,
              !devices.contains(where: { $0.id == selectedID }) else { return nil }

        if case let .ready(session, .device(id: targetID, name: _)) = selection.state,
           targetID == selectedID {
            _ = selection.unlock(token: session.token)
        }
        var updated = configuration
        updated.deviceID = nil
        updated.deviceName = nil
        publishConfiguration(updated)
        return selectedID
    }

    func makeRecordingPlan(pointerCaptureFrame: CGRect) throws -> RecordingPlan {
        guard let target else {
            throw RecordingPlanError.targetDoesNotMatchConfiguration
        }
        return try RecordingPlan(
            target: target,
            configuration: configuration,
            pointerCaptureFrame: pointerCaptureFrame,
            automaticallyCreatesZooms: automaticallyCreatesZooms
        )
    }

    func beginRecordingPresentation(for plan: RecordingPlan) {
        presenter.beginRecordingPresentation(configuration: plan.configuration)
        if case let .window(id, _, _, _) = plan.target {
            windowGeometryRuntime.start(
                windowID: id,
                initialFrame: plan.pointerCaptureFrame,
                pollInterval: .milliseconds(250)
            )
        } else {
            windowGeometryRuntime.stop()
        }
    }

    func pointerFrameSource(for plan: RecordingPlan) -> PointerCaptureFrameSource {
        guard case let .window(id, _, _, _) = plan.target else {
            return .fixed(plan.pointerCaptureFrame)
        }
        return .trackedWindow(windowID: id) { [weak self] windowID in
            self?.windowGeometryRuntime.frame(for: windowID)
        }
    }

    func stopPresentation() {
        windowsRefreshToken = nil
        isRefreshingWindows = false
        windowGeometryRuntime.stop()
        presenter.stopAll()
    }

    func reset() {
        focusRestorationGeneration &+= 1
        startRequestedToken = nil
        selectionBaselineToken = nil
        selectionBaselineConfiguration = nil
        selectionBaselineTarget = nil
        _ = selection.reset()
        // Invalidate the semantic session before closing AppKit surfaces.
        // Some selectors synchronously report cancellation while stopping;
        // those callbacks must already be stale and therefore be ignored.
        stopPresentation()
    }

    private func wirePresenterCallbacks() {
        presenter.onAreaSelectionChanged = { [weak self] rect in
            guard let self else { return }
            // 拖选落下即生效：区域配置立即发布，开始按钮马上可用，
            // 不必等单独的点“确认”步骤。
            var updated = self.configuration
            updated.source = .area
            updated.area = rect.constrained()
            self.publishConfiguration(updated)
        }
        presenter.onDisplaySelect = { [weak self] display, token in
            _ = self?.confirmDisplay(display, token: token)
        }
        presenter.onDisplayStart = { [weak self] display, token in
            guard self?.confirmDisplay(display, token: token) == true else { return }
            self?.requestStart(token: token)
        }
        presenter.onDisplayCancel = { [weak self] token in self?.cancel(token: token) }
        presenter.onWindowSelect = { [weak self] window, token in
            _ = self?.confirmWindow(window, token: token)
        }
        presenter.onWindowUnlock = { [weak self] token in
            guard let self, selection.unlock(token: token) else { return }
            var updated = configuration
            clearTarget(for: .window, in: &updated)
            publishConfiguration(updated)
            onError?(nil)
        }
        presenter.onWindowStart = { [weak self] window, token in
            guard let self, confirmWindow(window, token: token) else { return }
            if isDesignReview {
                presenter.beginRecordingPresentation(configuration: configuration)
            } else {
                requestStart(token: token)
            }
        }
        presenter.onWindowCancel = { [weak self] token in self?.cancel(token: token) }
        presenter.onDeviceSelect = { [weak self] device, token in
            _ = self?.confirmDevice(device, token: token)
        }
        presenter.onDeviceStart = { [weak self] device, token in
            guard self?.confirmDevice(device, token: token) == true else { return }
            self?.requestStart(token: token)
        }
        presenter.onDeviceCancel = { [weak self] token in self?.cancel(token: token) }
        presenter.onDeviceRefresh = { [weak self] in self?.refreshScreenDevices() }
        presenter.onAutomaticallyCreatesZoomsChange = { [weak self] enabled in
            guard let self, automaticallyCreatesZooms != enabled else { return }
            automaticallyCreatesZooms = enabled
            presenter.setAutomaticallyCreatesZooms(enabled)
        }
    }

    private func completeAreaSelection(
        token: CaptureSelectionToken,
        outcome: CaptureAreaSelectionOutcome
    ) {
        guard selection.isCurrent(token) else { return }
        switch outcome {
        case .cancelled:
            cancel(token: token)
        case let .displayUnavailable(requestedID):
            let message = requestedID == nil
                ? "没有找到可用于区域录制的显示器。"
                : "用于区域录制的显示器已断开，请重新选择。"
            cancel(token: token, errorMessage: message)
        case let .selected(result):
            let target = CaptureSelectionTarget.area(
                displayID: result.display.id,
                displayName: result.display.name,
                rect: result.rect
            )
            guard confirm(target, token: token) else { return }
            // “开始录制”按钮（及回车）直接进入录制：选择器窗口随即关闭，
            // 录制蒙版由 beginRecordingPresentation 接续显示，选区不会消失。
            requestStart(token: token)
        }
    }

    private func confirmDisplay(
        _ display: CaptureDisplay,
        token: CaptureSelectionToken
    ) -> Bool {
        confirm(.display(id: display.id, name: display.name), token: token)
    }

    private func confirmWindow(
        _ window: CaptureWindowInfo,
        token: CaptureSelectionToken
    ) -> Bool {
        availableWindows = availableWindows.filter { $0.id != window.id } + [window]
        return confirm(
            .window(
                id: window.id,
                name: window.pickerLabel,
                applicationBundleIdentifier: window.applicationBundleIdentifier,
                applicationName: window.applicationName
            ),
            token: token
        )
    }

    private func confirmDevice(
        _ device: CaptureDeviceInfo,
        token: CaptureSelectionToken
    ) -> Bool {
        confirm(.device(id: device.id, name: device.name), token: token)
    }

    @discardableResult
    private func confirm(
        _ target: CaptureSelectionTarget,
        token: CaptureSelectionToken
    ) -> Bool {
        guard selection.isCurrent(token), selectedSource == target.source else { return false }
        if selection.state.target != target,
           !selection.confirm(target, token: token) {
            return false
        }
        publishConfiguration(target.materializing(in: configuration))
        if target.source == .display || target.source == .area {
            refreshReadiness()
        }
        onError?(nil)
        return true
    }

    private func requestStart(token: CaptureSelectionToken) {
        guard selection.isCurrent(token), target != nil,
              startRequestedToken != token else { return }
        startRequestedToken = token
        if selectionBaselineToken == token {
            selectionBaselineToken = nil
            selectionBaselineConfiguration = nil
            selectionBaselineTarget = nil
        }
        onStartRequested?()
    }

    private func cancel(
        token: CaptureSelectionToken,
        errorMessage: String? = nil
    ) {
        guard let source = selection.state.session?.source,
              selection.cancel(token: token) else { return }
        startRequestedToken = nil
        let baselineConfiguration = selectionBaselineToken == token
            ? selectionBaselineConfiguration
            : nil
        let baselineTarget = selectionBaselineToken == token
            ? selectionBaselineTarget
            : nil
        selectionBaselineToken = nil
        selectionBaselineConfiguration = nil
        selectionBaselineTarget = nil
        stopPresentation()
        if let baselineConfiguration {
            publishConfiguration(baselineConfiguration)
        } else {
            var updated = configuration
            clearTarget(for: source, in: &updated)
            publishConfiguration(updated)
        }
        if let baselineTarget {
            let restoredSession = selection.choose(baselineTarget.source)
            _ = selection.confirm(baselineTarget, token: restoredSession.token)
        }
        refreshReadiness()
        onError?(errorMessage)
        restoreFocus(allowingSelectedSource: baselineTarget != nil)
    }

    private func refreshWindows(token: CaptureSelectionToken) {
        guard selection.isCurrent(token) else { return }
        windowsRefreshToken = token
        isRefreshingWindows = true
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let windows = try await providers.windows()
                guard selection.isCurrent(token) else { return }
                availableWindows = windows
            } catch {
                guard selection.isCurrent(token), selectedSource == .window else { return }
                if !providers.hasScreenRecordingPermission() {
                    onError?("需要屏幕录制权限才能读取窗口列表。授权后请重新启动应用。")
                } else {
                    onError?("读取窗口列表失败：\(error.localizedDescription)")
                }
            }
            if windowsRefreshToken == token {
                windowsRefreshToken = nil
                isRefreshingWindows = false
            }
        }
    }

    private func restoreFocus(allowingSelectedSource: Bool) {
        focusRestorationGeneration &+= 1
        let generation = focusRestorationGeneration
        DispatchQueue.main.async { [weak self] in
            guard let self,
                  focusRestorationGeneration == generation,
                  allowingSelectedSource || selectedSource == nil else { return }
            onFocusRestorationRequested?()
        }
    }

    private func publishConfiguration(_ replacement: CaptureConfiguration) {
        let normalized = Self.currentProductConfiguration(replacement)
        guard normalized != configuration else { return }
        configuration = normalized
    }

    /// REC-001 / EXP-002: projects created by older builds may legitimately
    /// keep 90/120 FPS metadata for playback compatibility, but opening one
    /// must never leak that historical value into the next live recording.
    /// The setup controller is the production recording boundary, so every
    /// configuration entering it is normalized instead of merely hiding the
    /// unsupported choices in the menu.
    private static func currentProductConfiguration(
        _ configuration: CaptureConfiguration
    ) -> CaptureConfiguration {
        var normalized = configuration
        normalized.captureFrameRate = OutputFrameRate.captureEncodingQualityTarget
        return normalized
    }

    private func clearTarget(
        for source: CaptureSource,
        in configuration: inout CaptureConfiguration
    ) {
        switch source {
        case .display:
            configuration.displayID = nil
            configuration.displayName = nil
        case .window:
            configuration.windowID = nil
            configuration.windowName = nil
            configuration.selectedApplicationBundleIdentifier = nil
            configuration.selectedApplicationName = nil
        case .area:
            configuration.area = nil
        case .device:
            configuration.deviceID = nil
            configuration.deviceName = nil
        }
    }
}
