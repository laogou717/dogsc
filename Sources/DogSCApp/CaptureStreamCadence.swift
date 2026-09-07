import CoreMedia
import Foundation
import RecorderCore

/// REC-001/REC-002/REC-004: product recording is authored for at most 60 FPS.
/// Asking a 120 Hz compositor or independent window for unlimited updates adds
/// frames the 60 FPS export cannot retain and divides the same real-time HEVC
/// budget across up to twice as many screen images. Ask ScreenCaptureKit for at
/// most 60 updates for every Mac screen source. This remains VFR: no frames are
/// synthesized or callback-filtered, and every frame ScreenCaptureKit chooses
/// to deliver keeps its original PTS.
enum CaptureStreamTimingPolicy {
    static func minimumFrameInterval(for source: CaptureSource) -> CMTime {
        switch source {
        case .display, .window, .area:
            CMTime(value: 1, timescale: 60)
        case .device:
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
