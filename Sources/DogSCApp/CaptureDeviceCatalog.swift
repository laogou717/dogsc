import AVFoundation
import CoreMediaIO
import Foundation
import RecorderCore

struct CaptureDeviceInfo: Identifiable, Equatable, Sendable {
    let id: String
    let name: String
}

struct CameraRuntimeFormat: Equatable, Sendable {
    let width: Int
    let height: Int
    let framesPerSecond: Double

    var resolution: CameraCaptureResolution {
        CameraCaptureResolution(width: width, height: height)
    }

    var label: String {
        let fps = String(format: "%.1f", framesPerSecond)
        return "\(resolution.resolutionLabel) · \(resolution.aspectRatioLabel) · \(fps) FPS"
    }
}

struct CameraSystemVideoEffects: Equatable, Sendable {
    let names: [String]
}

/// The AVFoundation boundary for device discovery. Discovery sessions are
/// rebuilt for each catalog refresh and again for every recorder start.
enum CaptureDeviceCatalog {
    static func enabledSystemVideoEffects() -> CameraSystemVideoEffects {
        var names: [String] = []
        if AVCaptureDevice.isPortraitEffectEnabled { names.append("人像") }
        if AVCaptureDevice.isCenterStageEnabled { names.append("人物居中") }
        if AVCaptureDevice.isStudioLightEnabled { names.append("演播室灯光") }
        if AVCaptureDevice.reactionEffectGesturesEnabled { names.append("手势特效识别") }
        if #available(macOS 15.0, *), AVCaptureDevice.isBackgroundReplacementEnabled {
            names.append("背景替换")
        }
        return CameraSystemVideoEffects(names: names)
    }

    static func showSystemVideoEffects() {
        AVCaptureDevice.showSystemUserInterface(.videoEffects)
    }

    @discardableResult
    static func enableIOSScreenCaptureDevices() -> Bool {
        var address = CMIOObjectPropertyAddress(
            mSelector: UInt32(kCMIOHardwarePropertyAllowScreenCaptureDevices),
            mScope: UInt32(kCMIOObjectPropertyScopeGlobal),
            mElement: UInt32(kCMIOObjectPropertyElementMain)
        )
        var enabled: UInt32 = 1
        let status = CMIOObjectSetPropertyData(
            CMIOObjectID(kCMIOObjectSystemObject),
            &address,
            0,
            nil,
            UInt32(MemoryLayout<UInt32>.size),
            &enabled
        )
        return status == noErr
    }

    static func screenDevices() -> [CaptureDeviceInfo] {
        deviceInfos(from: liveDevices(for: .iosDevice))
    }

    static func videoDevices() -> [CaptureDeviceInfo] {
        deviceInfos(from: liveDevices(for: .camera))
    }

    static func audioDevices() -> [CaptureDeviceInfo] {
        deviceInfos(from: liveDevices(for: .microphone))
    }

    /// Enumerates resolutions the selected device actually advertises. Frame
    /// rate remains automatic and is measured from delivered sample PTS.
    static func cameraResolutions(deviceUniqueID: String?) -> [CameraCaptureResolution] {
        guard let device = try? resolveLiveDevice(
            role: .camera,
            selectedUniqueID: deviceUniqueID
        ) else { return [] }

        var resolutions = Set<CameraCaptureResolution>()
        for format in device.formats {
            let dimensions = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
            guard dimensions.width > 0,
                  dimensions.height > 0,
                  !format.videoSupportedFrameRateRanges.isEmpty else { continue }
            resolutions.insert(CameraCaptureResolution(
                width: Int(dimensions.width),
                height: Int(dimensions.height)
            ))
        }

        return resolutions.sorted {
            let lhsPixels = $0.width * $0.height
            let rhsPixels = $1.width * $1.height
            if lhsPixels != rhsPixels { return lhsPixels > rhsPixels }
            return $0.width > $1.width
        }
    }

    /// Rebuilds a discovery session at the actual preview/recording boundary.
    /// An explicit identity never consults AVCaptureDevice.default; automatic
    /// selection is available only to a genuinely unspecified camera or mic.
    static func resolveLiveDevice(
        role: CaptureInputDeviceRole,
        selectedUniqueID: String?
    ) throws -> AVCaptureDevice {
        let request = CaptureInputDeviceRequest(
            role: role,
            selectedUniqueID: selectedUniqueID
        )
        var devices = liveDevices(for: role)
        let defaultDevice: AVCaptureDevice?

        switch request {
        case .exact:
            defaultDevice = nil
        case .automatic(role: .camera):
            defaultDevice = AVCaptureDevice.default(for: .video)
        case .automatic(role: .microphone):
            defaultDevice = AVCaptureDevice.default(for: .audio)
        case .automatic(role: .iosDevice):
            defaultDevice = nil
        }

        if let defaultDevice,
           defaultDevice.isConnected,
           !devices.contains(where: { $0.uniqueID == defaultDevice.uniqueID }) {
            devices.append(defaultDevice)
        }
        let descriptors = devices.map {
            CaptureInputDeviceDescriptor(
                role: role,
                uniqueID: $0.uniqueID,
                localizedName: $0.localizedName
            )
        }
        let descriptor = try CaptureInputDeviceResolutionPolicy.resolve(
            request,
            candidates: descriptors,
            defaultUniqueID: defaultDevice?.uniqueID
        )
        guard let device = devices.first(where: {
            $0.uniqueID == descriptor.uniqueID && $0.isConnected
        }) else {
            throw CaptureInputDeviceResolutionError(
                role: role,
                requestedUniqueID: request.requestedUniqueID
            )
        }
        return device
    }

    private static func deviceInfos(from devices: [AVCaptureDevice]) -> [CaptureDeviceInfo] {
        devices.map {
            CaptureDeviceInfo(id: $0.uniqueID, name: $0.localizedName)
        }
    }

    private static func liveDevices(
        for role: CaptureInputDeviceRole
    ) -> [AVCaptureDevice] {
        let discovery: AVCaptureDevice.DiscoverySession
        switch role {
        case .camera:
            discovery = AVCaptureDevice.DiscoverySession(
                deviceTypes: [.builtInWideAngleCamera, .external, .continuityCamera],
                mediaType: .video,
                position: .unspecified
            )
        case .microphone:
            discovery = AVCaptureDevice.DiscoverySession(
                deviceTypes: [.microphone],
                mediaType: .audio,
                position: .unspecified
            )
        case .iosDevice:
            guard enableIOSScreenCaptureDevices() else { return [] }
            discovery = AVCaptureDevice.DiscoverySession(
                deviceTypes: [.external],
                mediaType: .muxed,
                position: .unspecified
            )
        }

        return discovery.devices.filter { device in
            guard device.isConnected else { return false }
            if role == .iosDevice {
                return device.modelID == "iOS Device"
            }
            return true
        }
    }
}
