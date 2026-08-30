import AVFoundation
import CoreImage
import Foundation

/// Serial, forward-only decoder used by the export video queue. The wallpaper
/// loops against output time and is intentionally silent; project audio remains
/// exclusively owned by the recorded system/microphone tracks.
final class ExportLoopingWallpaperVideoReader: @unchecked Sendable {
    private let source: LoadedVideoAsset
    private let duration: TimeInterval
    private var reader: AVAssetReader?
    private var output: AVAssetReaderTrackOutput?
    private var nextSample: CMSampleBuffer?
    private var currentBuffer: CVPixelBuffer?
    private var loopIndex: Int = -1
    private var currentLocalTime: TimeInterval = -1

    init(source: LoadedVideoAsset) throws {
        self.source = source
        duration = source.timeRange.duration.seconds
        guard duration.isFinite, duration > 0 else {
            throw VideoExporterError.unusableMediaRange(.wallpaper)
        }
    }

    func frame(at outputTime: TimeInterval) throws -> CIImage? {
        let safeOutputTime = max(outputTime.isFinite ? outputTime : 0, 0)
        let nextLoopIndex = Int(floor(safeOutputTime / duration))
        let targetLocal = safeOutputTime.truncatingRemainder(dividingBy: duration)
        if reader == nil || nextLoopIndex != loopIndex || targetLocal < currentLocalTime {
            try resetReader()
            loopIndex = nextLoopIndex
        }
        currentLocalTime = targetLocal

        while let sample = nextSample {
            let localSampleTime = sample.presentationTimeStamp.seconds
                - source.timeRange.start.seconds
            guard localSampleTime <= targetLocal + 0.000_5 else { break }
            currentBuffer = sample.imageBuffer
            nextSample = output?.copyNextSampleBuffer()
        }
        if currentBuffer == nil, let sample = nextSample {
            currentBuffer = sample.imageBuffer
        }
        if reader?.status == .failed {
            throw reader?.error
                ?? VideoExporterError.cannotReadMediaTrack(
                    role: .wallpaper,
                    media: .video
                )
        }
        guard let currentBuffer else { return nil }
        return VideoExporter.orientVideoFrameForDisplay(
            CIImage(cvPixelBuffer: currentBuffer),
            preferredTransform: source.preferredTransform
        )
    }

    private func resetReader() throws {
        let reader = try AVAssetReader(asset: source.asset)
        reader.timeRange = source.timeRange
        let output = AVAssetReaderTrackOutput(
            track: source.track,
            outputSettings: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            ]
        )
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else {
            throw VideoExporterError.cannotReadMediaTrack(
                role: .wallpaper,
                media: .video
            )
        }
        reader.add(output)
        guard reader.startReading() else {
            throw reader.error
                ?? VideoExporterError.cannotReadMediaTrack(
                    role: .wallpaper,
                    media: .video
                )
        }
        self.reader = reader
        self.output = output
        nextSample = output.copyNextSampleBuffer()
        currentBuffer = nil
        currentLocalTime = -1
    }
}
