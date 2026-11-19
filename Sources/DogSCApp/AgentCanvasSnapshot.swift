import AVFoundation
import CoreImage
import Foundation
import RecorderCore

/// One immutable request with its own decoders and HTML pages. It never seeks
/// the editor's AVPlayer or reads the live preview's last rendered image.
final class AgentCanvasSnapshot: @unchecked Sendable {
    struct Result: @unchecked Sendable {
        let scene: FrameScene
        let image: CGImage
        let decodedSourceTime: Double?
        let sourceID: UUID?
        let segmentID: UUID
    }

    private let project: RecorderProject
    private let media: TimelineCompositionBundle
    private let canvas: CGSize
    private let backgrounds: [String: URL]
    private let cursors: [CursorAssetID: CursorRenderSource]
    private let package: URL
    private let cancellation = ExportCancellationLatch()

    init(project: RecorderProject, media: TimelineCompositionBundle, canvas: CGSize,
         backgrounds: [String: URL], cursors: [CursorAssetID: CursorRenderSource], package: URL) {
        self.project = project; self.media = media; self.canvas = canvas
        self.backgrounds = backgrounds; self.cursors = cursors; self.package = package
    }

    func cancel() { cancellation.request() }

    private func url(_ path: String) -> URL {
        path.hasPrefix("/") ? URL(fileURLWithPath: path) : package.appendingPathComponent(path)
    }

    func render(at time: Double, sourceOnly: Bool, maxDimension: Double) async throws -> Result {
        try Task.checkCancellation()
        guard let slice = media.plan.primary.slice(atOutputTime: time) else {
            throw SnapshotError("No main-track frame at the requested time.")
        }
        if sourceOnly, slice.media?.motionPath != nil {
            throw SnapshotError("An HTML motion has no source recording. Use view: canvas to render its frame.")
        }
        let screenReader = ExportTimelineVideoReader(sources: media.recordingSources.mapValues(\.screen),
            inserted: media.insertedSources, offsets: media.plan.sourceTimeOffsets, role: .screenRecording)
        let cameraReader = ExportTimelineVideoReader(sources: media.recordingSources.compactMapValues(\.camera), role: .cameraRecording)
        defer { screenReader.close(); cameraReader.close() }
        guard let buffer = try screenReader.frame(in: slice, at: time, cancellation: cancellation, progress: {}) else {
            throw SnapshotError("No video sample in the requested clip.")
        }
        var source = VideoExporter.orientVideoFrameForDisplay(CIImage(cvPixelBuffer: buffer),
            preferredTransform: slice.media.flatMap { media.insertedSources[$0.path]?.preferredTransform }
                ?? media.recordingSources[slice.sourceID]?.screen.preferredTransform ?? .identity)
        if let path = slice.media?.imagePath {
            let localTime = slice.sourceStart + max(time - slice.outputStart, 0) * slice.sourceTimeScale
            guard let image = ImageMediaFrameCache.shared.frame(at: url(path), time: localTime) else {
                throw SnapshotError("Could not read main-track image \(path).")
            }
            source = image
        }
        var camera: CIImage?
        if let cameraSlice = media.plan.camera?.slice(atOutputTime: time),
           let frame = try cameraReader.frame(in: cameraSlice, at: time, cancellation: cancellation, progress: {}) {
            let oriented = VideoExporter.orientVideoFrameForDisplay(CIImage(cvPixelBuffer: frame),
                preferredTransform: media.recordingSources[cameraSlice.sourceID]?.camera?.preferredTransform ?? .identity)
            camera = media.recordingSources[cameraSlice.sourceID]?.cameraContentCrop
                .map { CameraLetterboxAnalysis.cropped(oriented, to: $0) } ?? oriented
        }
        let transitions = RecordingAspectTransitions(primary: media.plan.primary,
            sourceAspectRatios: media.recordingSources.compactMapValues {
                $0.screen.displaySize.map { Double($0.width / max($0.height, 1)) }
            }, crops: Dictionary(uniqueKeysWithValues: project.sources.map { ($0.id, $0.crop) }),
            frameStyles: Dictionary(uniqueKeysWithValues: project.sources.map {
                ($0.id, $0.screenAppearance?.screenFrame ?? project.canvas.screenFrame)
            }), segmentStyles: project.segmentSceneStyles, segmentCrops: project.segmentCrops)
        let scale = min(maxDimension / max(canvas.width, canvas.height), 1)
        let size = CGSize(width: max(2, (canvas.width * scale).rounded()), height: max(2, (canvas.height * scale).rounded()))
        let plan = FrameSceneEvaluator.renderPlan(project: project, presentationTime: time,
            outputDuration: media.plan.outputDuration, frameRate: project.exportSettings.frameRate.rawValue,
            canvasSize: CompositionSize(width: size.width, height: size.height),
            sourceAspectRatio: source.extent.width / max(source.extent.height, 1),
            cameraSourceSize: camera.map { CompositionSize(width: $0.extent.width, height: $0.extent.height) },
            pointerTrack: media.plan.pointer, cursorMetrics: cursors[project.cursorStyle.assetID]?.metrics,
            cursorMetricsByAssetID: cursors.mapValues(\.metrics),
            zoomTrack: ZoomAnimationTrack(project.zoomAnimations, outputDuration: media.plan.outputDuration),
            screenMotionTrack: ScreenMotionTrack(project.timeline.screenMotionClips),
            cameraMotionTrack: CameraMotionTrack(project.timeline.cameraMotionClips),
            stickerTrack: StickerTransitionTrack(project.timeline.stickerClips), cameraTimeline: media.plan.camera,
            recordingSourceID: slice.media == nil ? slice.sourceID : nil,
            geometrySourceAspectRatio: transitions.sourceAspectRatio(atOutputTime: time,
                sourceID: slice.media == nil ? slice.sourceID : nil))
        let image: CIImage
        if sourceOnly {
            let ratio = min(maxDimension / max(source.extent.width, source.extent.height), 1)
            image = source.transformed(by: CGAffineTransform(translationX: -source.extent.minX, y: -source.extent.minY))
                .transformed(by: CGAffineTransform(scaleX: ratio, y: ratio))
        } else {
            let scene = plan.scene
            var wallpaper: CIImage?
            if let key = scene.background.source.sceneResourceKey, let path = backgrounds[key] {
                if scene.background.source.isVideo {
                    let asset = AVURLAsset(url: path)
                    let duration = try await asset.load(.duration).seconds
                    guard duration.isFinite, duration > 0 else { throw SnapshotError("Invalid background video duration.") }
                    let generator = AVAssetImageGenerator(asset: asset)
                    generator.appliesPreferredTrackTransform = true
                    generator.requestedTimeToleranceBefore = .zero
                    generator.requestedTimeToleranceAfter = .zero
                    let frame = try await generator.image(at: CMTime(seconds: time.truncatingRemainder(dividingBy: duration), preferredTimescale: 60_000))
                    wallpaper = CIImage(cgImage: frame.image)
                } else {
                    wallpaper = CIImage(contentsOf: path, options: [.applyOrientationProperty: true])
                }
                guard wallpaper != nil else { throw SnapshotError("Could not read the scene background.") }
            } else if scene.background.source.usesWallpaperMedia {
                throw SnapshotError("The scene background file is unavailable.")
            }
            var resources = SharedFrameRenderResources(screen: source, camera: camera, wallpaper: wallpaper,
                cursor: scene.cursor.flatMap { cursors[$0.assetID]?.image }, stickers: [:], animations: [:])
            if scene.insertedImage != nil { resources.insertedImage = source }
            for sticker in scene.stickers {
                resources.timedStickers[sticker.id] = ImageMediaFrameCache.shared.frame(
                    at: url(sticker.relativePath), time: sticker.sourceTime)
            }
            for sticker in project.timeline.stickerClips where sticker.timing.contains(time) {
                guard let image = CIImage(contentsOf: url(sticker.relativePath), options: [.applyOrientationProperty: true]) else {
                    throw SnapshotError("Could not read sticker \(sticker.relativePath).")
                }
                resources.stickers[sticker.relativePath] = image
            }
            let videos = VideoOverlayDecoder()
            for video in scene.videos {
                guard let frame = await videos.frame(clip: video.id, path: url(video.sourcePath).path, at: video.sourceTime) else {
                    throw SnapshotError("Could not decode overlay video \(video.sourcePath).")
                }
                resources.videos[video.id] = frame
            }
            let motions = ExportHTMLMotionSession()
            do {
                let fps = Double(max(project.exportSettings.frameRate.rawValue, 1))
                for animation in scene.animations where HTMLMotion.isHTMLMotion(animation.sourcePath) {
                    let width = max(size.width * animation.width, 2)
                    let localTime = (animation.localTime * fps + 1e-6).rounded(.down) / fps
                    guard let frame = await motions.frame(path: url(animation.sourcePath).path, properties: animation.properties,
                        time: localTime, pixelSize: CGSize(width: width, height: width * size.height / size.width), edits: animation.elementEdits) else {
                        throw SnapshotError("Could not render motion \(animation.sourcePath).")
                    }
                    resources.animations[animation.id] = frame
                }
                if let motion = scene.insertedMotion {
                    let localTime = (motion.localTime * fps + 1e-6).rounded(.down) / fps
                    guard let frame = await motions.frame(path: url(motion.sourcePath).path, properties: motion.properties,
                        time: localTime, pixelSize: HTMLMotion.insertedPixelSize(scene), edits: motion.elementEdits) else {
                        throw SnapshotError("Could not render main-track motion \(motion.sourcePath).")
                    }
                    resources.insertedMotion = frame
                }
                await motions.close()
            } catch {
                await motions.close()
                throw error
            }
            guard let composed = SharedFrameCompositor.composite(plan, resources: resources,
                extent: CGRect(origin: .zero, size: size)) else { throw SnapshotError("Could not composite the requested frame.") }
            image = composed
        }
        try Task.checkCancellation()
        let profile = try CoreImageFrameColorProfile(contract: .sdrDesktop)
        guard let cg = profile.makeContext(cacheIntermediates: false).createCGImage(image, from: image.extent,
            format: .RGBA8, colorSpace: profile.outputColorSpace) else { throw SnapshotError("Could not create a snapshot image.") }
        return Result(scene: plan.scene, image: cg, decodedSourceTime: screenReader.frameSourceTime,
                      sourceID: slice.media == nil ? slice.sourceID : nil, segmentID: slice.segmentID)
    }

    struct SnapshotError: LocalizedError {
        let message: String
        init(_ message: String) { self.message = message }
        var errorDescription: String? { message }
    }
}
