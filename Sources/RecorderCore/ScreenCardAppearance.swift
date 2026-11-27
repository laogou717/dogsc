import Foundation

/// Screen decoration belongs to a recording (or an inserted clip). Canvas
/// background, ratio and layout remain shared by the programme.
public struct ScreenCardAppearance: Codable, Equatable, Sendable {
    public var cornerRadius: Double
    public var borderWidth: Double
    public var borderColor: HexColor
    public var shadowStrength: Double
    public var insetOpacity: Double
    public var screenFrame: ScreenFrameStyle
    public var screenFrameScale: Double
    public var screenFrameToolbarScale: Double
    public var screenFrameOuterCornerRadius: Double?
    public var screenFrameContentCornerRadius: Double?
    public var screenFrameTitle: String
    public var screenFrameBrowserAddress: String

    public init(canvas: CanvasStyle = CanvasStyle()) {
        cornerRadius = canvas.cornerRadius
        borderWidth = canvas.borderWidth
        borderColor = canvas.borderColor
        shadowStrength = canvas.shadowStrength
        insetOpacity = canvas.insetOpacity
        screenFrame = canvas.screenFrame
        screenFrameScale = canvas.screenFrameScale
        screenFrameToolbarScale = canvas.screenFrameToolbarScale
        screenFrameOuterCornerRadius = canvas.screenFrameOuterCornerRadius
        screenFrameContentCornerRadius = canvas.screenFrameContentCornerRadius
        screenFrameTitle = canvas.screenFrameTitle
        screenFrameBrowserAddress = canvas.screenFrameBrowserAddress
    }

    public func apply(to canvas: inout CanvasStyle) {
        canvas.cornerRadius = cornerRadius
        canvas.borderWidth = borderWidth
        canvas.borderColor = borderColor
        canvas.shadowStrength = shadowStrength
        canvas.insetOpacity = insetOpacity
        canvas.screenFrame = screenFrame
        canvas.screenFrameScale = screenFrameScale
        canvas.screenFrameToolbarScale = screenFrameToolbarScale
        canvas.screenFrameOuterCornerRadius = screenFrameOuterCornerRadius
        canvas.screenFrameContentCornerRadius = screenFrameContentCornerRadius
        canvas.screenFrameTitle = screenFrameTitle
        canvas.screenFrameBrowserAddress = screenFrameBrowserAddress
    }

    private enum CodingKeys: String, CodingKey {
        case cornerRadius
        case borderWidth
        case borderColor
        case shadowStrength
        case insetOpacity
        case screenFrame
        case screenFrameScale
        case screenFrameToolbarScale
        case screenFrameOuterCornerRadius
        case screenFrameContentCornerRadius
        case screenFrameTitle
        case screenFrameBrowserAddress
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = CanvasStyle()
        cornerRadius = try c.decodeIfPresent(Double.self, forKey: .cornerRadius) ?? defaults.cornerRadius
        borderWidth = try c.decodeIfPresent(Double.self, forKey: .borderWidth) ?? defaults.borderWidth
        borderColor = try c.decodeIfPresent(HexColor.self, forKey: .borderColor) ?? defaults.borderColor
        shadowStrength = try c.decodeIfPresent(Double.self, forKey: .shadowStrength) ?? defaults.shadowStrength
        insetOpacity = try c.decodeIfPresent(Double.self, forKey: .insetOpacity) ?? defaults.insetOpacity
        screenFrame = try c.decodeIfPresent(ScreenFrameStyle.self, forKey: .screenFrame) ?? defaults.screenFrame
        screenFrameScale = try c.decodeIfPresent(Double.self, forKey: .screenFrameScale) ?? defaults.screenFrameScale
        screenFrameToolbarScale = try c.decodeIfPresent(Double.self, forKey: .screenFrameToolbarScale) ?? defaults.screenFrameToolbarScale
        screenFrameOuterCornerRadius = try c.decodeIfPresent(Double.self, forKey: .screenFrameOuterCornerRadius)
        screenFrameContentCornerRadius = try c.decodeIfPresent(Double.self, forKey: .screenFrameContentCornerRadius)
        screenFrameTitle = try c.decodeIfPresent(String.self, forKey: .screenFrameTitle) ?? defaults.screenFrameTitle
        screenFrameBrowserAddress = try c.decodeIfPresent(String.self, forKey: .screenFrameBrowserAddress) ?? defaults.screenFrameBrowserAddress
    }
}

public enum ScreenAppearanceTarget: Hashable, Sendable {
    case recording(UUID)
    case insertedSegment(UUID)
    case segment(UUID)
}

public extension RecorderProject {
    /// The single crop authority, shared by preview, export and the inspector.
    /// An occurrence that opted out of following its recording keeps its own
    /// rectangle; everything else follows the source, and an inserted clip
    /// never borrows a recording's crop.
    func resolvedCrop(for segment: RecordingSegment?) -> NormalizedCrop {
        guard let segment else { return canvas.crop }
        guard segment.media == nil else { return .full }
        if let crop = segment.crop { return crop.clamped() }
        return source(segment.resolvedSourceID)?.crop ?? canvas.crop
    }

    /// Paused authoring has to show the clip's own authored values: a playhead
    /// parked just after a cut would otherwise sit inside the appearance
    /// settling window, and the inspector's numbers would not match the
    /// picture. Handing the outgoing clip this clip's appearance leaves the
    /// blend nothing to interpolate, without a presentation flag in the
    /// document. Playback and export keep the real settling.
    func settlingSegmentAppearance(atOutputTime time: TimeInterval) -> RecorderProject {
        let boundary = timeline.recordingSegmentBoundary(atOutputTime: time)
        guard let current = boundary.segment, let previous = boundary.previous,
              SegmentAppearanceTransition.canSettle(from: previous, to: current),
              SegmentAppearanceTransition.progress(at: time, boundary: boundary.start,
                  duration: max(SegmentAppearanceTransition.duration, SegmentAppearanceTransition.cameraDuration)) != nil,
              case var .edited(segments) = timeline.sourceSequence,
              let index = segments.firstIndex(where: { $0.id == previous.id }) else { return self }
        segments[index].sceneStyle = SegmentSceneStyle(
            project: sceneProject(forSegmentID: current.id),
            presetID: previous.sceneStyle?.presetID,
            presetName: previous.sceneStyle?.presetName
        )
        var result = self
        result.timeline.sourceSequence = .edited(segments)
        return result
    }

    /// Per-occurrence crop overrides, for builders that cannot walk the
    /// sequence themselves (the shared aspect-transition table).
    var segmentCrops: [UUID: NormalizedCrop] {
        guard case let .edited(segments) = timeline.sourceSequence else { return [:] }
        return segments.reduce(into: [:]) { result, segment in
            guard segment.media == nil, let crop = segment.crop else { return }
            result[segment.id] = crop.clamped()
        }
    }

    func screenCanvas(for target: ScreenAppearanceTarget) -> CanvasStyle {
        var result = canvas
        switch target {
        case let .segment(id):
            return sceneProject(forSegmentID: id).canvas
        case let .recording(id):
            if let source = source(id) {
                source.screenAppearance?.apply(to: &result)
                result.crop = source.crop
            }
        case let .insertedSegment(id):
            result.crop = .full
            if case let .edited(segments) = timeline.sourceSequence {
                let media = segments.first { $0.id == id }?.media
                media?.screenAppearance?.apply(to: &result)
                if media?.imagePath != nil, media?.usesFrameStyle == false {
                    result.padding = 0
                }
            }
        }
        return result
    }

    func screenCanvas(atOutputTime time: TimeInterval, recordingSourceID: UUID?) -> CanvasStyle {
        screenCanvas(atOutputTime: time, recordingSourceID: recordingSourceID, boundary: timeline.recordingSegmentBoundary(atOutputTime: time))
    }

    internal func screenCanvas(atOutputTime time: TimeInterval, recordingSourceID: UUID?, boundary: RecordingSegmentBoundary) -> CanvasStyle {
        var result = screenCanvas(segment: boundary.segment,
                                  recordingSourceID: recordingSourceID)
        // Static appearance differing across a cut used to read as a dropped
        // frame. Settle it over the same window a source's aspect uses, from
        // the clip that was on screen, so the two morphs stay in step.
        guard let current = boundary.segment, let previous = boundary.previous,
              SegmentAppearanceTransition.canSettle(from: previous, to: current),
              let progress = SegmentAppearanceTransition.progress(at: time, boundary: boundary.start)
        else { return result }
        let from = screenCanvas(segment: previous,
                                recordingSourceID: previous.resolvedSourceID)
        result.blend(from: from, progress: progress)
        return result
    }

    /// The static camera pose eases across a cut. Authored camera motion
    /// samples this base using the clip’s own timing and easing.
    func settledCamera(atOutputTime time: TimeInterval) -> CameraStyle {
        settledCamera(atOutputTime: time, boundary: timeline.recordingSegmentBoundary(atOutputTime: time))
    }

    /// A slot controls an existing camera feed. It cannot supply one on an
    /// inserted shot or outside the recording's retained camera intervals.
    internal func hasVisibleCamera(in segment: RecordingSegment?, at time: TimeInterval,
                                   cameraTimeline: TimelineMediaPlan?) -> Bool {
        guard segment?.media == nil, !(segment?.sceneStyle?.camera ?? camera).isHidden else { return false }
        if let cameraTimeline { return cameraTimeline.contains(outputTime: time) }
        let id = segment?.resolvedSourceID ?? RecordingSource.primaryID
        if let source = source(id) { return source.media.camera != nil || source.capture.source == .cameraOnly }
        // Standalone scene evaluations may supply decoded camera dimensions
        // before the primary recording has a manifest.
        return id == RecordingSource.primaryID
    }

    /// While scrubbing between output frames next to a camera-free primary shot,
    /// keep camera-hosting overlays on the visible frame inside this occurrence.
    /// The primary cut, audio clock and unrelated overlays keep their exact time.
    internal func cameraHostSampleTime(at time: TimeInterval, boundary: RecordingSegmentBoundary,
                                       frameRate: Int, cameraTimeline: TimelineMediaPlan?) -> TimeInterval {
        guard let segment = boundary.segment else { return time }
        let rate = Double(frameRate)
        let end = boundary.start + segment.outputDuration
        guard time - boundary.start < 1 / rate || end - time < 1 / rate,
              hasVisibleCamera(in: segment, at: time, cameraTimeline: cameraTimeline) else { return time }
        let first = OutputFrameSchedule.firstFrameIndex(atOrAfter: boundary.start, frameRate: frameRate) / rate
        if time < first, first < end, let previous = boundary.previous,
           !hasVisibleCamera(in: previous, at: boundary.start - TimelineMediaPlan.boundaryProbeOffset,
                             cameraTimeline: cameraTimeline) { return first }
        let last = (OutputFrameSchedule.firstFrameIndex(atOrAfter: end, frameRate: frameRate) - 1) / rate
        if time > last, last >= boundary.start {
            let after = end + TimelineMediaPlan.boundaryProbeOffset
            if let next = timeline.recordingSegment(atOutputTime: after),
               !hasVisibleCamera(in: next, at: after, cameraTimeline: cameraTimeline) { return last }
        }
        return time
    }

    private func cameraTransitionProgress(at time: TimeInterval, boundary: RecordingSegmentBoundary,
                                          cameraTimeline: TimelineMediaPlan?) -> Double? {
        guard let current = boundary.segment, let previous = boundary.previous,
              SegmentAppearanceTransition.canSettle(from: previous, to: current),
              let progress = SegmentAppearanceTransition.cameraProgress(at: time, boundary: boundary),
              hasVisibleCamera(in: previous, at: boundary.start - TimelineMediaPlan.boundaryProbeOffset,
                               cameraTimeline: cameraTimeline),
              hasVisibleCamera(in: current, at: boundary.start, cameraTimeline: cameraTimeline) else { return nil }
        return progress
    }

    internal func settledCamera(atOutputTime time: TimeInterval, boundary: RecordingSegmentBoundary,
                                cameraTimeline: TimelineMediaPlan? = nil) -> CameraStyle {
        var result = boundary.segment?.sceneStyle?.camera ?? camera
        guard let previous = boundary.previous,
              let progress = cameraTransitionProgress(at: time, boundary: boundary, cameraTimeline: cameraTimeline)
        else { return result }
        result.blend(from: previous.sceneStyle?.camera ?? camera, progress: progress)
        return result
    }

    /// Resolve shapes into aspect and corner fractions before blending. An
    /// authored enum cannot represent the intermediate silhouette of a cut.
    func cameraAppearanceTransitionSample(atOutputTime time: TimeInterval, cameraAspectRatio: Double,
                                         canvasAspectRatio: Double) -> CameraMotionSample? {
        cameraAppearanceTransitionSample(atOutputTime: time, cameraAspectRatio: cameraAspectRatio,
            canvasAspectRatio: canvasAspectRatio, boundary: timeline.recordingSegmentBoundary(atOutputTime: time))
    }

    internal func cameraAppearanceTransitionSample(atOutputTime time: TimeInterval, cameraAspectRatio: Double,
                                                  canvasAspectRatio: Double, boundary: RecordingSegmentBoundary,
                                                  cameraTimeline: TimelineMediaPlan? = nil, asInset: Bool = false) -> CameraMotionSample? {
        guard let current = boundary.segment, let previous = boundary.previous,
              let progress = cameraTransitionProgress(at: time, boundary: boundary, cameraTimeline: cameraTimeline)
        else { return nil }
        let currentStyle = current.sceneStyle?.camera ?? camera
        let previousStyle = previous.sceneStyle?.camera ?? camera
        func sample(_ style: CameraStyle) -> CameraMotionSample {
            var state = CameraMotionState(base: style)
            if asInset { state.layout = .shape(style.shape) }
            return CameraMotionTrack.resolve(state, cameraAspectRatio: cameraAspectRatio, canvasAspectRatio: canvasAspectRatio)
        }
        return CameraMotionTrack.transitionSample(from: sample(previousStyle), to: sample(currentStyle), progress: progress)
    }

    /// 摄像机动画片段的基准：这一刻的逐片段摄像头姿态（跨切点已 settle）。
    /// 片段的 target 是绝对值，所以基准只负责未动画的时间、片段的入点和
    /// 回落；改某一段的摄像头姿态不会改写已经写好的目标。渲染、在播放头
    /// 新建、切分、面板读数都从这里取基准，四处才会说同一件事。
    func cameraMotionBase(atOutputTime time: TimeInterval) -> CameraMotionState {
        CameraMotionState(base: settledCamera(atOutputTime: time))
    }

    private func screenCanvas(segment: RecordingSegment?, recordingSourceID: UUID?) -> CanvasStyle {
        if let segment, let style = segment.sceneStyle {
            var result = style.canvas
            result.aspectRatio = canvas.aspectRatio
            result.customAspectRatio = canvas.customAspectRatio
            result.crop = resolvedCrop(for: segment)
            return result
        }
        var result = canvas
        if let inserted = segment?.media {
            inserted.screenAppearance?.apply(to: &result)
            result.crop = .full
            if !inserted.usesFrameStyle {
                if inserted.imagePath != nil { result.padding = 0 }
                result.contentScale = 1
                result.contentPosition = NormalizedPoint(x: 0.5, y: 0.5)
            }
        } else if let recordingSourceID, let source = source(recordingSourceID) {
            source.screenAppearance?.apply(to: &result)
            result.crop = source.crop
        }
        if let segment { result.crop = resolvedCrop(for: segment) }
        return result
    }

    mutating func setScreenAppearance(_ appearance: ScreenCardAppearance, for target: ScreenAppearanceTarget) {
        preserveLegacyScreenAppearances()
        switch target {
        case let .segment(id):
            var style = SegmentSceneStyle(project: sceneProject(forSegmentID: id))
            if let existing = timeline.recordingSegment(id: id)?.sceneStyle { style = existing }
            appearance.apply(to: &style.canvas)
            setSceneStyle(style, forSegmentID: id)
        case let .recording(id):
            if id == RecordingSource.primaryID {
                appearance.apply(to: &canvas)
            } else if let index = additionalSources.firstIndex(where: { $0.id == id }) {
                additionalSources[index].screenAppearance = appearance
            }
        case let .insertedSegment(id):
            guard case var .edited(segments) = timeline.sourceSequence,
                  let index = segments.firstIndex(where: { $0.id == id }), segments[index].media != nil else { return }
            segments[index].media?.screenAppearance = appearance
            segments[index].media?.usesFrameStyle = true
            timeline.sourceSequence = .edited(segments)
        }
    }

    /// Materialize the previous shared appearance without changing old pixels.
    /// A later edit to the primary recording must not restyle these sources.
    mutating func preserveLegacyScreenAppearances() {
        let previous = ScreenCardAppearance(canvas: canvas)
        for index in additionalSources.indices where additionalSources[index].screenAppearance == nil {
            additionalSources[index].screenAppearance = previous
        }
        if case var .edited(segments) = timeline.sourceSequence {
            for index in segments.indices where segments[index].media?.screenAppearance == nil {
                segments[index].media?.screenAppearance = previous
            }
            timeline.sourceSequence = .edited(segments)
        }
    }
}
