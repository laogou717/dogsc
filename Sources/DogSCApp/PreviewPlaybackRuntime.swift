import AVFoundation
import CoreImage
import Foundation
import os
import QuartzCore
import RecorderCore

/// AVFoundation owns this clock. Its rate becomes zero when audio waits;
/// neither a UI timer nor the renderer may advance it independently.
struct PreviewPlaybackSource: @unchecked Sendable {
    let clock: CMTimebase
    let cameraPlayer: AVPlayer?
    let generation: UInt64
    let discontinuityID: UInt64
    let metadata: PreviewSourceMetadata
    var cameraFrameRates: [UUID: Double] = [:]

    func tick(target: CFTimeInterval) -> EditorPlaybackRenderTick? {
        let rate = CMTimebaseGetEffectiveRate(clock)
        let lead = target - CACurrentMediaTime()
        // Convert the display's host deadline through the audio timebase's
        // current anchors, including its latest seek/rate. A video-output
        // mapping may still describe a retired seek and is not a second clock.
        let displayTime: Double? = lead >= 0 && lead <= 0.1
            ? CMSyncConvertTime(CMTime(seconds: target, preferredTimescale: 1_000_000_000),
                from: CMClockGetHostTimeClock(), to: clock).seconds : nil
        guard let time = EditorPlaybackClockPolicy.playbackTime(
            playerTime: CMTimebaseGetTime(clock).seconds, rate: rate,
            displayTime: displayTime, duration: metadata.plan.outputDuration,
            maximumLead: 0.1 * max(rate, 1)) else { return nil }
        let frame = metadata.frame(at: time)
        return EditorPlaybackRenderTick(mediaGeneration: generation, discontinuityID: discontinuityID,
            outputTime: time, itemTime: CMTime(seconds: time, preferredTimescale: 60_000),
            cameraIsAvailable: frame.cameraSlice != nil, isPlaying: true, sourceFrame: frame)
    }
}

struct PreviewSceneWallpaper: Sendable {
    var image: CIImage?
    var videoURL: URL?
}

/// NSView geometry and immutable media inputs cross this boundary only when
/// they change. Mutable AppKit objects never participate in the frame loop.
struct PreviewEngineInput: @unchecked Sendable {
    var layer: CAMetalLayer?
    var bounds: CGRect
    var backingScale: CGFloat
    var suspended: Bool
    var source: PreviewPlaybackSource?
    var provider: SharedPreviewPlaybackFrameProvider?
    var screenOutput: AVPlayerItemVideoOutput?
    var cameraOutput: AVPlayerItemVideoOutput?
    var tick: EditorPlaybackRenderTick?
    var paused: Bool
    var plan: FrameRenderPlan
    var scene: FrameScene
    var prewarm: [FrameRenderPlan]
    var pausedScreen: CIImage?
    var pausedCamera: CIImage?
    var wallpaper: CIImage?
    var wallpaperVideo: URL?
    var sceneWallpapers: [String: PreviewSceneWallpaper]
    var defaultWallpaperKey: String?
    var stickers: [String: CIImage]
    var suppressCamera: Bool
    var suppressScreen: Bool
    var liveDrag: MotionElementEditor.LiveDrag?
    var assetRootURL: URL? = nil
    var motionStarts: [PreviewMotionStart] = []
}

struct PreviewDisplayFrame: @unchecked Sendable {
    let drawable: any CAMetalDrawable
    let presentationTime: CFTimeInterval

    init(update: CAMetalDisplayLink.Update) {
        drawable = update.drawable
        presentationTime = update.targetPresentationTimestamp
    }

    init(drawable: any CAMetalDrawable, presentationTime: CFTimeInterval) {
        self.drawable = drawable
        self.presentationTime = presentationTime
    }
}

/// One pending configuration and one pending display request, regardless of
/// event frequency. No completion needs MainActor to release the next slot.
final class PreviewEngineMailbox: @unchecked Sendable {
    struct Configuration: Sendable {
        var input: PreviewEngineInput
        var revision: UInt64
        var epoch: UInt64
    }
    struct Work: Sendable {
        var configuration: Configuration?
        var frame: PreviewDisplayFrame?
        var redraw: Bool
    }
    private struct State: Sendable {
        var configuration: Configuration?
        var frame: PreviewDisplayFrame?
        var redraw = false
        var scheduled = false
        var revision: UInt64 = 0
        var epoch: UInt64 = 0
        var retirement: UInt64 = 0
        var readiness: PreviewFrameReadiness?
        var identity: PreviewPresentationEpoch?
        var resources: [ObjectIdentifier?] = []
    }
    private let state = OSAllocatedUnfairLock(initialState: State())
    var configurationRevision: UInt64 { state.withLock { $0.revision } }
    var epoch: UInt64 { state.withLock { $0.epoch } }
    var retirementGeneration: UInt64 { state.withLock { $0.retirement } }

    func configure(_ input: PreviewEngineInput) -> Bool {
        state.withLock { s in
            let identity = PreviewPresentationEpoch(mediaGeneration: input.tick?.mediaGeneration,
                discontinuityID: input.tick?.discontinuityID,
                isPlaying: !input.paused && input.source != nil && !input.suspended)
            let resources = [input.layer.map(ObjectIdentifier.init), input.source.map { ObjectIdentifier($0.clock) },
                             input.screenOutput.map(ObjectIdentifier.init), input.cameraOutput.map(ObjectIdentifier.init)]
            if s.identity != identity || s.resources != resources {
                s.epoch &+= 1; s.identity = identity; s.resources = resources
                s.frame = nil
            }
            s.revision &+= 1
            s.configuration = Configuration(input: input, revision: s.revision, epoch: s.epoch)
            let schedule = !s.scheduled
            s.scheduled = true
            return schedule
        }
    }
    func request(_ frame: PreviewDisplayFrame? = nil) -> Bool {
        state.withLock { s in
            if let frame { s.frame = frame } else { s.redraw = true }
            let schedule = !s.scheduled
            s.scheduled = true
            return schedule
        }
    }
    func take() -> Work {
        state.withLock { s in
            let work = Work(configuration: s.configuration, frame: s.frame, redraw: s.redraw)
            s.configuration = nil; s.frame = nil; s.redraw = false; s.scheduled = false
            return work
        }
    }
    @discardableResult func interrupt() -> UInt64 {
        state.withLock { s in
            s.epoch &+= 1; s.identity = nil
            s.frame = nil
            return s.epoch
        }
    }
    func claimReadiness(_ event: PreviewFrameReadiness) -> Bool {
        state.withLock { s in
            guard s.epoch == event.epoch, s.revision == event.revision, s.readiness != event else { return false }
            s.readiness = event
            return true
        }
    }
    @discardableResult func nextRetirement() -> UInt64 {
        state.withLock { $0.retirement &+= 1; return $0.retirement }
    }
}

struct PreviewFrameReadiness: Equatable, Sendable {
    let epoch: UInt64
    let revision: UInt64
    let includesCamera: Bool
    let includesScreen: Bool
}

struct PreviewMotionStart: Equatable, Sendable {
    let time: TimeInterval
    var segmentID: UUID? = nil
}
