import Foundation

/// One recording's independent media clocks and source geometry. The primary
/// recording remains in the legacy project fields; imported recordings live
/// in `additionalSources`. Neither is an inserted, flattened video.
public struct RecordingSource: Codable, Equatable, Identifiable, Sendable {
    public static let primaryID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!

    public var id: UUID
    public var name: String
    public var media: ProjectMediaManifest
    public var capture: CaptureConfiguration
    public var cameraContentCrop: NormalizedCrop?
    public var crop: NormalizedCrop
    /// Stable import-order palette slot; nil preserves projects saved before source colours.
    public var colorIndex: Int?
    public var cameraAppearance: CameraStyle?
    public var screenAppearance: ScreenCardAppearance?

    public init(
        id: UUID = UUID(),
        name: String,
        media: ProjectMediaManifest,
        capture: CaptureConfiguration = CaptureConfiguration(),
        cameraContentCrop: NormalizedCrop? = nil,
        crop: NormalizedCrop = .full,
        colorIndex: Int? = nil,
        cameraAppearance: CameraStyle? = nil,
        screenAppearance: ScreenCardAppearance? = nil
    ) {
        self.id = id
        self.name = name
        self.media = media
        self.capture = capture
        self.cameraContentCrop = cameraContentCrop?.clamped()
        self.crop = crop.clamped()
        self.colorIndex = colorIndex.map { max($0, 0) }
        self.cameraAppearance = cameraAppearance
        self.screenAppearance = screenAppearance
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, media, capture, cameraContentCrop, crop, colorIndex, cameraAppearance, screenAppearance
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            id: try c.decode(UUID.self, forKey: .id),
            name: try c.decodeIfPresent(String.self, forKey: .name) ?? "",
            media: try c.decode(ProjectMediaManifest.self, forKey: .media),
            capture: try c.decodeIfPresent(CaptureConfiguration.self, forKey: .capture) ?? CaptureConfiguration(),
            cameraContentCrop: try c.decodeIfPresent(NormalizedCrop.self, forKey: .cameraContentCrop),
            crop: try c.decodeIfPresent(NormalizedCrop.self, forKey: .crop) ?? .full,
            colorIndex: try c.decodeIfPresent(Int.self, forKey: .colorIndex),
            cameraAppearance: try c.decodeIfPresent(CameraStyle.self, forKey: .cameraAppearance),
            screenAppearance: try c.decodeIfPresent(ScreenCardAppearance.self, forKey: .screenAppearance)
        )
    }
}

public extension RecorderProject {
    /// The recording the programme opens on. The opening sequence animates
    /// that recording's camera bubble in, so a camera belonging to some later
    /// recording must not add a slot to its roster. Read this before any code
    /// rebinds `media` to the frame's own source.
    var openingRecordingSourceID: UUID {
        guard case let .edited(segments) = timeline.sourceSequence else { return RecordingSource.primaryID }
        return segments.first?.resolvedSourceID ?? RecordingSource.primaryID
    }

    /// Whether the opening's own recording brings a camera, from the manifest
    /// rather than from whatever happens to be decoded right now.
    var openingDeclaresCamera: Bool {
        source(openingRecordingSourceID)?.media.camera != nil
    }
}

public extension RecorderProject {
    /// A view over the original fields, never a second persisted primary source.
    var sources: [RecordingSource] {
        let primary = media.map {
            RecordingSource(id: RecordingSource.primaryID, name: title, media: $0,
                            capture: capture, crop: canvas.crop, screenAppearance: ScreenCardAppearance(canvas: canvas))
        }
        return primary.map { [$0] + additionalSources } ?? additionalSources
    }

    /// An unknown source must never fall back to the primary recording's media.
    func source(_ id: UUID) -> RecordingSource? {
        if id == RecordingSource.primaryID {
            return media.map {
                RecordingSource(id: id, name: title, media: $0, capture: capture, crop: canvas.crop, screenAppearance: ScreenCardAppearance(canvas: canvas))
            }
        }
        return additionalSources.first { $0.id == id }
    }
}

public extension RecorderProject {
    /// Mutations name their recording explicitly. Unknown IDs never edit the
    /// primary recording, and its legacy storage stays backwards compatible.
    @discardableResult
    mutating func setMedia(_ manifest: ProjectMediaManifest, for sourceID: UUID) -> Bool {
        if sourceID == RecordingSource.primaryID {
            guard media != nil else { return false }
            media = manifest
            return true
        }
        guard let index = additionalSources.firstIndex(where: { $0.id == sourceID }) else { return false }
        additionalSources[index].media = manifest
        return true
    }

    /// Frame stepping and frame read-outs follow the recording that is
    /// actually on screen; an imported 30 fps source keeps its own grid.
    func captureFrameRate(for sourceID: UUID?) -> OutputFrameRate {
        sourceID.flatMap { source($0)?.capture.captureFrameRate } ?? capture.captureFrameRate
    }

    @discardableResult
    mutating func setCrop(_ crop: NormalizedCrop, for sourceID: UUID) -> Bool {
        if sourceID == RecordingSource.primaryID {
            canvas.crop = crop.clamped()
            return true
        }
        guard let index = additionalSources.firstIndex(where: { $0.id == sourceID }) else { return false }
        additionalSources[index].crop = crop.clamped()
        return true
    }

    /// Narrows the crop to one occurrence of a recording, or, with nil, puts
    /// that occurrence back on its recording's own rectangle. An inserted clip
    /// has no recording to deviate from, so it is refused.
    @discardableResult
    mutating func setSegmentCrop(_ crop: NormalizedCrop?, forSegmentID id: UUID) -> Bool {
        timeline.setSegmentCrop(crop, forSegmentID: id)
    }

    /// How many times one recording appears on the main track. A per-clip crop
    /// is only a meaningful choice when there is more than one.
    func segmentCount(forSourceID sourceID: UUID) -> Int {
        guard case let .edited(segments) = timeline.sourceSequence else { return 1 }
        return segments.count { $0.media == nil && $0.resolvedSourceID == sourceID }
    }
}

public extension ProjectTimeline {
    @discardableResult
    mutating func setSegmentCrop(_ crop: NormalizedCrop?, forSegmentID id: UUID) -> Bool {
        guard case var .edited(segments) = sourceSequence,
              let index = segments.firstIndex(where: { $0.id == id }),
              segments[index].media == nil else { return false }
        segments[index].crop = crop?.clamped()
        sourceSequence = .edited(segments)
        return true
    }
}
