import Foundation

public struct MediaSyncAnchor: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var sourceTime: TimeInterval
    public var offset: TimeInterval

    public init(
        id: UUID = UUID(),
        sourceTime: TimeInterval,
        offset: TimeInterval
    ) {
        self.id = id
        self.sourceTime = sourceTime.isFinite ? max(sourceTime, 0) : 0
        self.offset = offset.isFinite ? min(max(offset, -10), 10) : 0
    }
}

/// A package-relative project asset placed on the main recording timeline.
public struct ProjectMediaReference: Codable, Equatable, Sendable {
    public var relativePath: String
    public var startOffset: TimeInterval {
        didSet { startOffset = startOffset.isFinite ? max(startOffset, 0) : 0 }
    }
    /// Leading time to skip inside the source file. Auxiliary capture is
    /// intentionally started before the screen writer, so timeline alignment
    /// needs both a non-negative placement offset and a non-negative source
    /// trim instead of silently discarding a negative offset.
    public var sourceStartTime: TimeInterval {
        didSet { sourceStartTime = sourceStartTime.isFinite ? max(sourceStartTime, 0) : 0 }
    }
    /// Source-clock seconds consumed by one second on the primary recording
    /// clock. Independent capture devices can drift even when their first
    /// frames are aligned; preserving this rate aligns both the beginning and
    /// the end instead of accumulating lip-sync error over a long recording.
    /// `nil` lets legacy projects infer the rate from their finalized media.
    public var sourceTimeScale: Double? {
        didSet {
            guard let sourceTimeScale else { return }
            self.sourceTimeScale = sourceTimeScale.isFinite && sourceTimeScale > 0
                ? sourceTimeScale : nil
        }
    }
    /// Optional source-clock end captured at the shared stop host time. An
    /// auxiliary writer may physically finish later, but post-roll after this
    /// boundary is never part of the project timeline.
    public var sourceEndTime: TimeInterval? {
        didSet {
            guard let sourceEndTime else { return }
            self.sourceEndTime = sourceEndTime.isFinite && sourceEndTime >= 0
                ? sourceEndTime : nil
        }
    }
    /// Piecewise camera-clock correction. Times are stored on the original
    /// screen source clock so ripple edits do not move or invalidate them.
    public var syncAnchors: [MediaSyncAnchor] {
        didSet { syncAnchors = Self.normalizedSyncAnchors(syncAnchors) }
    }

    public init(
        relativePath: String,
        startOffset: TimeInterval = 0,
        sourceStartTime: TimeInterval = 0,
        sourceTimeScale: Double? = nil,
        sourceEndTime: TimeInterval? = nil,
        syncAnchors: [MediaSyncAnchor] = []
    ) {
        self.relativePath = relativePath
        self.startOffset = startOffset.isFinite ? max(startOffset, 0) : 0
        self.sourceStartTime = sourceStartTime.isFinite ? max(sourceStartTime, 0) : 0
        self.sourceTimeScale = sourceTimeScale.flatMap {
            $0.isFinite && $0 > 0 ? $0 : nil
        }
        self.sourceEndTime = sourceEndTime.flatMap {
            $0.isFinite && $0 >= 0 ? $0 : nil
        }
        self.syncAnchors = Self.normalizedSyncAnchors(syncAnchors)
    }

    private enum CodingKeys: String, CodingKey {
        case relativePath
        case startOffset
        case sourceStartTime
        case sourceTimeScale
        case sourceEndTime
        case syncAnchors
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            relativePath: try container.decode(String.self, forKey: .relativePath),
            startOffset: try container.decodeIfPresent(
                TimeInterval.self,
                forKey: .startOffset
            ) ?? 0,
            sourceStartTime: try container.decodeIfPresent(
                TimeInterval.self,
                forKey: .sourceStartTime
            ) ?? 0,
            sourceTimeScale: try container.decodeIfPresent(
                Double.self,
                forKey: .sourceTimeScale
            ),
            sourceEndTime: try container.decodeIfPresent(
                TimeInterval.self,
                forKey: .sourceEndTime
            ),
            syncAnchors: try container.decodeIfPresent(
                [MediaSyncAnchor].self,
                forKey: .syncAnchors
            ) ?? []
        )
    }

    private static func normalizedSyncAnchors(
        _ anchors: [MediaSyncAnchor]
    ) -> [MediaSyncAnchor] {
        anchors
            .map { MediaSyncAnchor(id: $0.id, sourceTime: $0.sourceTime, offset: $0.offset) }
            .sorted {
                if $0.sourceTime != $1.sourceTime { return $0.sourceTime < $1.sourceTime }
                return $0.id.uuidString < $1.id.uuidString
            }
    }
}

/// Complete media inventory for a recorded project.
///
/// `screen` is structurally required once a manifest exists. A fresh project
/// that has not recorded anything uses `RecorderProject.media == nil`; this
/// avoids partial manifests containing only orphan camera or audio files.
public struct ProjectMediaManifest: Codable, Equatable, Sendable {
    public var screen: ProjectMediaReference
    public var camera: ProjectMediaReference?
    public var microphone: ProjectMediaReference?
    public var pointerEvents: ProjectMediaReference?

    public init(
        screen: ProjectMediaReference,
        camera: ProjectMediaReference? = nil,
        microphone: ProjectMediaReference? = nil,
        pointerEvents: ProjectMediaReference? = nil
    ) {
        self.screen = screen
        self.camera = camera
        self.microphone = microphone
        self.pointerEvents = pointerEvents
    }
}

public struct RecorderProject: Codable, Equatable, Sendable {
    public var version: Int
    public var title: String
    public var createdAt: Date
    public var capture: CaptureConfiguration
    public var canvas: CanvasStyle
    public var camera: CameraStyle
    public var audio: AudioStyle
    public var motion: MotionStyle
    public var openingSequence: OpeningSequence
    public var cursorStyle: CursorStyle
    public var exportSettings: ExportSettings
    public var timeline: ProjectTimeline
    public var media: ProjectMediaManifest?

    /// Source-compatibility bridge while app call sites migrate to
    /// `timeline.zoomClips`. This is not a second persisted field.
    public var zoomAnimations: [ZoomAnimationClip] {
        get { timeline.zoomClips }
        set { timeline.zoomClips = newValue }
    }

    public init(
        version: Int = ProjectSchema.currentVersion,
        title: String = "未命名录制",
        createdAt: Date = Date(),
        capture: CaptureConfiguration = CaptureConfiguration(),
        canvas: CanvasStyle = CanvasStyle(),
        camera: CameraStyle = CameraStyle(),
        audio: AudioStyle = AudioStyle(),
        motion: MotionStyle = MotionStyle(),
        openingSequence: OpeningSequence = OpeningSequence(),
        cursorStyle: CursorStyle = CursorStyle(),
        exportSettings: ExportSettings = ExportSettings(),
        zoomAnimations: [ZoomAnimationClip] = [],
        timeline: ProjectTimeline? = nil,
        media: ProjectMediaManifest? = nil
    ) {
        self.version = version
        self.title = title
        self.createdAt = createdAt
        self.capture = capture
        self.canvas = canvas
        self.camera = camera
        self.audio = audio
        self.motion = motion
        self.openingSequence = openingSequence
        self.cursorStyle = cursorStyle
        self.exportSettings = exportSettings
        self.timeline = timeline ?? ProjectTimeline(zoomClips: zoomAnimations)
        self.media = media
    }

    private enum CodingKeys: String, CodingKey {
        case version
        case title
        case createdAt
        case capture
        case canvas
        case camera
        case audio
        case motion
        case openingSequence
        case cursorStyle
        case exportSettings
        case timeline
        case zoomKeyframes
        case zoomAnimations
        case media
        // v1/v2 decode-only fields.
        case screenRecordingRelativePath
        case cameraRecordingRelativePath
        case microphoneRecordingRelativePath
        case pointerEventsRelativePath
        case cameraStartOffset
        case microphoneStartOffset
        case pointerStartOffset
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let decodedVersion = try container.decodeIfPresent(Int.self, forKey: .version) ?? 1
        try ProjectSchema.validateForDecoding(decodedVersion)
        let legacyCaptureExport = try container.decodeIfPresent(
            LegacyCaptureExportFields.self,
            forKey: .capture
        )
        let legacyCanvasExport = try container.decodeIfPresent(
            LegacyCanvasExportFields.self,
            forKey: .canvas
        )
        version = ProjectSchema.currentVersion
        title = try container.decodeIfPresent(String.self, forKey: .title) ?? "未命名录制"
        createdAt = try container.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
        capture = try container.decodeIfPresent(CaptureConfiguration.self, forKey: .capture)
            ?? CaptureConfiguration()
        if container.contains(.canvas) {
            canvas = try CanvasStyle(
                from: container.superDecoder(forKey: .canvas),
                projectSchemaVersion: decodedVersion
            )
        } else {
            canvas = CanvasStyle()
        }
        camera = try container.decodeIfPresent(CameraStyle.self, forKey: .camera) ?? CameraStyle()
        audio = try container.decodeIfPresent(AudioStyle.self, forKey: .audio) ?? AudioStyle()
        motion = try container.decodeIfPresent(MotionStyle.self, forKey: .motion) ?? MotionStyle()
        openingSequence = try container.decodeIfPresent(
            OpeningSequence.self,
            forKey: .openingSequence
        ) ?? OpeningSequence()
        cursorStyle = try container.decodeIfPresent(CursorStyle.self, forKey: .cursorStyle) ?? CursorStyle()
        if decodedVersion >= 5 {
            var decodedSettings = try container.decode(
                ExportSettings.self,
                forKey: .exportSettings
            )
            // Before v7, 1080p was the implicit project default. It must not
            // keep silently downscaling a native 4K/5K recording after the
            // product switched to source-driven full quality.
            if decodedVersion < 7, decodedSettings.resolution == .fullHD {
                decodedSettings.resolution = .source
            }
            exportSettings = decodedSettings
        } else {
            let legacyResolution = legacyCanvasExport?.resolution ?? .fullHD
            exportSettings = ExportSettings(
                frameRate: legacyCaptureExport?.exportFrameRate ?? .fps60,
                resolution: legacyResolution == .fullHD ? .source : legacyResolution
            )
        }
        if decodedVersion >= 4 {
            timeline = try container.decode(ProjectTimeline.self, forKey: .timeline)
        } else {
            let decodedAnimations = try container.decodeIfPresent(
                [ZoomAnimationClip].self,
                forKey: .zoomAnimations
            )
            let migratedAnimations: [ZoomAnimationClip]
            if decodedVersion == 1, !container.contains(.zoomAnimations) {
                let legacyKeyframes = try container.decodeIfPresent(
                    [ZoomKeyframe].self,
                    forKey: .zoomKeyframes
                ) ?? []
                migratedAnimations = ZoomAnimationClip.migrating(
                    keyframes: legacyKeyframes,
                    defaultEasing: motion.defaultZoomEasing
                )
            } else {
                // An explicitly empty animation array is authoritative, even
                // when a v1 file also contains stale legacy keyframes.
                migratedAnimations = decodedAnimations ?? []
            }
            timeline = ProjectTimeline(zoomClips: migratedAnimations)
        }
        if decodedVersion >= 3 {
            // Current projects never consult stale flat paths. An absent media
            // manifest means the project intentionally has no recording yet.
            media = try container.decodeIfPresent(
                ProjectMediaManifest.self,
                forKey: .media
            )
        } else {
            let screenPath = try container.decodeIfPresent(
                String.self,
                forKey: .screenRecordingRelativePath
            )
            if let screenPath, !screenPath.isEmpty {
                let cameraPath = try container.decodeIfPresent(
                    String.self,
                    forKey: .cameraRecordingRelativePath
                )
                let microphonePath = try container.decodeIfPresent(
                    String.self,
                    forKey: .microphoneRecordingRelativePath
                )
                let pointerPath = try container.decodeIfPresent(
                    String.self,
                    forKey: .pointerEventsRelativePath
                )
                let cameraOffset = try container.decodeIfPresent(
                    TimeInterval.self,
                    forKey: .cameraStartOffset
                ) ?? 0
                let microphoneOffset = try container.decodeIfPresent(
                    TimeInterval.self,
                    forKey: .microphoneStartOffset
                ) ?? 0
                let pointerOffset = try container.decodeIfPresent(
                    TimeInterval.self,
                    forKey: .pointerStartOffset
                ) ?? 0
                media = ProjectMediaManifest(
                    screen: ProjectMediaReference(relativePath: screenPath),
                    camera: cameraPath.flatMap { path in
                        path.isEmpty ? nil : ProjectMediaReference(
                            relativePath: path,
                            startOffset: cameraOffset
                        )
                    },
                    microphone: microphonePath.flatMap { path in
                        path.isEmpty ? nil : ProjectMediaReference(
                            relativePath: path,
                            startOffset: microphoneOffset
                        )
                    },
                    pointerEvents: pointerPath.flatMap { path in
                        path.isEmpty ? nil : ProjectMediaReference(
                            relativePath: path,
                            startOffset: pointerOffset
                        )
                    }
                )
            } else {
                // Camera/audio/event paths without a screen are orphaned and
                // cannot form a valid recorded project manifest.
                media = nil
            }
        }
    }

    public func encode(to encoder: any Encoder) throws {
        try ProjectSchema.validateForEncoding(version)
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(ProjectSchema.currentVersion, forKey: .version)
        try container.encode(title, forKey: .title)
        try container.encode(createdAt, forKey: .createdAt)
        try container.encode(capture, forKey: .capture)
        try container.encode(canvas, forKey: .canvas)
        try container.encode(camera, forKey: .camera)
        try container.encode(audio, forKey: .audio)
        try container.encode(motion, forKey: .motion)
        try container.encode(openingSequence, forKey: .openingSequence)
        try container.encode(cursorStyle, forKey: .cursorStyle)
        try container.encode(exportSettings, forKey: .exportSettings)
        try container.encode(timeline, forKey: .timeline)
        try container.encodeIfPresent(media, forKey: .media)
    }

}

/// Decode-only access to export fields persisted before project schema v5.
/// Keeping these compatibility records outside `CaptureConfiguration` and
/// `CanvasStyle` prevents either domain type from retaining a second owner.
private struct LegacyCaptureExportFields: Decodable {
    let exportFrameRate: OutputFrameRate?
}

private struct LegacyCanvasExportFields: Decodable {
    let resolution: CanvasResolution?
}
