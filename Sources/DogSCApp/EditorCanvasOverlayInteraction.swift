import RecorderCore
import SwiftUI

/// The outline and handle hit areas use the same canvas-local quad. No handle
/// view participates in SwiftUI layout, so resizing cannot move its origin.
private struct MosaicSelectionHitShape: Shape {
    let quad: ProjectedScreenQuad
    let showsHandles: Bool

    func path(in rect: CGRect) -> Path {
        var path = ProjectedScreenShape(quad: quad).path(in: rect)
        if showsHandles {
            for corner in OverlayResizeCorner.allCases {
                let point = mosaicCornerPoint(corner, in: quad)
                path.addRect(CGRect(x: point.x - 15, y: point.y - 15,
                                    width: 30, height: 30))
            }
        }
        return path
    }
}

private func mosaicCornerPoint(
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

extension CanvasPreview {
    @ViewBuilder
    func mosaicSelectionTargets(
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
                    let selection = EditorSelection.mosaic(clip.id)
                    let selected = editorStore.selection == selection
                    let chrome = canvasObjectChrome(for: selection)
                    Canvas { context, size in
                        let outline = ProjectedScreenShape(quad: quad).path(
                            in: CGRect(origin: .zero, size: size)
                        )
                        context.fill(outline, with: .color(chrome.fillColor))
                        if chrome.showsOutline {
                            context.stroke(outline, with: .color(chrome.strokeColor),
                                           lineWidth: chrome.lineWidth)
                        }
                        if selected {
                            let isResizing = overlayResizeSelection == selection
                            for corner in OverlayResizeCorner.allCases {
                                let point = mosaicCornerPoint(corner, in: quad)
                                let radius: CGFloat = isResizing ? 6.5 : 6
                                let dot = Path(ellipseIn: CGRect(
                                    x: point.x - radius, y: point.y - radius,
                                    width: radius * 2, height: radius * 2
                                ))
                                context.fill(dot, with: .color(Color(white: 0.055)))
                                context.stroke(dot,
                                               with: .color(EditorTheme.mediaAccent.opacity(isResizing ? 1 : 0.90)),
                                               lineWidth: isResizing ? 2.5 : 2)
                            }
                        }
                    }
                        .frame(width: canvasSize.width, height: canvasSize.height)
                        .contentShape(MosaicSelectionHitShape(
                            quad: quad, showsHandles: selected
                        ))
                        .onTapGesture {
                            onCanvasFocused()
                            editorStore.selection = selection
                        }
                        .gesture(mosaicSelectionGesture(
                            clip: clip,
                            quad: quad,
                            selected: selected,
                            screen: scene.screen
                        ))
                        .onHover {
                            updateCanvasHover(selection, hovering: $0)
                        }
                        .accessibilityLabel(
                            clip.style == .spotlight ? "突出区域" : "柔化区域"
                        )
                        .accessibilityHint("点击以选中，拖动以调整位置")
                        .accessibilityAddTraits(
                            selected ? [.isButton, .isSelected] : .isButton
                        )
                        .accessibilityAction {
                            editorStore.selection = selection
                        }
                        .transaction { $0.animation = nil }
                        .zIndex(selected ? 1 : 0)
                }
            }
        }
        .frame(width: canvasSize.width, height: canvasSize.height)
    }

    @ViewBuilder
    func frontOverlaySelectionTargets(
        scene: FrameScene,
        canvasSize: CGSize,
        time: TimeInterval
    ) -> some View {
        ZStack(alignment: .topLeading) {
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
                let selection = EditorSelection.sticker(sticker.id)
                let selected = editorStore.selection == selection
                let chrome = canvasObjectChrome(for: selection)
                // Keep authored sticker order in the rendered frame, but lift
                // the selected sticker's transparent interaction chrome above
                // later stickers and the progress hit surface. Otherwise a
                // lower sticker selected from the timeline/inspector becomes
                // impossible to move, resize or rotate wherever it overlaps a
                // higher layer.
                let interactionZIndex = selected
                    ? 10_000.0
                    : Double(sticker.layerIndex)
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(chrome.fillColor)
                    .contentShape(Rectangle())
                    .overlay {
                        if chrome.showsOutline {
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .stroke(chrome.strokeColor, lineWidth: chrome.lineWidth)
                        }
                    }
                    .shadow(color: chrome.glowColor, radius: chrome.glowRadius)
                    .frame(width: width, height: height)
                    .rotationEffect(.radians(sticker.rotationRadians))
                    .position(center)
                    .onTapGesture {
                        onCanvasFocused()
                        editorStore.selection = selection
                    }
                    .gesture(overlayMoveGesture(
                        selection: selection,
                        canvasSize: canvasSize,
                        elementSize: CGSize(width: width, height: height)
                    ))
                    .onHover {
                        updateCanvasHover(selection, hovering: $0)
                    }
                    .accessibilityLabel("贴图")
                    .accessibilityHint("点击以选中，拖动以调整位置")
                    .accessibilityAddTraits(
                        selected ? [.isButton, .isSelected] : .isButton
                    )
                    .accessibilityAction {
                        editorStore.selection = selection
                    }
                    .zIndex(interactionZIndex)
                if selected {
                    ForEach(OverlayResizeCorner.allCases) { corner in
                        let isResizing = overlayResizeSelection == selection
                        let point = stickerHandlePoint(
                            corner,
                            center: center,
                            size: CGSize(width: width, height: height),
                            rotation: sticker.rotationRadians
                        )
                        Circle()
                            .fill(Color(white: 0.055))
                            .overlay {
                                Circle().stroke(
                                    EditorTheme.mediaAccent.opacity(isResizing ? 1 : 0.90),
                                    lineWidth: isResizing ? 2.5 : 2
                                )
                            }
                            .shadow(
                                color: isResizing
                                    ? EditorTheme.mediaAccent.opacity(0.32)
                                    : .black.opacity(0.7),
                                radius: isResizing ? 5 : 2
                            )
                            .frame(width: 12, height: 12)
                            .frame(width: 30, height: 30)
                            .contentShape(Rectangle())
                            .position(point)
                            .scaleEffect(isResizing ? 1.08 : 1)
                            .animation(SpringMotion.interactive, value: isResizing)
                            .highPriorityGesture(stickerResizeGesture(
                                id: sticker.id,
                                center: center,
                                handle: point
                            ))
                            .zIndex(interactionZIndex + 1)
                    }

                    let rotationGeometry = stickerRotationHandleGeometry(
                        center: center,
                        size: CGSize(width: width, height: height),
                        rotation: sticker.rotationRadians,
                        canvasSize: canvasSize
                    )
                    let isRotating = stickerRotationOrigin?.id == sticker.id
                    Path { path in
                        path.move(to: rotationGeometry.anchor)
                        path.addLine(to: rotationGeometry.handle)
                    }
                    .stroke(
                        EditorTheme.mediaAccent.opacity(isRotating ? 0.92 : 0.62),
                        style: StrokeStyle(lineWidth: isRotating ? 1.75 : 1.25)
                    )
                    .frame(width: canvasSize.width, height: canvasSize.height)
                    .allowsHitTesting(false)
                    .zIndex(interactionZIndex + 1)

                    Circle()
                        .fill(Color(white: 0.055))
                        .overlay {
                            Circle().stroke(
                                EditorTheme.mediaAccent.opacity(isRotating ? 1 : 0.90),
                                lineWidth: isRotating ? 2.5 : 2
                            )
                        }
                        .overlay {
                            Image(systemName: "arrow.triangle.2.circlepath")
                                .font(.appUI(size: 8.5, weight: .bold))
                                .foregroundStyle(EditorTheme.mediaAccent)
                        }
                        .shadow(
                            color: isRotating
                                ? EditorTheme.mediaAccent.opacity(0.34)
                                : .black.opacity(0.7),
                            radius: isRotating ? 6 : 2
                        )
                        .frame(width: 18, height: 18)
                        .frame(width: 34, height: 34)
                        .contentShape(Rectangle())
                        .position(rotationGeometry.handle)
                        .scaleEffect(isRotating ? 1.10 : 1)
                        .animation(SpringMotion.interactive, value: isRotating)
                        .highPriorityGesture(stickerRotationGesture(
                            id: sticker.id,
                            center: center,
                            handle: rotationGeometry.handle
                        ))
                        .help("拖动旋转贴图")
                        .accessibilityHidden(true)
                        .zIndex(interactionZIndex + 2)
                }
            }

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
                    overlayDragOrigin = overlayPosition(
                        for: selection,
                        in: editorStore.project
                    )
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
                            normalizedSize: normalizedSize,
                            canvasSize: canvasSize
                        )
                        canvasSnapGuideX = snapped.guideX
                        canvasSnapGuideY = snapped.guideY
                        project.timeline.stickerClips[index].position = snapped.point
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

    func overlayPosition(
        for selection: EditorSelection,
        in project: RecorderProject
    ) -> NormalizedPoint? {
        switch selection {
        case let .sticker(id):
            return project.timeline.stickerClips.first { $0.id == id }?.position
        default:
            return nil
        }
    }

    func mosaicSelectionGesture(
        clip: MosaicClip,
        quad: ProjectedScreenQuad,
        selected: Bool,
        screen: FrameScreenScene
    ) -> some Gesture {
        let selection = EditorSelection.mosaic(clip.id)
        return DragGesture(minimumDistance: 1, coordinateSpace: .local)
            .onChanged { value in
                if mosaicDragOrigin == nil && mosaicResizeOrigin == nil {
                    guard let origin = editorStore.project.timeline.mosaicClips
                        .first(where: { $0.id == clip.id })?.sourceRect else { return }
                    onCanvasFocused()
                    if selected, let corner = mosaicCorner(
                        at: value.startLocation, in: quad
                    ) {
                        mosaicResizeOrigin = origin
                        mosaicResizeCorner = corner
                        overlayResizeSelection = selection
                    } else {
                        mosaicDragOrigin = origin
                    }
                    editorStore.beginInteraction(tool: .select, selection: selection)
                }

                let delta = mosaicSourceDelta(
                    translation: value.translation,
                    screen: screen
                )
                if let corner = mosaicResizeCorner,
                   let origin = mosaicResizeOrigin {
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
                        corner: corner,
                        thresholds: mosaicSnapThresholds(screen: screen)
                    )
                    updateMosaicDragPreview(clipID: clip.id, snapped: snapped)
                } else if let origin = mosaicDragOrigin {
                    let proposed = NormalizedOverlayRect(
                        x: origin.x + delta.x,
                        y: origin.y + delta.y,
                        width: origin.width,
                        height: origin.height
                    ).clamped()
                    let thresholds = mosaicSnapThresholds(screen: screen)
                    let snapped = snappedMosaicRect(
                        proposed,
                        thresholdX: thresholds.x,
                        thresholdY: thresholds.y
                    )
                    updateMosaicDragPreview(clipID: clip.id, snapped: snapped)
                }
            }
            .onEnded { _ in
                let didResize = mosaicResizeOrigin != nil
                let didMove = mosaicDragOrigin != nil
                defer {
                    mosaicDragOrigin = nil
                    mosaicResizeOrigin = nil
                    mosaicResizeCorner = nil
                    overlayResizeSelection = nil
                    canvasSnapGuideX = nil
                    canvasSnapGuideY = nil
                }
                guard didResize || didMove else { return }
                do {
                    _ = try editorStore.commitInteraction(
                        actionName: didResize ? "调整打码大小" : "移动打码区域"
                    )
                } catch {
                    editorStore.cancelInteraction()
                    onError(error.localizedDescription)
                }
            }
    }

    func updateMosaicDragPreview(
        clipID: UUID,
        snapped: (rect: NormalizedOverlayRect, guideX: Double?, guideY: Double?)
    ) {
        if canvasSnapGuideX != snapped.guideX { canvasSnapGuideX = snapped.guideX }
        if canvasSnapGuideY != snapped.guideY { canvasSnapGuideY = snapped.guideY }
        guard let currentRect = editorStore.interaction?.previewProject.timeline
            .mosaicClips.first(where: { $0.id == clipID })?.sourceRect,
              currentRect != snapped.rect else { return }
        editorStore.updateInteraction { project in
            guard let index = project.timeline.mosaicClips.firstIndex(
                where: { $0.id == clipID }
            ) else { return }
            project.timeline.mosaicClips[index].sourceRect = snapped.rect
        }
    }

    func mosaicCorner(
        at location: CGPoint,
        in quad: ProjectedScreenQuad
    ) -> OverlayResizeCorner? {
        OverlayResizeCorner.allCases
            .compactMap { corner -> (OverlayResizeCorner, CGFloat)? in
                let point = mosaicCornerPoint(corner, in: quad)
                let dx = location.x - point.x
                let dy = location.y - point.y
                guard abs(dx) <= 15, abs(dy) <= 15 else { return nil }
                return (corner, dx * dx + dy * dy)
            }
            .min(by: { $0.1 < $1.1 })?.0
    }

    func stickerResizeGesture(
        id: UUID,
        center: CGPoint,
        handle: CGPoint
    ) -> some Gesture {
        let selection = EditorSelection.sticker(id)
        return DragGesture(minimumDistance: 0, coordinateSpace: .global)
            .onChanged { value in
                if stickerResizeOrigin == nil {
                    onCanvasFocused()
                    guard let width = editorStore.project.timeline.stickerClips
                        .first(where: { $0.id == id })?.width else { return }
                    stickerResizeOrigin = StickerResizeGestureOrigin(
                        id: id,
                        width: width,
                        center: center,
                        handle: handle,
                        handleRadius: max(hypot(
                            handle.x - center.x,
                            handle.y - center.y
                        ), 1)
                    )
                    overlayResizeSelection = selection
                    editorStore.beginInteraction(tool: .select, selection: selection)
                }
                guard overlayResizeSelection == selection,
                      let origin = stickerResizeOrigin,
                      origin.id == id else { return }
                let pointer = CGPoint(
                    x: origin.handle.x + value.translation.width,
                    y: origin.handle.y + value.translation.height
                )
                let radius = hypot(
                    pointer.x - origin.center.x,
                    pointer.y - origin.center.y
                )
                let width = min(max(
                    origin.width * Double(radius / origin.handleRadius),
                    0.03
                ), 1.5)
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

    func stickerRotationGesture(
        id: UUID,
        center: CGPoint,
        handle: CGPoint
    ) -> some Gesture {
        let selection = EditorSelection.sticker(id)
        return DragGesture(minimumDistance: 0, coordinateSpace: .global)
            .onChanged { value in
                if stickerRotationOrigin == nil {
                    onCanvasFocused()
                    guard let degrees = editorStore.project.timeline.stickerClips
                        .first(where: { $0.id == id })?.rotationDegrees else {
                        return
                    }
                    stickerRotationOrigin = StickerRotationGestureOrigin(
                        id: id,
                        rotationDegrees: degrees,
                        center: center,
                        handle: handle,
                        handleAngle: atan2(
                            handle.y - center.y,
                            handle.x - center.x
                        )
                    )
                    editorStore.beginInteraction(tool: .select, selection: selection)
                }
                guard let origin = stickerRotationOrigin,
                      origin.id == id else { return }
                let pointer = CGPoint(
                    x: origin.handle.x + value.translation.width,
                    y: origin.handle.y + value.translation.height
                )
                let pointerAngle = atan2(
                    pointer.y - origin.center.y,
                    pointer.x - origin.center.x
                )
                let angleDelta = normalizedStickerRotationRadians(
                    pointerAngle - origin.handleAngle
                )
                let proposed = origin.rotationDegrees + angleDelta * 180 / .pi
                let degrees = snappedStickerRotationDegrees(proposed)
                editorStore.updateInteraction { project in
                    guard let index = project.timeline.stickerClips.firstIndex(
                        where: { $0.id == id }
                    ) else { return }
                    project.timeline.stickerClips[index].rotationDegrees = degrees
                }
            }
            .onEnded { _ in
                defer { stickerRotationOrigin = nil }
                do {
                    _ = try editorStore.commitInteraction(actionName: "旋转贴图")
                } catch {
                    editorStore.cancelInteraction()
                    onError(error.localizedDescription)
                }
            }
    }

    func normalizedStickerRotationRadians(_ radians: Double) -> Double {
        var value = radians.truncatingRemainder(dividingBy: 2 * .pi)
        if value > .pi { value -= 2 * .pi }
        if value < -.pi { value += 2 * .pi }
        return value
    }

    func snappedStickerRotationDegrees(_ proposed: Double) -> Double {
        var normalized = proposed.truncatingRemainder(dividingBy: 360)
        if normalized > 180 { normalized -= 360 }
        if normalized < -180 { normalized += 360 }
        let anchors = [-180.0, -90, 0, 90, 180]
        if let nearest = anchors.min(by: {
            abs(normalized - $0) < abs(normalized - $1)
        }), abs(normalized - nearest) <= 3 {
            return nearest
        }
        return normalized
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
        normalizedSize: CGSize,
        canvasSize: CGSize
    ) -> (point: NormalizedPoint, guideX: Double?, guideY: Double?) {
        let halfWidth = Double(normalizedSize.width) / 2
        let halfHeight = Double(normalizedSize.height) / 2
        func snapAxis(
            _ value: Double,
            half: Double,
            threshold: Double
        ) -> (Double, Double?) {
            let candidates = [
                (0.5, 0.5),
                (half, 0),
                (1 - half, 1),
            ]
            for (target, guide) in candidates where abs(value - target) <= threshold {
                return (target, guide)
            }
            return (min(max(value, half), 1 - half), nil)
        }
        let x = snapAxis(
            proposed.x,
            half: halfWidth,
            threshold: CanvasSnapMath.normalizedThreshold(along: canvasSize.width)
        )
        let y = snapAxis(
            proposed.y,
            half: halfHeight,
            threshold: CanvasSnapMath.normalizedThreshold(along: canvasSize.height)
        )
        return (NormalizedPoint(x: x.0, y: y.0), x.1, y.1)
    }

    func snappedMosaicRect(
        _ proposed: NormalizedOverlayRect,
        thresholdX: Double,
        thresholdY: Double
    ) -> (rect: NormalizedOverlayRect, guideX: Double?, guideY: Double?) {
        var rect = proposed.clamped()
        var guideX: Double?
        var guideY: Double?
        let centerX = rect.x + rect.width / 2
        if abs(centerX - 0.5) <= thresholdX {
            rect.x += 0.5 - centerX
            guideX = 0.5
        } else if abs(rect.x) <= thresholdX {
            rect.x = 0
            guideX = 0
        } else if abs(rect.x + rect.width - 1) <= thresholdX {
            rect.x = 1 - rect.width
            guideX = 1
        }
        let centerY = rect.y + rect.height / 2
        if abs(centerY - 0.5) <= thresholdY {
            rect.y += 0.5 - centerY
            guideY = 0.5
        } else if abs(rect.y) <= thresholdY {
            rect.y = 0
            guideY = 0
        } else if abs(rect.y + rect.height - 1) <= thresholdY {
            rect.y = 1 - rect.height
            guideY = 1
        }
        return (rect.clamped(), guideX, guideY)
    }

    func snappedMosaicResize(
        _ proposed: NormalizedOverlayRect,
        corner: OverlayResizeCorner,
        thresholds: (x: Double, y: Double)
    ) -> (rect: NormalizedOverlayRect, guideX: Double?, guideY: Double?) {
        var left = proposed.x
        var top = proposed.y
        var right = proposed.x + proposed.width
        var bottom = proposed.y + proposed.height
        var guideX: Double?
        var guideY: Double?
        let xEdge = corner == .topLeft || corner == .bottomLeft ? left : right
        let yEdge = corner == .topLeft || corner == .topRight ? top : bottom
        if let anchor = [0.0, 0.5, 1.0].first(
            where: { abs(xEdge - $0) <= thresholds.x }
        ) {
            if corner == .topLeft || corner == .bottomLeft { left = anchor } else { right = anchor }
            guideX = anchor
        }
        if let anchor = [0.0, 0.5, 1.0].first(
            where: { abs(yEdge - $0) <= thresholds.y }
        ) {
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

    func mosaicSnapThresholds(
        screen: FrameScreenScene
    ) -> (x: Double, y: Double) {
        let quad = screen.projectedQuad
        let horizontalTravel = hypot(
            quad.topRight.x - quad.topLeft.x,
            quad.topRight.y - quad.topLeft.y
        ) / max(screen.sourceCrop.width, 0.001)
        let verticalTravel = hypot(
            quad.bottomLeft.x - quad.topLeft.x,
            quad.bottomLeft.y - quad.topLeft.y
        ) / max(screen.sourceCrop.height, 0.001)
        return (
            CanvasSnapMath.normalizedThreshold(
                along: horizontalTravel,
                limits: 0.003...0.04
            ),
            CanvasSnapMath.normalizedThreshold(
                along: verticalTravel,
                limits: 0.003...0.04
            )
        )
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

    func stickerRotationHandleGeometry(
        center: CGPoint,
        size: CGSize,
        rotation: Double,
        canvasSize: CGSize
    ) -> StickerRotationHandleGeometry {
        func geometry(direction: CGFloat) -> StickerRotationHandleGeometry {
            let cosine = CGFloat(cos(rotation))
            let sine = CGFloat(sin(rotation))
            let anchorDistance = direction * size.height / 2
            let handleDistance = anchorDistance + direction * 34
            func point(distance: CGFloat) -> CGPoint {
                CGPoint(
                    x: center.x - distance * sine,
                    y: center.y + distance * cosine
                )
            }
            return StickerRotationHandleGeometry(
                anchor: point(distance: anchorDistance),
                handle: point(distance: handleDistance)
            )
        }

        let top = geometry(direction: -1)
        let bottom = geometry(direction: 1)
        let safeCanvas = CGRect(origin: .zero, size: canvasSize)
            .insetBy(dx: 18, dy: 18)
        if safeCanvas.contains(top.handle) || !safeCanvas.contains(bottom.handle) {
            return top
        }
        return bottom
    }

}
