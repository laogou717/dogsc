import Foundation

/// Recording may only begin after every enabled live input has produced real
/// media. Merely selecting a camera is not readiness: permissions, USB device
/// negotiation, and the first delivered sample can all still be pending.
enum RecorderCameraReadiness: Equatable, Sendable {
    case disabled
    case preparing
    case ready(CameraRuntimeFormat)

    init(recordsCamera: Bool, runtimeFormat: CameraRuntimeFormat?) {
        guard recordsCamera else {
            self = .disabled
            return
        }
        guard let runtimeFormat else {
            self = .preparing
            return
        }
        self = .ready(runtimeFormat)
    }

    var permitsRecording: Bool {
        switch self {
        case .disabled, .ready:
            true
        case .preparing:
            false
        }
    }
}

enum RecorderStartAvailability: Equatable, Sendable {
    case needsCaptureTarget
    case preparingCamera
    case ready

    init(hasCaptureTarget: Bool, cameraReadiness: RecorderCameraReadiness) {
        guard hasCaptureTarget else {
            self = .needsCaptureTarget
            return
        }
        self = cameraReadiness.permitsRecording ? .ready : .preparingCamera
    }

    var permitsRecording: Bool { self == .ready }
}
