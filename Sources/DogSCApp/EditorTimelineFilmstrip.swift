import OSLog
import SwiftUI

/// Height-sized source pictures, sampled only inside the buffered viewport.
/// Clip duration changes the number of pictures, never their aspect ratio.
struct EditorTimelineFilmstrip: View {
    @ObservedObject var mediaSession: EditorMediaSession
    let sourceStart: TimeInterval
    let sourceDuration: TimeInterval
    let visibleRange: ClosedRange<CGFloat>
    let priorityRange: ClosedRange<CGFloat>
    let isEnabled: Bool
    @Environment(\.editorIsActive) private var isEditorActive
    @Environment(\.accessibilityReduceMotion) private var reducesMotion
    @State private var frameSource: SourceIdentity?
    @State private var frames: [Int64: CGImage] = [:]
    @State private var frameReveals: [Int64: FrameReveal] = [:]
    @State private var latestRevealDate: Date?

    private static let revealDuration: TimeInterval = 0.18
    private static let logger = Logger(subsystem: "cn.laogou.dogsc", category: "timeline-filmstrip")

    private struct FrameReveal {
        let previous: CGImage
        let startedAt: Date
    }

    private struct Sample: Equatable {
        let timeValue: Int64
        let toleranceValue: Int64
    }

    private struct Tile {
        let index: Int
        let origin: CGFloat
        let width: CGFloat
        let sample: Sample
    }

    private struct Request: Equatable {
        let generation: UInt64?
        let source: SourceIdentity?
        let sourceStart: TimeInterval
        let sourceDuration: TimeInterval
        let samples: [Sample]
        let priorityTimes: Set<Int64>
        let isEnabled: Bool
        let isEditorActive: Bool
    }

    private struct SourceIdentity: Equatable {
        let input: EditorMediaInput
        let timeOffset: TimeInterval
    }

    private var sourceIdentity: SourceIdentity? {
        guard let prepared = mediaSession.prepared, let input = prepared.request.source else { return nil }
        return SourceIdentity(input: input, timeOffset: prepared.plan.primarySourceTimeOffset)
    }

    var body: some View {
        GeometryReader { geometry in
            let tiles = visibleTiles(size: geometry.size)
            let drawingOrigin = tiles.first?.origin ?? 0
            let drawingEnd = tiles.last.map { $0.origin + $0.width } ?? drawingOrigin
            let source = sourceIdentity
            let cached = availableFrames(for: source)
            let request = makeRequest(tiles: tiles, source: source)
            // Loading belongs to this stable container. Its identity excludes
            // pixel geometry and is independent of the reveal animation clock.
            ZStack(alignment: .topLeading) {
                TimelineView(.animation(minimumInterval: 1.0 / 30,
                    paused: frameReveals.isEmpty || !isEnabled || !isEditorActive)) { tick in
                    Canvas { context, size in
                        guard source != nil, source == sourceIdentity else { return }
                        for tile in tiles {
                            let time = tile.sample.timeValue
                            guard let frame = nearestFrame(to: time, in: cached) else { continue }
                            if cached[time] != nil, let reveal = frameReveals[time],
                               tick.date.timeIntervalSince(reveal.startedAt) < Self.revealDuration {
                                let progress = min(max(tick.date.timeIntervalSince(reveal.startedAt)
                                    / Self.revealDuration, 0), 1)
                                // Keep the old picture opaque until the new one
                                // covers it; never expose an empty midpoint.
                                draw(reveal.previous, tile: tile, origin: drawingOrigin,
                                    height: size.height, context: context)
                                draw(frame, tile: tile, origin: drawingOrigin,
                                    height: size.height, context: context,
                                    opacity: 1 - pow(1 - progress, 3))
                            } else {
                                draw(frame, tile: tile, origin: drawingOrigin,
                                    height: size.height, context: context)
                            }
                        }
                    }
                    // A zoomed hour-long clip must not allocate a document-wide bitmap.
                    .frame(width: max(drawingEnd - drawingOrigin, 1), height: geometry.size.height)
                    .offset(x: drawingOrigin)
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height, alignment: .topLeading)
            .task(id: request) { await load(request) }
            .task(id: latestRevealDate) {
                guard latestRevealDate != nil else { return }
                do { try await Task.sleep(for: .milliseconds(180)) } catch { return }
                guard !Task.isCancelled else { return }
                frameReveals = frameReveals.filter {
                    Date().timeIntervalSince($0.value.startedAt) < Self.revealDuration
                }
            }
        }
        .background(EditorTheme.panelRaised)
        .clipped()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private func visibleTiles(size: CGSize) -> [Tile] {
        guard size.width.isFinite, size.width > 0, size.height.isFinite, size.height > 0,
              sourceStart.isFinite, sourceDuration.isFinite, sourceDuration > 0,
              visibleRange.upperBound > 0, visibleRange.lowerBound < size.width
        else { return [] }
        let sourceSize = mediaSession.sourceDisplaySize
        let aspect = sourceSize.width.isFinite && sourceSize.height.isFinite
            && sourceSize.width > 0 && sourceSize.height > 0
            ? sourceSize.width / sourceSize.height : 16.0 / 9.0
        // Full tiles follow the source aspect. Short clips/tails crop the same
        // full-height picture horizontally instead of shrinking its height.
        let tileWidth = max(size.height * aspect, 40)
        let first = max(Int(floor(max(visibleRange.lowerBound, 0) / tileWidth)), 0)
        let end = Int(ceil(min(visibleRange.upperBound, size.width) / tileWidth))
        guard end > first else { return [] }
        return (first..<end).map { index in
            let origin = CGFloat(index) * tileWidth
            let width = min(tileWidth, size.width - origin)
            let rawTime = sourceStart + sourceDuration * Double((origin + width / 2) / size.width)
            // A small, stable source-time grid improves reuse during zoom/trim.
            // Bounds and tolerance keep a thumbnail inside its retained source clip.
            let firstTimeValue = Int64(ceil(sourceStart * 600))
            let lastTimeValue = max(firstTimeValue, Int64(floor((sourceStart + sourceDuration) * 600)) - 1)
            let timeValue = min(max(Int64((rawTime * 15).rounded()) * 40, firstTimeValue), lastTimeValue)
            let time = Double(timeValue) / 600
            let tolerance = max(min(0.12, sourceDuration * Double(width / size.width) / 4,
                time - sourceStart, sourceStart + sourceDuration - time), 0)
            // Tolerance changes within a 20 ms bucket do not restart decoding
            // for subpixel layout changes; always round down to stay in bounds.
            let toleranceValue = Int64(floor(tolerance * 50)) * 12
            return Tile(index: index, origin: origin, width: width,
                sample: Sample(timeValue: timeValue, toleranceValue: toleranceValue))
        }
    }

    private func makeRequest(tiles: [Tile], source: SourceIdentity?) -> Request {
        let priority = tiles.filter {
            $0.origin + $0.width > priorityRange.lowerBound && $0.origin < priorityRange.upperBound
        }
        let priorityIndices = Set(priority.map(\.index))
        let ordered = priority + tiles.filter { !priorityIndices.contains($0.index) }
        var seen: Set<Int64> = []
        let samples = ordered.compactMap { tile in
            seen.insert(tile.sample.timeValue).inserted ? tile.sample : nil
        }
        return Request(generation: mediaSession.prepared?.generation, source: source,
            sourceStart: sourceStart, sourceDuration: sourceDuration, samples: samples,
            priorityTimes: Set(priority.map { $0.sample.timeValue }),
            isEnabled: isEnabled, isEditorActive: isEditorActive)
    }

    private func load(_ request: Request) async {
        guard request.isEnabled, request.isEditorActive,
              let source = request.source, requestIsCurrent(request),
              !request.samples.isEmpty else { return }
        let requestedTimes = Set(request.samples.map(\.timeValue))
        // A zoom changes sample times. Keep compatible old pictures visible
        // until the replacement samples arrive instead of publishing emptiness.
        var decoded = availableFrames(for: source)
        publish(decoded, source: source, request: request)
        if requestedTimes.allSatisfy({ decoded[$0] != nil }) {
            return
        }
        // Cancel fast sweeps, but reveal the first useful picture promptly.
        // Buffered-only clips wait longer so they don't queue ahead of the
        // pictures actually on screen when many short clips become visible.
        do {
            try await Task.sleep(for: .milliseconds(request.priorityTimes.isEmpty ? 180 : 45))
        } catch { return }
        // A failed decode must not finish the task and leave a cached fallback
        // forever. Retry only missing samples, with bounded, cancellable backoff.
        for attempt in 0..<3 {
            guard requestIsCurrent(request) else { return }
            let shared = mediaSession.filmstripCachedFrames(sourceStart: sourceStart, sourceDuration: sourceDuration)
            decoded.merge(shared) { existing, _ in existing }
            var unpublishedCount = 0
            var hasPublishedNewFrame = false
            for sample in request.samples where decoded[sample.timeValue] == nil {
                guard requestIsCurrent(request) else { return }
                if let frame = await mediaSession.filmstripThumbnail(
                    atSourceTime: Double(sample.timeValue) / 600,
                    tolerance: Double(sample.toleranceValue) / 600
                ) {
                    guard requestIsCurrent(request) else { return }
                    decoded[sample.timeValue] = frame
                    unpublishedCount += 1
                    // The first frame is immediate, then publish small batches.
                    if !hasPublishedNewFrame || unpublishedCount == 3 {
                        publish(decoded, source: source, request: request)
                        unpublishedCount = 0
                        hasPublishedNewFrame = true
                    }
                }
                await Task.yield()
            }
            guard requestIsCurrent(request) else { return }
            publish(decoded, source: source, request: request)
            if requestedTimes.allSatisfy({ decoded[$0] != nil }) { return }
            if attempt < 2 {
                do { try await Task.sleep(for: .milliseconds(attempt == 0 ? 300 : 1_200)) }
                catch { return }
            }
        }
        let missing = requestedTimes.filter { decoded[$0] == nil }.count
        Self.logger.warning("Filmstrip still missing \(missing) samples after three attempts")
    }

    private func requestIsCurrent(_ request: Request) -> Bool {
        !Task.isCancelled && request.generation == mediaSession.prepared?.generation
            && request.source == sourceIdentity
    }

    private func availableFrames(for source: SourceIdentity?) -> [Int64: CGImage] {
        guard source != nil, source == sourceIdentity else { return [:] }
        return compatibleFrames(for: source).merging(mediaSession.filmstripCachedFrames(
            sourceStart: sourceStart, sourceDuration: sourceDuration)) { existing, _ in existing }
    }

    private func compatibleFrames(for source: SourceIdentity?) -> [Int64: CGImage] {
        guard source != nil, frameSource == source else { return [:] }
        return frames.filter {
            let time = Double($0.key) / 600
            return time >= sourceStart && time < sourceStart + sourceDuration
        }
    }

    private func nearestFrame(to time: Int64, in images: [Int64: CGImage]) -> CGImage? {
        images[time] ?? images.min {
            let left = abs(Double($0.key) - Double(time))
            let right = abs(Double($1.key) - Double(time))
            return left == right ? $0.key < $1.key : left < right
        }?.value
    }

    private func draw(_ frame: CGImage, tile: Tile, origin: CGFloat,
                      height: CGFloat, context: GraphicsContext, opacity: Double = 1) {
        let scale = height / CGFloat(frame.height)
        let pictureSize = CGSize(width: CGFloat(frame.width) * scale, height: CGFloat(frame.height) * scale)
        let rect = CGRect(x: tile.origin - origin + (tile.width - pictureSize.width) / 2,
            y: (height - pictureSize.height) / 2, width: pictureSize.width, height: pictureSize.height)
        var layer = context
        layer.clip(to: Path(CGRect(x: tile.origin - origin, y: 0, width: tile.width, height: height)))
        layer.opacity = opacity
        layer.draw(Image(decorative: frame, scale: 1), in: rect)
    }

    private func publish(_ decoded: [Int64: CGImage], source: SourceIdentity, request: Request) {
        let requested = Set(request.samples.map(\.timeValue))
        let center = request.samples.isEmpty ? 0 : request.samples.map { Double($0.timeValue) }.reduce(0, +)
            / Double(request.samples.count)
        // Retain the current viewport and a small fallback reservoir, not every
        // zoom level ever visited. Both local storage and active reveals are bounded.
        let limit = min(max(requested.count * 2, 32), 160)
        func rank(_ time: Int64) -> Int {
            request.priorityTimes.contains(time) ? 0 : (requested.contains(time) ? 1 : 2)
        }
        let retained = Dictionary(uniqueKeysWithValues: decoded.keys.sorted {
            if rank($0) != rank($1) { return rank($0) < rank($1) }
            let left = abs(Double($0) - center), right = abs(Double($1) - center)
            return left == right ? $0 < $1 : left < right
        }.prefix(limit).compactMap { time in decoded[time].map { (time, $0) } })
        let previous = compatibleFrames(for: source)
        let now = Date()
        var reveals = frameSource == source ? frameReveals.filter {
            retained[$0.key] != nil && now.timeIntervalSince($0.value.startedAt) < Self.revealDuration
        } : [:]
        if !reducesMotion {
            for time in retained.keys where previous[time] == nil {
                if let image = nearestFrame(to: time, in: previous) {
                    reveals[time] = FrameReveal(previous: image, startedAt: now)
                }
            }
        }
        withTransaction(Transaction(animation: nil)) {
            frames = retained
            frameSource = source
            frameReveals = reveals
            latestRevealDate = reveals.isEmpty ? nil : now
        }
    }
}
