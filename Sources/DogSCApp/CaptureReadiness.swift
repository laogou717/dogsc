import AppKit
import AVFoundation
import CoreGraphics
import Foundation
import RecorderCore

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
    static func available(screens: [NSScreen] = NSScreen.screens) -> [CaptureDisplay] {
        screens.compactMap { screen in
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
    let estimatedOneMinuteBytes: Int64
    let displayRefreshRate: Int?
    let targetFrameRate: OutputFrameRate
    let captureCodec: CaptureCodec

    var hasSufficientDisk: Bool {
        guard let availableDiskBytes else { return true }
        return availableDiskBytes >= estimatedOneMinuteBytes
    }

    var insufficientDiskMessage: String? {
        guard let availableDiskBytes, !hasSufficientDisk else { return nil }
        let available = max(availableDiskBytes, 0)
        return String(
            format: appLocalized("开始录制需预留约 1 分钟的空间（%@），当前可用 %@。请再释放约 %@ 后重试。"),
            ByteCountFormatter.string(fromByteCount: estimatedOneMinuteBytes, countStyle: .file),
            ByteCountFormatter.string(fromByteCount: available, countStyle: .file),
            ByteCountFormatter.string(fromByteCount: estimatedOneMinuteBytes - available, countStyle: .file)
        )
    }

    var displayCanShowTargetRate: Bool {
        guard let displayRefreshRate else { return true }
        return displayRefreshRate >= targetFrameRate.rawValue
    }

    var frameRateWarningText: String? {
        guard let displayRefreshRate,
              displayRefreshRate < targetFrameRate.rawValue else { return nil }
        return String(
            format: appLocalized("目标为 %ld FPS，但显示器当前仅报告 %ld Hz；录制会保留实际帧率，不会补帧冒充。"),
            targetFrameRate.rawValue,
            displayRefreshRate
        )
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
            name: appLocalized("未知显示器"),
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
            duration: 60
        )
        return CaptureReadiness(
            hasScreenRecordingPermission: CGPreflightScreenCaptureAccess(),
            availableDiskBytes: availableDiskCapacity(),
            estimatedOneMinuteBytes: estimatedBytes,
            displayRefreshRate: display.refreshRate,
            targetFrameRate: targetFrameRate,
            captureCodec: captureCodec
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
        // New recordings are written to the working-project volume before
        // being archived. Movies or the saved-project destination may be on
        // another disk. Walk to an existing ancestor on first launch.
        var directory = ProjectStore.workingProjectsFolder
        while !FileManager.default.fileExists(atPath: directory.path), directory.path != "/" {
            directory.deleteLastPathComponent()
        }
        let attributes = try? FileManager.default.attributesOfFileSystem(forPath: directory.path)
        return (attributes?[.systemFreeSize] as? NSNumber)?.int64Value
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
        case .notDetermined: return appLocalized("首次使用时询问")
        case .restricted: return appLocalized("系统限制")
        case .denied: return appLocalized("未授权")
        case .authorized: return appLocalized("已授权")
        }
    }
}
