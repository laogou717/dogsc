import Foundation

public enum OutputFrameRate: Int, CaseIterable, Codable, Identifiable, Sendable {
    case fps30 = 30
    case fps60 = 60
    // Decode-only compatibility for projects created before the product was
    // narrowed back to a stable 60 FPS recording/export contract.
    case fps90 = 90
    case fps120 = 120

    public var id: Int { rawValue }
    public var label: String { "\(rawValue) FPS" }
    public var frameDuration: TimeInterval { 1.0 / Double(rawValue) }
    /// REC-002/EXP-002: capture preserves the timestamps of every frame that
    /// ScreenCaptureKit actually delivers. These are CFR output choices only;
    /// they must never be reused as a callback-side capture limiter.
    public static let exportProductChoices: [OutputFrameRate] = [.fps30, .fps60]
    public static let captureEncodingQualityTarget: OutputFrameRate = .fps60
}

/// A concrete camera resolution advertised by an AVCaptureDevice format. Frame
/// rate intentionally isn't a user setting: AVFoundation negotiates the live
/// device cadence and the recorder preserves every sample's real PTS.
public struct CameraCaptureResolution: Codable, Equatable, Hashable, Identifiable, Sendable {
    public let width: Int
    public let height: Int

    public init(width: Int, height: Int) {
        self.width = width
        self.height = height
    }

    public var id: String { "\(width)x\(height)" }

    public var resolutionLabel: String {
        switch (width, height) {
        case (3840, 2160), (4096, 2160): "4K"
        case (2560, 1440): "1440p"
        case (1920, 1080): "1080p"
        case (1280, 720): "720p"
        default: "\(width)×\(height)"
        }
    }

    public var aspectRatioLabel: String {
        let divisor = Self.greatestCommonDivisor(width, height)
        return "\(width / divisor):\(height / divisor)"
    }

    public var label: String {
        "\(resolutionLabel) · \(aspectRatioLabel) · \(width)×\(height)"
    }

    private static func greatestCommonDivisor(_ lhs: Int, _ rhs: Int) -> Int {
        var a = max(abs(lhs), 1)
        var b = max(abs(rhs), 1)
        while b != 0 {
            (a, b) = (b, a % b)
        }
        return max(a, 1)
    }
}

public enum CaptureSource: String, CaseIterable, Codable, Identifiable, Sendable {
    case display = "整块屏幕"
    case window = "单个窗口"
    case area = "自选区域"
    case device = "iOS 设备"

    public var id: String { rawValue }
}

public enum SystemAudioScope: String, CaseIterable, Codable, Identifiable, Sendable {
    case all = "全部系统声音"
    case selectedApplication = "所选窗口 App"

    public var id: String { rawValue }
}

public struct NormalizedRect: Codable, Equatable, Sendable {
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    public func constrained() -> NormalizedRect {
        let safeX = min(max(x, 0), 1)
        let safeY = min(max(y, 0), 1)
        return NormalizedRect(
            x: safeX,
            y: safeY,
            width: min(max(width, 0.02), 1 - safeX),
            height: min(max(height, 0.02), 1 - safeY)
        )
    }
}

public struct CaptureDimensions: Equatable, Sendable {
    public let width: Int
    public let height: Int

    public init(width: Int, height: Int) {
        self.width = width
        self.height = height
    }

    public static func h264Compatible(
        sourceWidth: Int,
        sourceHeight: Int,
        maximumWidth: Int = 4096,
        maximumHeight: Int = 2304
    ) -> CaptureDimensions {
        let safeWidth = max(sourceWidth, 2)
        let safeHeight = max(sourceHeight, 2)
        let scale = min(
            1,
            Double(maximumWidth) / Double(safeWidth),
            Double(maximumHeight) / Double(safeHeight)
        )
        let width = max(Int((Double(safeWidth) * scale).rounded(.down)) / 2 * 2, 2)
        let height = max(Int((Double(safeHeight) * scale).rounded(.down)) / 2 * 2, 2)
        return CaptureDimensions(width: width, height: height)
    }
}

public enum CaptureCodec: String, Codable, CaseIterable, Identifiable, Sendable {
    case hevc = "HEVC"
    case h264 = "H.264"
    case proRes422 = "ProRes 422"

    public var id: String { rawValue }

    public var usesMOVContainer: Bool {
        self == .proRes422
    }

    public var recordingLabel: String {
        switch self {
        case .hevc: "HEVC（H.265，原生分辨率）"
        case .h264: "H.264（兼容模式，最高 4K）"
        case .proRes422: "ProRes 422（原生分辨率）"
        }
    }
}

public enum CaptureResolutionLimit: String, CaseIterable, Codable, Identifiable, Sendable {
    case native = "原始分辨率"
    case uhd = "最高 4K"
    case fullHD = "最高 1080p"
    public var id: String { rawValue }

    /// Downscale within a landscape or portrait envelope; never enlarge a source.
    public func applying(to size: CaptureDimensions) -> CaptureDimensions {
        guard self != .native else { return size }
        let longEdge = self == .uhd ? 3840 : 1920
        let shortEdge = self == .uhd ? 2160 : 1080
        return .h264Compatible(sourceWidth: size.width, sourceHeight: size.height,
            maximumWidth: size.width >= size.height ? longEdge : shortEdge,
            maximumHeight: size.width >= size.height ? shortEdge : longEdge)
    }
}

public struct CaptureConfiguration: Codable, Equatable, Sendable {
    public var source: CaptureSource
    public var displayID: UInt32?
    public var displayName: String?
    public var windowID: UInt32?
    public var windowName: String?
    public var selectedApplicationBundleIdentifier: String?
    public var selectedApplicationName: String?
    public var area: NormalizedRect?
    public var deviceID: String?
    public var deviceName: String?
    public var captureFrameRate: OutputFrameRate
    /// Recording-time master codec. HEVC is the native-resolution Apple
    /// hardware default, H.264 is the <=4K compatibility path, and ProRes 422
    /// is the large near-lossless option. Export remains an independent choice.
    public var captureResolutionLimit: CaptureResolutionLimit
    public var captureCodec: CaptureCodec
    public var hidesDesktopFiles: Bool
    public var hidesDock: Bool
    public var recordsSystemAudio: Bool
    public var systemAudioScope: SystemAudioScope
    public var recordsMicrophone: Bool
    public var microphoneDeviceID: String?
    public var microphoneDeviceName: String?
    public var recordsCamera: Bool
    public var cameraDeviceID: String?
    public var cameraDeviceName: String?
    /// nil lets AVFoundation negotiate both format and native cadence.
    public var cameraCaptureResolution: CameraCaptureResolution?

    public init(
        source: CaptureSource = .display,
        displayID: UInt32? = nil,
        displayName: String? = nil,
        windowID: UInt32? = nil,
        windowName: String? = nil,
        selectedApplicationBundleIdentifier: String? = nil,
        selectedApplicationName: String? = nil,
        area: NormalizedRect? = nil,
        deviceID: String? = nil,
        deviceName: String? = nil,
        captureFrameRate: OutputFrameRate = .fps60,
        captureCodec: CaptureCodec = .hevc,
        captureResolutionLimit: CaptureResolutionLimit = .native,
        hidesDesktopFiles: Bool = false,
        hidesDock: Bool = false,
        recordsSystemAudio: Bool = true,
        systemAudioScope: SystemAudioScope = .all,
        recordsMicrophone: Bool = false,
        microphoneDeviceID: String? = nil,
        microphoneDeviceName: String? = nil,
        recordsCamera: Bool = false,
        cameraDeviceID: String? = nil,
        cameraDeviceName: String? = nil,
        cameraCaptureResolution: CameraCaptureResolution? = nil
    ) {
        self.source = source
        self.displayID = displayID
        self.displayName = displayName
        self.windowID = windowID
        self.windowName = windowName
        self.selectedApplicationBundleIdentifier = selectedApplicationBundleIdentifier
        self.selectedApplicationName = selectedApplicationName
        self.area = area
        self.deviceID = deviceID
        self.deviceName = deviceName
        self.captureFrameRate = captureFrameRate
        self.captureCodec = captureCodec
        self.captureResolutionLimit = captureResolutionLimit
        self.hidesDesktopFiles = hidesDesktopFiles
        self.hidesDock = hidesDock
        self.recordsSystemAudio = recordsSystemAudio
        self.systemAudioScope = systemAudioScope
        self.recordsMicrophone = recordsMicrophone
        self.microphoneDeviceID = microphoneDeviceID
        self.microphoneDeviceName = microphoneDeviceName
        self.recordsCamera = recordsCamera
        self.cameraDeviceID = cameraDeviceID
        self.cameraDeviceName = cameraDeviceName
        self.cameraCaptureResolution = cameraCaptureResolution
    }

    private enum CodingKeys: String, CodingKey {
        case source
        case displayID
        case displayName
        case windowID
        case windowName
        case selectedApplicationBundleIdentifier
        case selectedApplicationName
        case area
        case deviceID
        case deviceName
        case captureFrameRate
        case hidesDesktopFiles
        case hidesDock
        case recordsSystemAudio
        case systemAudioScope
        case recordsMicrophone
        case microphoneDeviceID
        case microphoneDeviceName
        case recordsCamera
        case cameraDeviceID
        case cameraDeviceName
        case cameraCaptureResolution
        case captureCodec
        case captureResolutionLimit
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        source = try container.decodeIfPresent(CaptureSource.self, forKey: .source) ?? .display
        displayID = try container.decodeIfPresent(UInt32.self, forKey: .displayID)
        displayName = try container.decodeIfPresent(String.self, forKey: .displayName)
        windowID = try container.decodeIfPresent(UInt32.self, forKey: .windowID)
        windowName = try container.decodeIfPresent(String.self, forKey: .windowName)
        selectedApplicationBundleIdentifier = try container.decodeIfPresent(
            String.self,
            forKey: .selectedApplicationBundleIdentifier
        )
        selectedApplicationName = try container.decodeIfPresent(
            String.self,
            forKey: .selectedApplicationName
        )
        area = try container.decodeIfPresent(NormalizedRect.self, forKey: .area)
        deviceID = try container.decodeIfPresent(String.self, forKey: .deviceID)
        deviceName = try container.decodeIfPresent(String.self, forKey: .deviceName)
        captureFrameRate = try container.decodeIfPresent(OutputFrameRate.self, forKey: .captureFrameRate) ?? .fps60
        captureCodec = try container.decodeIfPresent(CaptureCodec.self, forKey: .captureCodec) ?? .h264
        captureResolutionLimit = try container.decodeIfPresent(CaptureResolutionLimit.self, forKey: .captureResolutionLimit) ?? .native
        hidesDesktopFiles = try container.decodeIfPresent(Bool.self, forKey: .hidesDesktopFiles) ?? false
        hidesDock = try container.decodeIfPresent(Bool.self, forKey: .hidesDock) ?? false
        recordsSystemAudio = try container.decodeIfPresent(Bool.self, forKey: .recordsSystemAudio) ?? true
        systemAudioScope = try container.decodeIfPresent(
            SystemAudioScope.self,
            forKey: .systemAudioScope
        ) ?? .all
        recordsMicrophone = try container.decodeIfPresent(Bool.self, forKey: .recordsMicrophone) ?? false
        microphoneDeviceID = try container.decodeIfPresent(String.self, forKey: .microphoneDeviceID)
        microphoneDeviceName = try container.decodeIfPresent(String.self, forKey: .microphoneDeviceName)
        recordsCamera = try container.decodeIfPresent(Bool.self, forKey: .recordsCamera) ?? false
        cameraDeviceID = try container.decodeIfPresent(String.self, forKey: .cameraDeviceID)
        cameraDeviceName = try container.decodeIfPresent(String.self, forKey: .cameraDeviceName)
        cameraCaptureResolution = try container.decodeIfPresent(
            CameraCaptureResolution.self,
            forKey: .cameraCaptureResolution
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(source, forKey: .source)
        try container.encodeIfPresent(displayID, forKey: .displayID)
        try container.encodeIfPresent(displayName, forKey: .displayName)
        try container.encodeIfPresent(windowID, forKey: .windowID)
        try container.encodeIfPresent(windowName, forKey: .windowName)
        try container.encodeIfPresent(
            selectedApplicationBundleIdentifier,
            forKey: .selectedApplicationBundleIdentifier
        )
        try container.encodeIfPresent(selectedApplicationName, forKey: .selectedApplicationName)
        try container.encodeIfPresent(area, forKey: .area)
        try container.encodeIfPresent(deviceID, forKey: .deviceID)
        try container.encodeIfPresent(deviceName, forKey: .deviceName)
        try container.encode(captureFrameRate, forKey: .captureFrameRate)
        try container.encode(captureCodec, forKey: .captureCodec)
        try container.encode(captureResolutionLimit, forKey: .captureResolutionLimit)
        try container.encode(hidesDesktopFiles, forKey: .hidesDesktopFiles)
        try container.encode(hidesDock, forKey: .hidesDock)
        try container.encode(recordsSystemAudio, forKey: .recordsSystemAudio)
        try container.encode(systemAudioScope, forKey: .systemAudioScope)
        try container.encode(recordsMicrophone, forKey: .recordsMicrophone)
        try container.encodeIfPresent(microphoneDeviceID, forKey: .microphoneDeviceID)
        try container.encodeIfPresent(microphoneDeviceName, forKey: .microphoneDeviceName)
        try container.encode(recordsCamera, forKey: .recordsCamera)
        try container.encodeIfPresent(cameraDeviceID, forKey: .cameraDeviceID)
        try container.encodeIfPresent(cameraDeviceName, forKey: .cameraDeviceName)
        try container.encodeIfPresent(cameraCaptureResolution, forKey: .cameraCaptureResolution)
    }
}

/// Ordered frame-gap evidence for diagnosing visible capture stutter. Average
/// FPS hides isolated and repeated long gaps, so recordings keep percentiles,
/// threshold counts and the longest consecutive run as separate facts.
public struct FrameIntervalDiagnostics: Codable, Equatable, Sendable {
    public let sampleCount: Int
    public let p50: TimeInterval
    public let p90: TimeInterval
    public let p95: TimeInterval
    public let p99: TimeInterval
    public let maximum: TimeInterval
    public let over25Milliseconds: Int
    public let over33Milliseconds: Int
    public let over50Milliseconds: Int
    public let maximumConsecutiveOver33Milliseconds: Int

    public static let empty = FrameIntervalDiagnostics(intervals: [])

    public init(intervals: [TimeInterval]) {
        var mutableIntervals = intervals
        self.init(consuming: &mutableIntervals)
    }

    /// Consumes and sorts the caller's storage in place. Recording finalizers
    /// no longer need the chronological interval array after diagnostics are
    /// produced, so this avoids creating both a filtered and a sorted copy at
    /// the memory-sensitive end of a long capture.
    public init(consuming intervals: inout [TimeInterval]) {
        intervals.removeAll { !$0.isFinite || $0 <= 0 }
        sampleCount = intervals.count
        over25Milliseconds = intervals.count { $0 > 0.025 }
        over33Milliseconds = intervals.count { $0 > (1.0 / 30.0) }
        over50Milliseconds = intervals.count { $0 > 0.050 }

        var currentRun = 0
        var longestRun = 0
        for interval in intervals {
            if interval > (1.0 / 30.0) {
                currentRun += 1
                longestRun = max(longestRun, currentRun)
            } else {
                currentRun = 0
            }
        }
        maximumConsecutiveOver33Milliseconds = longestRun

        intervals.sort()
        p50 = Self.percentile(0.50, in: intervals)
        p90 = Self.percentile(0.90, in: intervals)
        p95 = Self.percentile(0.95, in: intervals)
        p99 = Self.percentile(0.99, in: intervals)
        maximum = intervals.last ?? 0
    }

    private static func percentile(
        _ percentile: Double,
        in sorted: [TimeInterval]
    ) -> TimeInterval {
        guard !sorted.isEmpty else { return 0 }
        let position = Double(sorted.count - 1) * min(max(percentile, 0), 1)
        let lower = Int(position.rounded(.down))
        let upper = Int(position.rounded(.up))
        guard lower != upper else { return sorted[lower] }
        let fraction = position - Double(lower)
        return sorted[lower] * (1 - fraction) + sorted[upper] * fraction
    }
}

public struct FrameRateMeasurement: Equatable, Sendable {
    public let target: OutputFrameRate
    public let receivedFrames: Int
    public let deliveredFrames: Int
    public let writerDroppedFrames: Int
    /// ScreenCaptureKit samples that carried no encodable image data (idle /
    /// transition frames). A high share means the captured content is
    /// stationary — the low delivered rate is expected, not a performance
    /// problem.
    public let idleFrames: Int
    public let elapsed: TimeInterval
    public let maxFrameInterval: TimeInterval
    public let intervalDiagnostics: FrameIntervalDiagnostics

    public init(
        target: OutputFrameRate,
        receivedFrames: Int? = nil,
        deliveredFrames: Int,
        writerDroppedFrames: Int = 0,
        idleFrames: Int = 0,
        elapsed: TimeInterval,
        maxFrameInterval: TimeInterval = 0,
        intervalDiagnostics: FrameIntervalDiagnostics = .empty
    ) {
        self.target = target
        self.receivedFrames = receivedFrames ?? deliveredFrames
        self.deliveredFrames = deliveredFrames
        self.writerDroppedFrames = writerDroppedFrames
        self.idleFrames = idleFrames
        self.elapsed = elapsed
        self.maxFrameInterval = max(maxFrameInterval, intervalDiagnostics.maximum)
        self.intervalDiagnostics = intervalDiagnostics
    }

    /// Frames per second actually delivered by ScreenCaptureKit, idle frames
    /// included. This is the pipeline's real ceiling — it cannot exceed the
    /// display refresh rate.
    public var sckDeliveryFramesPerSecond: Double {
        guard elapsed > 0, receivedFrames + idleFrames > 1 else { return 0 }
        return Double(receivedFrames + idleFrames) / elapsed
    }

    /// Whether the captured content is mostly stationary (idle frames
    /// dominate), in which case a low delivered rate is expected.
    public var isMostlyIdle: Bool {
        idleFrames > receivedFrames
    }

    public var actualFramesPerSecond: Double {
        guard elapsed > 0, deliveredFrames > 1 else { return 0 }
        return Double(deliveredFrames - 1) / elapsed
    }

    public var deliveryRatio: Double {
        guard target.rawValue > 0 else { return 0 }
        return actualFramesPerSecond / Double(target.rawValue)
    }

    public var averageFrameInterval: TimeInterval {
        guard receivedFrames > 1, elapsed > 0 else { return 0 }
        return elapsed / Double(receivedFrames - 1)
    }

    public var estimatedDroppedFrames: Int {
        let expected = Int((elapsed * Double(target.rawValue)).rounded()) + 1
        let timelineMissing = max(expected - deliveredFrames, 0)
        return max(timelineMissing, writerDroppedFrames)
    }

    public var droppedFrameRatio: Double {
        let expected = deliveredFrames + estimatedDroppedFrames
        guard expected > 0 else { return 0 }
        return Double(estimatedDroppedFrames) / Double(expected)
    }
}
