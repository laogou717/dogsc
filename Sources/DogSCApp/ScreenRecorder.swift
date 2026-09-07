import AppKit
import AVFoundation
import CoreMedia
import CoreVideo
import Foundation
import os
import RecorderCore
import ScreenCaptureKit
import VideoToolbox

@MainActor
final class ScreenRecorder: NSObject, ObservableObject, SCStreamDelegate {
    @Published private(set) var isCapturing = false
    @Published private(set) var isPaused = false
    @Published private(set) var liveMeasurement: FrameRateMeasurement?
    @Published private(set) var lastMeasurement: FrameRateMeasurement?
    @Published private(set) var lastStopWarning: String?
    @Published private(set) var firstFrameStartedAt: Date?
    private(set) var lastSystemAudioDiagnostics: AudioCaptureDiagnostics?
    /// First accepted screen frame in Core Media's monotonic host clock.
    /// Pointer recording consumes this value to share the video timeline epoch.
    var firstFrameStartedAtHostTime: TimeInterval? { nativeFirstFrameHostTime }
    var onUnexpectedStop: (@MainActor (RecordingRunID, any Error) -> Void)?
    private let surfaceVisibilityGate = AsyncOperationGate()
    private let maximumH264CaptureDimensions: CaptureDimensions

    private let sampleQueue = DispatchQueue(
        label: "cn.laogou.dogsc.capture",
        // ScreenCaptureKit delivery is deadline-sensitive: lowering this queue
        // to userInitiated let the desktop stay at 118.92 Hz but reduced actual
        // captured delivery to 32.21 fps. Keep only this tiny ingress callback
        // interactive; encoding and file I/O remain on the lower writer queue.
        qos: .userInteractive
    )
    private var stream: SCStream?
    private var audioStream: SCStream?
    private var captureOutput: CaptureOutput?
    private var nativeRecordingSegment: (any NativeScreenRecordingSegmentProtocol)?
    /// Stored as `AnyObject` so the recorder keeps its pre-macOS-15 deployment
    /// target while conditionally owning the macOS 15 frame monitor.
    private var nativeFrameMonitor: AnyObject?
    private var nativeCompletedSegmentURLs: [URL] = []
    private var nativeFinalOutputURL: URL?
    private var nativeRunToken: ScreenRecorderRunToken?
    private var nativeCaptureCodec: CaptureCodec?
    private var nativeSystemAudioOutput: NativeSystemAudioCaptureOutput?
    private var coreAudioSystemAudioTap: AnyObject?
    private var nativeFirstFrameHostTime: TimeInterval?
    private var performanceActivity: NSObjectProtocol?
    private var usesNativeRecordingOutput = false
    private var requestedFrameRate: OutputFrameRate = .fps60
    private var measurementTask: Task<Void, Never>?
    private var runSafety = ScreenRecorderRunSafetyState()
    /// Auxiliary (selected-app audio) stream failure while the primary stream
    /// keeps capturing. Merged into `lastStopWarning` so the lost audio track
    /// is surfaced without ending the recording.
    private var secondaryStreamTerminalError: (any Error)?

    init(
        maximumH264CaptureDimensions: CaptureDimensions = CaptureDimensions(
            width: 4096,
            height: 2304
        )
    ) {
        self.maximumH264CaptureDimensions = maximumH264CaptureDimensions
        super.init()
    }

    func start(
        runID: RecordingRunID,
        configuration: CaptureConfiguration,
        outputURL: URL
    ) async throws {
        let run: ScreenRecorderRunToken
        switch runSafety.begin(runID) {
        case let .accepted(token):
            run = token
        case let .alreadyActive(activeRunID):
            throw ScreenRecorderError.alreadyActive(activeRunID)
        }
        do {
            try await performStart(run: run, configuration: configuration, outputURL: outputURL)
        } catch {
            await rollbackFailedStart(run: run)
            throw error
        }
    }

    private func performStart(
        run: ScreenRecorderRunToken,
        configuration: CaptureConfiguration,
        outputURL: URL
    ) async throws {
        lastSystemAudioDiagnostics = nil

        // Authorization is completed by the setup permission gate before any
        // selector or recording mask can appear. This path only consumes the
        // permission; it must never raise a second system prompt mid-flow.
        let content = try await SCShareableContent.excludingDesktopWindows(
            false,
            onScreenWindowsOnly: true
        )

        let filter: SCContentFilter
        let sourceWidth: Int
        let sourceHeight: Int
        var sourceRect: CGRect?

        switch configuration.source {
        case .display, .area:
            let display = try preferredDisplay(
                from: content.displays,
                requestedDisplayID: configuration.displayID
            )
            filter = displayContentFilter(
                content: content,
                display: display,
                configuration: configuration
            )
            let pixelScale = max(CGFloat(filter.pointPixelScale), 1)

            if configuration.source == .area {
                guard let area = configuration.area?.constrained(),
                      area.width > 0.01,
                      area.height > 0.01 else {
                    throw ScreenRecorderError.invalidArea
                }
                let rect = CGRect(
                    x: Double(display.width) * area.x,
                    y: Double(display.height) * area.y,
                    width: Double(display.width) * area.width,
                    height: Double(display.height) * area.height
                ).integral
                sourceRect = rect
                sourceWidth = max(Int((rect.width * pixelScale).rounded()), 2)
                sourceHeight = max(Int((rect.height * pixelScale).rounded()), 2)
            } else {
                sourceWidth = max(Int((CGFloat(display.width) * pixelScale).rounded()), 2)
                sourceHeight = max(Int((CGFloat(display.height) * pixelScale).rounded()), 2)
            }

        case .window:
            guard let windowID = configuration.windowID,
                  let window = content.windows.first(where: { $0.windowID == windowID }),
                  window.owningApplication?.processID != getpid() else {
                throw ScreenRecorderError.noWindow
            }
            filter = SCContentFilter(desktopIndependentWindow: window)
            let pixelScale = max(CGFloat(filter.pointPixelScale), 1)
            // The window frame is expressed in global logical points. The
            // filter owns the exact captured content rect and its point-to-pixel
            // scale, including macOS scaled display modes. Use that pair so the
            // writer surface describes captured content rather than UI geometry.
            let contentSize = filter.contentRect.size
            let logicalWidth = contentSize.width > 0 ? contentSize.width : window.frame.width
            let logicalHeight = contentSize.height > 0 ? contentSize.height : window.frame.height
            sourceWidth = max(Int((logicalWidth * pixelScale).rounded()), 2)
            sourceHeight = max(Int((logicalHeight * pixelScale).rounded()), 2)
        case .device:
            throw ScreenRecorderError.unsupportedSource
        }

        let useNativeRecordingOutput: Bool
        if #available(macOS 15.0, *) {
            useNativeRecordingOutput = NativeScreenRecordingBackendPolicy
                .canUseNativeWriter(
                    source: configuration.source,
                    codec: configuration.captureCodec,
                    requestedFramesPerSecond: configuration.captureFrameRate.rawValue,
                    recordsSystemAudio: configuration.recordsSystemAudio,
                    nativeAPIIsAvailable: NativeScreenRecordingBackendPolicy
                        .nativeCodecIsAvailable(configuration.captureCodec)
                )
        } else {
            useNativeRecordingOutput = false
        }
        let streamConfiguration = SCStreamConfiguration()
        let nativeEncodedDimensions = NativeScreenRecordingBackendPolicy.captureDimensions(
            sourceWidth: sourceWidth,
            sourceHeight: sourceHeight,
            codec: configuration.captureCodec,
            usesNativeWriter: useNativeRecordingOutput,
            legacyH264Maximum: maximumH264CaptureDimensions
        )
        let encodedDimensions = configuration.captureResolutionLimit.applying(to: nativeEncodedDimensions)
        let nativeSurfaceDimensions = NativeScreenRecordingBackendPolicy
            .streamSurfaceDimensions(
                sourceWidth: sourceWidth,
                sourceHeight: sourceHeight
            )
        let streamSurfaceDimensions = useNativeRecordingOutput
            ? configuration.captureResolutionLimit.applying(to: nativeSurfaceDimensions)
            : nativeSurfaceDimensions
        // REC-003: preserve native Retina luma/detail until the writer's one
        // explicit resize. Capture surfaces and encoded output intentionally
        // remain separate ownership boundaries.
        streamConfiguration.width = streamSurfaceDimensions.width
        streamConfiguration.height = streamSurfaceDimensions.height
        streamConfiguration.captureResolution = NativeScreenRecordingBackendPolicy
            .captureResolution(for: configuration.source)
        // Ask ScreenCaptureKit for the same hardware-native NV12 layout that
        // H.264 consumes. A 4096x2304 BGRA stream moved about 2.25 GiB/s at
        // 60 fps before encoding and visibly reduced WindowServer cadence on a
        // ProMotion display. Convert the desktop once into the same SDR sRGB
        // transfer contract used by preview/export instead of changing the
        // transfer tag after capture.
        streamConfiguration.pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        streamConfiguration.colorSpaceName = CGColorSpace.sRGB as CFString
        streamConfiguration.colorMatrix = kCVImageBufferYCbCrMatrix_ITU_R_709_2
        if #available(macOS 15.0, *) {
            // Keep capture and the writer on one explicit SDR path. This is
            // especially important on XDR/P3 displays, where an implicit HDR
            // stream later tagged as Rec.709 produces the washed-out result.
            streamConfiguration.captureDynamicRange = .SDR
        }
        streamConfiguration.scalesToFit = true
        streamConfiguration.preservesAspectRatio = true
        if let sourceRect {
            streamConfiguration.sourceRect = sourceRect
        }
        // REC-001/REC-002/REC-004: keep real VFR timestamps and write every
        // complete monotonic SCK sample. Every Mac screen source requests at
        // most 60 updates so 120 Hz display/window producers do not spend the
        // recording's quality and encoding budget on frames a 60 FPS export
        // cannot retain.
        streamConfiguration.minimumFrameInterval =
            CaptureStreamTimingPolicy.minimumFrameInterval(for: configuration.source)
        // REC-001/REC-004: use SCK's bounded eight-surface pool so short
        // encoder ownership spikes do not immediately back-pressure
        // WindowServer and turn into missing desktop frames.
        streamConfiguration.queueDepth = CaptureStreamSurfacePolicy.queueDepth
        // Keep the raw recording cursor-free. Pointer positions are recorded on
        // a separate event track and rendered later, so the editor can replace,
        // resize, smooth or hide the cursor without baking it into the video.
        streamConfiguration.showsCursor = false
        streamConfiguration.excludesCurrentProcessAudio = true

        // Never attach audio to the native recording stream. On this macOS
        // runtime SCRecordingOutput writes bytes but can leave startCapture()
        // suspended forever when same-stream audio is enabled.
        streamConfiguration.capturesAudio = false
        let stream = SCStream(filter: filter, configuration: streamConfiguration, delegate: self)

        var captureOutput: CaptureOutput?
        var nativeFrameMonitor: AnyObject?
        var nativeSystemAudioOutput: NativeSystemAudioCaptureOutput?
        var coreAudioSystemAudioTap: AnyObject?
        var needsScreenCaptureKitAudioFallback = false
        if configuration.recordsSystemAudio {
            if #available(macOS 15.0, *) {
                let audioURL = outputURL.deletingLastPathComponent().appendingPathComponent(
                    ".independent-system-audio-\(UUID().uuidString).m4a"
                )
                nativeSystemAudioOutput = try NativeSystemAudioCaptureOutput(
                    outputURL: audioURL
                )
                coreAudioSystemAudioTap = try CoreAudioSystemAudioTap(
                    scope: configuration.systemAudioScope,
                    selectedApplicationBundleIdentifier:
                        configuration.selectedApplicationBundleIdentifier,
                    output: nativeSystemAudioOutput!
                )
            } else {
                needsScreenCaptureKitAudioFallback = true
            }
        }
        if useNativeRecordingOutput {
            if #available(macOS 15.0, *) {
                let segment = NativeScreenRecordingSegment(
                    outputURL: outputURL,
                    codec: configuration.captureCodec,
                    onFailure: { [weak self] error in
                        let event = CaptureOutputTerminalEvent(
                            run: run,
                            stage: .videoAppend,
                            error: error
                        )
                        Task { @MainActor [weak self] in
                            self?.handleCaptureOutputTerminal(event)
                        }
                    }
                )
                try stream.addRecordingOutput(segment.recordingOutput)
                let monitor = NativeScreenFrameMonitor(
                    target: configuration.captureFrameRate
                )
                try stream.addStreamOutput(
                    monitor,
                    type: .screen,
                    sampleHandlerQueue: sampleQueue
                )
                nativeFrameMonitor = monitor
                nativeRecordingSegment = segment
                nativeCompletedSegmentURLs = []
                nativeFinalOutputURL = outputURL
                nativeRunToken = run
                nativeCaptureCodec = configuration.captureCodec
            }
        } else {
            // REC-001/REC-004/NAT-001: the 60 fps path owns the single video
            // stream and writer. Core Audio records system sound independently,
            // so no second ScreenCaptureKit display compositor competes with
            // WindowServer or the 4K VideoToolbox encoder.
            let created = try CaptureOutput(
                run: run,
                outputURL: outputURL,
                width: encodedDimensions.width,
                height: encodedDimensions.height,
                frameRate: configuration.captureFrameRate,
                codec: configuration.captureCodec,
                recordsSystemAudio: needsScreenCaptureKitAudioFallback,
                onTerminalFailure: { [weak self] event in
                    Task { @MainActor [weak self] in
                        self?.handleCaptureOutputTerminal(event)
                    }
                }
            )
            try stream.addStreamOutput(created, type: .screen, sampleHandlerQueue: sampleQueue)
            captureOutput = created
        }

        var audioStream: SCStream?
        if needsScreenCaptureKitAudioFallback, let captureOutput {
            // 系统声音独立流：与视频流分离，避免 SCK 同流音视频采集
            // 拖累视频交付率。全部系统音频用 display 级 filter，
            // 所选 App 音频用 application 级 filter。
            let audioDisplay = try preferredDisplay(
                from: content.displays,
                requestedDisplayID: configuration.displayID
            )
            let audioFilter: SCContentFilter
            if configuration.systemAudioScope == .selectedApplication {
                guard let bundleIdentifier = configuration.selectedApplicationBundleIdentifier,
                      let application = content.applications.first(where: {
                          $0.bundleIdentifier == bundleIdentifier
                      }) else {
                    throw ScreenRecorderError.recordingFailed("没有找到所选窗口所属的 App")
                }
                audioFilter = SCContentFilter(
                    display: audioDisplay,
                    including: [application],
                    exceptingWindows: []
                )
            } else {
                audioFilter = SCContentFilter(
                    display: audioDisplay,
                    excludingApplications: content.applications.filter {
                        $0.processID == getpid()
                    },
                    exceptingWindows: []
                )
            }
            let audioConfiguration = SCStreamConfiguration()
            // REC-001/REC-004: this stream exists only to receive .audio.
            // Without an explicit low video cadence SCK still schedules a
            // second display compositor at its default rate even though no
            // .screen output is registered; the real 120 Hz A/B dropped the
            // foreground source from 60.00 to 28.80 fps. Keep the unavoidable
            // auxiliary surface tiny and refresh it only once per second while
            // the audio clock continues independently at 48 kHz.
            audioConfiguration.width = 2
            audioConfiguration.height = 2
            audioConfiguration.minimumFrameInterval = CMTime(
                value: 1,
                timescale: 1
            )
            audioConfiguration.queueDepth = 1
            audioConfiguration.pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
            audioConfiguration.showsCursor = false
            audioConfiguration.capturesAudio = true
            audioConfiguration.sampleRate = 48_000
            audioConfiguration.channelCount = 2
            audioConfiguration.excludesCurrentProcessAudio = true
            let createdAudioStream = SCStream(
                filter: audioFilter,
                configuration: audioConfiguration,
                delegate: self
            )
            try createdAudioStream.addStreamOutput(
                captureOutput,
                type: .audio,
                sampleHandlerQueue: sampleQueue
            )
            audioStream = createdAudioStream
        }

        self.requestedFrameRate = configuration.captureFrameRate
        self.captureOutput = captureOutput
        self.nativeFrameMonitor = nativeFrameMonitor
        self.nativeSystemAudioOutput = nativeSystemAudioOutput
        self.coreAudioSystemAudioTap = coreAudioSystemAudioTap
        usesNativeRecordingOutput = useNativeRecordingOutput
        self.stream = stream
        self.audioStream = audioStream
        guard runSafety.registerStreams(
            primary: ObjectIdentifier(stream),
            secondary: audioStream.map(ObjectIdentifier.init),
            for: run
        ) else { throw ScreenRecorderError.runNotActive(run.runID) }
        beginPerformanceActivity()
        // Start independent system audio first. Its raw samples and the first
        // accepted video frame both use Core Media's host clock, so the
        // final mux can precisely trim a short audio lead instead of losing the
        // first audible event while waiting for the first video frame.
        if #available(macOS 14.2, *),
           let tap = coreAudioSystemAudioTap as? CoreAudioSystemAudioTap {
            try tap.start()
        }
        try await stream.startCapture()
        if useNativeRecordingOutput {
            if #available(macOS 15.0, *),
               let nativeRecordingSegment,
               let monitor = nativeFrameMonitor as? NativeScreenFrameMonitor {
                // The delegate callback is only a lifecycle notification. Use
                // the first complete SCK sample for the real shared epoch so
                // system audio, pointer events and camera do not inherit a
                // callback-scheduling offset from the native writer.
                let observed = try await monitor.waitForFirstFrame(timeout: 5)
                _ = try await nativeRecordingSegment.waitForStart(timeout: 5)
                firstFrameStartedAt = observed.wallTime
                nativeFirstFrameHostTime = observed.hostTime
            } else {
                throw ScreenRecorderError.recordingFailed("苹果原生录制后端不可用")
            }
        } else if let captureOutput {
            firstFrameStartedAt = try await captureOutput.waitForFirstFrame()
            nativeFirstFrameHostTime = await captureOutput.firstFrameHostTime()
        } else {
            throw ScreenRecorderError.cannotCreateWriter
        }
        if !useNativeRecordingOutput {
            try await audioStream?.startCapture()
        }
        if let error = await captureOutput?.currentTerminalError() { throw error }
        guard runSafety.markCapturing(run) else {
            throw runSafety.terminalError(for: run.runID)
                ?? ScreenRecorderError.runNotActive(run.runID)
        }
        isCapturing = true
        isPaused = false
        liveMeasurement = nil
        lastStopWarning = nil
        secondaryStreamTerminalError = nil
        measurementTask?.cancel()
        if let captureOutput {
            measurementTask = Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: 1_000_000_000)
                    guard !Task.isCancelled, let self, self.isCapturing,
                          self.runSafety.activeRunID == run.runID
                    else { break }
                    self.liveMeasurement = await captureOutput.currentMeasurement()
                }
            }
        } else if #available(macOS 15.0, *),
                  let monitor = nativeFrameMonitor as? NativeScreenFrameMonitor {
            measurementTask = Task { [weak self, weak monitor] in
                while !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: 1_000_000_000)
                    guard !Task.isCancelled, let self, let monitor,
                          self.isCapturing,
                          self.runSafety.activeRunID == run.runID
                    else { break }
                    self.liveMeasurement = monitor.measurement()
                }
            }
        }
    }

    private func rollbackFailedStart(run: ScreenRecorderRunToken) async {
        endPerformanceActivity()
        if #available(macOS 14.2, *),
           let tap = coreAudioSystemAudioTap as? CoreAudioSystemAudioTap {
            try? tap.stop()
        }
        try? await audioStream?.stopCapture()
        try? await stream?.stopCapture()
        _ = try? await captureOutput?.finish()
        let nativeAudioURL = nativeSystemAudioOutput?.outputURL
        _ = try? await nativeSystemAudioOutput?.finish()
        if let nativeAudioURL {
            try? FileManager.default.removeItem(at: nativeAudioURL)
        }
        if #available(macOS 15.0, *) {
            try? await nativeRecordingSegment?.waitForFinish(timeout: 2)
            nativeRecordingSegment = nil
        }
        measurementTask?.cancel()
        measurementTask = nil
        stream = nil
        captureOutput = nil
        nativeFrameMonitor = nil
        audioStream = nil
        nativeSystemAudioOutput = nil
        coreAudioSystemAudioTap = nil
        nativeFirstFrameHostTime = nil
        nativeCompletedSegmentURLs = []
        nativeFinalOutputURL = nil
        nativeRunToken = nil
        nativeCaptureCodec = nil
        usesNativeRecordingOutput = false
        isCapturing = false
        isPaused = false
        firstFrameStartedAt = nil
        _ = runSafety.end(run)
    }

    func updateSurfaceVisibility(
        runID: RecordingRunID,
        configuration: CaptureConfiguration
    ) async throws {
        guard let update = runSafety.makeSurfaceUpdate(for: runID) else {
            throw ScreenRecorderError.runNotActive(runID)
        }
        try Task.checkCancellation()
        await surfaceVisibilityGate.acquire()
        do {
            try ensureSurfaceUpdateMayApply(update)
            try await performSurfaceVisibilityUpdate(
                update: update,
                configuration: configuration
            )
            await surfaceVisibilityGate.release()
        } catch {
            await surfaceVisibilityGate.release()
            throw error
        }
    }

    private func performSurfaceVisibilityUpdate(
        update: ScreenRecorderSurfaceUpdateToken,
        configuration: CaptureConfiguration
    ) async throws {
        guard isCapturing,
              let stream,
              ObjectIdentifier(stream) == update.streamIdentity,
              configuration.source != .window,
              configuration.source != .device else {
            throw ScreenRecorderError.runNotActive(update.run.runID)
        }
        let content = try await SCShareableContent.excludingDesktopWindows(
            false,
            onScreenWindowsOnly: true
        )
        try ensureSurfaceUpdateMayApply(update)
        let display = try preferredDisplay(
            from: content.displays,
            requestedDisplayID: configuration.displayID
        )
        let filter = displayContentFilter(
            content: content,
            display: display,
            configuration: configuration
        )
        try ensureSurfaceUpdateMayApply(update)
        if usesNativeRecordingOutput {
            guard #available(macOS 15.0, *),
                  let token = nativeRunToken,
                  let finalURL = nativeFinalOutputURL else {
                throw ScreenRecorderError.recordingFailed("苹果原生录制状态无效")
            }
            // SCRecordingOutput does not promise continuity across a filter
            // update. Close the current file cleanly, update SCK, then start a
            // new native segment. Finalization concatenates the segments with
            // AVAssetExportPresetPassthrough, so no frame is re-encoded.
            let activeSegment = nativeRecordingSegment as? NativeScreenRecordingSegment
            if activeSegment != nil {
                (nativeFrameMonitor as? NativeScreenFrameMonitor)?.setPaused(true)
                await nativeSystemAudioOutput?.setPaused(true)
            }
            do {
                if let activeSegment {
                    try stream.removeRecordingOutput(activeSegment.recordingOutput)
                    try await activeSegment.waitForFinish(timeout: 15)
                    nativeCompletedSegmentURLs.append(activeSegment.outputURL)
                    nativeRecordingSegment = nil
                }
                try await stream.updateContentFilter(filter)
                if activeSegment != nil {
                    try await startNativeContinuationSegment(
                        on: stream,
                        token: token,
                        finalURL: finalURL
                    )
                }
                if activeSegment != nil {
                    await nativeSystemAudioOutput?.setPaused(false)
                    (nativeFrameMonitor as? NativeScreenFrameMonitor)?.setPaused(false)
                }
            } catch {
                if activeSegment != nil, nativeRecordingSegment == nil {
                    try? await startNativeContinuationSegment(
                        on: stream,
                        token: token,
                        finalURL: finalURL
                    )
                }
                if activeSegment != nil {
                    await nativeSystemAudioOutput?.setPaused(false)
                    (nativeFrameMonitor as? NativeScreenFrameMonitor)?.setPaused(false)
                }
                throw error
            }
            return
        }
        try await stream.updateContentFilter(filter)
    }

    private func ensureSurfaceUpdateMayApply(
        _ update: ScreenRecorderSurfaceUpdateToken
    ) throws {
        switch runSafety.surfaceUpdateDecision(
            for: update,
            isCancelled: Task.isCancelled
        ) {
        case .apply:
            return
        case .cancelled, .stale:
            throw CancellationError()
        }
    }

    func pause(runID: RecordingRunID) async {
        guard runSafety.activeRunID == runID, isCapturing, !isPaused else { return }
        if usesNativeRecordingOutput {
            guard #available(macOS 15.0, *),
                  let stream,
                  let segment = nativeRecordingSegment
                    as? NativeScreenRecordingSegment else { return }
            do {
                (nativeFrameMonitor as? NativeScreenFrameMonitor)?.setPaused(true)
                await nativeSystemAudioOutput?.setPaused(true)
                try stream.removeRecordingOutput(segment.recordingOutput)
                try await segment.waitForFinish(timeout: 15)
                nativeCompletedSegmentURLs.append(segment.outputURL)
                nativeRecordingSegment = nil
                guard runSafety.activeRunID == runID else { return }
                isPaused = true
            } catch {
                (nativeFrameMonitor as? NativeScreenFrameMonitor)?.setPaused(false)
                await nativeSystemAudioOutput?.setPaused(false)
                lastStopWarning = "暂停原生录制失败：\(error.localizedDescription)"
                failNativeRecording(error)
            }
            return
        }
        guard let captureOutput else { return }
        await nativeSystemAudioOutput?.setPaused(true)
        await captureOutput.setPaused(true)
        guard runSafety.activeRunID == runID else { return }
        isPaused = true
    }

    func resume(runID: RecordingRunID) async {
        guard runSafety.activeRunID == runID, isCapturing, isPaused else { return }
        if usesNativeRecordingOutput {
            guard #available(macOS 15.0, *),
                  let stream,
                  let token = nativeRunToken,
                  let finalURL = nativeFinalOutputURL else { return }
            do {
                try await startNativeContinuationSegment(
                    on: stream,
                    token: token,
                    finalURL: finalURL
                )
                await nativeSystemAudioOutput?.setPaused(false)
                (nativeFrameMonitor as? NativeScreenFrameMonitor)?.setPaused(false)
                guard runSafety.activeRunID == runID else { return }
                isPaused = false
            } catch {
                lastStopWarning = "继续原生录制失败：\(error.localizedDescription)"
                failNativeRecording(error)
            }
            return
        }
        guard let captureOutput else { return }
        await captureOutput.setPaused(false)
        await nativeSystemAudioOutput?.setPaused(false)
        guard runSafety.activeRunID == runID else { return }
        isPaused = false
    }

    private func failNativeRecording(_ error: any Error) {
        guard let token = nativeRunToken else { return }
        if runSafety.claimTerminal(error, for: token) {
            enterTerminalState(runID: token.runID, error: error)
        }
    }

    @available(macOS 15.0, *)
    private func startNativeContinuationSegment(
        on stream: SCStream,
        token: ScreenRecorderRunToken,
        finalURL: URL
    ) async throws {
        let segmentURL = finalURL.deletingLastPathComponent().appendingPathComponent(
            ".native-segment-\(UUID().uuidString).mp4"
        )
        let segment = NativeScreenRecordingSegment(
            outputURL: segmentURL,
            codec: nativeCaptureCodec ?? .h264,
            onFailure: { [weak self] error in
                let event = CaptureOutputTerminalEvent(
                    run: token,
                    stage: .videoAppend,
                    error: error
                )
                Task { @MainActor [weak self] in
                    self?.handleCaptureOutputTerminal(event)
                }
            }
        )
        do {
            try stream.addRecordingOutput(segment.recordingOutput)
            nativeRecordingSegment = segment
            _ = try await segment.waitForStart(timeout: 5)
        } catch {
            try? stream.removeRecordingOutput(segment.recordingOutput)
            nativeRecordingSegment = nil
            try? FileManager.default.removeItem(at: segmentURL)
            throw error
        }
    }

    func stop(runID: RecordingRunID) async throws -> URL? {
        guard let stream, let run = runSafety.beginStopping(runID) else {
            throw ScreenRecorderError.runNotActive(runID)
        }
        isCapturing = false
        isPaused = false
        let nativeAudioTemporaryURL = nativeSystemAudioOutput?.outputURL
        let expectedNativeSystemAudio = nativeSystemAudioOutput != nil
        let nativeAudioDiagnosticsBeforeStop = await nativeSystemAudioOutput?
            .currentDiagnostics()
        if nativeSystemAudioOutput != nil {
            // Freeze audio at the same logical stop boundary as video. Samples
            // arriving while either writer drains must not extend the AAC track.
            await nativeSystemAudioOutput?.setPaused(true)
        }
        if #available(macOS 15.0, *) {
            (nativeFrameMonitor as? NativeScreenFrameMonitor)?.setPaused(true)
        }
        // REC-001/REC-004: SCRecordingOutput owns the native MP4 finalization.
        // Detach it while SCStream is still running, matching the already
        // reliable pause path. Stopping the stream first can leave an
        // audio-enabled recording output waiting forever while its file keeps
        // growing, which also prevents the rest of the recorder from cleaning
        // up its capture load.
        var nativeDetachedFinalizationError: (any Error)?
        if usesNativeRecordingOutput,
           #available(macOS 15.0, *),
           let segment = nativeRecordingSegment as? NativeScreenRecordingSegment {
            do {
                try stream.removeRecordingOutput(segment.recordingOutput)
                do {
                    try await segment.waitForFinish(timeout: 15)
                    nativeCompletedSegmentURLs.append(segment.outputURL)
                } catch {
                    nativeDetachedFinalizationError = error
                }
                // The output is no longer attached even if its delegate timed
                // out, so never wait on the same segment again after stream stop.
                nativeRecordingSegment = nil
            } catch {
                // If detach itself fails, leave the segment attached. The
                // stream stop below is still required for cleanup and the
                // existing post-stop fallback can observe its delegate result.
                nativeDetachedFinalizationError = nil
            }
        }
        var streamStopError: (any Error)?
        var nativeAudioResult: NativeSystemAudioCaptureResult?
        var nativeAudioFinishError: (any Error)?
        if let audioStream {
            do {
                try await audioStream.stopCapture()
            } catch {
                streamStopError = error
            }
        }
        if #available(macOS 14.2, *),
           let tap = coreAudioSystemAudioTap as? CoreAudioSystemAudioTap {
            do {
                try tap.stop()
            } catch {
                streamStopError = error
            }
        }
        if let nativeSystemAudioOutput {
            do {
                nativeAudioResult = try await nativeSystemAudioOutput.finish()
            } catch {
                nativeAudioFinishError = error
            }
        }
        lastSystemAudioDiagnostics = nativeAudioResult?.diagnostics
            ?? nativeAudioDiagnosticsBeforeStop
        do {
            try await stream.stopCapture()
        } catch {
            streamStopError = error
        }
        measurementTask?.cancel()
        measurementTask = nil
        defer {
            self.endPerformanceActivity()
            self.stream = nil
            self.audioStream = nil
            self.captureOutput = nil
            self.nativeFrameMonitor = nil
            self.nativeSystemAudioOutput = nil
            self.coreAudioSystemAudioTap = nil
            self.nativeFirstFrameHostTime = nil
            if #available(macOS 15.0, *) {
                self.nativeRecordingSegment = nil
            }
            self.nativeCompletedSegmentURLs = []
            self.nativeFinalOutputURL = nil
            self.nativeRunToken = nil
            self.nativeCaptureCodec = nil
            self.usesNativeRecordingOutput = false
            isCapturing = false
            isPaused = false
            firstFrameStartedAt = nil
            if let nativeAudioTemporaryURL {
                try? FileManager.default.removeItem(at: nativeAudioTemporaryURL)
            }
            _ = runSafety.end(run)
        }
        var warnings: [String] = []
        if let streamStopError {
            warnings.append(streamStopError.localizedDescription)
        }
        if let nativeAudioFinishError {
            warnings.append("系统声音文件写入失败，视频已保留："
                + nativeAudioFinishError.localizedDescription)
        } else if expectedNativeSystemAudio, nativeAudioResult == nil {
            warnings.append("未收到可写入的系统声音样本，视频已保留")
        }

        if usesNativeRecordingOutput {
            guard #available(macOS 15.0, *), let finalURL = nativeFinalOutputURL else {
                throw ScreenRecorderError.recordingFailed("苹果原生录制结果丢失")
            }
            if let nativeDetachedFinalizationError {
                throw nativeDetachedFinalizationError
            }
            if let segment = nativeRecordingSegment {
                try await segment.waitForFinish(timeout: 15)
                nativeCompletedSegmentURLs.append(segment.outputURL)
                nativeRecordingSegment = nil
            }
            try await NativeScreenRecordingFinalizer.concatenate(
                nativeCompletedSegmentURLs,
                to: finalURL
            )
            if let nativeAudioResult {
                if let nativeFirstFrameHostTime {
                    do {
                        try await NativeScreenRecordingFinalizer.muxSystemAudio(
                            nativeAudioResult,
                            videoStartedAtHostTime: nativeFirstFrameHostTime,
                            into: finalURL
                        )
                    } catch {
                        warnings.append("系统声音无损封装失败，视频已保留："
                            + error.localizedDescription)
                    }
                } else {
                    warnings.append("系统声音缺少原生视频主时钟，视频已保留")
                }
                if nativeAudioResult.droppedSampleCount > 0 {
                    warnings.append("系统声音写入拥塞，丢弃了 "
                        + "\(nativeAudioResult.droppedSampleCount) 个音频样本块")
                }
            }
            lastMeasurement = try await NativeScreenRecordingFinalizer.measurement(
                at: finalURL,
                target: requestedFrameRate
            )
            liveMeasurement = lastMeasurement
            lastStopWarning = warnings.isEmpty ? nil : warnings.joined(separator: "；")
            return finalURL
        }

        guard let captureOutput else { throw ScreenRecorderError.cannotCreateWriter }
        lastMeasurement = try await captureOutput.finish()
        lastSystemAudioDiagnostics = await captureOutput.currentAudioDiagnostics()
        liveMeasurement = lastMeasurement
        if let nativeAudioResult {
            if #available(macOS 15.0, *), let nativeFirstFrameHostTime {
                do {
                    try await NativeScreenRecordingFinalizer.muxSystemAudio(
                        nativeAudioResult,
                        videoStartedAtHostTime: nativeFirstFrameHostTime,
                        into: captureOutput.outputURL
                    )
                } catch {
                    warnings.append("系统声音无损封装失败，视频已保留："
                        + error.localizedDescription)
                }
            } else {
                warnings.append("系统声音缺少视频主时钟，视频已保留")
            }
            if nativeAudioResult.droppedSampleCount > 0 {
                warnings.append("系统声音写入拥塞，丢弃了 "
                    + "\(nativeAudioResult.droppedSampleCount) 个音频样本块")
            }
        }
        let droppedAudioSamples = await captureOutput.droppedAudioSamples()
        if let secondaryStreamTerminalError {
            warnings.append("所选 App 音频流意外停止，该音轨可能不完整："
                + secondaryStreamTerminalError.localizedDescription)
        }
        if droppedAudioSamples > 0 {
            warnings.append("系统声音写入拥塞，丢弃了 \(droppedAudioSamples) 个音频样本块")
        }
        lastStopWarning = warnings.isEmpty ? nil : warnings.joined(separator: "；")
        return captureOutput.outputURL
    }

    func systemAudioDiagnostics() async -> AudioCaptureDiagnostics? {
        if let nativeSystemAudioOutput,
           let diagnostics = await nativeSystemAudioOutput.currentDiagnostics() {
            return diagnostics
        }
        if let captureOutput,
           let diagnostics = await captureOutput.currentAudioDiagnostics() {
            return diagnostics
        }
        return lastSystemAudioDiagnostics
    }

    nonisolated func stream(_ stream: SCStream, didStopWithError error: any Error) {
        let streamIdentity = ObjectIdentifier(stream)
        Task { @MainActor [weak self] in
            guard let self,
                  let run = self.runSafety.tokenForDelegate(
                    streamIdentity: streamIdentity
                  ),
                  let role = self.runSafety.role(
                    for: streamIdentity,
                    in: run
                  ) else { return }
            if role == .secondary {
                // 所选 App 音频流意外停止：屏幕画面完好，只记录告警，
                // 不得因此终止整段录制。
                self.secondaryStreamTerminalError = error
                return
            }
            if self.runSafety.lifecycle(for: run) == .starting {
                _ = self.runSafety.deferTerminalDuringStart(error, for: run)
                self.captureOutput?.failStartup(with: error)
            } else if self.runSafety.claimTerminal(error, for: run) {
                self.enterTerminalState(runID: run.runID, error: error)
            }
        }
    }

    func terminalError(for runID: RecordingRunID) -> (any Error)? {
        runSafety.terminalError(for: runID)
    }

    private func handleCaptureOutputTerminal(_ event: CaptureOutputTerminalEvent) {
        if runSafety.lifecycle(for: event.run) == .starting {
            _ = runSafety.deferTerminalDuringStart(event.error, for: event.run)
            return
        }
        guard runSafety.claimTerminal(event.error, for: event.run) else { return }
        enterTerminalState(runID: event.run.runID, error: event.error)
    }

    private func enterTerminalState(runID: RecordingRunID, error: any Error) {
        isCapturing = false
        isPaused = false
        measurementTask?.cancel()
        measurementTask = nil
        onUnexpectedStop?(runID, error)
    }

    private func beginPerformanceActivity() {
        guard performanceActivity == nil else { return }
        performanceActivity = ProcessInfo.processInfo.beginActivity(
            options: RecordingPerformanceActivityPolicy.options,
            reason: "正在录制屏幕，需要稳定的帧交付"
        )
    }

    private func endPerformanceActivity() {
        guard let performanceActivity else { return }
        ProcessInfo.processInfo.endActivity(performanceActivity)
        self.performanceActivity = nil
    }

    private func preferredDisplay(
        from displays: [SCDisplay],
        requestedDisplayID: UInt32?
    ) throws -> SCDisplay {
        let resolved = CaptureDisplayResolver.resolve(
            requestedID: requestedDisplayID,
            candidates: displays,
            candidateID: { $0.displayID },
            preferredDefaultID: NSScreen.main.flatMap(
                AppKitCaptureDisplayResolver.displayID(for:)
            )
        )
        guard let resolved else {
            if let requestedDisplayID {
                throw ScreenRecorderError.displayUnavailable(requestedDisplayID)
            }
            throw ScreenRecorderError.noDisplay
        }
        return resolved
    }

    private func displayContentFilter(
        content: SCShareableContent,
        display: SCDisplay,
        configuration: CaptureConfiguration
    ) -> SCContentFilter {
        var excludedApplications = content.applications.filter { $0.processID == getpid() }
        if configuration.hidesDock {
            excludedApplications.append(contentsOf: content.applications.filter {
                $0.bundleIdentifier == "com.apple.dock"
            })
        }

        var exceptingWindows: [SCWindow] = []
        if configuration.hidesDesktopFiles {
            let desktopIDs = finderDesktopWindowIDs()
            exceptingWindows = content.windows.filter {
                desktopIDs.contains(CGWindowID($0.windowID))
            }
        }

        return SCContentFilter(
            display: display,
            excludingApplications: excludedApplications,
            exceptingWindows: exceptingWindows
        )
    }

    private func finderDesktopWindowIDs() -> Set<CGWindowID> {
        guard let descriptions = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly],
            kCGNullWindowID
        ) as? [[String: Any]] else {
            return []
        }

        return Set(descriptions.compactMap { description in
            let ownerPID = (description[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value ?? 0
            let bundleIdentifier = NSRunningApplication(
                processIdentifier: ownerPID
            )?.bundleIdentifier
            let layer = (description[kCGWindowLayer as String] as? NSNumber)?.intValue ?? 0
            guard bundleIdentifier == "com.apple.finder",
                  layer < 0,
                  let number = description[kCGWindowNumber as String] as? NSNumber
            else {
                return nil
            }
            return CGWindowID(number.uint32Value)
        })
    }

}

/// One-shot resumption of the `finish()` continuation, safe to call from the
/// concurrent `finishWriting` completion and the timeout path. The first call
/// wins; later calls (including the 15-second timeout after a normal finish)
/// are ignored, so a wedged encoder can never double-resume the continuation.
final class FinishResumeOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var didResume = false
    private let continuation: CheckedContinuation<FrameRateMeasurement?, any Error>

    init(_ continuation: CheckedContinuation<FrameRateMeasurement?, any Error>) {
        self.continuation = continuation
    }

    func resume(_ result: Result<FrameRateMeasurement?, any Error>) {
        lock.lock()
        guard !didResume else {
            lock.unlock()
            return
        }
        didResume = true
        lock.unlock()
        switch result {
        case let .success(measurement):
            continuation.resume(returning: measurement)
        case let .failure(error):
            continuation.resume(throwing: error)
        }
    }
}
