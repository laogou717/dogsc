import Foundation

struct ScreenRecorderRunToken: Equatable, Hashable, Sendable {
    let runID: RecordingRunID
    let streamGeneration: UInt64
}

enum ScreenRecorderRunLifecycle: Equatable, Sendable {
    case starting
    case capturing
    case terminal
    case stopping
}

struct ScreenRecorderSurfaceUpdateToken: Equatable, Hashable, Sendable {
    let run: ScreenRecorderRunToken
    let streamIdentity: ObjectIdentifier
    let revision: UInt64
}

enum ScreenRecorderSurfaceUpdateDecision: Equatable, Sendable {
    case apply
    case cancelled
    case stale
}

enum ScreenRecorderStreamRole: Equatable, Sendable {
    case primary
    case secondary
}

enum ScreenRecorderRunBeginResult: Equatable, Sendable {
    case accepted(ScreenRecorderRunToken)
    case alreadyActive(RecordingRunID)
}

/// Value-semantic ownership for one ScreenCaptureKit run. Every asynchronous
/// completion carries both the user-visible run identity and the concrete
/// stream generation, so a late callback cannot mutate a replacement stream.
struct ScreenRecorderRunSafetyState: Sendable {
    private struct ActiveRun: Sendable {
        let token: ScreenRecorderRunToken
        var lifecycle: ScreenRecorderRunLifecycle
        var streamIdentities: Set<ObjectIdentifier> = []
        var primaryStreamIdentity: ObjectIdentifier?
        var latestSurfaceRevision: UInt64 = 0
        var terminalError: (any Error)?
    }

    private var nextStreamGeneration: UInt64 = 0
    private var active: ActiveRun?

    var activeRunID: RecordingRunID? { active?.token.runID }

    mutating func begin(_ runID: RecordingRunID) -> ScreenRecorderRunBeginResult {
        guard let active else {
            nextStreamGeneration &+= 1
            let token = ScreenRecorderRunToken(
                runID: runID,
                streamGeneration: nextStreamGeneration
            )
            self.active = ActiveRun(token: token, lifecycle: .starting)
            return .accepted(token)
        }
        return .alreadyActive(active.token.runID)
    }

    @discardableResult
    mutating func registerStreams(
        primary: ObjectIdentifier,
        secondary: ObjectIdentifier?,
        for token: ScreenRecorderRunToken
    ) -> Bool {
        guard active?.token == token else { return false }
        active?.primaryStreamIdentity = primary
        active?.streamIdentities = [primary]
        if let secondary { active?.streamIdentities.insert(secondary) }
        return true
    }

    @discardableResult
    mutating func markCapturing(_ token: ScreenRecorderRunToken) -> Bool {
        guard active?.token == token,
              active?.lifecycle == .starting,
              active?.terminalError == nil else { return false }
        active?.lifecycle = .capturing
        return true
    }

    /// A terminal callback may reach the main actor while `start` is suspended
    /// after the first frame but before ownership becomes capturing. Preserve
    /// it for the throwing start path without publishing an unexpected-stop
    /// event that would race preparation cleanup.
    @discardableResult
    mutating func deferTerminalDuringStart(
        _ error: any Error,
        for token: ScreenRecorderRunToken
    ) -> Bool {
        guard active?.token == token,
              active?.lifecycle == .starting,
              active?.terminalError == nil else { return false }
        active?.terminalError = error
        return true
    }

    func tokenForDelegate(streamIdentity: ObjectIdentifier) -> ScreenRecorderRunToken? {
        guard let active,
              active.lifecycle == .starting || active.lifecycle == .capturing,
              active.streamIdentities.contains(streamIdentity) else { return nil }
        return active.token
    }

    /// Whether the stream that stopped is the primary screen stream or the
    /// auxiliary (selected-app audio) stream. The auxiliary stream must never
    /// terminate the whole recording: its loss only degrades one audio track.
    func role(
        for streamIdentity: ObjectIdentifier,
        in token: ScreenRecorderRunToken
    ) -> ScreenRecorderStreamRole? {
        guard active?.token == token,
              active?.streamIdentities.contains(streamIdentity) == true else { return nil }
        return streamIdentity == active?.primaryStreamIdentity ? .primary : .secondary
    }

    func lifecycle(for token: ScreenRecorderRunToken) -> ScreenRecorderRunLifecycle? {
        guard active?.token == token else { return nil }
        return active?.lifecycle
    }

    @discardableResult
    mutating func claimTerminal(
        _ error: any Error,
        for token: ScreenRecorderRunToken
    ) -> Bool {
        guard active?.token == token, active?.lifecycle == .capturing else { return false }
        active?.lifecycle = .terminal
        active?.terminalError = error
        return true
    }

    func terminalError(for runID: RecordingRunID) -> (any Error)? {
        guard active?.token.runID == runID else { return nil }
        return active?.terminalError
    }

    @discardableResult
    mutating func beginStopping(_ runID: RecordingRunID) -> ScreenRecorderRunToken? {
        guard let active, active.token.runID == runID,
              active.lifecycle == .capturing || active.lifecycle == .terminal else { return nil }
        self.active?.lifecycle = .stopping
        return active.token
    }

    mutating func makeSurfaceUpdate(
        for runID: RecordingRunID
    ) -> ScreenRecorderSurfaceUpdateToken? {
        guard var active,
              active.token.runID == runID,
              active.lifecycle == .capturing,
              let streamIdentity = active.primaryStreamIdentity else { return nil }
        active.latestSurfaceRevision &+= 1
        self.active = active
        return ScreenRecorderSurfaceUpdateToken(
            run: active.token,
            streamIdentity: streamIdentity,
            revision: active.latestSurfaceRevision
        )
    }

    func surfaceUpdateDecision(
        for token: ScreenRecorderSurfaceUpdateToken,
        isCancelled: Bool
    ) -> ScreenRecorderSurfaceUpdateDecision {
        if isCancelled { return .cancelled }
        guard let active,
              active.token == token.run,
              active.lifecycle == .capturing,
              active.primaryStreamIdentity == token.streamIdentity,
              active.latestSurfaceRevision == token.revision else { return .stale }
        return .apply
    }

    @discardableResult
    mutating func end(_ token: ScreenRecorderRunToken) -> Bool {
        guard active?.token == token else { return false }
        active = nil
        return true
    }
}

enum CaptureOutputTerminalStage: Equatable, Sendable {
    case writerStart
    case videoAppend
    case audioAppend
}

struct CaptureOutputTerminalFailure: LocalizedError, CustomNSError, @unchecked Sendable {
    let stage: CaptureOutputTerminalStage
    let underlyingError: any Error

    static let errorDomain = "cn.laogou.dogsc.capture-output"

    var errorCode: Int {
        switch stage {
        case .writerStart: 1
        case .videoAppend: 2
        case .audioAppend: 3
        }
    }

    var errorDescription: String? {
        "\(stage.description)失败：\(underlyingError.localizedDescription)"
    }

    var errorUserInfo: [String: Any] {
        [
            NSLocalizedDescriptionKey: errorDescription ?? underlyingError.localizedDescription,
            NSUnderlyingErrorKey: underlyingError,
            "CaptureOutputTerminalStage": stage.description,
        ]
    }
}

private extension CaptureOutputTerminalStage {
    var description: String {
        switch self {
        case .writerStart: "启动视频写入器"
        case .videoAppend: "写入视频帧"
        case .audioAppend: "写入系统声音"
        }
    }
}

/// `CaptureOutput` is serialized on its sample queue, but keeping the one-shot
/// claim as a value policy makes the terminal-event contract directly testable.
struct CaptureOutputTerminalState: Equatable, Sendable {
    private(set) var stage: CaptureOutputTerminalStage?

    mutating func claim(_ stage: CaptureOutputTerminalStage) -> Bool {
        guard self.stage == nil else { return false }
        self.stage = stage
        return true
    }
}
