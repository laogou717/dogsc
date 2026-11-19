import AVFoundation
import Combine
import CoreGraphics
import Foundation
import OSLog
import RecorderCore

/// Stable file identity plus the version fields that can change while a URL
/// remains the same. Editor media preparation keys use this value instead of
/// a path alone so replacing a recording in place cannot reuse stale assets.
struct EditorMediaFileVersion: Codable, Equatable, Hashable, Sendable {
    let standardizedPath: String
    let fileSystemNumber: UInt64?
    let fileNumber: UInt64?
    let fileSize: UInt64?
    let modificationDate: Date?

    init(url: URL) {
        let standardizedURL = url.standardizedFileURL
        standardizedPath = standardizedURL.path
        let attributes = try? FileManager.default.attributesOfItem(
            atPath: standardizedPath
        )
        fileSystemNumber = (attributes?[.systemNumber] as? NSNumber)?.uint64Value
        fileNumber = (attributes?[.systemFileNumber] as? NSNumber)?.uint64Value
        fileSize = (attributes?[.size] as? NSNumber)?.uint64Value
        modificationDate = attributes?[.modificationDate] as? Date
    }
}

struct EditorMediaInput: Equatable, Sendable {
    let url: URL
    let version: EditorMediaFileVersion

    init?(_ url: URL?) {
        guard let url else { return nil }
        self.url = url
        version = EditorMediaFileVersion(url: url)
    }
}

/// Immutable file identities for an imported recording. Pointer JSONL is read
/// by the background loader, never on the editor's main thread.
struct EditorRecordingSourceInput: Equatable, Sendable {
    var manifest: ProjectMediaManifest
    /// Carried so a failure can name the recording it belongs to. Renaming a
    /// recording must not re-prepare its media, so `==` ignores it.
    var name: String = ""
    let screen: EditorMediaInput?
    let camera: EditorMediaInput?
    let microphone: EditorMediaInput?
    let pointer: EditorMediaInput?
    let cameraContentCrop: NormalizedCrop?
    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.screen == rhs.screen && lhs.camera == rhs.camera && lhs.microphone == rhs.microphone
            && lhs.pointer == rhs.pointer && lhs.cameraContentCrop == rhs.cameraContentCrop
            && EditorMediaRequest.mediaManifestMatchesForPreparation(lhs.manifest, rhs.manifest)
    }

}

/// An exclusively leased generator. The actor reuses idle decoders so a filmstrip
/// does not reopen a hardware decode session for every picture. A cancelled
/// lease is discarded; its generator is never shared with another request.
private final class EditorMediaThumbnailRequest: @unchecked Sendable {
    private let generator: AVAssetImageGenerator

    init(source: ImmutablePreviewAsset, maximumSize: CGSize, tolerance: TimeInterval = 0) {
        generator = AVAssetImageGenerator(asset: source.asset)
        generator.videoComposition = source.videoComposition
        generator.appliesPreferredTrackTransform = source.videoComposition == nil
        generator.requestedTimeToleranceBefore = CMTime(seconds: tolerance, preferredTimescale: 600)
        generator.requestedTimeToleranceAfter = CMTime(seconds: tolerance, preferredTimescale: 600)
        generator.maximumSize = maximumSize
    }

    func image(at time: CMTime, timeout: Duration?) async throws -> CGImage {
        let deadline = EditorMediaThumbnailDeadline(generator: generator)
        let watchdog = timeout.map { duration in
            Task {
                do { try await Task.sleep(for: duration) } catch { return }
                deadline.expire()
            }
        }
        defer {
            watchdog?.cancel()
            // Synchronize with a firing deadline before this generator can
            // return to the idle pool and be leased by another request.
            deadline.finish()
        }
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            let (image, _) = try await generator.image(at: time)
            return image
        } onCancel: {
            self.cancel()
        }
    }

    func cancel() {
        generator.cancelAllCGImageGeneration()
    }
}

/// The deadline belongs to one lease, not the reusable generator. A timer
/// that fires after a successful return must never cancel the next lease.
private final class EditorMediaThumbnailDeadline: @unchecked Sendable {
    private let lock = NSLock()
    private let generator: AVAssetImageGenerator
    private var isPending = true

    init(generator: AVAssetImageGenerator) { self.generator = generator }

    func expire() {
        lock.withLock {
            guard isPending else { return }
            isPending = false
            generator.cancelAllCGImageGeneration()
        }
    }

    func finish() { lock.withLock { isPending = false } }
}

private actor EditorMediaThumbnailDecoder {
    private struct CacheKey: Hashable {
        let timeValue: Int64
        let width: Int
        let height: Int
        let toleranceValue: Int64
    }

    private struct IdleDecoder {
        let width: Int
        let height: Int
        let toleranceValue: Int64
        let request: EditorMediaThumbnailRequest
    }
    private var idleDecoders: [IdleDecoder] = []

    private static let permits = EditorThumbnailPermits(limit: 2)
    private let cacheLimit: Int
    private let requestTimeout: Duration?
    private var sourceGeneration: UInt64?
    private var inFlightRequests: [UUID: EditorMediaThumbnailRequest] = [:]
    private var cache: [CacheKey: CGImage] = [:]
    private var cacheOrder: [CacheKey] = []

    init(cacheLimit: Int = 12, requestTimeout: Duration? = nil) {
        self.cacheLimit = cacheLimit
        self.requestTimeout = requestTimeout
    }

    func image(
        source: ImmutablePreviewAsset,
        generation: UInt64,
        at assetTime: TimeInterval,
        maximumSize: CGSize,
        tolerance: TimeInterval = 0
    ) async throws -> CGImage {
        try Task.checkCancellation()
        guard assetTime.isFinite else { throw CancellationError() }
        let safeSize = CGSize(
            width: max(maximumSize.width.rounded(), 1),
            height: max(maximumSize.height.rounded(), 1)
        )
        let requestedTime = CMTime(
            seconds: max(assetTime, 0),
            preferredTimescale: 600
        )
        let cacheKey = CacheKey(
            timeValue: requestedTime.value,
            width: Int(safeSize.width),
            height: Int(safeSize.height),
            toleranceValue: Int64(floor(max(tolerance, 0) * 600))
        )

        // Actor reentrancy can deliver an old source request after a newer
        // one. It must not cancel the new source or reset its cache backwards.
        if let sourceGeneration, generation < sourceGeneration { throw CancellationError() }
        if sourceGeneration != generation {
            cancelInFlightRequests()
            sourceGeneration = generation
            cache.removeAll(keepingCapacity: true)
            cacheOrder.removeAll(keepingCapacity: true)
        }

        if let cached = cachedImage(for: cacheKey) { return cached }
        try await Self.permits.acquire()
        defer { Task { await Self.permits.release() } }
        try Task.checkCancellation()
        guard sourceGeneration == generation else { throw CancellationError() }
        if let cached = cachedImage(for: cacheKey) { return cached }
        let requestID = UUID()
        let request: EditorMediaThumbnailRequest
        if let index = idleDecoders.firstIndex(where: {
            $0.width == cacheKey.width && $0.height == cacheKey.height
                && $0.toleranceValue == cacheKey.toleranceValue
        }) {
            request = idleDecoders.remove(at: index).request
        } else {
            // Replace an idle configuration instead of retaining two unused
            // decoders alongside the two permitted active requests.
            if !idleDecoders.isEmpty { idleDecoders.removeFirst() }
            request = EditorMediaThumbnailRequest(source: source, maximumSize: safeSize,
                tolerance: Double(cacheKey.toleranceValue) / 600)
        }
        inFlightRequests[requestID] = request
        defer { inFlightRequests.removeValue(forKey: requestID) }
        let image = try await request.image(at: requestedTime, timeout: requestTimeout)
        try Task.checkCancellation()
        guard sourceGeneration == generation else { throw CancellationError() }

        if idleDecoders.count < 2 {
            idleDecoders.append(IdleDecoder(width: cacheKey.width, height: cacheKey.height,
                toleranceValue: cacheKey.toleranceValue, request: request))
        }
        cache[cacheKey] = image
        cacheOrder.removeAll { $0 == cacheKey }
        cacheOrder.append(cacheKey)
        if cacheOrder.count > cacheLimit {
            cache.removeValue(forKey: cacheOrder.removeFirst())
        }
        return image
    }

    private func cachedImage(for key: CacheKey) -> CGImage? {
        guard let image = cache[key] else { return nil }
        cacheOrder.removeAll { $0 == key }
        cacheOrder.append(key)
        return image
    }

    func invalidate() {
        cancelInFlightRequests()
        sourceGeneration = nil
        cache.removeAll(keepingCapacity: false)
        cacheOrder.removeAll(keepingCapacity: false)
    }

    private func cancelInFlightRequests() {
        idleDecoders.removeAll()
        inFlightRequests.values.forEach { $0.cancel() }
        inFlightRequests.removeAll(keepingCapacity: true)
    }
}

/// The complete identity of work that may change decoded media or its output
/// clock. Visual styling and audio gain deliberately do not appear here: they
/// are evaluated downstream and must not reopen assets or rebuild players.
struct EditorMediaRequest: Equatable, Sendable {
    let editorSessionID: EditorSessionID
    let source: EditorMediaInput?
    let camera: EditorMediaInput?
    let microphone: EditorMediaInput?
    let sourceSequence: SourceSequence
    var mediaManifest: ProjectMediaManifest?
    /// Keeping every record is intentional. Count/first/last fingerprints miss
    /// edits to an event in the middle and can leave pointer timing stale.
    let pointerEvents: [PointerEventRecord]
    /// EDT-054: music/effects are part of the prepared composition.
    var audioClips: [AudioClip] = []
    /// Speech ranges (subtitle cues) that ducking music dips under; only
    /// relevant when a music clip ducks.
    var speech: [OverlayTiming] = []
    var additionalSources: [UUID: EditorRecordingSourceInput] = [:]


    init(
        editorSessionID: EditorSessionID,
        source: EditorMediaInput?,
        camera: EditorMediaInput?,
        microphone: EditorMediaInput?,
        sourceSequence: SourceSequence,
        mediaManifest: ProjectMediaManifest?,
        pointerEvents: [PointerEventRecord]
    ) {
        self.editorSessionID = editorSessionID
        self.source = source
        self.camera = camera
        self.microphone = microphone
        self.sourceSequence = sourceSequence
        self.mediaManifest = mediaManifest
        self.pointerEvents = pointerEvents
    }

    /// Camera clock corrections are intentionally not part of the expensive
    /// media-preparation identity. They do not change a file, primary cut,
    /// waveform or audio mix; treating every 40 ms nudge as a new request used
    /// to reopen all three long assets and rebuild every AVComposition.
    static func == (lhs: EditorMediaRequest, rhs: EditorMediaRequest) -> Bool {
        lhs.editorSessionID == rhs.editorSessionID
            && lhs.source == rhs.source
            && lhs.camera == rhs.camera
            && lhs.microphone == rhs.microphone
            && lhs.sourceSequence.withoutSceneStyles == rhs.sourceSequence.withoutSceneStyles
            && mediaManifestMatchesForPreparation(lhs.mediaManifest, rhs.mediaManifest)
            && lhs.pointerEvents == rhs.pointerEvents
            && lhs.audioClips.count == rhs.audioClips.count
            && zip(lhs.audioClips, rhs.audioClips).allSatisfy { $0.matchesCompositionStructure(of: $1) }
            && lhs.additionalSources == rhs.additionalSources
    }

    func matchesPreparationManifests(_ project: RecorderProject) -> Bool {
        matchesPreparationManifest(project.media)
            && Set(additionalSources.keys) == Set(project.additionalSources.map(\.id))
            && project.additionalSources.allSatisfy { source in
                Self.mediaManifestMatchesForPreparation(additionalSources[source.id]?.manifest, source.media)
            }
    }

    func matchesPreparationManifest(_ manifest: ProjectMediaManifest?) -> Bool {
        Self.mediaManifestMatchesForPreparation(mediaManifest, manifest)
    }

    /// A cut changes placement, not source-file metadata. Reuse only within
    /// the same editor and file versions, with the same declared audio/video.
    func canReuseSourceTracks(from other: EditorMediaRequest) -> Bool {
        editorSessionID == other.editorSessionID
            && source == other.source
            && camera == other.camera
            && microphone == other.microphone
            && Set(additionalSources.keys) == Set(other.additionalSources.keys)
            && additionalSources.allSatisfy { id, input in
                guard let previous = other.additionalSources[id] else { return false }
                return input.screen == previous.screen && input.camera == previous.camera
                    && input.microphone == previous.microphone && input.pointer == previous.pointer
                    && input.cameraContentCrop == previous.cameraContentCrop
                    && input.manifest.camera?.relativePath == previous.manifest.camera?.relativePath
                    && input.manifest.microphone?.relativePath == previous.manifest.microphone?.relativePath
                    && input.manifest.pointerEvents?.relativePath == previous.manifest.pointerEvents?.relativePath
            }
            && (mediaManifest?.camera != nil) == (other.mediaManifest?.camera != nil)
            && (mediaManifest?.microphone != nil) == (other.mediaManifest?.microphone != nil)
            && ([source, camera, microphone] + additionalSources.values.flatMap {
                [$0.screen, $0.camera, $0.microphone, $0.pointer]
            }).compactMap { $0 }.allSatisfy {
                // Session inputs are pinned; an external in-place replacement
                // must still invalidate reuse before another timeline edit.
                $0.version == EditorMediaFileVersion(url: $0.url)
            }
    }

    func updatingMediaManifest(_ manifest: ProjectMediaManifest?) -> EditorMediaRequest {
        var request = EditorMediaRequest(
            editorSessionID: editorSessionID,
            source: source,
            camera: camera,
            microphone: microphone,
            sourceSequence: sourceSequence,
            mediaManifest: manifest,
            pointerEvents: pointerEvents
        )
        request.audioClips = audioClips
        request.speech = speech
        request.additionalSources = additionalSources
        return request
    }

    static func mediaManifestMatchesForPreparation(
        _ lhs: ProjectMediaManifest?,
        _ rhs: ProjectMediaManifest?
    ) -> Bool {
        switch (lhs, rhs) {
        case (nil, nil):
            return true
        case let (lhs?, rhs?):
            // Camera file identity is already carried by `camera`; only the
            // relative declaration/presence is structural here. All timing
            // fields are consumed by the camera-only update path below.
            return lhs.screen == rhs.screen
                && lhs.microphone == rhs.microphone
                && lhs.pointerEvents == rhs.pointerEvents
                && lhs.camera?.relativePath == rhs.camera?.relativePath
        case (nil, _?), (_?, nil):
            return false
        }
    }

}

struct EditorCameraTimingRequest: Equatable, Sendable {
    let editorSessionID: EditorSessionID
    let sourceSequence: SourceSequence
    let cameraReferences: [UUID: ProjectMediaReference]
}

struct EditorMediaInventories: Equatable, Sendable {
    let source: MediaAssetInventory
    let camera: MediaAssetInventory
    let microphone: MediaAssetInventory

    static let empty = EditorMediaInventories(
        source: .empty,
        camera: .empty,
        microphone: .empty
    )
}

/// Result produced by the asset loader before the session attaches its own
/// monotonically increasing generation.
struct EditorPreparedMediaPayload {
    let composition: TimelineCompositionBundle
    let inventories: EditorMediaInventories
    let sourceDisplaySize: CGSize
    let cameraDisplaySize: CGSize?
    let cameraContentCrop: NormalizedCrop?
    /// Original camera track retained for cheap metadata-only timing rebuilds.
    /// It is never decoded here and does not reopen the source file.
    let cameraSource: EditorPreparedCameraSource?
    let sourceTracks: TimelinePreparedSourceTracks?
    var inventoriesBySource: [UUID: EditorMediaInventories] = [:]

    init(
        composition: TimelineCompositionBundle,
        inventories: EditorMediaInventories,
        sourceDisplaySize: CGSize,
        cameraDisplaySize: CGSize?,
        cameraContentCrop: NormalizedCrop?,
        cameraSource: EditorPreparedCameraSource?,
        sourceTracks: TimelinePreparedSourceTracks? = nil
    ) {
        self.composition = composition
        self.inventories = inventories
        self.sourceDisplaySize = sourceDisplaySize
        self.cameraDisplaySize = cameraDisplaySize
        self.cameraContentCrop = cameraContentCrop
        self.cameraSource = cameraSource
        self.sourceTracks = sourceTracks
    }
}

struct EditorPreparedCameraSource {
    /// Camera timing may be rebuilt after the initial loader has returned.
    /// Retain the source asset alongside its original track.
    let asset: AVURLAsset
    let track: AVAssetTrack
    let timeRange: CMTimeRange
    let preferredTransform: CGAffineTransform
}

struct EditorPreparedMedia {
    let generation: UInt64
    let request: EditorMediaRequest
    let payload: EditorPreparedMediaPayload

    var composition: TimelineCompositionBundle { payload.composition }
    var plan: ProjectTimelineMediaPlan { composition.plan }
    @available(*, deprecated, message: "Use payload.inventoriesBySource with an explicit recording source ID.")
    var inventories: EditorMediaInventories { payload.inventories }
    var primarySourceDisplaySize: CGSize { payload.sourceDisplaySize }
    @available(*, deprecated, message: "Use recordingGeometry by source ID; primarySourceDisplaySize is only for the global canvas.")
    var sourceDisplaySize: CGSize { payload.sourceDisplaySize }
    @available(*, deprecated, message: "Use recordingGeometry by source ID.")
    var cameraDisplaySize: CGSize? { payload.cameraDisplaySize }
    @available(*, deprecated, message: "Use composition.frameMetadata(at:) for the active recording's camera crop.")
    var cameraContentCrop: NormalizedCrop? { payload.cameraContentCrop }
    var outputDuration: TimeInterval { plan.outputDuration }
}

enum EditorMediaSessionState {
    case empty
    case preparing(generation: UInt64)
    case ready(EditorPreparedMedia)
    case failed(generation: UInt64, message: String)
}

enum EditorMediaSessionLifecycle: Equatable {
    case empty
    case preparing(UInt64)
    case ready(UInt64)
    case failed(UInt64)
}

/// Owns one editor generation's asset inspection, media plan and immutable
/// preview compositions. AVPlayer transport stays outside this type until the
/// dedicated playback-controller migration.
@MainActor
final class EditorMediaSession: ObservableObject {
    typealias Preparation = (EditorMediaRequest) async throws -> EditorPreparedMediaPayload

    private static let logger = Logger(
        subsystem: "cn.laogou.dogsc",
        category: "editor-media"
    )

    @Published private(set) var state: EditorMediaSessionState = .empty
    @Published private(set) var cameraTimingRevision: UInt64 = 0
    @Published private(set) var cameraTimingErrorMessage: String?
    /// The most recent ready media, kept across `.preparing` so an in-flight
    /// re-preparation (any timeline edit) does not blank the preview or
    /// silence the audio until the replacement generation is actually ready.
    /// `install` already early-returns when the generation matches, so keeping
    /// this value is enough to avoid tearing down the playing transport.
    private var lastReadyMedia: EditorPreparedMedia?

    private let preparation: Preparation
    private var thumbnailDecoders: [String: EditorMediaThumbnailDecoder] = [:]
    private final class FilmstripCache {
        let input: EditorMediaInput
        let asset: ImmutablePreviewAsset
        let decoder = EditorMediaThumbnailDecoder(cacheLimit: 160, requestTimeout: .seconds(4))
        var frames: [Int64: CGImage] = [:]
        var order: [Int64] = []
        init(input: EditorMediaInput) {
            self.input = input
            self.asset = ImmutablePreviewAsset(AVURLAsset(url: input.url))
        }
    }
    private var filmstripCaches: [UUID: FilmstripCache] = [:]
    private var currentRequest: EditorMediaRequest?
    /// The recorded pointer events of the open project, in source time (the
    /// AI reads clicks from here).
    var pointerEventsBySource: [UUID: [PointerEventRecord]] {
        mediaPlan?.sources.mapValues {
            PointerTimelineAlignment.align($0.pointerEvents,
                startOffset: $0.manifest?.pointerEvents?.startOffset ?? 0,
                sourceStartTime: $0.manifest?.pointerEvents?.sourceStartTime ?? 0)
        } ?? [:]
    }
    private var generation: UInt64 = 0
    private var cameraTimingGeneration: UInt64 = 0
    private var latestCameraTimingRequest: EditorCameraTimingRequest?

    init(
        preparation: @escaping Preparation = { request in
            try await TimelinePreviewCompositionLoader.prepare(request: request)
        }
    ) {
        self.preparation = preparation
    }

    var lifecycle: EditorMediaSessionLifecycle {
        switch state {
        case .empty:
            return .empty
        case let .preparing(generation):
            return .preparing(generation)
        case let .ready(media):
            return .ready(media.generation)
        case let .failed(generation, _):
            return .failed(generation)
        }
    }

    var prepared: EditorPreparedMedia? {
        if case let .ready(media) = state { return media }
        return lastReadyMedia
    }

    @available(*, deprecated, message: "Use inventories(for:) or source-aware aggregate availability.")
    var inventories: EditorMediaInventories { prepared?.inventories ?? .empty }

    var primarySourceDisplaySize: CGSize { prepared?.primarySourceDisplaySize ?? CGSize(width: 1920, height: 1080) }

    @available(*, deprecated, message: "Use sourceDisplaySize(for:); use primarySourceDisplaySize only for the global canvas.")
    var sourceDisplaySize: CGSize { primarySourceDisplaySize }

    @available(*, deprecated, message: "Use cameraDisplaySize(for:) with the active source ID.")
    var cameraDisplaySize: CGSize? { prepared?.cameraDisplaySize }

    @available(*, deprecated, message: "Use the active frame's source-scoped camera crop.")
    var cameraContentCrop: NormalizedCrop? { prepared?.cameraContentCrop }

    var mediaPlan: ProjectTimelineMediaPlan? {
        prepared?.plan
    }

    var sourceDurations: [UUID: TimeInterval] {
        prepared?.plan.timelineMap.sourceDurations ?? [:]
    }

    var outputDuration: TimeInterval {
        prepared?.outputDuration ?? 0
    }

    var errorMessage: String? {
        guard case let .failed(_, message) = state else { return nil }
        return message
    }

    func thumbnail(atOutputTime outputTime: TimeInterval,
                   maximumSize: CGSize = CGSize(width: 640, height: 360)) async -> CGImage? {
        guard let prepared, let input = prepared.screenFrameInput(at: outputTime) else { return nil }
        let decoder = thumbnailDecoders[input.cacheKey] ?? EditorMediaThumbnailDecoder()
        thumbnailDecoders[input.cacheKey] = decoder
        let expectedGeneration = prepared.generation
        do {
            let image = try await decoder.image(source: input.asset, generation: expectedGeneration,
                at: input.assetTime, maximumSize: maximumSize)
            try Task.checkCancellation()
            guard self.prepared?.generation == expectedGeneration else { return nil }
            return image
        } catch { return nil }
    }

    func filmstripThumbnail(sourceID: UUID, atSourceTime sourceTime: TimeInterval,
                            tolerance: TimeInterval) async -> CGImage? {
        guard !Task.isCancelled, sourceTime.isFinite, sourceTime >= 0,
              let prepared, let input = prepared.request.screenInput(for: sourceID) else { return nil }
        let cache: FilmstripCache
        if let existing = filmstripCaches[sourceID], existing.input == input { cache = existing }
        else {
            cache = FilmstripCache(input: input)
            filmstripCaches[sourceID] = cache
        }
        let assetTime = sourceTime + (prepared.plan.sourceTimeOffsets[sourceID] ?? 0)
        do {
            let image = try await cache.decoder.image(source: cache.asset, generation: 0, at: assetTime,
                maximumSize: CGSize(width: 220, height: 140), tolerance: tolerance)
            try Task.checkCancellation()
            guard filmstripCaches[sourceID] === cache,
                  self.prepared?.request.screenInput(for: sourceID) == input else { return nil }
            let key = CMTime(seconds: assetTime, preferredTimescale: 600).value
            cache.frames[key] = image
            cache.order.removeAll { $0 == key }
            cache.order.append(key)
            if cache.order.count > 160 { cache.frames.removeValue(forKey: cache.order.removeFirst()) }
            return image
        } catch { return nil }
    }

    func filmstripCachedFrames(sourceID: UUID, sourceStart: TimeInterval, sourceDuration: TimeInterval) -> [Int64: CGImage] {
        guard sourceStart.isFinite, sourceDuration.isFinite, sourceDuration > 0,
              let prepared, let cache = filmstripCaches[sourceID],
              cache.input == prepared.request.screenInput(for: sourceID) else { return [:] }
        let offset = prepared.plan.sourceTimeOffsets[sourceID] ?? 0
        let offsetValue = CMTime(seconds: offset, preferredTimescale: 600).value
        return Dictionary(uniqueKeysWithValues: cache.frames.compactMap { assetTime, image in
            let sourceTime = assetTime - offsetValue
            let time = Double(sourceTime) / 600
            guard time >= sourceStart, time < sourceStart + sourceDuration else { return nil }
            return (sourceTime, image)
        })
    }

    func prepare(_ request: EditorMediaRequest) async {
        if currentRequest == request {
            switch state {
            case .preparing, .ready:
                return
            case .empty, .failed:
                break
            }
        }

        generation &+= 1
        cameraTimingGeneration &+= 1
        let requestedGeneration = generation
        currentRequest = request
        state = .preparing(generation: requestedGeneration)

        do {
            let payload: EditorPreparedMediaPayload
            if let previous = lastReadyMedia,
               request.canReuseSourceTracks(from: previous.request),
               let rebuilt = try TimelinePreviewCompositionLoader.rebuild(
                   request: request, reusing: previous.payload
               ) {
                payload = rebuilt
            } else {
                payload = try await preparation(request)
            }
            try Task.checkCancellation()
            guard generation == requestedGeneration,
                  currentRequest == request else { return }
            let media = EditorPreparedMedia(
                generation: requestedGeneration,
                request: request,
                payload: payload
            )
            lastReadyMedia = media
            state = .ready(media)
            if let latestCameraTimingRequest {
                await updateCameraTiming(latestCameraTimingRequest)
            }
        } catch is CancellationError {
            guard generation == requestedGeneration,
                  currentRequest == request else { return }
            currentRequest = nil
            state = .empty
        } catch {
            guard generation == requestedGeneration,
                  currentRequest == request else { return }
            Self.logger.error(
                "media preparation failed generation=\(requestedGeneration, privacy: .public) error=\(String(reflecting: error), privacy: .public)"
            )
            state = .failed(
                generation: requestedGeneration,
                message: error.localizedDescription
            )
        }
    }

    /// Rebuilds only the camera's timestamp composition. The primary player,
    /// screen audio, microphone mix, waveforms and file analysis remain alive.
    func updateCameraTiming(_ request: EditorCameraTimingRequest) async {
        latestCameraTimingRequest = request
        guard let ready = lastReadyMedia,
              request.editorSessionID == ready.request.editorSessionID,
              ready.request.sourceSequence.withoutSceneStyles == request.sourceSequence.withoutSceneStyles,
              ready.request.cameraReferences.mapValues(\.relativePath) == request.cameraReferences.mapValues(\.relativePath),
              ready.request.cameraReferences != request.cameraReferences,
              let tracks = ready.payload.sourceTracks else { return }
        cameraTimingGeneration &+= 1
        let requestedGeneration = cameraTimingGeneration
        do {
            let updatedRequest = ready.request.updatingCameraReferences(request.cameraReferences)
            let plan = try TimelinePreviewCompositionLoader.mediaPlan(request: updatedRequest, recordings: tracks.recordings)
            let camera = try TimelineCompositionBuilder.buildCamera(plan: plan.camera,
                sources: tracks.recordings.compactMapValues(\.camera))
            try Task.checkCancellation()
            guard requestedGeneration == cameraTimingGeneration,
                  lastReadyMedia?.generation == ready.generation else { return }
            let old = ready.composition
            var composition = TimelineCompositionBundle(plan: plan,
                primaryComposition: old.primaryComposition, primaryVideoTrack: old.primaryVideoTrack,
                primaryVideoTracks: old.primaryVideoTracks, primaryVideoComposition: old.primaryVideoComposition,
                systemAudioTrack: old.systemAudioTrack, microphoneAudioTrack: old.microphoneAudioTrack,
                cameraComposition: camera?.composition, cameraVideoTrack: camera?.track)
            composition.externalAudio = old.externalAudio
            composition.recordingSources = old.recordingSources
            composition.insertedSources = old.insertedSources
            var payload = EditorPreparedMediaPayload(composition: composition,
                inventories: ready.payload.inventories, sourceDisplaySize: ready.primarySourceDisplaySize,
                cameraDisplaySize: ready.payload.cameraDisplaySize, cameraContentCrop: ready.payload.cameraContentCrop,
                cameraSource: ready.payload.cameraSource, sourceTracks: tracks)
            payload.inventoriesBySource = ready.payload.inventoriesBySource
            let updated = EditorPreparedMedia(generation: ready.generation, request: updatedRequest, payload: payload)
            lastReadyMedia = updated
            state = .ready(updated)
            cameraTimingErrorMessage = nil
            cameraTimingRevision &+= 1
        } catch is CancellationError {
            return
        } catch {
            guard requestedGeneration == cameraTimingGeneration else { return }
            cameraTimingErrorMessage = error.localizedDescription
        }
    }

    func invalidate() {
        generation &+= 1
        cameraTimingGeneration &+= 1
        currentRequest = nil
        state = .empty
        lastReadyMedia = nil
        let decoders = Array(thumbnailDecoders.values) + filmstripCaches.values.map(\.decoder)
        thumbnailDecoders = [:]
        filmstripCaches = [:]
        latestCameraTimingRequest = nil
        cameraTimingErrorMessage = nil
        Task { for decoder in decoders { await decoder.invalidate() } }
    }
}
