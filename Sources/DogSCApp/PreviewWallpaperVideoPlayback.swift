import AVFoundation
import CoreImage
import Foundation

/// A silent looping AVPlayer dedicated to the canvas background. It follows
/// the editor's canonical output clock; it never creates a second independent
/// animation clock that could drift from the recording and camera tracks.
@MainActor
final class PreviewWallpaperVideoPlayback {
    var onFrameAvailable: (() -> Void)?

    private var url: URL?
    private var player: AVPlayer?
    private var output: AVPlayerItemVideoOutput?
    private var duration: TimeInterval = 0
    private var preferredTransform = CGAffineTransform.identity
    private var lastDiscontinuityID: UInt64?
    private var lastCopiedItemTime = CMTime.invalid
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

        preparationTask = Task { [weak self] in
            do {
                guard try await asset.load(.isPlayable) else { return }
                let tracks = try await asset.loadTracks(withMediaType: .video)
                guard let track = tracks.first else { return }
                let transform = try await track.load(.preferredTransform)
                let timeRange = try await track.load(.timeRange)
                guard let self, self.url == standardized else { return }
                preferredTransform = transform
                duration = max(timeRange.duration.seconds, 0)
                guard duration > 0 else { return }

                // A completed seek does not guarantee that
                // AVPlayerItemVideoOutput owns a decoded frame. Prime the
                // hardware decoder while the cached poster stays visible,
                // then join the editor's latest output time in one operation.
                let initialTarget = localTime(for: latestTick?.outputTime ?? 0)
                _ = await seekPlayer(
                    player,
                    to: initialTarget,
                    exact: latestTick?.isPlaying != true
                )
                guard self.url == standardized else { return }
                guard await waitUntilReady(player) else { return }
                guard self.url == standardized else { return }
                await preroll(player)
                guard self.url == standardized else { return }
                isPrimed = true
                if let latestTick, latestTick.isPlaying {
                    applySynchronization(latestTick, force: true)
                } else {
                    player.pause()
                    lastDiscontinuityID = latestTick?.discontinuityID
                }
                onFrameAvailable?()
            } catch {
                // The inspector still keeps the chosen file and export will
                // report a precise media error. Preview simply remains on the
                // previously presented drawable instead of flashing black.
            }
        }
    }

    func synchronize(to tick: EditorPlaybackRenderTick?) {
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
        let target = localTime(for: tick.outputTime)
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
            Task { @MainActor [weak self, weak player] in
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

    private func seekPlayer(
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

    private func preroll(_ player: AVPlayer) async {
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
    private func waitUntilReady(_ player: AVPlayer) async -> Bool {
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
