import RecorderCore
import SwiftUI

extension CanvasPreview {
    @ViewBuilder
    func overlaySelectionTargets(
        scene: FrameScene,
        canvasSize: CGSize,
        time: TimeInterval
    ) -> some View {
        ZStack(alignment: .topLeading) {
            ForEach(
                project.timeline.mosaicClips.filter { $0.timing.contains(time) }
            ) { clip in
                if let quad = mosaicSelectionQuad(
                    clip: clip,
                    screen: scene.screen
                ) {
                    let selected = editorStore.selection == .mosaic(clip.id)
                    ProjectedScreenShape(quad: quad)
                        .fill(Color.clear)
                        .contentShape(ProjectedScreenShape(quad: quad))
                        .frame(width: canvasSize.width, height: canvasSize.height)
                        .onTapGesture {
                            onCanvasFocused()
                            editorStore.selection = .mosaic(clip.id)
                        }
                        .gesture(mosaicMoveGesture(
                            clip: clip,
                            screen: scene.screen,
                            canvasSize: canvasSize
                        ))
                    if selected {
                        ForEach(OverlayResizeCorner.allCases) { corner in
                            Circle()
                                .fill(Color(white: 0.055))
                                .overlay(Circle().stroke(editorAccent, lineWidth: 2))
                                .shadow(color: .black.opacity(0.7), radius: 2)
                                .frame(width: 12, height: 12)
                                .frame(width: 26, height: 26)
                                .contentShape(Rectangle())
                                .position(mosaicHandlePoint(corner, in: quad))
                                .highPriorityGesture(mosaicResizeGesture(
                                    clip: clip,
                                    corner: corner,
                                    screen: scene.screen,
                                    canvasSize: canvasSize
                                ))
                        }
                    }
                }
            }

            ForEach(scene.stickers, id: \.id) { sticker in
                let width = canvasSize.width * sticker.width * sticker.scale
                let sourceSize = resolvedStickerImages[sticker.relativePath]?.size
                    ?? NSSize(width: 1, height: 1)
                let height = width * max(sourceSize.height, 1)
                    / max(sourceSize.width, 1)
                let center = CGPoint(
                    x: canvasSize.width * (sticker.position.x + sticker.offset.x),
                    y: canvasSize.height * (sticker.position.y + sticker.offset.y)
                )
                let selected = editorStore.selection == .sticker(sticker.id)
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color.clear)
                    .contentShape(Rectangle())
                    .overlay {
                        if selected {
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .stroke(editorAccent, lineWidth: 1.5)
                        }
                    }
                    .frame(width: width, height: height)
                    .rotationEffect(.radians(sticker.rotationRadians))
                    .position(center)
                    .onTapGesture {
                        onCanvasFocused()
                        editorStore.selection = .sticker(sticker.id)
                    }
                    .gesture(overlayMoveGesture(
                        selection: .sticker(sticker.id),
                        canvasSize: canvasSize,
                        elementSize: CGSize(width: width, height: height)
                    ))
                if selected {
                    ForEach(OverlayResizeCorner.allCases) { corner in
                        let point = stickerHandlePoint(
                            corner,
                            center: center,
                            size: CGSize(width: width, height: height),
                            rotation: sticker.rotationRadians
                        )
                        Circle()
                            .fill(Color(white: 0.055))
                            .overlay(Circle().stroke(editorAccent, lineWidth: 2))
                            .shadow(color: .black.opacity(0.7), radius: 2)
                            .frame(width: 12, height: 12)
                            .frame(width: 26, height: 26)
                            .contentShape(Rectangle())
                            .position(point)
                            .highPriorityGesture(stickerResizeGesture(
                                id: sticker.id,
                                corner: corner,
                                canvasSize: canvasSize
                            ))
                    }
                }
            }

            if let progress = scene.progress {
                let width = canvasSize.width * CGFloat(
                    min(max(progress.width, 0.05), 1)
                )
                let bandHeight = max(
                    CGFloat(progress.bandHeight) * canvasSize.width / 1_920,
                    24
                )
                let centerX = min(
                    max(
                        canvasSize.width * CGFloat(progress.position.x),
                        width / 2
                    ),
                    canvasSize.width - width / 2
                )
                let center = CGPoint(
                    x: centerX,
                    y: progressCenterY(
                        progress,
                        canvasHeight: canvasSize.height,
                        bandHeight: bandHeight
                    )
                )
                let selected = editorStore.selection == .progress
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.black.opacity(0.001))
                    .contentShape(Rectangle())
                    .overlay {
                        if selected {
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .stroke(editorAccent, lineWidth: 1.5)
                        }
                    }
                    .frame(width: width, height: bandHeight)
                    .position(center)
                    .highPriorityGesture(overlayMoveGesture(
                        selection: .progress,
                        canvasSize: canvasSize,
                        elementSize: CGSize(width: width, height: bandHeight)
                    ))
                    .zIndex(100)
            }

            overlayQuickEditor(
                scene: scene,
                canvasSize: canvasSize,
                time: time
            )
        }
        .frame(width: canvasSize.width, height: canvasSize.height)
    }

    func mosaicSelectionQuad(
        clip: MosaicClip,
        screen: FrameScreenScene
    ) -> ProjectedScreenQuad? {
        let crop = screen.sourceCrop.clamped()
        let source = clip.sourceRect.clamped()
        let visibleX0 = max(source.x, crop.x)
        let visibleY0 = max(source.y, crop.y)
        let visibleX1 = min(source.x + source.width, crop.x + crop.width)
        let visibleY1 = min(source.y + source.height, crop.y + crop.height)
        guard visibleX1 > visibleX0, visibleY1 > visibleY0 else { return nil }
        let localX0 = (visibleX0 - crop.x) / crop.width
        let localY0 = (visibleY0 - crop.y) / crop.height
        let localX1 = (visibleX1 - crop.x) / crop.width
        let localY1 = (visibleY1 - crop.y) / crop.height
        let content = screen.finalRect
        let authored = [
            CompositionPoint(x: content.x + content.width * localX0, y: content.y + content.height * localY0),
            CompositionPoint(x: content.x + content.width * localX1, y: content.y + content.height * localY0),
            CompositionPoint(x: content.x + content.width * localX1, y: content.y + content.height * localY1),
            CompositionPoint(x: content.x + content.width * localX0, y: content.y + content.height * localY1),
        ]
        let projectionRect = screen.projectionRect
        let projected = authored.compactMap {
            screen.projectedQuad.project($0, from: projectionRect)
        }
        guard projected.count == 4 else { return nil }
        return ProjectedScreenQuad(
            topLeft: projected[0],
            topRight: projected[1],
            bottomRight: projected[2],
            bottomLeft: projected[3]
        )
    }

    func overlayMoveGesture(
        selection: EditorSelection,
        canvasSize: CGSize,
        elementSize: CGSize? = nil
    ) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .global)
            .onChanged { value in
                if overlayDragSelection != selection {
                    onCanvasFocused()
                    overlayDragSelection = selection
                    if selection == .progress,
                       let progress = editorStore.project.timeline.progressOverlay {
                        let halfHeight = Double(
                            (elementSize?.height ?? 0) / max(canvasSize.height, 1)
                        ) / 2
                        let effectiveY: Double = switch progress.placement {
                        case .top: halfHeight
                        case .bottom: 1 - halfHeight
                        case .custom: progress.position.y
                        }
                        overlayDragOrigin = NormalizedPoint(
                            x: progress.position.x,
                            y: effectiveY
                        )
                    } else {
                        overlayDragOrigin = overlayPosition(
                            for: selection,
                            in: editorStore.project
                        )
                    }
                    editorStore.beginInteraction(
                        tool: .select,
                        selection: selection
                    )
                }
                guard let origin = overlayDragOrigin else { return }
                let rawPosition = NormalizedPoint(
                    x: origin.x + value.translation.width / max(canvasSize.width, 1),
                    y: origin.y + value.translation.height / max(canvasSize.height, 1)
                )
                editorStore.updateInteraction { project in
                    switch selection {
                    case let .sticker(id):
                        guard let index = project.timeline.stickerClips.firstIndex(
                            where: { $0.id == id }
                        ) else { return }
                        let size = elementSize ?? .zero
                        let normalizedSize = CGSize(
                            width: size.width / max(canvasSize.width, 1),
                            height: size.height / max(canvasSize.height, 1)
                        )
                        let snapped = snappedOverlayCenter(
                            rawPosition,
                            normalizedSize: normalizedSize
                        )
                        canvasSnapGuideX = snapped.guideX
                        canvasSnapGuideY = snapped.guideY
                        project.timeline.stickerClips[index].position = snapped.point
                    case .progress:
                        guard var progress = project.timeline.progressOverlay else { return }
                        let size = elementSize ?? .zero
                        let normalizedSize = CGSize(
                            width: size.width / max(canvasSize.width, 1),
                            height: size.height / max(canvasSize.height, 1)
                        )
                        let snapped = snappedOverlayCenter(
                            rawPosition,
                            normalizedSize: normalizedSize
                        )
                        let y = snapped.point.y
                        canvasSnapGuideX = snapped.guideX
                        if y <= max(Double(normalizedSize.height) / 2 + 0.04, 0.10) {
                            progress.placement = .top
                            progress.position = NormalizedPoint(
                                x: snapped.point.x,
                                y: Double(normalizedSize.height) / 2
                            )
                            canvasSnapGuideY = 0
                        } else if y >= 1 - max(
                            Double(normalizedSize.height) / 2 + 0.04,
                            0.10
                        ) {
                            progress.placement = .bottom
                            progress.position = NormalizedPoint(
                                x: snapped.point.x,
                                y: 1 - Double(normalizedSize.height) / 2
                            )
                            canvasSnapGuideY = 1
                        } else {
                            progress.placement = .custom
                            progress.position = snapped.point
                            canvasSnapGuideY = snapped.guideY
                        }
                        project.timeline.progressOverlay = progress
                    default:
                        break
                    }
                }
            }
            .onEnded { _ in
                defer {
                    overlayDragOrigin = nil
                    overlayDragSelection = nil
                    canvasSnapGuideX = nil
                    canvasSnapGuideY = nil
                }
                do {
                    _ = try editorStore.commitInteraction(actionName: "移动叠加内容")
                } catch {
                    editorStore.cancelInteraction()
                    onError(error.localizedDescription)
                }
            }
    }

    func progressCenterY(
        _ progress: FrameProgressScene,
        canvasHeight: CGFloat,
        bandHeight: CGFloat
    ) -> CGFloat {
        switch progress.placement {
        case .top: return bandHeight / 2
        case .bottom: return canvasHeight - bandHeight / 2
        case .custom:
            return min(max(
                canvasHeight * progress.position.y,
                bandHeight / 2
            ), canvasHeight - bandHeight / 2)
        }
    }

    func overlayPosition(
        for selection: EditorSelection,
        in project: RecorderProject
    ) -> NormalizedPoint? {
        switch selection {
        case let .sticker(id):
            return project.timeline.stickerClips.first { $0.id == id }?.position
        case .progress:
            return project.timeline.progressOverlay?.position
        default:
            return nil
        }
    }

    func mosaicMoveGesture(
        clip: MosaicClip,
        screen: FrameScreenScene,
        canvasSize: CGSize
    ) -> some Gesture {
        let selection = EditorSelection.mosaic(clip.id)
        return DragGesture(minimumDistance: 1, coordinateSpace: .global)
            .onChanged { value in
                if mosaicDragOrigin == nil {
                    onCanvasFocused()
                    mosaicDragOrigin = editorStore.project.timeline.mosaicClips
                        .first(where: { $0.id == clip.id })?.sourceRect
                    editorStore.beginInteraction(tool: .select, selection: selection)
                }
                guard let origin = mosaicDragOrigin else { return }
                let delta = mosaicSourceDelta(
                    translation: value.translation,
                    screen: screen
                )
                let proposed = NormalizedOverlayRect(
                    x: origin.x + delta.x,
                    y: origin.y + delta.y,
                    width: origin.width,
                    height: origin.height
                ).clamped()
                let snapped = snappedMosaicRect(proposed)
                canvasSnapGuideX = snapped.guideX
                canvasSnapGuideY = snapped.guideY
                editorStore.updateInteraction { project in
                    guard let index = project.timeline.mosaicClips.firstIndex(
                        where: { $0.id == clip.id }
                    ) else { return }
                    project.timeline.mosaicClips[index].sourceRect = snapped.rect
                }
            }
            .onEnded { _ in
                defer {
                    mosaicDragOrigin = nil
                    canvasSnapGuideX = nil
                    canvasSnapGuideY = nil
                }
                do {
                    _ = try editorStore.commitInteraction(actionName: "移动打码区域")
                } catch {
                    editorStore.cancelInteraction()
                    onError(error.localizedDescription)
                }
            }
    }

    func mosaicResizeGesture(
        clip: MosaicClip,
        corner: OverlayResizeCorner,
        screen: FrameScreenScene,
        canvasSize: CGSize
    ) -> some Gesture {
        let selection = EditorSelection.mosaic(clip.id)
        return DragGesture(minimumDistance: 0, coordinateSpace: .global)
            .onChanged { value in
                if mosaicResizeOrigin == nil {
                    onCanvasFocused()
                    mosaicResizeOrigin = editorStore.project.timeline.mosaicClips
                        .first(where: { $0.id == clip.id })?.sourceRect
                    overlayResizeSelection = selection
                    editorStore.beginInteraction(tool: .select, selection: selection)
                }
                guard overlayResizeSelection == selection,
                      let origin = mosaicResizeOrigin else { return }
                let delta = mosaicSourceDelta(
                    translation: value.translation,
                    screen: screen
                )
                var left = origin.x
                var top = origin.y
                var right = origin.x + origin.width
                var bottom = origin.y + origin.height
                if corner == .topLeft || corner == .bottomLeft {
                    left = min(max(left + delta.x, 0), right - 0.02)
                } else {
                    right = max(min(right + delta.x, 1), left + 0.02)
                }
                if corner == .topLeft || corner == .topRight {
                    top = min(max(top + delta.y, 0), bottom - 0.02)
                } else {
                    bottom = max(min(bottom + delta.y, 1), top + 0.02)
                }
                let snapped = snappedMosaicResize(
                    NormalizedOverlayRect(
                        x: left,
                        y: top,
                        width: right - left,
                        height: bottom - top
                    ),
                    corner: corner
                )
                canvasSnapGuideX = snapped.guideX
                canvasSnapGuideY = snapped.guideY
                editorStore.updateInteraction { project in
                    guard let index = project.timeline.mosaicClips.firstIndex(
                        where: { $0.id == clip.id }
                    ) else { return }
                    project.timeline.mosaicClips[index].sourceRect = snapped.rect
                }
            }
            .onEnded { _ in
                defer {
                    mosaicResizeOrigin = nil
                    overlayResizeSelection = nil
                    canvasSnapGuideX = nil
                    canvasSnapGuideY = nil
                }
                do {
                    _ = try editorStore.commitInteraction(actionName: "调整打码大小")
                } catch {
                    editorStore.cancelInteraction()
                    onError(error.localizedDescription)
                }
            }
    }

    func stickerResizeGesture(
        id: UUID,
        corner: OverlayResizeCorner,
        canvasSize: CGSize
    ) -> some Gesture {
        let selection = EditorSelection.sticker(id)
        return DragGesture(minimumDistance: 0, coordinateSpace: .global)
            .onChanged { value in
                if stickerResizeOrigin == nil {
                    onCanvasFocused()
                    stickerResizeOrigin = editorStore.project.timeline.stickerClips
                        .first(where: { $0.id == id })?.width
                    overlayResizeSelection = selection
                    editorStore.beginInteraction(tool: .select, selection: selection)
                }
                guard overlayResizeSelection == selection,
                      let origin = stickerResizeOrigin else { return }
                let x = Double(value.translation.width / max(canvasSize.width, 1))
                    * corner.xSign
                let y = Double(value.translation.height / max(canvasSize.height, 1))
                    * corner.ySign
                let width = min(max(origin + x + y, 0.03), 1.5)
                editorStore.updateInteraction { project in
                    guard let index = project.timeline.stickerClips.firstIndex(
                        where: { $0.id == id }
                    ) else { return }
                    project.timeline.stickerClips[index].width = width
                }
            }
            .onEnded { _ in
                defer {
                    stickerResizeOrigin = nil
                    overlayResizeSelection = nil
                }
                do {
                    _ = try editorStore.commitInteraction(actionName: "调整贴图大小")
                } catch {
                    editorStore.cancelInteraction()
                    onError(error.localizedDescription)
                }
            }
    }

    func mosaicSourceDelta(
        translation: CGSize,
        screen: FrameScreenScene
    ) -> NormalizedPoint {
        let quad = screen.projectedQuad
        let ux = quad.topRight.x - quad.topLeft.x
        let uy = quad.topRight.y - quad.topLeft.y
        let vx = quad.bottomLeft.x - quad.topLeft.x
        let vy = quad.bottomLeft.y - quad.topLeft.y
        let determinant = ux * vy - uy * vx
        guard abs(determinant) > 0.000_1 else {
            return NormalizedPoint(x: 0, y: 0)
        }
        let dx = Double(translation.width)
        let dy = Double(translation.height)
        let localX = (dx * vy - dy * vx) / determinant
        let localY = (dy * ux - dx * uy) / determinant
        let crop = screen.sourceCrop.clamped()
        return NormalizedPoint(
            x: localX * crop.width,
            y: localY * crop.height
        )
    }

    func snappedOverlayCenter(
        _ proposed: NormalizedPoint,
        normalizedSize: CGSize
    ) -> (point: NormalizedPoint, guideX: Double?, guideY: Double?) {
        let halfWidth = Double(normalizedSize.width) / 2
        let halfHeight = Double(normalizedSize.height) / 2
        func snapAxis(
            _ value: Double,
            half: Double
        ) -> (Double, Double?) {
            let candidates = [
                (0.5, 0.5),
                (half, 0),
                (1 - half, 1),
            ]
            for (target, guide) in candidates where abs(value - target) <= 0.018 {
                return (target, guide)
            }
            return (min(max(value, half), 1 - half), nil)
        }
        let x = snapAxis(proposed.x, half: halfWidth)
        let y = snapAxis(proposed.y, half: halfHeight)
        return (NormalizedPoint(x: x.0, y: y.0), x.1, y.1)
    }

    func snappedMosaicRect(
        _ proposed: NormalizedOverlayRect
    ) -> (rect: NormalizedOverlayRect, guideX: Double?, guideY: Double?) {
        var rect = proposed.clamped()
        var guideX: Double?
        var guideY: Double?
        let centerX = rect.x + rect.width / 2
        if abs(centerX - 0.5) <= 0.015 {
            rect.x += 0.5 - centerX
            guideX = 0.5
        } else if abs(rect.x) <= 0.015 {
            rect.x = 0
            guideX = 0
        } else if abs(rect.x + rect.width - 1) <= 0.015 {
            rect.x = 1 - rect.width
            guideX = 1
        }
        let centerY = rect.y + rect.height / 2
        if abs(centerY - 0.5) <= 0.015 {
            rect.y += 0.5 - centerY
            guideY = 0.5
        } else if abs(rect.y) <= 0.015 {
            rect.y = 0
            guideY = 0
        } else if abs(rect.y + rect.height - 1) <= 0.015 {
            rect.y = 1 - rect.height
            guideY = 1
        }
        return (rect.clamped(), guideX, guideY)
    }

    func snappedMosaicResize(
        _ proposed: NormalizedOverlayRect,
        corner: OverlayResizeCorner
    ) -> (rect: NormalizedOverlayRect, guideX: Double?, guideY: Double?) {
        var left = proposed.x
        var top = proposed.y
        var right = proposed.x + proposed.width
        var bottom = proposed.y + proposed.height
        var guideX: Double?
        var guideY: Double?
        let xEdge = corner == .topLeft || corner == .bottomLeft ? left : right
        let yEdge = corner == .topLeft || corner == .topRight ? top : bottom
        if let anchor = [0.0, 0.5, 1.0].first(where: { abs(xEdge - $0) <= 0.015 }) {
            if corner == .topLeft || corner == .bottomLeft { left = anchor } else { right = anchor }
            guideX = anchor
        }
        if let anchor = [0.0, 0.5, 1.0].first(where: { abs(yEdge - $0) <= 0.015 }) {
            if corner == .topLeft || corner == .topRight { top = anchor } else { bottom = anchor }
            guideY = anchor
        }
        if right - left < 0.02 {
            if corner == .topLeft || corner == .bottomLeft { left = right - 0.02 } else { right = left + 0.02 }
        }
        if bottom - top < 0.02 {
            if corner == .topLeft || corner == .topRight { top = bottom - 0.02 } else { bottom = top + 0.02 }
        }
        return (
            NormalizedOverlayRect(
                x: left,
                y: top,
                width: right - left,
                height: bottom - top
            ).clamped(),
            guideX,
            guideY
        )
    }

    func mosaicHandlePoint(
        _ corner: OverlayResizeCorner,
        in quad: ProjectedScreenQuad
    ) -> CGPoint {
        switch corner {
        case .topLeft: return CGPoint(x: quad.topLeft.x, y: quad.topLeft.y)
        case .topRight: return CGPoint(x: quad.topRight.x, y: quad.topRight.y)
        case .bottomRight: return CGPoint(x: quad.bottomRight.x, y: quad.bottomRight.y)
        case .bottomLeft: return CGPoint(x: quad.bottomLeft.x, y: quad.bottomLeft.y)
        }
    }

    func stickerHandlePoint(
        _ corner: OverlayResizeCorner,
        center: CGPoint,
        size: CGSize,
        rotation: Double
    ) -> CGPoint {
        let dx = CGFloat(corner.xSign) * size.width / 2
        let dy = CGFloat(corner.ySign) * size.height / 2
        let cosine = CGFloat(cos(rotation))
        let sine = CGFloat(sin(rotation))
        return CGPoint(
            x: center.x + dx * cosine - dy * sine,
            y: center.y + dx * sine + dy * cosine
        )
    }

}
