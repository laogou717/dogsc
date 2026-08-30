import AVFoundation

/// EDT-030 时间线悬浮预览轴。
///
/// 暂停时指针扫过时间线任意位置（包括片段元素上方），画布实时显示所指帧；
/// 逻辑时钟（`latestOutputTime`、紫色播放头、时间码、总览）全程不动。只有
/// 传输层被物理 seek 到所指帧，悬浮结束时再异步归还播放头——下一次播放、
/// 精确暂停帧和导出位置都不被悬浮污染。
///
/// 本文件从 `EditorPlaybackController.swift` 拆出以满足架构行数预算；主
/// 声明里为此放宽到模块内访问的成员（传输层、seek 令牌、scrub 状态与
/// `synchronizeCamera`/`advanceDiscontinuity`）只允许这里的代码使用。
extension EditorPlaybackController {
    /// 悬浮预览激活时的画布渲染时钟。只有画布消费这个所指时刻；播放头、
    /// 时间码和总览仍读 `outputTime`，预览结束（nil）后画布自动回落。
    var hoverRenderTick: EditorPlaybackRenderTick? {
        guard let endpoints, let hoverPreviewTime else { return nil }
        let time = EditorPlaybackClockPolicy.clampedTime(
            hoverPreviewTime,
            duration: duration
        )
        return EditorPlaybackRenderTick(
            mediaGeneration: endpoints.generation,
            discontinuityID: discontinuityID,
            outputTime: time,
            itemTime: CMTime(seconds: time, preferredTimescale: 60_000),
            cameraIsAvailable: cameraIsAvailable(at: time),
            isPlaying: false
        )
    }

    /// 指针在时间线上移动时调用。只在暂停状态生效；播放中由播放时钟独占
    /// 画布。目标帧按 scrub 同一节奏（33ms）合并，传输层 seek 落地后才发
    /// 布 `hoverPreviewTime`，每次落地只触发一次画布重绘。
    func updateHoverPreview(to requestedTime: TimeInterval) {
        guard !isPlaying, !scrubIsActive, primaryPlayer != nil else { return }
        let target = EditorPlaybackClockPolicy.clampedTime(
            requestedTime,
            duration: duration
        )
        hoverSeekCoalescer.update(target)
        scheduleHoverSeekIfNeeded()
    }

    /// 指针离开时间线（或窗口）时调用：画布立即回落到播放头的完整暂停帧
    /// （该帧从未被清除，无需等待），传输层随后异步 seek 回播放头。
    func endHoverPreview() {
        endHoverPreview(restoreTransport: true)
    }

    /// 任何接管传输层的入口（显式 seek、按下拖动、起播、媒体重建）以
    /// `restoreTransport: false` 调用：那些路径自己决定物理位置，悬浮预览
    /// 只需让位，不再归还。
    func endHoverPreview(restoreTransport: Bool) {
        let wasPreviewing = hoverPreviewTime != nil
        let needsTransportRestore = wasPreviewing || hoverSeekInFlightCount > 0
        let hasScheduledHover = hoverSeekTask != nil
            || hoverSeekCoalescer.pendingTarget != nil
        guard needsTransportRestore || hasScheduledHover else { return }
        // Invalidate even when the seek has not published hoverPreviewTime yet.
        // Otherwise a result that lands after the user disables skimming can
        // resurrect the hover frame without its reference line.
        hoverSeekGeneration &+= 1
        hoverSeekTask?.cancel()
        hoverSeekTask = nil
        hoverSeekCoalescer.cancel()
        hoverSeekInFlightCount = 0
        if wasPreviewing {
            hoverPreviewTime = nil
        }
        guard needsTransportRestore, let primaryPlayer else { return }
        primaryPlayer.cancelPendingSeeks()
        guard restoreTransport else { return }
        // 逻辑时钟从未离开播放头，这里只归还物理传输位置；不 advance
        // discontinuity，画布回落由 hoverPreviewTime = nil 的发布驱动。
        let target = EditorPlaybackClockPolicy.clampedTime(
            outputTime,
            duration: duration
        )
        seekToken &+= 1
        let requestedSeek = seekToken
        let requestedGeneration = endpoints?.generation
        primaryPlayer.cancelPendingSeeks()
        Task { [weak self] in
            let finished = await primaryPlayer.seekTransport(
                to: CMTime(seconds: target, preferredTimescale: 60_000),
                toleranceBefore: .zero,
                toleranceAfter: .zero
            )
            guard let self,
                  self.seekToken == requestedSeek,
                  self.endpoints?.generation == requestedGeneration,
                  finished else { return }
            self.synchronizeCamera(to: target, force: true)
        }
    }

    private func scheduleHoverSeekIfNeeded() {
        guard hoverSeekTask == nil else { return }
        hoverSeekTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: .milliseconds(33))
            } catch {
                return
            }
            guard let self, !self.isPlaying, !self.scrubIsActive else { return }
            self.hoverSeekTask = nil
            guard let target = self.hoverSeekCoalescer.takePending() else { return }
            self.performHoverSeek(to: target)
            if self.hoverSeekCoalescer.pendingTarget != nil {
                self.scheduleHoverSeekIfNeeded()
            }
        }
    }

    private func performHoverSeek(to target: TimeInterval) {
        guard let primaryPlayer, !isPlaying, !scrubIsActive else { return }
        let requestedHoverGeneration = hoverSeekGeneration
        hoverSeekInFlightCount += 1
        seekToken &+= 1
        let requestedSeek = seekToken
        let requestedGeneration = endpoints?.generation
        cameraSeekToken &+= 1
        cameraSeekIsPending = false
        cameraPlayer?.cancelPendingSeeks()
        primaryPlayer.cancelPendingSeeks()
        Task { [weak self] in
            let finished = await primaryPlayer.seekTransport(
                to: CMTime(seconds: target, preferredTimescale: 60_000),
                toleranceBefore: .zero,
                toleranceAfter: .zero
            )
            guard let self else { return }
            let belongsToCurrentHoverSession = self.hoverSeekGeneration
                == requestedHoverGeneration
            if belongsToCurrentHoverSession {
                self.hoverSeekInFlightCount = max(self.hoverSeekInFlightCount - 1, 0)
            }
            guard belongsToCurrentHoverSession,
                  self.seekToken == requestedSeek,
                  self.endpoints?.generation == requestedGeneration,
                  finished else { return }
            // 帧已进视频输出再发布：画布这一次重绘即可取到所指帧，避免
            // “先发布时刻、后等 seek”造成的双倍求值与旧帧闪回。
            self.hoverPreviewTime = target
            self.synchronizeCamera(to: target, force: true)
            self.advanceDiscontinuity()
        }
    }
}
