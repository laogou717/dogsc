import AVFoundation
import CoreImage
import Foundation

/// A silent looping AVPlayer dedicated to the canvas background. It follows
/// the editor's canonical output clock; it never creates a second independent
/// animation clock that could drift from the recording and camera tracks.
final class PreviewWallpaperVideoPlayback: @unchecked Sendable {
    var onFrameAvailable: (@Sendable () -> Void)?

    private let enqueue: @Sendable (@escaping @Sendable () -> Void) -> Void
    init(enqueue: @escaping @Sendable (@escaping @Sendable () -> Void) -> Void) { self.enqueue = enqueue }

    private var url: URL?
    private var player: AVPlayer?
    private var output: AVPlayerItemVideoOutput?
    private var duration: TimeInterval = 0
    private var preferredTransform = CGAffineTransform.identity
    private var lastDiscontinuityID: UInt64?
    private var lastCopiedItemTime = CMTime.invalid
    private var audioClock: CMTimebase?
    private var latestTick: EditorPlaybackRenderTick?
    private var isPrimed = false
    private var seekIsInFlight = false
    private var queuedPausedSeek: TimeInterval?
    private var preparationTask: Task<Void, Never>?

    func configure(url: URL?) {
        let standardized = url?.standardizedFileURL
        guard standardized != self.url else { return }
        invalidate()
        self.url = standardized
        guard let standardized else { return }

        let asset = AVURLAsset(url: standardized)
        let output = AVPlayerItemVideoOutput(pixelBufferAttributes: [
            // Core Image consumes hardware-native NV12 directly. Requesting
            // BGRA forced a full 4K colour conversion and substantially more
            // memory traffic before every preview composition.
            kCVPixelBufferPixelFormatTypeKey as String:
                kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            kCVPixelBufferMetalCompatibilityKey as String: true,
        ])
        let item = AVPlayerItem(asset: asset)
        item.preferredForwardBufferDuration = 1.5
        item.add(output)
        let player = AVPlayer(playerItem: item)
        player.isMuted = true
        player.actionAtItemEnd = .pause
        player.automaticallyWaitsToMinimizeStalling = false
        player.preventsDisplaySleepDuringVideoPlayback = false
        self.output = output
        self.player = player

        let initialTime = latestTick?.outputTime ?? 0
        preparationTask = Task.detached { [weak self] in
            do {
                guard try await asset.load(.isPlayable) else { return }
                let tracks = try await asset.loadTracks(withMediaType: .video)
                guard let track = tracks.first else { return }
                let transform = try await track.load(.preferredTransform)
                let range = try await track.load(.timeRange)
                let length = max(range.duration.seconds, 0)
                guard length > 0, !Task.isCancelled else { return }
                _ = await Self.seekPlayer(player, to: initialTime.truncatingRemainder(dividingBy: length), exact: true)
                guard !Task.isCancelled, await Self.waitUntilReady(player) else { return }
                await Self.preroll(player)
                guard !Task.isCancelled else { return }
                self?.enqueue { [weak self] in
                    guard let self, self.url == standardized, self.player === player else { return }
                    self.preferredTransform = transform; self.duration = length; self.isPrimed = true
                    if let tick = self.latestTick { self.applySynchronization(tick, force: true) }
                    else { player.pause() }
                    self.onFrameAvailable?()
                }
            } catch { /* Keep the cached poster until a valid resource is ready. */ }
        }
    }

    func synchronize(to tick: EditorPlaybackRenderTick?, audioClock: CMTimebase? = nil) {
        self.audioClock = audioClock
        latestTick = tick
        if tick == nil {
            player?.pause()
            return
        }
        guard let tick, duration > 0, isPrimed else { return }
        applySynchronization(tick, force: false)
    }

    private func applySynchronization(
        _ tick: EditorPlaybackRenderTick,
        force: Bool
    ) {
        guard duration > 0, let player else { return }
        let target = localTime(for: audioClock.map { CMTimebaseGetTime($0).seconds } ?? tick.outputTime)
        let current = player.currentTime().seconds
        let discontinuity = lastDiscontinuityID != tick.discontinuityID
        lastDiscontinuityID = tick.discontinuityID

        if !tick.isPlaying {
            player.pause()
            if force || discontinuity || !current.isFinite
                || abs(current - target) > 1.0 / 120.0 {
                enqueuePausedSeek(to: target)
            }
            return
        }

        let crossedLoopBoundary = current.isFinite && target + 0.08 < current
        if force || discontinuity || crossedLoopBoundary || !current.isFinite
            || abs(current - target) > 0.25 || player.rate == 0 {
            startAlignedPlayback(at: target)
        }
    }

    func copyFrame(at outputTime: TimeInterval) -> CIImage? {
        guard duration > 0, let output else { return nil }
        let target = CMTime(
            seconds: localTime(for: outputTime),
            preferredTimescale: 600
        )
        var displayTime = CMTime.invalid
        guard let buffer = output.copyPixelBuffer(
            forItemTime: target,
            itemTimeForDisplay: &displayTime
        ) else { return nil }
        if displayTime.isNumeric, displayTime == lastCopiedItemTime {
            return nil
        }
        lastCopiedItemTime = displayTime
        return VideoExporter.orientVideoFrameForDisplay(
            CIImage(cvPixelBuffer: buffer),
            preferredTransform: preferredTransform
        )
    }

    func invalidate() {
        preparationTask?.cancel()
        preparationTask = nil
        player?.currentItem?.cancelPendingSeeks()
        player?.pause()
        player?.replaceCurrentItem(with: nil)
        player = nil
        output = nil
        duration = 0
        preferredTransform = .identity
        lastDiscontinuityID = nil
        lastCopiedItemTime = .invalid
        latestTick = nil
        audioClock = nil
        isPrimed = false
        seekIsInFlight = false
        queuedPausedSeek = nil
        url = nil
    }

    private func localTime(for outputTime: TimeInterval) -> TimeInterval {
        guard duration > 0, outputTime.isFinite else { return 0 }
        let remainder = outputTime.truncatingRemainder(dividingBy: duration)
        return remainder >= 0 ? remainder : remainder + duration
    }

    private func startAlignedPlayback(at time: TimeInterval) {
        guard let player else { return }
        queuedPausedSeek = nil
        player.currentItem?.cancelPendingSeeks()
        let target = CMTime(seconds: max(time, 0), preferredTimescale: 600)
        let hostTime = CMClockGetTime(CMClockGetHostTimeClock())
        player.setRate(1, time: target, atHostTime: hostTime)
    }

    /// Stationary updates used to issue another zero-tolerance seek before the
    /// previous one completed. Coalescing them prevents the first playback
    /// decode from being starved until the user pauses and retries.
    private func enqueuePausedSeek(to time: TimeInterval) {
        queuedPausedSeek = max(time, 0)
        guard !seekIsInFlight, let player else { return }
        let target = queuedPausedSeek ?? 0
        queuedPausedSeek = nil
        seekIsInFlight = true
        player.seek(
            to: CMTime(seconds: target, preferredTimescale: 600),
            toleranceBefore: .zero,
            toleranceAfter: .zero
        ) { [weak self, weak player] _ in
            self?.enqueue { [weak self, weak player] in
                guard let self, let player, self.player === player else { return }
                self.seekIsInFlight = false
                self.onFrameAvailable?()
                if let queued = self.queuedPausedSeek {
                    self.queuedPausedSeek = nil
                    self.enqueuePausedSeek(to: queued)
                }
            }
        }
    }

    private static func seekPlayer(
        _ player: AVPlayer,
        to time: TimeInterval,
        exact: Bool
    ) async -> Bool {
        let tolerance = exact
            ? CMTime.zero
            : CMTime(seconds: 1.0 / 30.0, preferredTimescale: 600)
        return await withCheckedContinuation { continuation in
            player.seek(
                to: CMTime(seconds: max(time, 0), preferredTimescale: 600),
                toleranceBefore: tolerance,
                toleranceAfter: tolerance
            ) { continuation.resume(returning: $0) }
        }
    }

    private static func preroll(_ player: AVPlayer) async {
        await withCheckedContinuation { continuation in
            player.preroll(atRate: 1) { _ in
                continuation.resume()
            }
        }
    }

    /// AVPlayer seek completion only means the time request landed; local HEVC
    /// items can still report `.unknown` for a short interval. Calling preroll
    /// before the player itself reaches `.readyToPlay` raises an Objective-C
    /// exception, so yield asynchronously until the actual readiness gate.
    private static func waitUntilReady(_ player: AVPlayer) async -> Bool {
        for _ in 0..<500 {
            guard !Task.isCancelled else { return false }
            switch player.status {
            case .readyToPlay:
                return true
            case .failed:
                return false
            case .unknown:
                break
            @unknown default:
                return false
            }
            do {
                try await Task.sleep(for: .milliseconds(10))
            } catch {
                return false
            }
        }
        return false
    }
}
