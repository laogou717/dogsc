import Foundation

/// Background treatment is independent of the two images' animation opacity.
/// Joined hidden-screen stickers must keep suppression at one throughout the
/// handoff, even while both images are translucent or travelling off-canvas.
public struct FrameStickerBackdropScene: Equatable, Sendable {
    public var screenSuppression: Double = 0
    public var cameraSuppression: Double = 0
    public var screenBlur: Double = 0
    public var cameraBlur: Double = 0

    public init() {}

    init(stickers: [FrameStickerScene]) {
        for sticker in stickers {
            var treatment = Self()
            treatment.screenSuppression = sticker.hidesScreen ? sticker.transitionProgress : 0
            treatment.cameraSuppression = sticker.hidesCamera ? sticker.transitionProgress : 0
            treatment.screenBlur = sticker.hidesScreen ? 0 : sticker.backdropBlur
            treatment.cameraBlur = sticker.backdropBlurIncludesCamera ? sticker.backdropBlur : 0
            merge(treatment)
        }
    }

    init(clip: StickerClip, visibility: Double) {
        screenSuppression = clip.hidesScreen ? visibility : 0
        cameraSuppression = clip.hidesCamera ? visibility : 0
        screenBlur = clip.hidesScreen ? 0 : max(clip.backdropBlur, 0) * visibility
        cameraBlur = clip.backdropBlurIncludesCamera
            ? max(clip.backdropBlur, 0) * visibility : 0
    }

    mutating func merge(_ other: Self) {
        screenSuppression = max(screenSuppression, other.screenSuppression)
        cameraSuppression = max(cameraSuppression, other.cameraSuppression)
        screenBlur = max(screenBlur, other.screenBlur)
        cameraBlur = max(cameraBlur, other.cameraBlur)
    }

    func interpolated(to other: Self, progress: Double) -> Self {
        var result = Self()
        result.screenSuppression = screenSuppression
            + (other.screenSuppression - screenSuppression) * progress
        result.cameraSuppression = cameraSuppression
            + (other.cameraSuppression - cameraSuppression) * progress
        result.screenBlur = screenBlur + (other.screenBlur - screenBlur) * progress
        result.cameraBlur = cameraBlur + (other.cameraBlur - cameraBlur) * progress
        return result
    }
}

/// Prepared once per sticker edit, then shared by paused preview, playback and
/// export. Only numerical endpoint noise counts as adjacency, never a frame-
/// sized gap. Authored clip timings and layer order remain unchanged.
public struct StickerTransitionTrack: Equatable, Sendable {
    private static let endpointTolerance = 0.000_000_1

    private struct Entry: Equatable, Sendable {
        let clip: StickerClip
        let enterDuration: TimeInterval
        let exitDuration: TimeInterval
        var entryJoin: Int?
        var exitJoin: Int?

        var joinEnterDuration: TimeInterval {
            clip.animation == .none ? 0 : enterDuration
        }

        var joinExitDuration: TimeInterval {
            (clip.exitAnimation ?? clip.animation.automaticExit) == .none ? 0 : exitDuration
        }

        init(_ clip: StickerClip) {
            self.clip = clip
            let enter = max(clip.enterDuration, 0)
            let exit = max(clip.exitDuration, 0)
            let total = enter + exit
            let scale = total > clip.timing.duration && total > 0
                ? clip.timing.duration / total : 1
            enterDuration = enter * scale
            exitDuration = exit * scale
        }
    }

    private struct Endpoint {
        let time: TimeInterval
        let index: Int
        let isStart: Bool
    }

    private struct Join: Equatable, Sendable {
        let start: TimeInterval
        let end: TimeInterval
        let outgoingBackdrop: FrameStickerBackdropScene
        let incomingBackdrop: FrameStickerBackdropScene
        let curve: ElementMotionCurve

        func contains(_ time: TimeInterval) -> Bool { time >= start && time < end }

        func progress(at time: TimeInterval) -> Double {
            guard end > start else { return time >= end ? 1 : 0 }
            return min(max((time - start) / (end - start), 0), 1)
        }
    }

    struct Sample {
        let clip: StickerClip
        let visibility: Double
        let preset: StickerAnimationPreset
        let progress: Double
    }

    private var entries: [Entry]
    private var joins: [Join] = []

    public init(_ clips: [StickerClip]) {
        entries = clips.filter {
            $0.timing.startTime.isFinite && $0.timing.duration.isFinite
                && $0.timing.duration > 0
        }.sorted {
            $0.layerIndex == $1.layerIndex
                ? $0.id.uuidString < $1.id.uuidString : $0.layerIndex < $1.layerIndex
        }.map(Entry.init)
        let endpoints = entries.indices.flatMap { index in
            [Endpoint(time: entries[index].clip.timing.startTime, index: index, isStart: true),
             Endpoint(time: entries[index].clip.timing.endTime, index: index, isStart: false)]
        }.sorted { $0.time < $1.time }
        var cursor = 0
        while cursor < endpoints.count {
            let boundary = endpoints[cursor].time
            var outgoing: [Int] = []
            var incoming: [Int] = []
            repeat {
                let endpoint = endpoints[cursor]
                if endpoint.isStart { incoming.append(endpoint.index) }
                else { outgoing.append(endpoint.index) }
                cursor += 1
            } while cursor < endpoints.count
                && endpoints[cursor].time - boundary <= Self.endpointTolerance
            // A very short sticker must not connect its own start and end.
            let shared = Set(outgoing).intersection(incoming)
            outgoing.removeAll { shared.contains($0) }
            incoming.removeAll { shared.contains($0) }
            guard !outgoing.isEmpty, !incoming.isEmpty else { continue }
            // Each side stays inside every participant's allocated transition
            // budget. This also prevents adjacent handoffs from overlapping on
            // a short middle sticker or a group of simultaneous layers.
            let before = outgoing.map { entries[$0].joinExitDuration }.min() ?? 0
            let after = incoming.map { entries[$0].joinEnterDuration }.min() ?? 0
            var outgoingBackdrop = FrameStickerBackdropScene()
            var incomingBackdrop = FrameStickerBackdropScene()
            for index in outgoing {
                outgoingBackdrop.merge(.init(clip: entries[index].clip, visibility: 1))
            }
            for index in incoming {
                incomingBackdrop.merge(.init(clip: entries[index].clip, visibility: 1))
            }
            let joinIndex = joins.count
            joins.append(Join(
                start: (outgoing.map { entries[$0].clip.timing.endTime }.min() ?? boundary) - before,
                end: (incoming.map { entries[$0].clip.timing.startTime }.max() ?? boundary) + after,
                outgoingBackdrop: outgoingBackdrop,
                incomingBackdrop: incomingBackdrop,
                curve: entries[incoming.max() ?? incoming[0]].clip.animationCurve
            ))
            for index in outgoing { entries[index].exitJoin = joinIndex }
            for index in incoming { entries[index].entryJoin = joinIndex }
        }
    }

    public func hasJoinedEntry(_ id: UUID) -> Bool {
        entries.contains { $0.clip.id == id && $0.entryJoin != nil }
    }

    func sample(
        at time: TimeInterval,
        suppressesInitialEntry: Bool
    ) -> (stickers: [Sample], backdrop: FrameStickerBackdropScene) {
        var backdrop = FrameStickerBackdropScene()
        for join in joins where join.contains(time) {
            backdrop.merge(join.outgoingBackdrop.interpolated(
                to: join.incomingBackdrop,
                progress: ElementMotionEvaluator.progress(join.progress(at: time), curve: join.curve)
            ))
        }
        let stickers: [Sample] = entries.compactMap { entry in
            let clip = entry.clip
            let entryJoin = entry.entryJoin.map { joins[$0] }
            let exitJoin = entry.exitJoin.map { joins[$0] }
            let joinedEntryIsActive = entryJoin?.contains(time) ?? false
            let joinedExitIsActive = exitJoin?.contains(time) ?? false
            guard clip.timing.contains(time) || joinedEntryIsActive || joinedExitIsActive
            else { return nil }
            let localTime = max(time - clip.timing.startTime, 0)
            let remaining = max(clip.timing.endTime - time, 0)
            let suppressesEntry = suppressesInitialEntry && clip.timing.startTime <= 0.000_1
            let linearEnter = entryJoin?.progress(at: time) ?? (suppressesEntry ? 1 : (
                entry.enterDuration > 0 ? min(localTime / entry.enterDuration, 1) : 1
            ))
            let linearExit = exitJoin.map { 1 - $0.progress(at: time) } ?? (
                entry.exitDuration > 0 ? min(remaining / entry.exitDuration, 1) : 1
            )
            let enterProgress = ElementMotionEvaluator.progress(linearEnter, curve: clip.animationCurve)
            let exitProgress = ElementMotionEvaluator.progress(linearExit, curve: clip.animationCurve)
            let exitPreset = clip.exitAnimation ?? clip.animation.automaticExit
            let visibility = min(clip.animation == .none ? 1 : enterProgress,
                                 exitPreset == .none ? 1 : exitProgress)
            let isExiting = exitJoin.map { time >= $0.start } ?? (
                entry.exitDuration > 0 && remaining < entry.exitDuration
            )
            if !joinedEntryIsActive && !joinedExitIsActive {
                backdrop.merge(.init(clip: clip, visibility: visibility))
            }
            return Sample(clip: clip, visibility: visibility,
                          preset: isExiting ? exitPreset : clip.animation,
                          progress: isExiting ? exitProgress : enterProgress)
        }
        return (stickers, backdrop)
    }
}
