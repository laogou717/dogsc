import CoreMedia
import Foundation
import RecorderCore

/// REC-001/REC-002/REC-004: a display stream and an independent-window stream
/// have different producers. Asking a 120 Hz display compositor for unlimited
/// 5K updates made WindowServer deliver only ~27-29 complete fps, while the
/// nearly identical 5K independent window sustained ~60. Request at most 60
/// updates for display/area capture so the compositor does not attempt a 120 Hz
/// workload that the recording never exports. This remains VFR: no frames are
/// synthesized or callback-filtered, and every delivered frame keeps its PTS.
/// Independent windows retain native cadence because their producer already
/// sustains the current workload.
enum CaptureStreamTimingPolicy {
    static func minimumFrameInterval(for source: CaptureSource) -> CMTime {
        switch source {
        case .display, .area:
            CMTime(value: 1, timescale: 60)
        case .window, .device:
            .zero
        }
    }
}

/// REC-001/REC-004: keep the maximum ScreenCaptureKit surface pool that Apple
/// exposes for desktop capture. Three additional 4K NV12 surfaces cost roughly
/// 42 MiB, but let WindowServer continue presenting while the hardware encoder
/// briefly owns older surfaces. The eight-surface boundary is declared and
/// verified locally from the ScreenCaptureKit contract.
enum CaptureStreamSurfacePolicy {
    static let queueDepth = 8
}

/// Recording is a foreground, deadline-sensitive user operation. The activity
/// scope ends with the capture run and never remains active in the editor.
enum RecordingPerformanceActivityPolicy {
    static let options: ProcessInfo.ActivityOptions = [
        .userInitiated,
        .latencyCritical,
        .idleSystemSleepDisabled,
    ]
}
