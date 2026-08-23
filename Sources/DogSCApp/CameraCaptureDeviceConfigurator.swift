import AVFoundation
import CoreMedia
import Foundation
import RecorderCore
import os

/// Owns the device-format contract at preview/recording boundaries. Keeping
/// this outside CameraRecorder leaves that type focused on capture lifecycle
/// and makes every reconfiguration go through one deterministic path.
enum CameraCaptureDeviceConfigurator {
    private static let logger = Logger(
        subsystem: "cn.laogou.dogsc",
        category: "camera-recorder"
    )

    static func applyPreferredFormat(
        to device: AVCaptureDevice,
        role: MovieCaptureRole
    ) throws {
        let dimensions = device.formats.map {
            CMVideoFormatDescriptionGetDimensions($0.formatDescription)
        }
        guard let index = CameraCaptureFormatSelector.preferredFormatIndex(
            dimensions: dimensions.map { (width: Int($0.width), height: Int($0.height)) },
            prefersLandscape: role == .camera
        ) else { return }
        let targetDimensions = dimensions[index]
        let candidates = device.formats.filter { format in
            let candidate = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
            return candidate.width == targetDimensions.width
                && candidate.height == targetDimensions.height
                && !format.videoSupportedFrameRateRanges.isEmpty
        }
        let format = candidates.max { lhs, rhs in
            let lhsMax = lhs.videoSupportedFrameRateRanges.map(\.maxFrameRate).max() ?? 0
            let rhsMax = rhs.videoSupportedFrameRateRanges.map(\.maxFrameRate).max() ?? 0
            return lhsMax < rhsMax
        } ?? device.formats[index]
        try apply(format, to: device, role: role)
    }

    static func applyCameraFormat(
        _ resolution: CameraCaptureResolution,
        to device: AVCaptureDevice,
        role: MovieCaptureRole
    ) throws {
        let candidates = device.formats.filter { format in
            let dimensions = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
            return Int(dimensions.width) == resolution.width
                && Int(dimensions.height) == resolution.height
                && !format.videoSupportedFrameRateRanges.isEmpty
        }
        // Multiple formats can expose the same dimensions with different pixel
        // encodings. Choose the broadest automatic cadence range, but never set
        // a concrete FPS; the device remains authoritative.
        guard let format = candidates.max(by: { lhs, rhs in
            let lhsMax = lhs.videoSupportedFrameRateRanges.map(\.maxFrameRate).max() ?? 0
            let rhsMax = rhs.videoSupportedFrameRateRanges.map(\.maxFrameRate).max() ?? 0
            return lhsMax < rhsMax
        }) else {
            throw CameraRecorderError.recordingFailed(
                role.displayName,
                "摄像头不再支持所选分辨率 \(resolution.label)"
            )
        }
        try apply(format, to: device, role: role, label: resolution.label)
    }

    static func restoreAutomaticCadence(
        to input: AVCaptureDeviceInput,
        device: AVCaptureDevice
    ) throws {
        if #available(macOS 26.0, *), input.isLockedVideoFrameDurationSupported {
            input.activeLockedVideoFrameDuration = .invalid
        }
        try device.lockForConfiguration()
        device.activeVideoMinFrameDuration = .invalid
        device.activeVideoMaxFrameDuration = .invalid
        device.unlockForConfiguration()
        logConfiguredMode(device: device)
    }

    private static func apply(
        _ format: AVCaptureDevice.Format,
        to device: AVCaptureDevice,
        role: MovieCaptureRole,
        label: String? = nil
    ) throws {
        guard device.activeFormat != format else { return }
        do {
            try device.lockForConfiguration()
            device.activeFormat = format
            device.unlockForConfiguration()
        } catch {
            let reason = label.map { "无法选择 \($0)" }
                ?? "无法锁定设备采集格式"
            throw CameraRecorderError.recordingFailed(
                role.displayName,
                "\(reason)：\(error.localizedDescription)"
            )
        }
    }

    private static func logConfiguredMode(device: AVCaptureDevice) {
        let dimensions = CMVideoFormatDescriptionGetDimensions(
            device.activeFormat.formatDescription
        )
        let message = "camera configured size=\(dimensions.width)x\(dimensions.height) "
            + "fps=automatic"
        logger.notice("\(message, privacy: .public)")
    }
}
