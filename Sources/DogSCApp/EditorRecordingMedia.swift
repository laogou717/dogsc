import AVFoundation
import Foundation
import RecorderCore

/// Value-only geometry captured with a prepared generation. The display link
/// never opens files or consults the primary recording for another source.
struct EditorRecordingGeometry: Equatable, Sendable {
    let screenSize: CGSize
    let cameraSize: CGSize?
}

struct EditorRecordingFrameInput {
    let asset: ImmutablePreviewAsset
    let assetTime: TimeInterval
    let cacheKey: String
}

extension EditorMediaRequest {
    func cameraInput(for sourceID: UUID?) -> EditorMediaInput? {
        guard let sourceID else { return nil }
        return sourceID == RecordingSource.primaryID ? camera : additionalSources[sourceID]?.camera
    }

    func screenInput(for sourceID: UUID) -> EditorMediaInput? {
        sourceID == RecordingSource.primaryID ? source : additionalSources[sourceID]?.screen
    }

    var cameraReferences: [UUID: ProjectMediaReference] {
        var references = additionalSources.compactMapValues { $0.manifest.camera }
        references[RecordingSource.primaryID] = mediaManifest?.camera
        return references
    }

    func updatingCameraReferences(_ references: [UUID: ProjectMediaReference]) -> EditorMediaRequest {
        var request = self
        request.mediaManifest?.camera = references[RecordingSource.primaryID]
        for id in request.additionalSources.keys {
            request.additionalSources[id]?.manifest.camera = references[id]
        }
        return request
    }
}

extension EditorPreparedMedia {
    var recordingGeometry: [UUID: EditorRecordingGeometry] {
        composition.recordingSources.mapValues { tracks in
            EditorRecordingGeometry(screenSize: tracks.screen.displaySize ?? CGSize(width: 1920, height: 1080),
                cameraSize: CameraLetterboxAnalysis.croppedDisplaySize(tracks.camera?.displaySize, crop: tracks.cameraContentCrop))
        }
    }

    func screenFrameInput(at outputTime: TimeInterval) -> EditorRecordingFrameInput? {
        let time = EditorPlaybackClockPolicy.frameLookupTime(outputTime, duration: outputDuration)
        guard let slice = plan.primary.slice(atOutputTime: time),
              let sourceTime = slice.sourceTime(atOutputTime: time) else { return nil }
        let track = slice.media.flatMap { composition.insertedSources[$0.path] }
            ?? (slice.media == nil ? composition.recordingSources[slice.sourceID]?.screen : nil)
        guard let track else { return nil }
        return EditorRecordingFrameInput(asset: ImmutablePreviewAsset(track.asset),
            assetTime: sourceTime + (slice.media == nil ? plan.sourceTimeOffsets[slice.sourceID] ?? 0 : track.timeRange.start.seconds), cacheKey: track.asset.url.path)
    }

    func cameraFrameInput(at outputTime: TimeInterval) -> EditorRecordingFrameInput? {
        let time = EditorPlaybackClockPolicy.frameLookupTime(outputTime, duration: outputDuration)
        guard let slice = plan.camera?.slice(atOutputTime: time),
              let sourceTime = slice.sourceTime(atOutputTime: time),
              let track = composition.recordingSources[slice.sourceID]?.camera else { return nil }
        return EditorRecordingFrameInput(asset: ImmutablePreviewAsset(track.asset), assetTime: sourceTime, cacheKey: track.asset.url.path)
    }
}

extension EditorMediaSession {
    func sourceID(at outputTime: TimeInterval) -> UUID? {
        guard let plan = mediaPlan else { return nil }
        return plan.timelineMap.sourcePosition(atOutputTime: EditorPlaybackClockPolicy.frameLookupTime(outputTime, duration: plan.outputDuration))?.sourceID
    }

    func sourceDisplaySize(for sourceID: UUID) -> CGSize? {
        prepared?.composition.recordingSources[sourceID]?.screen.displaySize
    }

    func cameraDisplaySize(for sourceID: UUID) -> CGSize? {
        guard let tracks = prepared?.composition.recordingSources[sourceID] else { return nil }
        return CameraLetterboxAnalysis.croppedDisplaySize(tracks.camera?.displaySize, crop: tracks.cameraContentCrop)
    }

    func inventories(for sourceID: UUID) -> EditorMediaInventories {
        prepared?.payload.inventoriesBySource[sourceID] ?? .empty
    }
}

struct EditorPlaybackSourceFrame: Equatable, Sendable {
    let screenSlice: TimelineMediaSlice?
    let cameraSlice: TimelineMediaSlice?
    let screenTransform: CGAffineTransform
    let cameraTransform: CGAffineTransform
    let cameraContentCrop: NormalizedCrop?
    var usesPrimaryFrameForCamera = false

    var recordingSourceID: UUID? {
        screenSlice.flatMap { $0.media == nil ? $0.sourceID : nil }
    }
}

struct PreviewSourceMetadata: Sendable {
    let plan: ProjectTimelineMediaPlan
    let screens: [UUID: CGAffineTransform]
    let cameras: [UUID: CGAffineTransform]
    let crops: [UUID: NormalizedCrop]
    let inserts: [String: CGAffineTransform]
    var primaryCameraOffsets: [UUID: TimeInterval] = [:]

    func frame(at outputTime: TimeInterval) -> EditorPlaybackSourceFrame {
        let time = EditorPlaybackClockPolicy.frameLookupTime(outputTime, duration: plan.outputDuration)
        let screen = plan.primary.slice(atOutputTime: time)
        let camera = plan.camera?.slice(atOutputTime: time)
        return EditorPlaybackSourceFrame(screenSlice: screen, cameraSlice: camera,
            screenTransform: screen.flatMap { slice in
                if let media = slice.media { return inserts[media.path] }
                return screens[slice.sourceID]
            } ?? .identity,
            cameraTransform: camera.flatMap { cameras[$0.sourceID] } ?? .identity,
            cameraContentCrop: camera.flatMap { crops[$0.sourceID] },
            usesPrimaryFrameForCamera: screen.map { primary in
                primaryCameraOffsets[primary.sourceID].map {
                    primary.sharesCameraFrame(with: camera, at: time, sourceOffset: $0)
                } ?? false
            } ?? false)
    }
}

extension TimelineCompositionBundle {
    func layoutAspectRatio(for canvas: CanvasStyle) -> Double? {
        recordingSources[RecordingSource.primaryID]?.screen.displaySize.map {
            Double(EditorWorkspaceGeometry.aspectRatio(canvas: canvas, sourceSize: $0))
        }
    }

    var previewMetadata: PreviewSourceMetadata {
        PreviewSourceMetadata(plan: plan,
            screens: recordingSources.mapValues { $0.screen.preferredTransform },
            cameras: recordingSources.compactMapValues { $0.camera?.preferredTransform },
            crops: recordingSources.compactMapValues { $0.cameraContentCrop },
            inserts: insertedSources.mapValues { $0.preferredTransform },
            primaryCameraOffsets: recordingSources.compactMapValues { $0.usesCameraAsPrimary ? $0.screen.timeRange.start.seconds : nil })
    }

    func frameMetadata(at outputTime: TimeInterval) -> EditorPlaybackSourceFrame {
        previewMetadata.frame(at: outputTime)
    }
}

/// Native resolution uses the largest used recording while the canvas ratio
/// stays anchored to the primary recording. Export, its size label and full
/// quality preview all consume this same pixel envelope.
enum EditorRecordingCanvasGeometry {
    static func sourceSize(project: RecorderProject, sizes: [UUID: CGSize]) -> CGSize {
        let primary = sizes[RecordingSource.primaryID] ?? CGSize(width: 1920, height: 1080)
        let crop = project.canvas.crop.clamped()
        let primaryEdge = max(primary.width * crop.width, primary.height * crop.height)
        let used = TimelinePreviewCompositionLoader.referencedSourceIDs(project.timeline.sourceSequence)
        let largest = sizes.filter { used.contains($0.key) }.map { id, size in
            let crop = project.source(id)?.crop.clamped() ?? .full
            return max(size.width * crop.width, size.height * crop.height)
        }.max() ?? primaryEdge
        let baseScale = max(largest / max(primaryEdge, 1), 1)
        var scale = baseScale
        let envelope = CGSize(width: primary.width * scale, height: primary.height * scale)
        let canvas = project.canvas.pixelDimensions(resolution: .source,
            sourcePixelSize: CanvasDimensions(width: Int(envelope.width), height: Int(envelope.height)))
        // Fitting a portrait phone's envelope INSIDE a landscape canvas used
        // to turn 1320×2868 into a 1320×742 full-quality render. Preserve the
        // device's pixel density by expanding the background envelope instead.
        // Desktop-only projects retain their existing native canvas contract.
        for (id, size) in sizes where used.contains(id) && project.source(id)?.capture.source == .device {
            let sourceCrop = project.source(id)?.crop.clamped() ?? .full
            let density = max(size.width * sourceCrop.width / CGFloat(max(canvas.width, 2)),
                              size.height * sourceCrop.height / CGFloat(max(canvas.height, 2)))
            scale = max(scale, baseScale * density)
        }
        return CGSize(width: primary.width * scale, height: primary.height * scale)
    }
}

extension EditorMediaSession {
    func canvasSourceSize(for project: RecorderProject) -> CGSize {
        EditorRecordingCanvasGeometry.sourceSize(project: project,
            sizes: prepared?.recordingGeometry.mapValues(\.screenSize) ?? [:])
    }
    var hasSystemAudio: Bool { prepared?.payload.inventoriesBySource.values.contains { $0.source.hasAudio } == true }
    var hasMicrophoneAudio: Bool { prepared?.payload.inventoriesBySource.values.contains { $0.microphone.hasAudio } == true }
    var hasCameraVideo: Bool { prepared?.payload.inventoriesBySource.values.contains { $0.camera.hasVideo } == true }
}
