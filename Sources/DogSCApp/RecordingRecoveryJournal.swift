import Foundation
import RecorderCore

/// Immutable input for one recovery checkpoint. AppModel captures live state
/// on MainActor, then this value crosses to the journal actor for system probes,
/// JSON encoding and file I/O.
struct RecordingRecoverySnapshot: Sendable {
    let state: String
    let session: RecordingSession
    let frameRate: OutputFrameRate
    var measurement: FrameRateMeasurement? = nil
    var cameraDiagnostics: CameraCaptureDiagnostics? = nil
    var systemAudioDiagnostics: AudioCaptureDiagnostics? = nil
    var microphoneDiagnostics: AudioCaptureDiagnostics? = nil
    var performanceMonitor: RecordingPerformanceMonitor? = nil
    var appendsPerformanceSample = false
    var screenRelativePath = "media/screen-0001.mp4"
}

/// Orders every recording-time recovery write away from MainActor. Final-state
/// writes use the same actor, so an in-flight heartbeat can never overwrite a
/// later `complete`, `failed` or `discarded` manifest.
actor RecordingRecoveryJournal {
    func persist(_ snapshot: RecordingRecoverySnapshot) throws {
        if snapshot.appendsPerformanceSample,
           let sample = snapshot.performanceMonitor?.sample() {
            try ProjectStore.appendRecordingPerformanceSample(
                sample,
                session: snapshot.session
            )
        }
        try ProjectStore.writeRecoveryManifest(
            state: snapshot.state,
            session: snapshot.session,
            frameRate: snapshot.frameRate,
            measurement: snapshot.measurement,
            cameraDiagnostics: snapshot.cameraDiagnostics,
            systemAudioDiagnostics: snapshot.systemAudioDiagnostics,
            microphoneDiagnostics: snapshot.microphoneDiagnostics,
            performanceSummary: snapshot.performanceMonitor?.summary,
            screenRelativePath: snapshot.screenRelativePath
        )
    }
}
