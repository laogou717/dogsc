import AVFoundation
import Combine
import CoreGraphics
import Foundation
import OSLog
import RecorderCore

/// Stable file identity plus the version fields that can change while a URL
/// remains the same. Editor media preparation keys use this value instead of
/// a path alone so replacing a recording in place cannot reuse stale assets.
struct EditorMediaFileVersion: Equatable, Sendable {
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

enum EditorMediaThumbnailClock {
    static func assetTime(
        atOutputTime outputTime: TimeInterval,
        timelineMap: TimelineMap,
        sourceTimeRange: MediaTimeRange?
    ) -> TimeInterval? {
        guard let sourceTimeRange,
              let sourceTime = timelineMap.sourceTime(atOutputTime: outputTime)
        else { return nil }
        return sourceTimeRange.start + sourceTime
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

    func image(at time: CMTime) async throws -> CGImage {
        try await withTaskCancellationHandler {
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

    private let permits = EditorThumbnailPermits(limit: 2)
    private let cacheLimit: Int
    private var sourceGeneration: UInt64?
    private var inFlightRequests: [UUID: EditorMediaThumbnailRequest] = [:]
    private var cache: [CacheKey: CGImage] = [:]
    private var cacheOrder: [CacheKey] = []

    init(cacheLimit: Int = 12) { self.cacheLimit = cacheLimit }

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

        if sourceGeneration != generation {
            cancelInFlightRequests()
            sourceGeneration = generation
            cache.removeAll(keepingCapacity: true)
            cacheOrder.removeAll(keepingCapacity: true)
        }

        if let cached = cachedImage(for: cacheKey) { return cached }
        try await permits.acquire()
        defer { Task { await permits.release() } }
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
        let image = try await request.image(at: requestedTime)
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
    let mediaManifest: ProjectMediaManifest?
    /// Keeping every record is intentional. Count/first/last fingerprints miss
    /// edits to an event in the middle and can leave pointer timing stale.
    let pointerEvents: [PointerEventRecord]

    init(
        editorSessionID: EditorSessionID,
        sourceURL: URL?,
        cameraURL: URL?,
        microphoneURL: URL?,
        sourceSequence: SourceSequence,
        mediaManifest: ProjectMediaManifest?,
        pointerEvents: [PointerEventRecord]
    ) {
        self.init(
            editorSessionID: editorSessionID,
            source: EditorMediaInput(sourceURL),
            camera: EditorMediaInput(cameraURL),
            microphone: EditorMediaInput(microphoneURL),
            sourceSequence: sourceSequence,
            mediaManifest: mediaManifest,
            pointerEvents: pointerEvents
        )
    }

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
            && lhs.sourceSequence == rhs.sourceSequence
            && mediaManifestMatchesForPreparation(lhs.mediaManifest, rhs.mediaManifest)
            && lhs.pointerEvents == rhs.pointerEvents
    }

    func matchesPreparationManifest(_ manifest: ProjectMediaManifest?) -> Bool {
        Self.mediaManifestMatchesForPreparation(mediaManifest, manifest)
    }

    func updatingMediaManifest(_ manifest: ProjectMediaManifest?) -> EditorMediaRequest {
        EditorMediaRequest(
            editorSessionID: editorSessionID,
            source: source,
            camera: camera,
            microphone: microphone,
            sourceSequence: sourceSequence,
            mediaManifest: manifest,
            pointerEvents: pointerEvents
        )
    }

    private static func mediaManifestMatchesForPreparation(
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
    let cameraReference: ProjectMediaReference?
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
    var inventories: EditorMediaInventories { payload.inventories }
    var sourceDisplaySize: CGSize { payload.sourceDisplaySize }
    var cameraDisplaySize: CGSize? { payload.cameraDisplaySize }
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
    private let thumbnailDecoder = EditorMediaThumbnailDecoder()
    private let filmstripDecoder = EditorMediaThumbnailDecoder(cacheLimit: 160)
    private var filmstripAsset: ImmutablePreviewAsset?
    private var filmstripInput: EditorMediaInput?
    private var filmstripSourceGeneration: UInt64 = 0
    private var currentRequest: EditorMediaRequest?
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

    var inventories: EditorMediaInventories {
        prepared?.inventories ?? .empty
    }

    var sourceDisplaySize: CGSize {
        prepared?.sourceDisplaySize ?? CGSize(width: 1_920, height: 1_080)
    }

    var cameraDisplaySize: CGSize? {
        prepared?.cameraDisplaySize
    }

    var cameraContentCrop: NormalizedCrop? {
        prepared?.cameraContentCrop
    }

    var mediaPlan: ProjectTimelineMediaPlan? {
        prepared?.plan
    }

    var outputDuration: TimeInterval {
        prepared?.outputDuration ?? 0
    }

    var errorMessage: String? {
        guard case let .failed(_, message) = state else { return nil }
        return message
    }

    func thumbnail(
        atOutputTime outputTime: TimeInterval,
        maximumSize: CGSize = CGSize(width: 640, height: 360)
    ) async -> CGImage? {
        guard let prepared else { return nil }
        let expectedGeneration = prepared.generation
        let assetTime = EditorPlaybackClockPolicy.clampedTime(
            outputTime,
            duration: prepared.outputDuration
        )
        let source = ImmutablePreviewAsset(
            prepared.composition.primaryComposition,
            videoComposition: prepared.composition.primaryVideoComposition
        )
        do {
            let image = try await thumbnailDecoder.image(
                source: source,
                generation: expectedGeneration,
                at: assetTime,
                maximumSize: maximumSize
            )
            try Task.checkCancellation()
            guard self.prepared?.generation == expectedGeneration else { return nil }
            return image
        } catch {
            return nil
        }
    }

    func filmstripThumbnail(atSourceTime sourceTime: TimeInterval,
                            tolerance: TimeInterval) async -> CGImage? {
        guard !Task.isCancelled, sourceTime.isFinite, sourceTime >= 0,
              let prepared, let input = prepared.request.source
        else { return nil }
        let expectedGeneration = prepared.generation
        if filmstripInput != input {
            filmstripAsset = ImmutablePreviewAsset(AVURLAsset(url: input.url))
            filmstripInput = input
            filmstripSourceGeneration &+= 1
        }
        let sourceGeneration = filmstripSourceGeneration
        guard let source = filmstripAsset else { return nil }
        do {
            let image = try await filmstripDecoder.image(
                source: source, generation: sourceGeneration,
                at: sourceTime + prepared.plan.primarySourceTimeOffset,
                maximumSize: CGSize(width: 220, height: 140), tolerance: tolerance)
            try Task.checkCancellation()
            guard self.prepared?.generation == expectedGeneration else { return nil }
            return image
        } catch { return nil }
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
            let payload = try await preparation(request)
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
        guard request.editorSessionID == lastReadyMedia?.request.editorSessionID,
              let ready = lastReadyMedia,
              ready.request.sourceSequence == request.sourceSequence,
              ready.request.mediaManifest?.camera?.relativePath
                == request.cameraReference?.relativePath,
              ready.request.mediaManifest?.camera != request.cameraReference
        else { return }

        cameraTimingGeneration &+= 1
        let requestedGeneration = cameraTimingGeneration
        do {
            var manifest = ready.request.mediaManifest
            manifest?.camera = request.cameraReference
            guard let primaryRange = ready.inventories.source.videoTimeRange else { return }
            let plan = try ProjectTimelineMediaPlan(
                sourceSequence: request.sourceSequence,
                mediaManifest: manifest,
                primaryVideoRange: primaryRange,
                systemAudioRange: ready.inventories.source.audioTimeRange,
                cameraRange: ready.inventories.camera.videoTimeRange,
                microphoneRange: ready.inventories.microphone.audioTimeRange,
                sourcePointerEvents: ready.request.pointerEvents
            )
            let camera = try TimelineCompositionBuilder.buildCamera(
                plan: plan.camera,
                source: ready.payload.cameraSource
            )
            try Task.checkCancellation()
            guard requestedGeneration == cameraTimingGeneration,
                  lastReadyMedia?.generation == ready.generation else { return }

            let old = ready.composition
            let payload = EditorPreparedMediaPayload(
                composition: TimelineCompositionBundle(
                    plan: plan,
                    primaryComposition: old.primaryComposition,
                    primaryVideoTrack: old.primaryVideoTrack,
                    primaryVideoTracks: old.primaryVideoTracks,
                    primaryVideoComposition: old.primaryVideoComposition,
                    systemAudioTrack: old.systemAudioTrack,
                    microphoneAudioTrack: old.microphoneAudioTrack,
                    cameraComposition: camera?.composition,
                    cameraVideoTrack: camera?.track
                ),
                inventories: ready.inventories,
                sourceDisplaySize: ready.sourceDisplaySize,
                cameraDisplaySize: ready.cameraDisplaySize,
                cameraContentCrop: ready.cameraContentCrop,
                cameraSource: ready.payload.cameraSource
            )
            let updated = EditorPreparedMedia(
                generation: ready.generation,
                request: ready.request.updatingMediaManifest(manifest),
                payload: payload
            )
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
        filmstripAsset = nil
        filmstripInput = nil
        filmstripSourceGeneration &+= 1
        latestCameraTimingRequest = nil
        cameraTimingErrorMessage = nil
        let thumbnailDecoder = thumbnailDecoder
        let filmstripDecoder = filmstripDecoder
        Task {
            await thumbnailDecoder.invalidate()
            await filmstripDecoder.invalidate()
        }
    }
}
