import AVFoundation
import RecorderCore

enum OverlayVideoSource {
    /// Audio can outlast the picture in the same container.
    static func end(of url: URL) async throws -> Double {
        let asset = AVURLAsset(url: url, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
        guard let track = try await asset.loadTracks(withMediaType: .video).first else {
            throw VideoSourceError.unreadable(name: url.lastPathComponent)
        }
        let range = try await track.load(.timeRange)
        let end = range.duration.seconds
        guard end.isFinite, end > 0 else {
            throw VideoSourceError.unreadable(name: url.lastPathComponent)
        }
        return end
    }

    /// Resolve against the package being opened, even when another project is active.
    /// Keep every source frame the old edit can actually play, at its original output time.
    static func resolve(_ clips: [VideoClip], in session: RecordingSession) async throws
        -> (clips: [VideoClip], shortened: Int, empty: Int) {
        var ends: [String: Double] = [:]
        var unavailable = Set<String>()
        var result: [VideoClip] = []
        var shortened = 0
        var empty = 0
        for var clip in clips {
            try Task.checkCancellation()
            let path = clip.sourcePath
            if ends[path] == nil, !unavailable.contains(path) {
                if let url = ProjectStore.resolveMediaPath(path, session: session),
                   let end = try? await end(of: url) { ends[path] = end }
                else { unavailable.insert(path) }
            }
            if let end = ends[path] {
                clip.sourceFileEnd = end
                guard clip.sourceStart < end else { empty += 1; continue }
                if clip.sourceEnd > end + VideoClip.sourceTimeTolerance {
                    clip.timing.duration = (end - clip.sourceStart) / clip.playbackRate
                    shortened += 1
                }
            }
            result.append(clip)
        }
        try Task.checkCancellation()
        return (result, shortened, empty)
    }

    static func validateExport(_ request: EditorExportRequest) async throws {
        let start = request.outputRange?.start ?? 0
        let end = request.outputRange?.end ?? request.mediaPlan.timelineMap.outputDuration
        var ends: [String: Double] = [:]
        for var clip in request.project.timeline.videoClips where clip.opacity > 0 {
            let first = max(start, clip.timing.startTime)
            let last = min(end, clip.timing.endTime)
            guard first < last else { continue }
            try Task.checkCancellation()
            if ends[clip.sourcePath] == nil {
                ends[clip.sourcePath] = try await self.end(of: ProjectFiles.url(clip.sourcePath))
            }
            clip.sourceFileEnd = ends[clip.sourcePath]
            clip.sourceStart += (first - clip.timing.startTime) * clip.playbackRate
            clip.timing = OverlayTiming(startTime: first, duration: last - first)
            try clip.validateSourceRange()
        }
    }
}
