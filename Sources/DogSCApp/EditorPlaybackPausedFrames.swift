import AppKit
import AVFoundation

/// 暂停精确帧双路解码（PRE-014/PRE-018），从
/// `EditorPlaybackController.swift` 拆出以满足架构行数预算。主声明里放宽到
/// 模块内访问的暂停帧任务/令牌/请求数组只允许这里的代码写入。
extension EditorPlaybackController {
    func refreshPausedFrames(at time: TimeInterval, seekToken: UInt64? = nil) {
        guard isPreviewActive, let preparedMedia, !isPlaying else { return }
        let requestedGeneration = preparedMedia.generation
        let requestedSeek = seekToken ?? self.seekToken
        let pausedFrameRate = max(frameRate, 1)
        let frame = floor(EditorPlaybackClockPolicy.clampedTime(time, duration: duration)
            * Double(pausedFrameRate))
        let requestedTime = CMTime(
            seconds: frame / Double(pausedFrameRate),
            preferredTimescale: 60_000
        )
        let primaryAsset = ImmutablePreviewAsset(
            preparedMedia.composition.primaryComposition,
            videoComposition: preparedMedia.composition.primaryVideoComposition
        )
        let cameraAsset = preparedMedia.composition.cameraComposition.map {
            ImmutablePreviewAsset($0)
        }
        let shouldLoadCamera = cameraIsAvailable(at: frame / Double(pausedFrameRate))
        cancelPausedFrameDecode()
        // Own the generators for the whole request: Task cancellation alone
        // would leave them decoding in the background during fast scrubbing.
        let screenRequest = PausedPreviewFrameRequest(
            primaryAsset.asset,
            videoComposition: primaryAsset.videoComposition
        )
        let cameraRequest = shouldLoadCamera
            ? cameraAsset.map { PausedPreviewFrameRequest($0.asset) }
            : nil
        pausedFrameRequests = [screenRequest] + (cameraRequest.map { [$0] } ?? [])
        let requestedDecode = pausedFrameDecodeToken
        pausedFrameTask = Task { [weak self] in
            // The screen and camera compositions have independent generators.
            // Waiting for them serially made every pause/cut/scrub on a camera
            // project pay both exact-seek latencies before either frame could
            // be published. Structured children keep cancellation ownership
            // while reducing the refresh to the slower of the two branches.
            async let screenImageTask = try? await screenRequest.image(at: requestedTime)
            async let cameraImageTask: CGImage? = {
                guard let cameraRequest else { return nil }
                return try? await cameraRequest.image(at: requestedTime)
            }()
            let (screenImage, cameraImage) = await (
                screenImageTask,
                cameraImageTask
            )
            guard !Task.isCancelled else { return }
            await MainActor.run {
                guard let self,
                      self.preparedMedia?.generation == requestedGeneration,
                      self.seekToken == requestedSeek,
                      self.pausedFrameDecodeToken == requestedDecode,
                      !self.isPlaying else { return }
                if let screenImage {
                    self.pausedScreenImage = NSImage(cgImage: screenImage,
                        size: NSSize(width: screenImage.width, height: screenImage.height))
                }
                if let cameraImage {
                    self.pausedCameraImage = NSImage(cgImage: cameraImage,
                        size: NSSize(width: cameraImage.width, height: cameraImage.height))
                } else if !shouldLoadCamera {
                    self.pausedCameraImage = nil
                }
                self.pausedFrameTask = nil
                self.pausedFrameRequests.removeAll(keepingCapacity: true)
            }
        }
    }

    func cancelPausedFrameDecode() {
        pausedFrameDecodeToken &+= 1
        pausedFrameTask?.cancel()
        pausedFrameTask = nil
        pausedFrameRequests.forEach { $0.cancel() }
        pausedFrameRequests.removeAll(keepingCapacity: true)
    }
}
