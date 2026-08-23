import Foundation

/// A media-input identity namespace. Roles are part of identity so that a
/// similarly named camera, microphone or iOS endpoint can never satisfy a
/// request for another kind of input.
enum CaptureInputDeviceRole: String, CaseIterable, Hashable, Sendable {
    case camera
    case microphone
    case iosDevice
}

/// The immutable, testable projection of an AVCaptureDevice used at capture
/// boundaries. The unique ID, rather than the localized name, is authoritative.
struct CaptureInputDeviceDescriptor: Equatable, Sendable {
    let role: CaptureInputDeviceRole
    let uniqueID: String
    let localizedName: String
}

enum CaptureInputDeviceRequest: Equatable, Sendable {
    /// Automatic/default selection is deliberately representable only as an
    /// explicit request state. It is never inferred from a failed exact lookup.
    case automatic(role: CaptureInputDeviceRole)
    case exact(role: CaptureInputDeviceRole, uniqueID: String)

    init(role: CaptureInputDeviceRole, selectedUniqueID: String?) {
        if let selectedUniqueID {
            self = .exact(role: role, uniqueID: selectedUniqueID)
        } else {
            self = .automatic(role: role)
        }
    }

    var role: CaptureInputDeviceRole {
        switch self {
        case let .automatic(role), let .exact(role, _): role
        }
    }

    var requestedUniqueID: String? {
        switch self {
        case .automatic: nil
        case let .exact(_, uniqueID): uniqueID
        }
    }
}

enum CaptureInputDeviceResolutionError: LocalizedError, Equatable, Sendable {
    case cameraUnavailable(requestedUniqueID: String?)
    case microphoneUnavailable(requestedUniqueID: String?)
    case iosDeviceUnavailable(requestedUniqueID: String?)

    init(role: CaptureInputDeviceRole, requestedUniqueID: String?) {
        switch role {
        case .camera:
            self = .cameraUnavailable(requestedUniqueID: requestedUniqueID)
        case .microphone:
            self = .microphoneUnavailable(requestedUniqueID: requestedUniqueID)
        case .iosDevice:
            self = .iosDeviceUnavailable(requestedUniqueID: requestedUniqueID)
        }
    }

    var errorDescription: String? {
        switch self {
        case let .cameraUnavailable(requestedUniqueID):
            requestedUniqueID == nil
                ? "没有找到可用的摄像头。"
                : "所选摄像头已断开或不可用，请重新选择。"
        case let .microphoneUnavailable(requestedUniqueID):
            requestedUniqueID == nil
                ? "没有找到可用的麦克风。"
                : "所选麦克风已断开或不可用，请重新选择。"
        case let .iosDeviceUnavailable(requestedUniqueID):
            requestedUniqueID == nil
                ? "请先选择要录制的 iPhone 或 iPad。"
                : "所选 iPhone 或 iPad 已断开或不可用，请重新选择。"
        }
    }
}

enum CaptureInputDeviceResolutionPolicy {
    /// Resolves only within the requested role and identity. A default ID is
    /// consulted exclusively for an `.automatic` camera/microphone request.
    /// iOS capture endpoints always require an exact unique ID.
    static func resolve(
        _ request: CaptureInputDeviceRequest,
        candidates: [CaptureInputDeviceDescriptor],
        defaultUniqueID: String?
    ) throws -> CaptureInputDeviceDescriptor {
        let roleCandidates = candidates.filter { $0.role == request.role }

        switch request {
        case let .exact(_, uniqueID):
            guard let exact = roleCandidates.first(where: { $0.uniqueID == uniqueID }) else {
                throw CaptureInputDeviceResolutionError(
                    role: request.role,
                    requestedUniqueID: uniqueID
                )
            }
            return exact

        case let .automatic(role):
            guard role != .iosDevice,
                  let defaultUniqueID,
                  let defaultDevice = roleCandidates.first(where: {
                      $0.uniqueID == defaultUniqueID
                  }) else {
                throw CaptureInputDeviceResolutionError(
                    role: role,
                    requestedUniqueID: nil
                )
            }
            return defaultDevice
        }
    }
}
