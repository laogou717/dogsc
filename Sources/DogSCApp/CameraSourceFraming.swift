import AVFoundation
import os

/// Used only on the recorder's serial sample queue. Some UVC cameras advertise both
/// orientations, but embed the actual picture in a black frame when they disagree.
final class CameraSourceFraming {
    private static let logger = Logger(subsystem: "cn.laogou.dogsc", category: "camera-recorder")
    private let requestNativeSize: (Int, Int) -> Bool
    private var size = CGSize.zero
    private var nextProbe = 0.0
    private var settleUntil = 0.0
    private var firstFrame = 0.0
    private var nativeSamples = 0
    private var paddedSamples = 0
    private var lastSwitch = -Double.infinity
    private var cropPool: CVPixelBufferPool?
    private let cropper = CameraSampleWriterFrameNormalizer()

    init(requestNativeSize: @escaping (Int, Int) -> Bool) {
        self.requestNativeSize = requestNativeSize
    }

    func sample(from sample: CMSampleBuffer, settling: Bool) -> CMSampleBuffer? {
        guard sample.isValid, CMSampleBufferDataIsReady(sample), let image = sample.imageBuffer else { return sample }
        let width = CVPixelBufferGetWidth(image), height = CVPixelBufferGetHeight(image)
        let now = CACurrentMediaTime()
        if size != CGSize(width: width, height: height) {
            size = CGSize(width: width, height: height)
            firstFrame = now
            nextProbe = now
            settleUntil = now
            nativeSamples = 0
            paddedSamples = 0
            cropPool = nil
        }
        guard min(width, height) >= 32, Double(max(width, height)) > Double(min(width, height)) * 1.2 else { return sample }
        let short = min(width, height)
        let inner = 2 * Int((Double(short * short) / Double(max(width, height)) / 2).rounded())
        // UVC startup can contain a stale or dark frame. Don't make that frame
        // determine the dimensions of the recording for the entire take.
        let confirming = settling && now - firstFrame < 1.5 && nativeSamples < 3
        if now >= nextProbe {
            switch Self.evidence(in: image, format: sample.formatDescription, inner: inner) {
            case .native:
                paddedSamples = 0
                nativeSamples = min(3, nativeSamples + 1)
                cropPool = nil
                settleUntil = now
                if confirming && nativeSamples < 3 { return nil }
            case .uncertain:
                if paddedSamples < 3 {
                    paddedSamples = 0
                    if confirming {
                        nativeSamples = 0
                        return nil
                    }
                }
            case .padded:
                nativeSamples = 0
                if paddedSamples < 3 {
                    paddedSamples += 1
                    if paddedSamples < 3 { return confirming ? nil : sample }
                    if now - lastSwitch > 1, requestNativeSize(height, width) {
                        lastSwitch = now
                        settleUntil = now + 1.25
                    }
                }
            }
            nextProbe = now + 0.25
        }
        guard paddedSamples == 3 else { return sample }
        if settling, now < settleUntil { return nil }
        // No reciprocal native mode, or the device continued delivering padded buffers.
        // Keep the centre's real pixel resolution and the original sample timestamp.
        let cropWidth = width > height ? inner : width
        let cropHeight = width > height ? height : inner
        return cropped(sample, image: image, width: cropWidth, height: cropHeight) ?? sample
    }

    enum Evidence { case native, padded, uncertain }

    private static func evidence(in image: CVPixelBuffer, format: CMFormatDescription?, inner: Int) -> Evidence {
        let w = CVPixelBufferGetWidth(image), h = CVPixelBufferGetHeight(image)
        let verticalBars = w > h
        let long = max(w, h), short = min(w, h)
        let edge = (long - inner) / 2
        guard edge > 4, inner >= 8 else { return .native }
        if let format {
            let clean = CMVideoFormatDescriptionGetCleanAperture(format, originIsAtTopLeft: true)
            let expected = verticalBars ? CGRect(x: edge, y: 0, width: inner, height: h)
                                        : CGRect(x: 0, y: edge, width: w, height: inner)
            if abs(clean.minX - expected.minX) <= 2, abs(clean.minY - expected.minY) <= 2,
               abs(clean.width - expected.width) <= 4, abs(clean.height - expected.height) <= 4 {
                return .padded
            }
        }
        guard CVPixelBufferGetPixelFormatType(image) == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
              CameraPixelBufferLayout(image).isStructurallyValid,
              CVPixelBufferGetBytesPerRowOfPlane(image, 1) >= (w + 1) / 2 * 2,
              CVPixelBufferLockBaseAddress(image, .readOnly) == kCVReturnSuccess else { return .uncertain }
        defer { CVPixelBufferUnlockBaseAddress(image, .readOnly) }
        guard let plane = CVPixelBufferGetBaseAddressOfPlane(image, 0),
              let chroma = CVPixelBufferGetBaseAddressOfPlane(image, 1) else { return .uncertain }
        let luma = plane.assumingMemoryBound(to: UInt8.self), uv = chroma.assumingMemoryBound(to: UInt8.self)
        let strideY = CVPixelBufferGetBytesPerRowOfPlane(image, 0)
        let strideUV = CVPixelBufferGetBytesPerRowOfPlane(image, 1)
        func containsPicture(_ along: Int) -> Bool {
            for i in 1...15 {
                let across = short * i / 16
                let x = verticalBars ? along : across, y = verticalBars ? across : along
                let c = y / 2 * strideUV + x / 2 * 2
                if luma[y * strideY + x] > 26 || abs(Int(uv[c]) - 128) > 6 || abs(Int(uv[c + 1]) - 128) > 6 {
                    return true
                }
            }
            return false
        }
        // Require neutral black on both sides up to the predicted picture boundary,
        // and visible picture just inside both edges. A dark frame gives no direction.
        for offset in [edge / 8, edge / 2, edge - 3] {
            if containsPicture(offset) || containsPicture(long - 1 - offset) { return .native }
        }
        let inside = edge + max(3, inner / 24)
        return containsPicture(inside) && containsPicture(long - 1 - inside) ? .padded : .uncertain
    }

    private func cropped(_ sample: CMSampleBuffer, image: CVPixelBuffer, width: Int, height: Int) -> CMSampleBuffer? {
        do {
            if cropPool == nil {
                let pixelFormat = CVPixelBufferGetPixelFormatType(image)
                let attrs: [String: Any] = [kCVPixelBufferPixelFormatTypeKey as String: pixelFormat,
                    kCVPixelBufferWidthKey as String: width, kCVPixelBufferHeightKey as String: height,
                    kCVPixelBufferIOSurfacePropertiesKey as String: [:], kCVPixelBufferMetalCompatibilityKey as String: true]
                try cropper.prepareContract(width: width, height: height, pixelFormat: pixelFormat,
                    sourceWidth: CVPixelBufferGetWidth(image), sourceHeight: CVPixelBufferGetHeight(image),
                    sourcePixelFormat: pixelFormat, roleName: MovieCaptureRole.camera.displayName)
                guard CVPixelBufferPoolCreate(nil, nil, attrs as CFDictionary, &cropPool) == kCVReturnSuccess else { return nil }
            }
            let output = try cropper.normalizedImageBuffer(image, pool: cropPool, roleName: MovieCaptureRole.camera.displayName)
            CVBufferRemoveAttachment(output, kCVImageBufferCleanApertureKey)
            let format = try CMVideoFormatDescription(imageBuffer: output)
            return try CMSampleBuffer(imageBuffer: output, formatDescription: format,
                sampleTiming: CMSampleTimingInfo(duration: sample.duration,
                    presentationTimeStamp: sample.presentationTimeStamp, decodeTimeStamp: sample.decodeTimeStamp))
        } catch {
            Self.logger.debug("camera source framing: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }
}
