import AVFoundation
import CoreMedia
import Foundation
import RecorderCore

enum CoreAudioSystemAudioTapError: LocalizedError {
    case unavailable
    case selectedApplicationUnavailable(String)
    case coreAudio(operation: String, status: OSStatus)
    case invalidFormat
    case invalidInputBuffer

    var errorDescription: String? {
        switch self {
        case .unavailable:
            return "Core Audio 系统声音捕获需要 macOS 14.2 或更高版本"
        case let .selectedApplicationUnavailable(bundleIdentifier):
            return "Core Audio 没有找到所选 App 的输出进程：\(bundleIdentifier)"
        case let .coreAudio(operation, status):
            return "\(operation) 失败（\(status)）"
        case .invalidFormat:
            return "Core Audio 系统声音 Tap 返回了无效格式"
        case .invalidInputBuffer:
            return "Core Audio 系统声音 Tap 返回了无效样本块"
        }
    }
}

final class CoreAudioSystemAudioTap {
    init(configuration: CaptureConfiguration, onSample: @escaping (CMSampleBuffer) -> Void) throws {
        throw CoreAudioSystemAudioTapError.unavailable
    }

    init(
        scope: Any = (),
        selectedApplicationBundleIdentifier: String? = nil,
        output: Any
    ) throws {
        throw CoreAudioSystemAudioTapError.unavailable
    }

    func start() throws {}
    func stop() throws {}
}
