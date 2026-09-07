import AVFoundation

/// PRE-005/EDT-004 标尺/总览/修剪手柄的拖动刷帧机器，从
/// `EditorPlaybackController.swift` 拆出以满足架构行数预算。主声明里放宽到
/// 模块内访问的 scrub 状态只允许这里的代码写入。
extension EditorPlaybackController {
    /// PRE-005/EDT-004: pointer motion owns a cheap logical clock. Native
    /// playhead layers follow every update, while expensive exact AVFoundation
    /// seeks chase the latest target after the previous seek completes. Mouse-up is exact.
    func beginScrubbing() {
        guard !scrubIsActive, let primaryPlayer else { return }
        // 按下拖动（标尺、总览、裁剪手柄）接管传输层，悬浮预览立即让位。
        endHoverPreview(restoreTransport: false)
        playbackStartToken &+= 1
        cameraSeekToken &+= 1
        cameraSeekIsPending = false
        cameraPlayer?.cancelPendingSeeks()
        cancelScrubScheduling()
        scrubIsActive = true
        scrubPreviewTime = outputTime
        primaryPlayer.pauseTransport()
        cameraPlayer?.pauseTransport()
        primaryPlayer.cancelPendingSeeks()
        isPlaying = false
        cancelPausedFrameDecode()
        // Let the existing live-output frame remain as the visual fallback;
        // stale exact paused images must not cover newly landed scrub frames.
        pausedScreenImage = nil
        pausedCameraImage = nil
    }

    func updateScrubbing(to requestedTime: TimeInterval) {
        guard primaryPlayer != nil else { return }
        if !scrubIsActive { beginScrubbing() }
        let target = EditorPlaybackClockPolicy.clampedTime(
            requestedTime,
            duration: duration
        )
        // The pointer clock never waits for decoding. A completed seek only
        // publishes a preview frame; it must never pull this clock backwards.
        latestOutputTime = target
        resetPlaybackAnchor(to: target)
        scrubSeekCoalescer.update(target)
        scheduleScrubSeekIfNeeded()
    }

    func endScrubbing() {
        guard scrubIsActive else { return }
        let finalTime = scrubSeekCoalescer.pendingTarget ?? outputTime
        scrubIsActive = false
        cancelScrubScheduling()
        seek(to: finalTime, pausing: true, loadsPausedFrame: true)
    }

    private func scheduleScrubSeekIfNeeded() {
        guard scrubIsActive, scrubSeekTask == nil, let primaryPlayer,
              let target = scrubSeekCoalescer.takePending() else { return }
        let session = scrubSeekGeneration
        let generation = endpoints?.generation
        seekToken &+= 1
        let token = seekToken
        primarySeekIsPending = true
        scrubSeekTask = Task { @MainActor [weak self] in
            // At most one seek is in flight. Repeated cancel-and-seek at a
            // fixed 33 ms interval can starve AVPlayer on a dense recording.
            let finished = await primaryPlayer.seekTransport(
                to: CMTime(seconds: target, preferredTimescale: 60_000),
                toleranceBefore: .zero, toleranceAfter: .zero)
            guard let self, self.scrubSeekGeneration == session else { return }
            self.scrubSeekTask = nil
            guard self.scrubIsActive, self.endpoints?.generation == generation,
                  self.seekToken == token, !Task.isCancelled else { return }
            self.primarySeekIsPending = false
            if finished {
                self.scrubPreviewTime = target
                self.synchronizeCamera(to: target, force: true)
                self.advanceDiscontinuity()
            }
            self.scheduleScrubSeekIfNeeded()
        }
    }

    func cancelScrubScheduling() {
        scrubSeekGeneration &+= 1
        scrubPreviewTime = nil
        scrubSeekTask?.cancel()
        scrubSeekTask = nil
        scrubSeekCoalescer.cancel()
    }
}
