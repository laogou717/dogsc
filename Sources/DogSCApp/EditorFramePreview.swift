import AppKit
import CoreImage
import RecorderCore
import SwiftUI

/// The top of every 画面 page: the project's own frame on the wallpaper it
/// has chosen, drawn with the live margin, corner, stroke, shadow and mockup
/// so turning any control repaints a picture rather than a number.
struct EditorFramePreview: View {
    let canvas: CanvasStyle
    let screenImage: NSImage?
    var usesFrameStyle = true
    var isMainTrackImage = false
    let wallpaper: SystemWallpaperAsset?
    var sourceAspectRatio: Double? = nil
    var canvasAspectRatio: Double? = nil
    var height: CGFloat = 146
    @State private var rasterImage: CGImage?

    var body: some View {
        EditorInspectorStage(height: height) {
            ZStack {
                switch canvas.backgroundSource {
                case let .pattern(preset):
                    PatternMiniatureView(preset: preset)
                case let .dynamicFlow(preset):
                    DynamicFlowMiniatureView(preset: preset)
                case let .projectImage(relativePath):
                    if let package = ProjectFiles.package,
                       let image = NSImage(contentsOf: package.appendingPathComponent(relativePath)) {
                        Color.clear.overlay { Image(nsImage: image).resizable().scaledToFill() }.clipped()
                    }
                default:
                    EmptyView()
                }
                if let wallpaper {
                    Color.clear
                        .overlay { SystemWallpaperThumbnail(asset: wallpaper) }
                        .clipped()
                        .blur(radius: min(max(canvas.backgroundBlur, 0), 40) * 0.25)
                        .overlay { Color.black.opacity(0.06) }
                        .transition(.opacity)
                        .id(wallpaper.id)
                }
                GeometryReader { proxy in
                    screen(in: proxy.size)
                }
            }
            .animation(SpringMotion.fade, value: wallpaper?.id)
        }
        // Dragging a slider repaints this live; animating each value would
        // make the picture trail the pointer.
        .transaction { $0.animation = nil }
    }

    private struct RasterRequest: Equatable {
        let canvas: CanvasStyle
        let sourceIdentity: ObjectIdentifier?
        let sourceAspect: Double
        let pixelSize: CGSize
        let usesFrameStyle: Bool
        let isMainTrackImage: Bool
    }

    private func screen(in stage: CGSize) -> some View {
        let imageSize = screenImage?.size
        let aspect = imageSize.map { Double($0.width / max($0.height, 1)) }
            ?? sourceAspectRatio ?? 16.0 / 9.0
        let ratio = canvasAspectRatio ?? canvas.resolvedFixedAspectRatio ?? aspect
        let safeRatio = ratio.isFinite && ratio > 0 ? ratio : 16.0 / 9.0
        let width = min(max(stage.width - 16, 2), max(stage.height - 16, 2) * safeRatio)
        let size = CGSize(width: width, height: width / safeRatio)
        let request = RasterRequest(canvas: canvas, sourceIdentity: screenImage.map(ObjectIdentifier.init),
            sourceAspect: aspect, pixelSize: CGSize(width: (size.width * 2).rounded(), height: (size.height * 2).rounded()),
            usesFrameStyle: usesFrameStyle, isMainTrackImage: isMainTrackImage)
        return Group {
            if let rasterImage {
                Image(decorative: rasterImage, scale: 2).resizable().interpolation(.high)
            } else {
                Color.clear
            }
        }
        .frame(width: size.width, height: size.height)
        .position(x: stage.width / 2, y: stage.height / 2)
        .task(id: request) {
            let source: CIImage
            if let cg = screenImage?.cgImage(forProposedRect: nil, context: nil, hints: nil) {
                source = CIImage(cgImage: cg)
            } else {
                source = CIImage(color: CIColor(red: 0.96, green: 0.96, blue: 0.96))
                    .cropped(to: CGRect(x: 0, y: 0, width: max(aspect * 720, 2), height: 720))
            }
            var preview = RecorderProject(canvas: canvas)
            preview.camera.isHidden = true
            preview.openingSequence.isEnabled = false
            if !usesFrameStyle || isMainTrackImage {
                preview.timeline.sourceSequence = .edited([
                    RecordingSegment(sourceStart: 0, sourceDuration: 1,
                        media: InsertedMedia(path: "", fileDuration: 1, name: "", usesFrameStyle: usesFrameStyle,
                            sourceAspectRatio: aspect, imagePath: isMainTrackImage ? "" : nil),
                        sceneStyle: SegmentSceneStyle(project: preview))
                ])
            }
            let scene = FrameSceneEvaluator.scene(project: preview, time: 0,
                canvasSize: CompositionSize(width: request.pixelSize.width, height: request.pixelSize.height),
                sourceAspectRatio: aspect)
            let result = await EditorFramePreviewRasterizer.shared.image(
                scene: scene, resources: SharedFrameRenderResources(screen: source))
            guard !Task.isCancelled else { return }
            rasterImage = result
        }
    }
}

/// Inspector and programme use the same crop, bezel, corner radii and shadow.
/// Raster work stays off the main actor while sliders and splitters are moving.
private actor EditorFramePreviewRasterizer {
    static let shared = EditorFramePreviewRasterizer()
    private let context = CIContext(options: [.cacheIntermediates: false])

    func image(scene: FrameScene, resources: SharedFrameRenderResources) -> CGImage? {
        let extent = CGRect(x: 0, y: 0, width: scene.canvasSize.width, height: scene.canvasSize.height)
        let transparent = CIImage(color: .clear).cropped(to: extent)
        let image = SharedFrameRenderer.render(scene: scene, resources: resources, over: transparent)
        return context.createCGImage(image, from: extent, format: .RGBA8,
            colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
    }
}
