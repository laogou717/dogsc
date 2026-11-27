import Foundation

/// A real camera aperture in an HTML template's aspect-fit design canvas.
/// Bounds use top-left coordinates; radius is a fraction of the shorter edge.
public struct MotionCameraSlot: Codable, Equatable, Sendable {
    public var x, y, width, height: Double
    public var aspect, radius: Double
    public var aboveGraphics: Bool
    /// Framing inside the mask, in visual coordinates after mirroring.
    /// Omitted values inherit the recording's own framing.
    public var contentPosition: NormalizedPoint?
    public var contentScale: Double?

    public var isValid: Bool {
        x >= 0 && y >= 0 && width > 0 && height > 0 &&
            x + width <= 1.000001 && y + height <= 1.000001 &&
            aspect.isFinite && aspect > 0 && radius >= 0 && radius <= 0.5 &&
            (contentPosition.map { (0...1).contains($0.x) && (0...1).contains($0.y) } ?? true) &&
            (contentScale.map { (1...4).contains($0) } ?? true)
    }

    public func rect(in canvas: CompositionSize, clip: AnimationClip) -> CompositionRect {
        let frameWidth = canvas.width * clip.width
        let frameHeight = canvas.height * clip.width
        let designWidth = min(frameWidth, frameHeight * aspect)
        let designHeight = designWidth / aspect
        return CompositionRect(x: canvas.width * clip.position.x + (x - 0.5) * designWidth,
                               y: canvas.height * clip.position.y + (y - 0.5) * designHeight,
                               width: width * designWidth, height: height * designHeight)
    }
}

extension MotionCameraSlot {
    static func layerOrder(_ lhs: AnimationClip, _ rhs: AnimationClip) -> Bool {
        lhs.layerIndex == rhs.layerIndex ? lhs.id.uuidString < rhs.id.uuidString : lhs.layerIndex < rhs.layerIndex
    }

    struct Placement: Equatable {
        var rect: CompositionRect
        var radius: Double
        var contentPosition: NormalizedPoint
        var contentScale: Double
        var borderWidth = 0.0
        var cameraReveal = 0.0

        func moving(towards other: Self, progress: Double, beneathGraphic: Bool) -> Self {
            guard self != other else { return self }
            func mix(_ a: Double, _ b: Double) -> Double { a + (b - a) * progress }
            return Self(rect: CompositionRect(x: mix(rect.x, other.rect.x), y: mix(rect.y, other.rect.y),
                                              width: mix(rect.width, other.rect.width),
                                              height: mix(rect.height, other.rect.height)),
                        radius: mix(radius, other.radius),
                        contentPosition: NormalizedPoint(x: mix(contentPosition.x, other.contentPosition.x),
                                                         y: mix(contentPosition.y, other.contentPosition.y)),
                        contentScale: mix(contentScale, other.contentScale),
                        borderWidth: mix(borderWidth, other.borderWidth),
                        cameraReveal: beneathGraphic && (rect != other.rect || radius != other.radius) ? progress : 0)
        }
    }

    /// A slot and an inset move the same camera. Resolve their shared handoff in
    /// output time so scrubbing, playback and offline export see the same mask.
    enum Host {
        case video(VideoClip), motion(AnimationClip)

        var timing: OverlayTiming {
            switch self { case let .video(v): v.timing; case let .motion(m): m.timing }
        }
        var id: UUID {
            switch self { case let .video(v): v.id; case let .motion(m): m.id }
        }
        var hidesCamera: Bool {
            if case let .video(v) = self { return v.cameraMode == .hidden }
            return false
        }

        static func visible(video: VideoClip?, motion: AnimationClip?) -> Self? {
            if let video, video.cameraMode == .hidden { return .video(video) }
            if let motion, motion.layerIndex >= (video?.layerIndex ?? Int.min) { return .motion(motion) }
            return video.map(Self.video)
        }
    }

    static func placement(at time: TimeInterval, frameRate: Int, host: Host?, videos: [VideoClip], slots: [AnimationClip],
                          videoStart: (VideoClip) -> TimeInterval, native: Placement,
                          cameraVisible: (TimeInterval, Host?, Placement) -> Bool, pose: (Host) -> Placement) -> Placement {
        guard let host, !host.hidesCamera else { return native }
        let settled = pose(host)
        let duration = SegmentAppearanceTransition.cameraDuration
        var start = host.timing.startTime
        if case let .video(video) = host { start = videoStart(video) }
        var end = host.timing.endTime
        func winner(at boundary: Double) -> Host? {
            Host.visible(video: videos.last { boundary >= videoStart($0) && boundary < $0.timing.endTime },
                         motion: slots.last { $0.timing.contains(boundary) })
        }
        // An overlapping higher layer can interrupt an otherwise continuous
        // host. Two nearby boundaries can also shorten the window shared
        // by entry and exit, even when one is more than a leg away.
        func consider(_ boundary: Double) {
            if boundary <= time, boundary > start, time - boundary < 2 * duration,
               winner(at: boundary - TimelineMediaPlan.boundaryProbeOffset)?.id != host.id { start = boundary }
            if boundary > time, boundary < end, boundary - time < 2 * duration,
               winner(at: boundary + TimelineMediaPlan.boundaryProbeOffset)?.id != host.id { end = boundary }
        }
        for clip in videos { consider(videoStart(clip)); consider(clip.timing.endTime) }
        for clip in slots { consider(clip.timing.startTime); consider(clip.timing.endTime) }
        if time - start >= duration && end - time >= duration { return settled }
        // Decide whether to animate against shots that have a displayed frame.
        // Audio-aligned trims can expose a native pose for a few milliseconds
        // in the model even when the next output frame already hides the camera.
        let before = (OutputFrameSchedule.firstFrameIndex(atOrAfter: start, frameRate: frameRate) - 1) / Double(frameRate)
        let after = OutputFrameSchedule.firstFrameIndex(atOrAfter: end, frameRate: frameRate) / Double(frameRate)
        // For short shots both legs share the available time. For longer
        // shots only inspect the neighbour whose transition is on screen.
        let short = end - start < 2 * duration
        let enters = (short || time - start < duration) && before >= 0 && native != settled
            && winner(at: before + TimelineMediaPlan.boundaryProbeOffset) == nil && cameraVisible(before, nil, native)
        var destination = settled
        if short || end - time < duration {
            let next = winner(at: after + TimelineMediaPlan.boundaryProbeOffset)
            if next?.hidesCamera != true {
                let target = next.map(pose) ?? native
                if target != settled, cameraVisible(after, next, target) { destination = target }
            }
        }
        let leaves = settled != destination
        let window = min(duration, (end - start) / (enters && leaves ? 2 : 1))
        let beneathGraphic: Bool
        if case let .motion(clip) = host { beneathGraphic = clip.cameraSlot?.aboveGraphics == false }
        else { beneathGraphic = false }
        if leaves, let p = SegmentAppearanceTransition.progress(at: time, boundary: end - window, duration: window) {
            return settled.moving(towards: destination, progress: p, beneathGraphic: beneathGraphic)
        }
        if enters, let p = SegmentAppearanceTransition.progress(at: time, boundary: start, duration: window) {
            return settled.moving(towards: native, progress: 1 - p, beneathGraphic: beneathGraphic)
        }
        return settled
    }
}
