import AppKit
import AVFoundation
import CoreGraphics
import Foundation
import RecorderCore
import VideoToolbox

struct CaptureDisplay: Identifiable, Equatable, Sendable {
    let id: UInt32
    let name: String
    let width: Int
    let height: Int
    let refreshRate: Int

    func captureDimensions(for codec: CaptureCodec) -> CaptureDimensions {
        guard codec == .h264 else {
            return CaptureDimensions(width: width, height: height)
        }
        return CaptureDimensions.h264Compatible(sourceWidth: width, sourceHeight: height)
    }

    var pickerLabel: String {
        "\(name) · \(width)×\(height) · \(refreshRate) Hz"
    }

    @MainActor
    static func available() -> [CaptureDisplay] {
        NSScreen.screens.compactMap { screen in
            guard let screenNumber = screen.deviceDescription[
                NSDeviceDescriptionKey("NSScreenNumber")
            ] as? NSNumber else { return nil }
            let displayID = CGDirectDisplayID(screenNumber.uint32Value)
            let displayMode = CGDisplayCopyDisplayMode(displayID)
            let modeRefreshRate = displayMode?.refreshRate ?? 0
            let refreshRate = modeRefreshRate > 0
                ? Int(modeRefreshRate.rounded())
                : max(screen.maximumFramesPerSecond, 1)
            return CaptureDisplay(
                id: displayID,
                name: screen.localizedName,
                width: max(displayMode?.pixelWidth ?? CGDisplayPixelsWide(displayID), 1),
                height: max(displayMode?.pixelHeight ?? CGDisplayPixelsHigh(displayID), 1),
                refreshRate: refreshRate
            )
        }
    }
}

struct CaptureReadiness: Equatable, Sendable {
    let hasScreenRecordingPermission: Bool
    let availableDiskBytes: Int64?
    let estimatedThirtyMinuteBytes: Int64
    let displayRefreshRate: Int?
    let targetFrameRate: OutputFrameRate
    let captureCodec: CaptureCodec
    let hasHardwareVideoEncoder: Bool
    let selectedDisplayName: String?
    let cameraPermission: CapturePermissionState
    let microphonePermission: CapturePermissionState

    var hasSufficientDisk: Bool {
        guard let availableDiskBytes else { return true }
        let reserve = max(Int64(Double(estimatedThirtyMinuteBytes) * 1.2), 2_000_000_000)
        return availableDiskBytes >= reserve
    }

    var displayCanShowTargetRate: Bool {
        guard let displayRefreshRate else { return true }
        return displayRefreshRate >= targetFrameRate.rawValue
    }

    var permissionText: String {
        hasScreenRecordingPermission ? "已授权" : "待授权"
    }

    var displayText: String {
        guard let displayRefreshRate else { return "未知" }
        return "\(displayRefreshRate) Hz"
    }

    var diskText: String {
        guard let availableDiskBytes else { return "未知" }
        return ByteCountFormatter.string(fromByteCount: availableDiskBytes, countStyle: .file)
    }

    var encoderText: String {
        guard hasHardwareVideoEncoder else { return "\(captureCodec.rawValue) 硬件不可用" }
        return "\(captureCodec.rawValue) 硬件"
    }

    var frameRateWarningText: String? {
        guard let displayRefreshRate,
              displayRefreshRate < targetFrameRate.rawValue else { return nil }
        return "目标为 \(targetFrameRate.rawValue) FPS，但显示器当前仅报告 \(displayRefreshRate) Hz；录制会保留实际帧率，不会补帧冒充。"
    }

    @MainActor
    static func current(
        targetFrameRate: OutputFrameRate,
        captureCodec: CaptureCodec,
        displayID: UInt32? = nil
    ) -> CaptureReadiness {
        let display = CaptureDisplay.available().first {
            displayID == nil || $0.id == displayID
        } ?? CaptureDisplay(
            id: 0,
            name: "未知显示器",
            width: 1920,
            height: 1080,
            refreshRate: 60
        )
        let captureDimensions = display.captureDimensions(for: captureCodec)
        let estimatedBytes = estimatedRecordingBytes(
            width: captureDimensions.width,
            height: captureDimensions.height,
            frameRate: targetFrameRate,
            codec: captureCodec,
            duration: 30 * 60
        )
        return CaptureReadiness(
            hasScreenRecordingPermission: CGPreflightScreenCaptureAccess(),
            availableDiskBytes: availableDiskCapacity(),
            estimatedThirtyMinuteBytes: estimatedBytes,
            displayRefreshRate: display.refreshRate,
            targetFrameRate: targetFrameRate,
            captureCodec: captureCodec,
            hasHardwareVideoEncoder: hardwareVideoEncoderAvailable(
                width: captureDimensions.width,
                height: captureDimensions.height,
                codec: captureCodec
            ),
            selectedDisplayName: display.id == 0 ? nil : display.name,
            cameraPermission: CapturePermissionState(
                authorizationStatus: AVCaptureDevice.authorizationStatus(for: .video)
            ),
            microphonePermission: CapturePermissionState(
                authorizationStatus: AVCaptureDevice.authorizationStatus(for: .audio)
            )
        )
    }

    private static func estimatedRecordingBytes(
        width: Int,
        height: Int,
        frameRate: OutputFrameRate,
        codec: CaptureCodec,
        duration: TimeInterval
    ) -> Int64 {
        let videoBitsPerSecond: Int
        if codec == .proRes422 {
            // Conservative planning estimate; actual ProRes rate depends on
            // raster dimensions and cadence and intentionally remains large.
            videoBitsPerSecond = max(width * height * frameRate.rawValue * 2, 100_000_000)
        } else {
            videoBitsPerSecond = ExportEncodingPolicy.videoBitrate(
                width: width,
                height: height,
                frameRate: frameRate.rawValue
            )
        }
        let totalBitsPerSecond = videoBitsPerSecond + 192_000
        return Int64(Double(totalBitsPerSecond) * duration / 8)
    }

    private static func availableDiskCapacity() -> Int64? {
        let movies = FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let attributes = try? FileManager.default.attributesOfFileSystem(forPath: movies.path)
        return (attributes?[.systemFreeSize] as? NSNumber)?.int64Value
    }

    /// Creating a VideoToolbox compression session costs tens of milliseconds
    /// (encoder initialization). Readiness refreshes on every selection change,
    /// so cache the probe result per discrete (width, height) pair.
    private static func hardwareVideoEncoderAvailable(
        width: Int,
        height: Int,
        codec: CaptureCodec
    ) -> Bool {
        if let cached = encoderProbeCache.availability(
            width: width,
            height: height,
            codec: codec
        ) {
            return cached
        }
        let codecType: CMVideoCodecType
        switch codec {
        case .hevc: codecType = kCMVideoCodecType_HEVC
        case .h264: codecType = kCMVideoCodecType_H264
        case .proRes422: codecType = kCMVideoCodecType_AppleProRes422
        }
        let specification = [
            kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder as String: true,
        ] as CFDictionary
        var session: VTCompressionSession?
        let status = VTCompressionSessionCreate(
            allocator: kCFAllocatorDefault,
            width: Int32(width),
            height: Int32(height),
            codecType: codecType,
            encoderSpecification: specification,
            imageBufferAttributes: nil,
            compressedDataAllocator: nil,
            outputCallback: nil,
            refcon: nil,
            compressionSessionOut: &session
        )
        if let session {
            VTCompressionSessionInvalidate(session)
        }
        encoderProbeCache.store(
            width: width,
            height: height,
            codec: codec,
            available: status == noErr
        )
        return status == noErr
    }
}

enum CapturePermissionState: String, Equatable, Sendable {
    case notDetermined
    case restricted
    case denied
    case authorized

    init(authorizationStatus: AVAuthorizationStatus) {
        switch authorizationStatus {
        case .notDetermined: self = .notDetermined
        case .restricted: self = .restricted
        case .denied: self = .denied
        case .authorized: self = .authorized
        @unknown default: self = .restricted
        }
    }

    var label: String {
        switch self {
        case .notDetermined: return "首次使用时询问"
        case .restricted: return "系统限制"
        case .denied: return "未授权"
        case .authorized: return "已授权"
        }
    }
}

/// Lock-protected bounded LRU for hardware-encoder probes. `static let` keeps
/// the reference immutable; the lock guards both values and recency order.
final class EncoderProbeCacheStore: @unchecked Sendable {
    private let capacity: Int
    private let lock = NSLock()
    private var cache: [String: Bool] = [:]
    private var recency: [String] = []

    init(capacity: Int = 4) {
        self.capacity = max(capacity, 1)
    }

    func availability(width: Int, height: Int, codec: CaptureCodec) -> Bool? {
        let key = "\(codec.rawValue):\(width)x\(height)"
        lock.lock()
        defer { lock.unlock() }
        guard let value = cache[key] else { return nil }
        markRecentlyUsed(key)
        return value
    }

    func store(width: Int, height: Int, codec: CaptureCodec, available: Bool) {
        let key = "\(codec.rawValue):\(width)x\(height)"
        lock.lock()
        defer { lock.unlock() }
        cache[key] = available
        markRecentlyUsed(key)
        while recency.count > capacity {
            cache.removeValue(forKey: recency.removeFirst())
        }
    }

    private func markRecentlyUsed(_ key: String) {
        if let index = recency.firstIndex(of: key) {
            recency.remove(at: index)
        }
        recency.append(key)
    }
}

private let encoderProbeCache = EncoderProbeCacheStore()
