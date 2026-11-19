import Foundation

public extension BackgroundSource {
    var sceneResourceKey: String? {
        switch self {
        case let .projectImage(path): "project-image:" + path
        case let .systemImage(path): "system-image:" + path
        case let .projectVideo(path): "project-video:" + path
        case let .systemVideo(path): "system-video:" + path
        case .pattern, .dynamicFlow: nil
        }
    }
}

/// Static appearance of one timeline occurrence. Recording media and timed
/// animation tracks remain in their original domains; the output ratio is global.
public struct SegmentSceneStyle: Codable, Equatable, Sendable {
    public var canvas: CanvasStyle
    public var camera: CameraStyle
    public var cursor: CursorStyle
    public var motion: MotionStyle
    public var presetID: UUID?
    public var presetName: String?

    public init(project: RecorderProject, presetID: UUID? = nil, presetName: String? = nil) {
        canvas = project.canvas
        // Crop is owned by the recording source, never by one occurrence.
        // Freezing it here would detach the segment from later re-crops.
        canvas.crop = .full
        camera = project.camera
        cursor = project.cursorStyle
        motion = project.motion
        self.presetID = presetID
        self.presetName = presetName
    }

    private enum CodingKeys: String, CodingKey { case canvas, camera, cursor, motion, presetID, presetName }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        canvas = try c.decodeIfPresent(CanvasStyle.self, forKey: .canvas) ?? CanvasStyle()
        // Projects saved while styles still froze a crop fall back to the
        // source's crop, which is what the picture already showed.
        canvas.crop = .full
        camera = try c.decodeIfPresent(CameraStyle.self, forKey: .camera) ?? CameraStyle()
        cursor = try c.decodeIfPresent(CursorStyle.self, forKey: .cursor) ?? CursorStyle()
        motion = try c.decodeIfPresent(MotionStyle.self, forKey: .motion) ?? MotionStyle()
        presetID = try c.decodeIfPresent(UUID.self, forKey: .presetID)
        presetName = try c.decodeIfPresent(String.self, forKey: .presetName)
    }

    public func apply(to project: inout RecorderProject) {
        let aspect = project.canvas.aspectRatio
        let customAspect = project.canvas.customAspectRatio
        // The caller already resolved the crop for this occurrence's source.
        let crop = project.canvas.crop
        project.canvas = canvas
        project.canvas.aspectRatio = aspect
        project.canvas.customAspectRatio = customAspect
        project.canvas.crop = crop
        project.camera = camera
        project.cursorStyle = cursor
        project.motion = motion
    }
}

public extension ProjectTimeline {
    func recordingSegment(atOutputTime time: TimeInterval) -> RecordingSegment? {
        recordingSegmentBoundary(atOutputTime: time).segment
    }

    func recordingSegment(id: UUID) -> RecordingSegment? {
        guard case let .edited(segments) = sourceSequence else { return nil }
        return segments.first { $0.id == id }
    }

    /// The occurrence under the playhead together with the one before it and
    /// their shared cut, resolved in the one pass the lookup already costs.
    /// Appearance settling needs all three and must not add a second scan.
    func recordingSegmentBoundary(atOutputTime time: TimeInterval) -> RecordingSegmentBoundary {
        guard time.isFinite, time >= 0, case let .edited(segments) = sourceSequence else { return .none }
        var start: TimeInterval = 0
        var previous: RecordingSegment?
        for segment in segments {
            let end = start + segment.outputDuration
            if time > start || TimelineMediaPlan.isSameBoundary(time, start),
               time < end, !TimelineMediaPlan.isSameBoundary(time, end) {
                return RecordingSegmentBoundary(segment: segment, previous: previous, start: start)
            }
            previous = segment
            start = end
        }
        // The editor can park its playhead exactly at the programme end.
        guard TimelineMediaPlan.isSameBoundary(time, start), let last = segments.last else { return .none }
        return RecordingSegmentBoundary(segment: last, previous: segments.dropLast().last, start: start - last.outputDuration)
    }
}

public struct RecordingSegmentBoundary: Equatable, Sendable {
    public static let none = RecordingSegmentBoundary(segment: nil, previous: nil, start: 0)
    public let segment: RecordingSegment?
    /// The occurrence immediately before `segment`, nil at the programme start.
    public let previous: RecordingSegment?
    /// `segment`'s output start, i.e. the cut the settling is measured from.
    public let start: TimeInterval

    func insertedPlayback(at time: TimeInterval) -> (media: InsertedMedia, localTime: TimeInterval, playbackRate: Double)? {
        guard let segment, let media = segment.media else { return nil }
        let elapsed = min(max(time - start, 0), segment.outputDuration)
        return (media, segment.sourceStart + elapsed * segment.playbackRate, segment.playbackRate)
    }
}

/// Static appearance settling across a cut. It borrows `RecordingAspectTransitions`'
/// window and curve on purpose: a card whose aspect and whose padding move on
/// two different clocks reads as two separate glitches.
public enum SegmentAppearanceTransition {
    public static var duration: TimeInterval { RecordingAspectTransitions.duration }

    /// 0...1 inside the window after a cut, nil once the clip has settled.
    public static func progress(at time: TimeInterval, boundary: TimeInterval) -> Double? {
        let elapsed = time - boundary
        guard elapsed.isFinite, elapsed >= 0, elapsed < duration else { return nil }
        let x = elapsed / duration
        return x * x * (3 - 2 * x)
    }

    /// Only cards settle into each other. A full-canvas insert (a title card,
    /// black) is not a card: easing its padding would slide the next recording
    /// in from the edges instead of cutting to it.
    public static func settles(_ segment: RecordingSegment) -> Bool {
        segment.media.map(\.usesFrameStyle) ?? true
    }

    /// Two clips drawing their appearance from the same places have nothing to
    /// settle. Deciding that from the authored segments alone keeps the common
    /// cut — same recording, no per-clip style — off the per-frame path that
    /// would otherwise resolve a second canvas.
    public static func canSettle(from previous: RecordingSegment, to current: RecordingSegment) -> Bool {
        guard settles(previous), settles(current) else { return false }
        return previous.sceneStyle != current.sceneStyle
            || previous.resolvedSourceID != current.resolvedSourceID
            || previous.media != current.media
    }
}

public extension CanvasStyle {
    /// Eases the measurable half of this occurrence's appearance out of the
    /// previous one. Everything whose midpoint would be nonsense snaps: the
    /// mockup kind (no silhouette exists between a MacBook and a phone), the
    /// background asset, the frame's text, and the crop — the crop decides
    /// which source pixels are sampled and already has its own aspect morph.
    mutating func blend(from previous: CanvasStyle, progress: Double) {
        let t = min(max(progress, 0), 1)
        func mix(_ a: Double, _ b: Double) -> Double { a + (b - a) * t }
        padding = mix(previous.padding, padding)
        contentScale = mix(previous.contentScale, contentScale)
        contentPosition = NormalizedPoint(x: mix(previous.contentPosition.x, contentPosition.x),
                                          y: mix(previous.contentPosition.y, contentPosition.y))
        cornerRadius = mix(previous.cornerRadius, cornerRadius)
        borderWidth = mix(previous.borderWidth, borderWidth)
        borderColor = HexColor.mixing(previous.borderColor, borderColor, progress: t)
        shadowStrength = mix(previous.shadowStrength, shadowStrength)
        insetOpacity = mix(previous.insetOpacity, insetOpacity)
        backgroundBlur = mix(previous.backgroundBlur, backgroundBlur)
        // Pattern geometry only reads as motion while the pattern is the same
        // artwork; a different preset is a cut, so its own scale starts settled.
        if previous.backgroundSource == backgroundSource {
            patternScale = mix(previous.patternScale, patternScale)
            patternOpacity = mix(previous.patternOpacity, patternOpacity)
        }
        // A mockup's own measurements belong to that mockup. Carrying the
        // outgoing one's scale into a different frame pops it to a wrong size.
        guard previous.screenFrame == screenFrame else { return }
        screenFrameScale = mix(previous.screenFrameScale, screenFrameScale)
        screenFrameToolbarScale = mix(previous.screenFrameToolbarScale, screenFrameToolbarScale)
        if let from = previous.screenFrameOuterCornerRadius, let to = screenFrameOuterCornerRadius {
            screenFrameOuterCornerRadius = mix(from, to)
        }
        if let from = previous.screenFrameContentCornerRadius, let to = screenFrameContentCornerRadius {
            screenFrameContentCornerRadius = mix(from, to)
        }
    }
}

public extension CameraStyle {
    /// The bubble settles across a cut like the card does: jumping from one
    /// corner to the other, or resizing in one frame, reads as a dropped
    /// frame. Shape geometry is interpolated separately as a continuous
    /// CameraMotionSample; the authored shape enum remains the target's.
    mutating func blend(from previous: CameraStyle, progress: Double) {
        guard previous.isHidden == isHidden else { return }
        let t = min(max(progress, 0), 1)
        func mix(_ a: Double, _ b: Double) -> Double { a + (b - a) * t }
        position = NormalizedPoint(x: mix(previous.position.x, position.x),
                                   y: mix(previous.position.y, position.y))
        size = mix(previous.size, size)
        roundness = mix(previous.roundness, roundness)
        borderWidth = mix(previous.borderWidth, borderWidth)
        shadowStrength = mix(previous.shadowStrength, shadowStrength)
        scaleDuringZoom = mix(previous.scaleDuringZoom, scaleDuringZoom)
        contentScale = mix(previous.contentScale, contentScale)
        beauty.smoothing = mix(previous.beauty.smoothing, beauty.smoothing)
        beauty.whitening = mix(previous.beauty.whitening, beauty.whitening)
        contentPosition = NormalizedPoint(x: mix(previous.contentPosition.x, contentPosition.x),
                                          y: mix(previous.contentPosition.y, contentPosition.y))
    }
}

public extension HexColor {
    /// Per-channel sRGB mix. Border colours are authored as flat swatches, so
    /// a linear ramp is what the eye expects between two of them.
    static func mixing(_ from: HexColor, _ to: HexColor, progress: Double) -> HexColor {
        guard from != to else { return to }
        let t = min(max(progress, 0), 1)
        let a = from.components, b = to.components
        func channel(_ x: Double, _ y: Double) -> UInt32 {
            UInt32(min(max(((x + (y - x) * t) * 255).rounded(), 0), 255))
        }
        return HexColor(rgb24: channel(a.red, b.red) << 16
            | channel(a.green, b.green) << 8 | channel(a.blue, b.blue))
    }
}

public extension RecorderProject {
    func sceneProject(forSegmentID id: UUID?) -> RecorderProject {
        guard let id, let segment = timeline.recordingSegment(id: id) else { return self }
        var result = self
        result.canvas = screenCanvas(for: segment.media == nil
            ? .recording(segment.resolvedSourceID) : .insertedSegment(id))
        // `apply(to:)` preserves whatever crop the caller resolved, so the
        // occurrence's own rectangle has to be in place before the style runs.
        result.canvas.crop = resolvedCrop(for: segment)
        segment.sceneStyle?.apply(to: &result)
        if segment.media?.usesFrameStyle == false, segment.sceneStyle == nil {
            result.canvas.contentScale = 1
            result.canvas.contentPosition = NormalizedPoint(x: 0.5, y: 0.5)
        }
        return result
    }

    func sceneProject(atOutputTime time: TimeInterval) -> RecorderProject {
        var result = self
        timeline.recordingSegment(atOutputTime: time)?.sceneStyle?.apply(to: &result)
        return result
    }

    mutating func setSceneStyle(_ style: SegmentSceneStyle, forSegmentID id: UUID) {
        guard case var .edited(segments) = timeline.sourceSequence,
              let index = segments.firstIndex(where: { $0.id == id }) else { return }
        segments[index].sceneStyle = style
        if segments[index].media != nil { segments[index].media?.usesFrameStyle = true }
        timeline.sourceSequence = .edited(segments)
    }

    var segmentSceneStyles: [UUID: SegmentSceneStyle] {
        guard case let .edited(segments) = timeline.sourceSequence else { return [:] }
        return Dictionary(uniqueKeysWithValues: segments.compactMap { segment in
            segment.sceneStyle.map { (segment.id, $0) }
        })
    }

    /// All file-backed scene backgrounds, for loading and freezing export assets.
    var sceneBackgroundSources: [BackgroundSource] {
        var result = [canvas.backgroundSource]
        if case let .edited(segments) = timeline.sourceSequence {
            for segment in segments {
                if let source = segment.sceneStyle?.canvas.backgroundSource, !result.contains(source) {
                    result.append(source)
                }
            }
        }
        return result
    }
}

public extension SourceSequence {
    var withoutSceneStyles: SourceSequence {
        guard case let .edited(segments) = self else { return self }
        return .edited(segments.map { var segment = $0; segment.sceneStyle = nil; return segment })
    }
}
