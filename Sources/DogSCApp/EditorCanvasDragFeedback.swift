import Foundation
import RecorderCore
import SwiftUI

struct CanvasManipulationReadout {
    let systemImage: String
    let title: String
    let value: String
    let objectY: Double
}

extension CanvasPreview {
    var directCanvasManipulationSelection: EditorSelection? {
        if screenScaleOrigin != nil { return screenScaleScope?.selection }
        if screenDragOrigin != nil { return screenDragScope?.selection }
        if cameraSizeOrigin != nil { return cameraSizeScope?.selection }
        if cameraDragOrigin != nil { return cameraDragScope?.selection }
        if let stickerRotationOrigin { return .sticker(stickerRotationOrigin.id) }
        if let overlayResizeSelection { return overlayResizeSelection }
        if let overlayDragSelection { return overlayDragSelection }
        if mosaicDragOrigin != nil || mosaicResizeOrigin != nil {
            return editorStore.interaction?.selection
        }
        return nil
    }

    var isDirectCanvasManipulation: Bool {
        directCanvasManipulationSelection != nil
    }

    @ViewBuilder
    func canvasManipulationFeedback(canvasSize: CGSize) -> some View {
        ZStack {
            if let canvasSnapGuideX {
                canvasSnapGuide(
                    from: CGPoint(x: canvasSnapGuideX * canvasSize.width, y: 0),
                    to: CGPoint(
                        x: canvasSnapGuideX * canvasSize.width,
                        y: canvasSize.height
                    ),
                    canvasSize: canvasSize
                )
            }
            if let canvasSnapGuideY {
                canvasSnapGuide(
                    from: CGPoint(x: 0, y: canvasSnapGuideY * canvasSize.height),
                    to: CGPoint(
                        x: canvasSize.width,
                        y: canvasSnapGuideY * canvasSize.height
                    ),
                    canvasSize: canvasSize
                )
            }
            if let canvasSnapGuideX, let canvasSnapGuideY {
                Circle()
                    .fill(EditorTheme.backgroundDeep)
                    .overlay {
                        Circle().stroke(EditorTheme.mediaAccent, lineWidth: 1.25)
                    }
                    .frame(width: 7, height: 7)
                    .shadow(color: EditorTheme.mediaAccent.opacity(0.38), radius: 4)
                    .position(
                        x: canvasSnapGuideX * canvasSize.width,
                        y: canvasSnapGuideY * canvasSize.height
                    )
            }

            if let readout = canvasManipulationReadout() {
                HStack(spacing: 7) {
                    Label(readout.title, systemImage: readout.systemImage)
                        .foregroundStyle(Color.white.opacity(0.68))
                    Rectangle()
                        .fill(Color.white.opacity(0.14))
                        .frame(width: 1, height: 13)
                    Text(readout.value)
                        .fontDesign(.monospaced)
                        .foregroundStyle(Color.white.opacity(0.94))
                        .contentTransition(.numericText())
                }
                .font(.appUI(size: 10.5, weight: .semibold))
                .padding(.horizontal, 10)
                .frame(height: 30)
                .background(
                    EditorTheme.cardElevated.opacity(0.94),
                    in: RoundedRectangle(cornerRadius: 9, style: .continuous)
                )
                .overlay {
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .stroke(Color.white.opacity(0.16), lineWidth: 0.75)
                }
                .shadow(color: Color.black.opacity(0.38), radius: 8, y: 3)
                .position(
                    x: canvasSize.width / 2,
                    y: readout.objectY > 0.65
                        ? 22
                        : max(canvasSize.height - 22, 22)
                )
                .transition(.opacity.combined(with: .scale(scale: 0.94)))
            }
        }
        .frame(width: canvasSize.width, height: canvasSize.height)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    func canvasManipulationReadout() -> CanvasManipulationReadout? {
        guard let selection = directCanvasManipulationSelection else { return nil }
        let preview = editorStore.previewProject
        switch selection {
        case .screen, .screenMotion:
            let scope = EditorCanvasEditScope(selection: selection)
            guard let position = scope.position(in: preview),
                  let scale = scope.scale(in: preview) else { return nil }
            if screenScaleOrigin != nil {
                return CanvasManipulationReadout(
                    systemImage: "arrow.up.left.and.arrow.down.right",
                    title: "屏幕大小",
                    value: String(format: "%.2f×", scale),
                    objectY: position.y
                )
            }
            return normalizedPositionReadout(
                systemImage: "rectangle.on.rectangle",
                title: "屏幕位置",
                position: position
            )

        case .camera, .cameraMotion:
            let scope = EditorCanvasEditScope(selection: selection)
            guard let position = scope.position(in: preview),
                  let scale = scope.scale(in: preview) else { return nil }
            if cameraSizeOrigin != nil {
                return CanvasManipulationReadout(
                    systemImage: "arrow.up.left.and.arrow.down.right",
                    title: "摄像头大小",
                    value: "\(Int((scale * 100).rounded()))%",
                    objectY: position.y
                )
            }
            return normalizedPositionReadout(
                systemImage: "video.fill",
                title: "摄像头位置",
                position: position
            )

        case let .mosaic(id):
            guard let clip = preview.timeline.mosaicClips.first(
                where: { $0.id == id }
            ) else { return nil }
            let rect = clip.sourceRect.clamped()
            if overlayResizeSelection == selection || mosaicResizeOrigin != nil {
                return CanvasManipulationReadout(
                    systemImage: "viewfinder",
                    title: "区域大小",
                    value: "W \(percent(rect.width)) · H \(percent(rect.height))",
                    objectY: rect.y + rect.height / 2
                )
            }
            return CanvasManipulationReadout(
                systemImage: "viewfinder",
                title: "区域位置",
                value: "X \(percent(rect.x + rect.width / 2)) · Y \(percent(rect.y + rect.height / 2))",
                objectY: rect.y + rect.height / 2
            )

        case let .sticker(id):
            guard let clip = preview.timeline.stickerClips.first(
                where: { $0.id == id }
            ) else { return nil }
            if stickerRotationOrigin?.id == id {
                let snapped = [-180.0, -90, 0, 90, 180].contains {
                    abs(clip.rotationDegrees - $0) < 0.001
                }
                return CanvasManipulationReadout(
                    systemImage: "rotate.right",
                    title: "贴图旋转",
                    value: String(
                        format: snapped ? "%.0f° · 已吸附" : "%.1f°",
                        clip.rotationDegrees
                    ),
                    objectY: clip.position.y
                )
            }
            if overlayResizeSelection == selection {
                return CanvasManipulationReadout(
                    systemImage: "photo",
                    title: "贴图大小",
                    value: "W \(percent(clip.width))",
                    objectY: clip.position.y
                )
            }
            return normalizedPositionReadout(
                systemImage: "photo",
                title: "贴图位置",
                position: clip.position
            )

        default:
            return nil
        }
    }

    func normalizedPositionReadout(
        systemImage: String,
        title: String,
        position: NormalizedPoint
    ) -> CanvasManipulationReadout {
        CanvasManipulationReadout(
            systemImage: systemImage,
            title: title,
            value: "X \(percent(position.x)) · Y \(percent(position.y))",
            objectY: position.y
        )
    }

    func percent(_ value: Double) -> String {
        "\(Int((value * 100).rounded()))%"
    }

    func canvasSnapGuide(
        from start: CGPoint,
        to end: CGPoint,
        canvasSize: CGSize
    ) -> some View {
        ZStack {
            Path { path in
                path.move(to: start)
                path.addLine(to: end)
            }
            .stroke(EditorTheme.mediaAccent.opacity(0.20), lineWidth: 5)
            .blur(radius: 2)

            Path { path in
                path.move(to: start)
                path.addLine(to: end)
            }
            .stroke(
                EditorTheme.mediaAccent.opacity(0.88),
                style: StrokeStyle(lineWidth: 1, dash: [3, 3])
            )
        }
        .frame(width: canvasSize.width, height: canvasSize.height)
    }

    func clearCanvasManipulationPresentation() {
        screenDragOrigin = nil
        screenDragScope = nil
        screenScaleOrigin = nil
        screenScaleScope = nil
        cameraDragOrigin = nil
        cameraDragScope = nil
        cameraSizeOrigin = nil
        cameraSizeScope = nil
        overlayDragOrigin = nil
        overlayDragSelection = nil
        mosaicDragOrigin = nil
        mosaicResizeOrigin = nil
        stickerResizeOrigin = nil
        stickerRotationOrigin = nil
        overlayResizeSelection = nil
        canvasSnapGuideX = nil
        canvasSnapGuideY = nil
        screenCompositorSuppressed = false
        cameraCompositorSuppressed = false
        scheduleScreenDragPreviewClear()
        scheduleCameraDragPreviewClear()
    }
}
