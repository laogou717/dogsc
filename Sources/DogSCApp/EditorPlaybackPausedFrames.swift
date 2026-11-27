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
        let pausedFrameRate = max(frameRate(atOutputTime: time), 1)
        let target = EditorPlaybackClockPolicy.frameLookupTime(time, duration: duration)
        let gridTime = floor(target * Double(pausedFrameRate)) / Double(pausedFrameRate)
        let targetFrame = preparedMedia.composition.frameMetadata(at: target)
        let gridFrame = preparedMedia.composition.frameMetadata(at: gridTime)
        // A fractional cut can be later than the containing grid frame. Seek
        // in the target slice before converting its asset time to CMTime.
        let sameSlices = targetFrame.screenSlice?.id == gridFrame.screenSlice?.id
            && targetFrame.cameraSlice?.id == gridFrame.cameraSlice?.id
        let requestedTime = sameSlices ? gridTime : target
        guard let primaryInput = preparedMedia.screenFrameInput(at: requestedTime) else { return }
        let cameraInput = preparedMedia.cameraFrameInput(at: requestedTime)
        let shouldLoadCamera = cameraInput != nil
        cancelPausedFrameDecode()
        let screenRequest = PausedPreviewFrameRequest(primaryInput.asset.asset)
        let cameraRequest = cameraInput.map { PausedPreviewFrameRequest($0.asset.asset) }
        let screenTime = CMTime(seconds: primaryInput.assetTime, preferredTimescale: 60_000)
        let cameraTime = CMTime(seconds: cameraInput?.assetTime ?? 0, preferredTimescale: 60_000)
        pausedFrameRequests = [screenRequest] + (cameraRequest.map { [$0] } ?? [])
        let requestedDecode = pausedFrameDecodeToken
        let imageInput = targetFrame.screenSlice.flatMap { slice in
            slice.media?.imagePath.map { path in
                (ProjectFiles.url(path), slice.sourceStart + max(requestedTime - slice.outputStart, 0) * slice.sourceTimeScale)
            }
        }
        pausedFrameTask = Task { [weak self] in
            // The screen and camera compositions have independent generators.
            // Waiting for them serially made every pause/cut/scrub on a camera
            // project pay both exact-seek latencies before either frame could
            // be published. Structured children keep cancellation ownership
            // while reducing the refresh to the slower of the two branches.
            async let screenImageTask: CGImage? = {
                if let (url, localTime) = imageInput {
                    return ImageMediaFrameCache.shared.cgImage(at: url, time: localTime)
                }
                return try? await screenRequest.image(at: screenTime)
            }()
            async let cameraImageTask: CGImage? = {
                guard let cameraRequest else { return nil }
                return try? await cameraRequest.image(at: cameraTime)
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
                    self.pausedScreenSegmentID = targetFrame.screenSlice?.segmentID
                    self.pausedScreenImage = NSImage(cgImage: screenImage,
                        size: NSSize(width: screenImage.width, height: screenImage.height))
                }
                if let cameraImage {
                    self.pausedCameraSourceID = targetFrame.cameraSlice?.sourceID
                    self.pausedCameraImage = NSImage(cgImage: cameraImage,
                        size: NSSize(width: cameraImage.width, height: cameraImage.height))
                } else if !shouldLoadCamera {
                    self.pausedCameraSourceID = nil
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
