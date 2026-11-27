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

    static func selectedFormat(
        for device: AVCaptureDevice,
        role: MovieCaptureRole,
        resolution: CameraCaptureResolution?
    ) -> AVCaptureDevice.Format {
        let active = CMVideoFormatDescriptionGetDimensions(device.activeFormat.formatDescription)
        let landscape = role == .camera ? active.width >= active.height : nil
        return preferredFormat(on: device, sourceIsLandscape: landscape, quality: resolution) ?? device.activeFormat
    }

    static func preferredFormat(
        on device: AVCaptureDevice, sourceIsLandscape: Bool?, quality: CameraCaptureResolution?
    ) -> AVCaptureDevice.Format? {
        let formats = device.formats.filter { !$0.videoSupportedFrameRateRanges.isEmpty }
        let sizes = formats.map { CMVideoFormatDescriptionGetDimensions($0.formatDescription) }
        guard let index = CameraCaptureFormatSelector.preferredFormatIndex(
            dimensions: sizes.map { (Int($0.width), Int($0.height)) },
            sourceIsLandscape: sourceIsLandscape, requestedQuality: quality
        ) else { return nil }
        let target = sizes[index]
        return formats.indices.filter { sizes[$0].width == target.width && sizes[$0].height == target.height }
            .map { formats[$0] }
            .max {
                ($0.videoSupportedFrameRateRanges.map(\.maxFrameRate).max() ?? 0)
                    < ($1.videoSupportedFrameRateRanges.map(\.maxFrameRate).max() ?? 0)
            }
    }

    static func sessionPreset(for size: CMVideoDimensions) -> AVCaptureSession.Preset? {
        switch (size.width, size.height) {
        case (640, 480): .vga640x480
        case (1280, 720): .hd1280x720
        case (1920, 1080): .hd1920x1080
        case (3840, 2160): .hd4K3840x2160
        default: nil
        }
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

    static func apply(
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
            let reason = label.map { String(format: appLocalized("无法选择 %@"), $0) }
                ?? appLocalized("无法锁定设备采集格式")
            throw CameraRecorderError.recordingFailed(
                role.displayName,
                String(format: appLocalized("%@：%@"), reason, error.localizedDescription)
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
