import AVFoundation
import AudioToolbox
import Foundation
import RecorderCore
import os
import VideoToolbox

enum CameraRecorderError: LocalizedError, Sendable {
    case permissionDenied(String)
    case cannotConfigure(String)
    case recordingFailed(String, String)

    var errorDescription: String? {
        switch self {
        case let .permissionDenied(name):
            return "没有\(name)采集权限。"
        case let .cannotConfigure(name):
            return "无法配置\(name)录制。"
        case let .recordingFailed(name, reason):
            return "\(name)录制失败：\(reason)"
        }
    }
}

enum MovieCaptureRole: Sendable {
    case camera
    case iosDevice

    var displayName: String {
        switch self {
        case .camera: appLocalized("摄像头")
        case .iosDevice: appLocalized("iPhone/iPad 屏幕")
        }
    }

    var inputDeviceRole: CaptureInputDeviceRole {
        switch self {
        case .camera: .camera
        case .iosDevice: .iosDevice
        }
    }
}

enum MicrophoneRecorderError: LocalizedError, Sendable {
    case permissionDenied
    case recordingFailed(String)

    var errorDescription: String? {
        switch self {
        case .permissionDenied:
            return "没有麦克风权限。"
        case let .recordingFailed(reason):
            return "麦克风录制失败：\(reason)"
        }
    }
}

final class CaptureCancellationFlag: Sendable {
    private let storage = OSAllocatedUnfairLock(initialState: false)

    var isCancelled: Bool { storage.withLock { $0 } }

    func cancel() {
        storage.withLock { $0 = true }
    }
}

enum CaptureActivity {
    case idle
    case livePreview(UUID)
    case starting(UUID)
    case recording(UUID)
    case stopping(UUID)

    var recordingRequestID: UUID? {
        switch self {
        case let .starting(id), let .recording(id), let .stopping(id): id
        case .idle, .livePreview: nil
        }
    }

    var ownsRecordingOutput: Bool { recordingRequestID != nil }

    var isRecording: Bool {
        if case .recording = self { return true }
        return false
    }
}

struct CaptureFinishOutcome: Sendable {
    let succeeded: Bool
    let failureReason: String

    init(error: (any Error)?) {
        let nsError = error as NSError?
        succeeded = error == nil
            || (nsError?.userInfo[AVErrorRecordingSuccessfullyFinishedKey] as? Bool == true)
        failureReason = error?.localizedDescription ?? "未知错误"
    }
}

/// Convert a capture-session sample timestamp onto the one host clock shared
/// with ScreenCaptureKit and the other recorder sessions. Comparing raw sample
/// seconds from different session master clocks is not a valid synchronization
/// operation even when their numeric values happen to look similar.
func captureSampleHostTime(
    _ sampleBuffer: CMSampleBuffer,
    session: AVCaptureSession
) -> TimeInterval? {
    let presentationTime = sampleBuffer.presentationTimeStamp
    guard presentationTime.isNumeric else { return nil }
    let hostTime: CMTime
    if let masterClock = session.synchronizationClock {
        hostTime = CMSyncConvertTime(
            presentationTime,
            from: masterClock,
            to: CMClockGetHostTimeClock()
        )
    } else {
        hostTime = presentationTime
    }
    guard hostTime.isNumeric, hostTime.seconds.isFinite else { return nil }
    return hostTime.seconds
}

/// AVFoundation invokes file-output delegates on an internal queue. The unchecked
/// conformance is the narrow bridge into `sessionQueue`; every mutable property and
/// every AVCaptureSession/Input/Output operation is confined there.
