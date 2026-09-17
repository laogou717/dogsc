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
    @State private var frameSource: SourceIdentity?
    @State private var frames: [Int64: CGImage] = [:]

    private struct Tile: Identifiable, Hashable {
        let index: Int
        let origin: CGFloat
        let width: CGFloat
        let timeValue: Int64
        let tolerance: TimeInterval
        var id: Int { index }
    }

    private struct Request: Hashable {
        let generation: UInt64?
        let sourcePath: String?
        let tiles: [Tile]
        let priorityIndices: [Int]
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
            let request = Request(generation: mediaSession.prepared?.generation,
                sourcePath: mediaSession.prepared?.request.source?.version.standardizedPath,
                tiles: tiles,
                priorityIndices: tiles.filter {
                    $0.origin + $0.width > priorityRange.lowerBound && $0.origin < priorityRange.upperBound
                }.map(\.index),
                isEnabled: isEnabled, isEditorActive: isEditorActive)
            Canvas { context, size in
                guard frameSource != nil, frameSource == sourceIdentity else { return }
                for tile in tiles {
                    guard let frame = frames[tile.timeValue] else { continue }
                    let scale = min(tile.width / CGFloat(frame.width),
                        size.height / CGFloat(frame.height))
                    let pictureSize = CGSize(width: CGFloat(frame.width) * scale,
                        height: CGFloat(frame.height) * scale)
                    let rect = CGRect(x: tile.origin - drawingOrigin + (tile.width - pictureSize.width) / 2,
                        y: (size.height - pictureSize.height) / 2,
                        width: pictureSize.width, height: pictureSize.height)
                    context.draw(Image(decorative: frame, scale: 1), in: rect)
                }
            }
            // The native drawing surface is viewport-sized too. A zoomed
            // hour-long clip must not allocate one document-wide bitmap.
            .frame(width: max(drawingEnd - drawingOrigin, 1), height: geometry.size.height)
            .offset(x: drawingOrigin)
            .task(id: request) { await load(request) }
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
        // Extremely narrow recordings still get a usable tile; aspect-fit
        // leaves quiet space instead of enlarging and cropping their content.
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
            return Tile(index: index, origin: origin, width: width,
                timeValue: timeValue, tolerance: tolerance)
        }
    }

    private func load(_ request: Request) async {
        guard request.isEnabled, request.isEditorActive,
              let generation = request.generation, let source = sourceIdentity,
              !request.tiles.isEmpty else { return }
        // Retain overlapping pictures while scrolling, but keep per-clip
        // storage bounded to the new viewport, not the length of the recording.
        let requestedTimes = Set(request.tiles.map(\.timeValue))
        // A reordered timeline gets a new preparation generation, while its
        // source pictures remain valid. Reuse them by file version and source
        // time instead of blanking the strip on every edit.
        var decoded = frameSource == source
            ? frames.filter { requestedTimes.contains($0.key) } : [:]
        if frameSource != source || decoded.count != frames.count {
            publish(decoded, source: source)
        }
        if decoded.count == requestedTimes.count { return }
        // Cancel fast sweeps, but reveal the first useful picture promptly.
        do { try await Task.sleep(for: .milliseconds(45)) } catch { return }
        let priority = Set(request.priorityIndices)
        let ordered = request.tiles.filter { priority.contains($0.index) }
            + request.tiles.filter { !priority.contains($0.index) }
        var unpublishedCount = 0
        var hasPublishedNewFrame = false
        for tile in ordered where decoded[tile.timeValue] == nil {
            guard !Task.isCancelled else { return }
            if let frame = await mediaSession.filmstripThumbnail(
                atSourceTime: Double(tile.timeValue) / 600, tolerance: tile.tolerance
            ) {
                guard !Task.isCancelled, mediaSession.prepared?.generation == generation else { return }
                decoded[tile.timeValue] = frame
                unpublishedCount += 1
                // Small batches reveal useful pictures promptly without one
                // SwiftUI state publication for every returned video frame.
                if !hasPublishedNewFrame || unpublishedCount == 3 {
                    publish(decoded, source: source)
                    unpublishedCount = 0
                    hasPublishedNewFrame = true
                }
            }
            await Task.yield()
        }
        guard !Task.isCancelled, mediaSession.prepared?.generation == generation else { return }
        publish(decoded, source: source)
    }

    private func publish(_ decoded: [Int64: CGImage], source: SourceIdentity) {
        withTransaction(Transaction(animation: nil)) {
            frames = decoded
            frameSource = source
        }
    }
}
