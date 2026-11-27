import AVFoundation
import CoreImage
import Foundation

/// EDT-054: frames of overlay videos for preview and export. One reader per
/// clip reads forward sequentially (cheap during playback and export) and is
/// recreated at the requested time after a backwards or long jump.
actor VideoOverlayDecoder {
    static let shared = VideoOverlayDecoder()

    private final class Reader {
        let path: String
        let reader: AVAssetReader
        let output: AVAssetReaderTrackOutput
        let transform: CGAffineTransform
        let trackRange: CMTimeRange
        var current: (time: Double, image: CIImage)?
        var next: CMSampleBuffer?
        init(path: String, reader: AVAssetReader, output: AVAssetReaderTrackOutput, transform: CGAffineTransform, trackRange: CMTimeRange) {
            self.path = path
            self.reader = reader
            self.output = output
            self.trackRange = trackRange
            self.transform = transform
        }
    }

    private var readers: [UUID: Reader] = [:]

    func frame(clip id: UUID, path: String, at time: Double) async -> CIImage? {
        guard time.isFinite, time >= 0 else { return nil }
        if let reader = readers[id], reader.path == path, time >= reader.trackRange.duration.seconds { return nil }
        if let reader = readers[id], reader.path == path, let current = reader.current,
           time >= current.time - 0.001, time - current.time < 1.5 {
            return advance(reader, to: time)
        }
        guard let reader = await makeReader(path: path, from: time) else { readers[id] = nil; return nil }
        readers[id] = reader
        return advance(reader, to: time)
    }

    func release(except ids: Set<UUID>) {
        readers = readers.filter { ids.contains($0.key) }
    }

    private func advance(_ reader: Reader, to time: Double) -> CIImage? {
        while true {
            let sample = reader.next ?? reader.output.copyNextSampleBuffer()
            reader.next = nil
            guard let sample else {
                return reader.reader.status == .completed ? reader.current?.image : nil
            }
            let pts = (sample.presentationTimeStamp - reader.trackRange.start).seconds
            if pts > time + 0.0005, reader.current != nil {
                reader.next = sample
                return reader.current?.image
            }
            if let buffer = sample.imageBuffer {
                let image = CIImage(cvImageBuffer: buffer).oriented(forTransform: reader.transform)
                reader.current = (pts, image)
            }
            if pts >= time - 0.0005 { return reader.current?.image }
        }
    }

    private func makeReader(path: String, from time: Double) async -> Reader? {
        let asset = AVURLAsset(url: ProjectFiles.url(path))
        guard let track = try? await asset.loadTracks(withMediaType: .video).first,
              let range = try? await track.load(.timeRange), time < range.duration.seconds,
              let transform = try? await track.load(.preferredTransform),
              let reader = try? AVAssetReader(asset: asset) else { return nil }
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:] as [String: Any],
        ])
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { return nil }
        reader.add(output)
        let start = range.start + CMTime(seconds: max(time - 0.5, 0), preferredTimescale: 60_000)
        reader.timeRange = CMTimeRange(start: start, end: range.end)
        guard reader.startReading() else { return nil }
        return Reader(path: path, reader: reader, output: output, transform: transform, trackRange: range)
    }
}

private extension CIImage {
    func oriented(forTransform transform: CGAffineTransform) -> CIImage {
        guard transform != .identity else { return self }
        let rotated = transformed(by: transform)
        return rotated.transformed(by: CGAffineTransform(translationX: -rotated.extent.minX, y: -rotated.extent.minY))
    }
}
