import Foundation

public enum ExportVideoCodec: String, Codable, CaseIterable, Hashable, Sendable {
    case h264
    case hevc

    public var displayName: String {
        switch self {
        case .h264: "H.264"
        case .hevc: "HEVC"
        }
    }
}

public enum ExportQuality: String, Codable, CaseIterable, Hashable, Sendable {
    case compact
    case high
    case maximum

    public var displayName: String {
        switch self {
        case .compact: "体积优先"
        case .high: "高质量"
        case .maximum: "极致"
        }
    }

    public var detail: String {
        switch self {
        case .compact: "文件更小，适合快速分享"
        case .high: "兼顾画质和文件大小"
        case .maximum: "保留更多细节，文件更大"
        }
    }
}

/// Persisted output choices for one project.
///
/// Capture configuration and canvas styling intentionally do not own these
/// values: changing an export preset must not rewrite how footage was captured
/// or introduce a second output-resolution authority in the visual model.
public struct ExportSettings: Codable, Equatable, Sendable {
    public var frameRate: OutputFrameRate
    public var resolution: CanvasResolution
    /// Optional for compatibility with projects saved before codec selection.
    public var videoCodec: ExportVideoCodec?
    public var quality: ExportQuality

    public init(
        frameRate: OutputFrameRate = .fps60,
        resolution: CanvasResolution = .source,
        videoCodec: ExportVideoCodec? = .h264,
        quality: ExportQuality = .high
    ) {
        self.frameRate = frameRate
        self.resolution = resolution
        self.videoCodec = videoCodec
        self.quality = quality
    }

    private enum CodingKeys: String, CodingKey { case frameRate, resolution, videoCodec, quality }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        frameRate = try container.decodeIfPresent(OutputFrameRate.self, forKey: .frameRate) ?? .fps60
        resolution = try container.decodeIfPresent(CanvasResolution.self, forKey: .resolution) ?? .source
        videoCodec = try container.decodeIfPresent(ExportVideoCodec.self, forKey: .videoCodec)
        quality = try container.decodeIfPresent(ExportQuality.self, forKey: .quality) ?? .high
    }

    public func resolvedVideoCodec(for requested: CanvasDimensions) -> ExportVideoCodec {
        videoCodec ?? .h264
    }

    /// Adapt the rendered output, never the canvas or the recorded sources.
    /// Switching back to HEVC therefore restores the requested native pixels.
    public func outputDimensions(for requested: CanvasDimensions) -> CanvasDimensions {
        guard resolvedVideoCodec(for: requested) == .h264,
              max(requested.width, requested.height) > 4_096 else { return requested }
        let scale = 4_096.0 / Double(max(requested.width, requested.height))
        func even(_ edge: Int) -> Int {
            max(2, Int((Double(edge) * scale / 2).rounded()) * 2)
        }
        return CanvasDimensions(width: even(requested.width), height: even(requested.height))
    }
}
