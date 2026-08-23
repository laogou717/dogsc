import Foundation
import RecorderCore

struct CaptureSelectionToken: RawRepresentable, Equatable, Hashable, Sendable {
    let rawValue: UInt64

    init(rawValue: UInt64) {
        self.rawValue = rawValue
    }
}

/// A confirmed source target. Transient hover and loading data never enter the
/// persisted `CaptureConfiguration`; only this value may materialize a target.
enum CaptureSelectionTarget: Equatable, Sendable {
    case display(id: UInt32, name: String)
    case window(
        id: UInt32,
        name: String,
        applicationBundleIdentifier: String?,
        applicationName: String?
    )
    case area(displayID: UInt32?, displayName: String?, rect: NormalizedRect)
    case device(id: String, name: String)

    var source: CaptureSource {
        switch self {
        case .display: .display
        case .window: .window
        case .area: .area
        case .device: .device
        }
    }

    func materializing(in base: CaptureConfiguration) -> CaptureConfiguration {
        var result = base
        result.source = source
        result.displayID = nil
        result.displayName = nil
        result.windowID = nil
        result.windowName = nil
        result.selectedApplicationBundleIdentifier = nil
        result.selectedApplicationName = nil
        result.area = nil
        result.deviceID = nil
        result.deviceName = nil

        switch self {
        case let .display(id, name):
            result.displayID = id
            result.displayName = name
        case let .window(id, name, bundleIdentifier, applicationName):
            result.windowID = id
            result.windowName = name
            result.selectedApplicationBundleIdentifier = bundleIdentifier
            result.selectedApplicationName = applicationName
            if result.systemAudioScope == .selectedApplication,
               bundleIdentifier == nil {
                result.systemAudioScope = .all
            }
        case let .area(displayID, displayName, rect):
            result.displayID = displayID
            result.displayName = displayName
            result.area = rect.constrained()
            if result.systemAudioScope == .selectedApplication {
                result.systemAudioScope = .all
            }
        case let .device(id, name):
            result.deviceID = id
            result.deviceName = name
            if result.systemAudioScope == .selectedApplication {
                result.systemAudioScope = .all
            }
        }
        return result
    }
}

struct CaptureSelectionSession: Equatable, Sendable {
    var token: CaptureSelectionToken
    var source: CaptureSource
}

enum CaptureSelectionState: Equatable, Sendable {
    case idle
    case selecting(CaptureSelectionSession)
    case ready(CaptureSelectionSession, CaptureSelectionTarget)

    var session: CaptureSelectionSession? {
        switch self {
        case .idle:
            nil
        case let .selecting(session), let .ready(session, _):
            session
        }
    }

    var selectedSource: CaptureSource? { session?.source }
    var target: CaptureSelectionTarget? {
        guard case let .ready(_, target) = self else { return nil }
        return target
    }
    var canStartRecording: Bool { target != nil }
}

enum CaptureSelectionEvent: Equatable, Sendable {
    case choose(source: CaptureSource, token: CaptureSelectionToken)
    case confirm(target: CaptureSelectionTarget, token: CaptureSelectionToken)
    case unlock(token: CaptureSelectionToken)
    case cancel(token: CaptureSelectionToken)
}

enum CaptureSelectionReducer {
    static func reduce(
        _ state: CaptureSelectionState,
        event: CaptureSelectionEvent
    ) -> CaptureSelectionState {
        switch event {
        case let .choose(source, token):
            return .selecting(CaptureSelectionSession(token: token, source: source))

        case let .confirm(target, token):
            guard let session = state.session,
                  session.token == token,
                  session.source == target.source else { return state }
            return .ready(session, target)

        case let .unlock(token):
            guard let session = state.session,
                  session.token == token else { return state }
            return .selecting(session)

        case let .cancel(token):
            guard state.session?.token == token else { return state }
            return .idle
        }
    }
}

/// Owns token issuance and guarantees that callbacks from an older selector
/// session cannot mutate the currently visible selection.
@MainActor
final class CaptureSelectionCoordinator {
    private(set) var state: CaptureSelectionState = .idle
    var onStateChange: ((CaptureSelectionState) -> Void)?
    private var nextTokenValue: UInt64 = 0

    @discardableResult
    func choose(_ source: CaptureSource) -> CaptureSelectionSession {
        nextTokenValue &+= 1
        let token = CaptureSelectionToken(rawValue: nextTokenValue)
        setState(CaptureSelectionReducer.reduce(
            state,
            event: .choose(source: source, token: token)
        ))
        return state.session!
    }

    @discardableResult
    func confirm(
        _ target: CaptureSelectionTarget,
        token: CaptureSelectionToken
    ) -> Bool {
        let before = state
        setState(CaptureSelectionReducer.reduce(
            state,
            event: .confirm(target: target, token: token)
        ))
        return state != before
    }

    @discardableResult
    func unlock(token: CaptureSelectionToken) -> Bool {
        let before = state
        setState(CaptureSelectionReducer.reduce(state, event: .unlock(token: token)))
        return state != before
    }

    @discardableResult
    func cancel(token: CaptureSelectionToken) -> Bool {
        let before = state
        setState(CaptureSelectionReducer.reduce(state, event: .cancel(token: token)))
        return state != before
    }

    /// Invalidates the current session without reusing its generation. External
    /// lifecycle resets (closing a project or abandoning a recording) use this;
    /// selector callbacks must continue to use token-scoped `cancel(token:)`.
    @discardableResult
    func reset() -> Bool {
        guard state != .idle else { return false }
        setState(.idle)
        return true
    }

    func isCurrent(_ token: CaptureSelectionToken) -> Bool {
        state.session?.token == token
    }

    private func setState(_ newState: CaptureSelectionState) {
        guard newState != state else { return }
        state = newState
        onStateChange?(newState)
    }
}
