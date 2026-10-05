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
            return String(format: appLocalized("没有%@采集权限。"), appLocalized(name))
        case let .cannotConfigure(name):
            return String(format: appLocalized("无法配置%@录制。"), appLocalized(name))
        case let .recordingFailed(name, reason):
            return String(format: appLocalized("%@录制失败：%@"), appLocalized(name), appLocalized(reason))
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
            return appLocalized("没有麦克风权限。")
        case let .recordingFailed(reason):
            return String(format: appLocalized("麦克风录制失败：%@"), appLocalized(reason))
        }
    }
}

/// Recovery follows the canonical error presentation in the current language.
/// Legacy Chinese prefixes remain compatible with earlier message producers.
enum RecorderSetupErrorRecovery: Equatable, Sendable {
    case projectFolder
    case camera
    case microphone
    case none

    static func forMessage(_ message: String) -> Self {
        if message.hasPrefix("保存目录不可用")
            || message.hasPrefix(appLocalized("保存目录不可用")) {
            return .projectFolder
        }
        if message.hasPrefix("没有摄像头采集权限")
            || message == CameraRecorderError.permissionDenied("摄像头").localizedDescription {
            return .camera
        }
        if message.hasPrefix("没有麦克风权限")
            || message == MicrophoneRecorderError.permissionDenied.localizedDescription {
            return .microphone
        }
        return .none
    }

    static func isPermissionMessage(_ message: String) -> Bool {
        message.contains("权限")
            || forMessage(message) == .camera
            || forMessage(message) == .microphone
            || message == appLocalized("没有屏幕录制权限。请在系统设置中允许后重新启动。")
            || message == CameraRecorderError.permissionDenied("iPhone/iPad 屏幕").localizedDescription
    }

    static func isSurfaceUpdateErrorMessage(_ message: String) -> Bool {
        message.hasPrefix("无法更新录制画面")
            || message.hasPrefix(appLocalized("无法更新录制画面"))
            || message.hasPrefix(String(format: appLocalized("无法更新录制画面：%@"), ""))
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
        failureReason = error.map(appErrorDescription) ?? appLocalized("未知错误")
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
