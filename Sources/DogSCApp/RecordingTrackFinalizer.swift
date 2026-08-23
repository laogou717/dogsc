import Foundation
import RecorderCore

enum RecordingTrackFinalizationIntent: Equatable, Sendable {
    case commit
    case discard(restart: Bool)
    case rollbackFailedPreparation
}

struct RecordingTrackFinalizationRequest: Equatable, Sendable {
    let runID: RecordingRunID
    let startedTracks: RecordingStartedTracks
    let intent: RecordingTrackFinalizationIntent
}

enum RecordingTrackStopTarget: String, Equatable, Sendable {
    case screen
    case iosDevice
    case camera
    case microphone

    var displayName: String {
        switch self {
        case .screen: "屏幕"
        case .iosDevice: "iPhone/iPad"
        case .camera: "摄像头"
        case .microphone: "麦克风"
        }
    }
}

struct RecordingTrackStopFailure: LocalizedError, Equatable, Sendable {
    let target: RecordingTrackStopTarget
    let domain: String
    let code: Int
    let message: String

    init(target: RecordingTrackStopTarget, error: any Error) {
        let error = error as NSError
        self.target = target
        domain = error.domain
        code = error.code
        message = error.localizedDescription
    }

    var errorDescription: String? {
        "\(target.displayName)轨道停止失败：\(message)"
    }
}

struct RecordingPreparationRollbackError: LocalizedError, Equatable, Sendable {
    let startFailureMessage: String
    let stopFailures: [RecordingTrackStopFailure]

    init(startError: any Error, stopFailures: [RecordingTrackStopFailure]) {
        startFailureMessage = startError.localizedDescription
        self.stopFailures = stopFailures
    }

    var errorDescription: String? {
        let cleanup = stopFailures.compactMap(\.errorDescription).joined(separator: "；")
        return cleanup.isEmpty ? startFailureMessage : "\(startFailureMessage)；\(cleanup)"
    }
}

struct RecordingTrackStopOutcome: Equatable, Sendable {
    let target: RecordingTrackStopTarget
    let outputURL: URL?
    let failure: RecordingTrackStopFailure?
}

struct RecordingTrackFinalizationResult: Equatable, Sendable {
    let request: RecordingTrackFinalizationRequest
    let pointerEvents: [PointerEventRecord]
    let outcomes: [RecordingTrackStopOutcome]

    var failures: [RecordingTrackStopFailure] {
        outcomes.compactMap(\.failure)
    }

    func outputURL(for target: RecordingTrackStopTarget) -> URL? {
        outcomes.first(where: { $0.target == target })?.outputURL
    }
}

enum RecordingTrackFinalizerError: LocalizedError, Equatable, Sendable {
    case staleRun(requested: RecordingRunID, current: RecordingRunID?)
    case intentConflict(
        runID: RecordingRunID,
        existing: RecordingTrackFinalizationIntent,
        requested: RecordingTrackFinalizationIntent
    )
    case anotherRunFinalizing(active: RecordingRunID, requested: RecordingRunID)

    var errorDescription: String? {
        switch self {
        case .staleRun:
            "这次录制已结束或已被替换，不能再停止它的轨道。"
        case .intentConflict:
            "这次录制已经按另一种方式结束，不能在写入过程中改变结束意图。"
        case .anotherRunFinalizing:
            "另一次录制仍在结束写入，不能同时停止新的录制。"
        }
    }
}

@MainActor
struct RecordingTrackFinalizerOperations {
    var freezePointer: @MainActor @Sendable (RecordingRunID) -> [PointerEventRecord]
    var stopScreen: @MainActor @Sendable (RecordingRunID) async throws -> URL?
    var stopIOSDevice: @MainActor @Sendable (RecordingRunID) async throws -> Void
    var stopCamera: @MainActor @Sendable (RecordingRunID) async throws -> Void
    var stopMicrophone: @MainActor @Sendable (RecordingRunID) async throws -> Void

    static func live(
        screenRecorder: ScreenRecorder,
        iosDeviceRecorder: CameraRecorder,
        cameraRecorder: CameraRecorder,
        microphoneRecorder: MicrophoneRecorder,
        pointerRecorder: PointerEventRecorder
    ) -> RecordingTrackFinalizerOperations {
        RecordingTrackFinalizerOperations(
            freezePointer: { _ in pointerRecorder.stop() },
            stopScreen: { runID in try await screenRecorder.stop(runID: runID) },
            stopIOSDevice: { _ in try await iosDeviceRecorder.stop() },
            stopCamera: { _ in try await cameraRecorder.stop() },
            stopMicrophone: { _ in try await microphoneRecorder.stop() }
        )
    }
}

/// Owns only the multi-track stop boundary. Project persistence and App phase
/// routing remain outside this type. Its unstructured task is deliberately
/// shared by every same-run/same-intent caller and is never replaced or
/// cancelled by a duplicate request.
@MainActor
final class RecordingTrackFinalizer {
    private struct ActiveFinalization {
        let request: RecordingTrackFinalizationRequest
        let task: Task<RecordingTrackFinalizationResult, Never>
    }

    private struct CompletedFinalization {
        let request: RecordingTrackFinalizationRequest
        let result: RecordingTrackFinalizationResult
    }

    private let operations: RecordingTrackFinalizerOperations
    private var active: ActiveFinalization?
    private var completed: CompletedFinalization?

    init(operations: RecordingTrackFinalizerOperations) {
        self.operations = operations
    }

    func finalize(
        _ request: RecordingTrackFinalizationRequest,
        currentRunID: RecordingRunID?
    ) async throws -> RecordingTrackFinalizationResult {
        if let completed, completed.request.runID == request.runID {
            guard completed.request.intent == request.intent else {
                throw RecordingTrackFinalizerError.intentConflict(
                    runID: request.runID,
                    existing: completed.request.intent,
                    requested: request.intent
                )
            }
            return completed.result
        }
        if let active {
            guard active.request.runID == request.runID else {
                throw RecordingTrackFinalizerError.anotherRunFinalizing(
                    active: active.request.runID,
                    requested: request.runID
                )
            }
            guard active.request.intent == request.intent else {
                throw RecordingTrackFinalizerError.intentConflict(
                    runID: request.runID,
                    existing: active.request.intent,
                    requested: request.intent
                )
            }
            return await active.task.value
        }
        guard currentRunID == request.runID else {
            throw RecordingTrackFinalizerError.staleRun(
                requested: request.runID,
                current: currentRunID
            )
        }

        // This is the capture boundary: remove the global event monitor and
        // freeze pointer records before creating a task or reaching any await.
        let frozenPointerEvents = request.startedTracks.contains(.pointer)
            ? operations.freezePointer(request.runID)
            : []
        let operations = operations
        let task = Task { @MainActor in
            await Self.perform(
                request: request,
                frozenPointerEvents: frozenPointerEvents,
                operations: operations
            )
        }
        active = ActiveFinalization(request: request, task: task)
        let result = await task.value
        if active?.request == request {
            active = nil
            completed = CompletedFinalization(request: request, result: result)
        }
        return result
    }

    private static func perform(
        request: RecordingTrackFinalizationRequest,
        frozenPointerEvents: [PointerEventRecord],
        operations: RecordingTrackFinalizerOperations
    ) async -> RecordingTrackFinalizationResult {
        async let primary = stopPrimary(request: request, operations: operations)
        async let camera = stopAuxiliary(
            target: .camera,
            isStarted: request.startedTracks.contains(.camera),
            runID: request.runID,
            operation: operations.stopCamera
        )
        async let microphone = stopAuxiliary(
            target: .microphone,
            isStarted: request.startedTracks.contains(.microphone),
            runID: request.runID,
            operation: operations.stopMicrophone
        )
        let values = await (primary, camera, microphone)
        return RecordingTrackFinalizationResult(
            request: request,
            pointerEvents: frozenPointerEvents,
            outcomes: [values.0, values.1, values.2].compactMap { $0 }
        )
    }

    private static func stopPrimary(
        request: RecordingTrackFinalizationRequest,
        operations: RecordingTrackFinalizerOperations
    ) async -> RecordingTrackStopOutcome? {
        if request.startedTracks.contains(.device) {
            return await stop(
                target: .iosDevice,
                operation: {
                    try await operations.stopIOSDevice(request.runID)
                    return nil
                }
            )
        }
        if request.startedTracks.contains(.screen) {
            return await stop(
                target: .screen,
                operation: { try await operations.stopScreen(request.runID) }
            )
        }
        return nil
    }

    private static func stopAuxiliary(
        target: RecordingTrackStopTarget,
        isStarted: Bool,
        runID: RecordingRunID,
        operation: @escaping @MainActor @Sendable (RecordingRunID) async throws -> Void
    ) async -> RecordingTrackStopOutcome? {
        guard isStarted else { return nil }
        return await stop(target: target) {
            try await operation(runID)
            return nil
        }
    }

    private static func stop(
        target: RecordingTrackStopTarget,
        operation: @MainActor @Sendable () async throws -> URL?
    ) async -> RecordingTrackStopOutcome {
        do {
            return RecordingTrackStopOutcome(
                target: target,
                outputURL: try await operation(),
                failure: nil
            )
        } catch {
            return RecordingTrackStopOutcome(
                target: target,
                outputURL: nil,
                failure: RecordingTrackStopFailure(target: target, error: error)
            )
        }
    }
}
