import AVFoundation

/// PRE-005/EDT-004 标尺/总览/修剪手柄的拖动刷帧机器，从
/// `EditorPlaybackController.swift` 拆出以满足架构行数预算。主声明里放宽到
/// 模块内访问的 scrub 状态只允许这里的代码写入。
extension EditorPlaybackController {
    /// PRE-005/EDT-004: pointer motion owns a cheap logical clock. Native
    /// playhead layers follow every update, while expensive exact AVFoundation
    /// seeks are coalesced to one per 33 ms and the final mouse-up is exact.
    func beginScrubbing() {
        guard !scrubIsActive, let primaryPlayer else { return }
        // 按下拖动（标尺、总览、裁剪手柄）接管传输层，悬浮预览立即让位。
        endHoverPreview(restoreTransport: false)
        playbackStartToken &+= 1
        cameraSeekToken &+= 1
        cameraSeekIsPending = false
        cameraPlayer?.cancelPendingSeeks()
        scrubIsActive = true
        cancelScrubScheduling()
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
        // Invalidate any older in-flight seek before publishing the newer
        // pointer clock, otherwise its completion can pull the playhead back.
        seekToken &+= 1
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
        guard scrubIsActive, scrubSeekTask == nil else { return }
        scrubSeekTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: .milliseconds(33))
            } catch {
                return
            }
            guard let self, self.scrubIsActive else { return }
            self.scrubSeekTask = nil
            guard let target = self.scrubSeekCoalescer.takePending() else { return }
            self.seek(
                to: target,
                pausing: true,
                loadsPausedFrame: false
            )
            if self.scrubSeekCoalescer.pendingTarget != nil {
                self.scheduleScrubSeekIfNeeded()
            }
        }
    }

    func cancelScrubScheduling() {
        scrubSeekTask?.cancel()
        scrubSeekTask = nil
        scrubSeekCoalescer.cancel()
    }
}
