import AVFoundation
import CoreImage
import RecorderCore

/// Beauty never runs on the capture/writer queue. One pending sample replaces
/// older work; both live surfaces receive the same processed image.
final class CameraBeautyPreviewProcessor: @unchecked Sendable {
    private let sinks: [ImmediateCameraPreviewFrameSink]
    private let lock = NSLock()
    private let queue = DispatchQueue(label: "cn.laogou.dogsc.camera-beauty", qos: .userInteractive)
    private var settings: CameraBeautySettings
    private var revision: UInt64 = 0
    private var pending: CMSampleBuffer?
    private var scheduled = false
    // Accessed only on queue. Reuse colour context and output buffers.
    private lazy var profile = try? CoreImageFrameColorProfile(contract: .sdrDesktop)
    private lazy var context = profile?.makeContext(cacheIntermediates: false)
    private var pool: CVPixelBufferPool?
    private var poolSize = CGSize.zero
    private let beautyTracker = CameraBeautyTracker()
    private var beautyRevision: UInt64?

    init(sinks: [ImmediateCameraPreviewFrameSink], settings: CameraBeautySettings) {
        self.sinks = sinks
        self.settings = settings
    }

    func setSettings(_ value: CameraBeautySettings) {
        lock.lock()
        let togglesProcessing = settings.isEnabled != value.isEnabled
        settings = value
        // Strength sliders can update faster than one processed frame. Keep
        // presenting while dragging; only an on/off transition invalidates
        // in-flight output (so an old beauty frame cannot replace raw video).
        if togglesProcessing {
            revision &+= 1
            pending = nil
        }
        lock.unlock()
    }

    func reset() {
        lock.lock()
        revision &+= 1
        pending = nil
        lock.unlock()
        queue.async { [weak self] in self?.pool = nil }
    }

    func enqueue(_ sample: CMSampleBuffer) {
        guard sinks.contains(where: \.isAttached) else { return }
        lock.lock()
        if !settings.isEnabled {
            sinks.forEach { $0.enqueue(sample) }
            lock.unlock()
            return
        }
        pending = sample
        let shouldSchedule = !scheduled
        scheduled = true
        lock.unlock()
        if shouldSchedule { queue.async { [weak self] in self?.drain() } }
    }

    private func drain() {
        while true {
            lock.lock()
            guard let sample = pending else {
                scheduled = false
                lock.unlock()
                return
            }
            pending = nil
            let settings = settings, revision = revision
            lock.unlock()
            autoreleasepool {
                if beautyRevision != revision {
                    beautyTracker.reset()
                    beautyRevision = revision
                }
                guard let rendered = render(sample, settings: settings) else { return }
                lock.lock()
                if self.revision == revision { sinks.forEach { $0.enqueue(rendered) } }
                lock.unlock()
            }
        }
    }

    private func render(_ sample: CMSampleBuffer, settings: CameraBeautySettings) -> CMSampleBuffer? {
        guard let source = CMSampleBufferGetImageBuffer(sample), let context, let profile else { return nil }
        let size = CGSize(width: CVPixelBufferGetWidth(source), height: CVPixelBufferGetHeight(source))
        if pool == nil || poolSize != size {
            pool = nil
            poolSize = size
            let attributes: [String: Any] = [
                kCVPixelBufferWidthKey as String: Int(size.width),
                kCVPixelBufferHeightKey as String: Int(size.height),
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferIOSurfacePropertiesKey as String: [:],
                kCVPixelBufferMetalCompatibilityKey as String: true
            ]
            guard CVPixelBufferPoolCreate(nil, nil, attributes as CFDictionary, &pool) == kCVReturnSuccess else { return nil }
        }
        guard let pool else { return nil }
        var buffer: CVPixelBuffer?
        let limit = [kCVPixelBufferPoolAllocationThresholdKey as String: 6] as CFDictionary
        guard CVPixelBufferPoolCreatePixelBufferWithAuxAttributes(nil, pool, limit, &buffer) == kCVReturnSuccess,
              let buffer else { return nil }
        // Geometry survives the conversion; input HDR/P3/gamma tags must not
        // override the shared SDR colour contract on the processed buffer.
        for key in [kCVImageBufferCleanApertureKey, kCVImageBufferPixelAspectRatioKey] {
            if let value = CVBufferCopyAttachment(source, key, nil) {
                CVBufferSetAttachment(buffer, key, value, .shouldPropagate)
            }
        }
        profile.applyAttachments(to: buffer)
        let image = CameraBeautyRenderer.apply(to: CIImage(cvPixelBuffer: source), settings: settings,
            tracking: CameraBeautyFrame(tracker: beautyTracker, time: CMSampleBufferGetPresentationTimeStamp(sample).seconds))
        context.render(image, to: buffer, bounds: CGRect(origin: .zero, size: size), colorSpace: profile.outputColorSpace)
        var format: CMVideoFormatDescription?
        guard CMVideoFormatDescriptionCreateForImageBuffer(allocator: nil, imageBuffer: buffer,
            formatDescriptionOut: &format) == noErr, let format else { return nil }
        var timing = CMSampleTimingInfo()
        guard CMSampleBufferGetSampleTimingInfo(sample, at: 0, timingInfoOut: &timing) == noErr else { return nil }
        var output: CMSampleBuffer?
        guard CMSampleBufferCreateReadyWithImageBuffer(allocator: nil, imageBuffer: buffer,
            formatDescription: format, sampleTiming: &timing, sampleBufferOut: &output) == noErr else { return nil }
        return output
    }
}
