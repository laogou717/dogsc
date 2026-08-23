import Foundation

/// Persisted output choices for one project.
///
/// Capture configuration and canvas styling intentionally do not own these
/// values: changing an export preset must not rewrite how footage was captured
/// or introduce a second output-resolution authority in the visual model.
public struct ExportSettings: Codable, Equatable, Sendable {
    public var frameRate: OutputFrameRate
    public var resolution: CanvasResolution

    public init(
        frameRate: OutputFrameRate = .fps60,
        resolution: CanvasResolution = .source
    ) {
        self.frameRate = frameRate
        self.resolution = resolution
    }
}
