import RecorderCore
import SwiftUI

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
                    let selectionShape = ProjectedScreenShape(quad: quad)
                    selectionShape
                        .fill(chrome.fillColor)
                        .contentShape(selectionShape)
                        .overlay {
                            if chrome.showsOutline {
                                selectionShape
                                    .stroke(chrome.strokeColor, lineWidth: chrome.lineWidth)
                            }
                        }
                        .shadow(color: chrome.glowColor, radius: chrome.glowRadius)
                        .frame(width: canvasSize.width, height: canvasSize.height)
                        .onTapGesture {
                            onCanvasFocused()
                            editorStore.selection = selection
                        }
                        .gesture(mosaicMoveGesture(
                            clip: clip,
                            screen: scene.screen,
                            canvasSize: canvasSize
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
                    if selected {
                        ForEach(OverlayResizeCorner.allCases) { corner in
                            let isResizing = overlayResizeSelection == selection
                            Circle()
                                .fill(Color(white: 0.055))
                                .overlay {
                                    Circle().stroke(
                                        editorAccent.opacity(isResizing ? 1 : 0.90),
                                        lineWidth: isResizing ? 2.5 : 2
                                    )
                                }
                                .shadow(
                                    color: isResizing
                                        ? editorAccent.opacity(0.32)
                                        : .black.opacity(0.7),
                                    radius: isResizing ? 5 : 2
                                )
                                .frame(width: 12, height: 12)
                                .frame(width: 30, height: 30)
                                .contentShape(Rectangle())
                                .position(mosaicHandlePoint(corner, in: quad))
                                .scaleEffect(isResizing ? 1.08 : 1)
                                .animation(SpringMotion.interactive, value: isResizing)
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
                                    editorAccent.opacity(isResizing ? 1 : 0.90),
                                    lineWidth: isResizing ? 2.5 : 2
                                )
                            }
                            .shadow(
                                color: isResizing
                                    ? editorAccent.opacity(0.32)
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
                        editorAccent.opacity(isRotating ? 0.92 : 0.62),
                        style: StrokeStyle(lineWidth: isRotating ? 1.75 : 1.25)
                    )
                    .frame(width: canvasSize.width, height: canvasSize.height)
                    .allowsHitTesting(false)
                    .zIndex(interactionZIndex + 1)

                    Circle()
                        .fill(Color(white: 0.055))
                        .overlay {
                            Circle().stroke(
                                editorAccent.opacity(isRotating ? 1 : 0.90),
                                lineWidth: isRotating ? 2.5 : 2
                            )
                        }
                        .overlay {
                            Image(systemName: "arrow.triangle.2.circlepath")
                                .font(.system(size: 8.5, weight: .bold))
                                .foregroundStyle(editorAccent)
                        }
                        .shadow(
                            color: isRotating
                                ? editorAccent.opacity(0.34)
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
                let selection = EditorSelection.progress
                let selected = editorStore.selection == selection
                let chrome = canvasObjectChrome(for: selection)
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(
                        chrome.phase == .idle
                            ? Color.black.opacity(0.001)
                            : chrome.fillColor
                    )
                    .contentShape(Rectangle())
                    .overlay {
                        if chrome.showsOutline {
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .stroke(chrome.strokeColor, lineWidth: chrome.lineWidth)
                        }
                    }
                    .shadow(color: chrome.glowColor, radius: chrome.glowRadius)
                    .frame(width: width, height: bandHeight)
                    .position(center)
                    .onTapGesture {
                        onCanvasFocused()
                        editorStore.selection = selection
                    }
                    .gesture(overlayMoveGesture(
                        selection: selection,
                        canvasSize: canvasSize,
                        elementSize: CGSize(width: width, height: bandHeight)
                    ))
                    .onHover {
                        updateCanvasHover(selection, hovering: $0)
                    }
                    .accessibilityLabel("成片进度条")
                    .accessibilityHint("点击以选中，拖动以调整位置")
                    .accessibilityAddTraits(
                        selected ? [.isButton, .isSelected] : .isButton
                    )
                    .accessibilityAction {
                        editorStore.selection = selection
                    }
                    .zIndex(100)
                if selected {
                    ForEach(
                        [ProgressResizeEdge.leading, .trailing],
                        id: \.self
                    ) { edge in
                        let active = progressResizeOrigin?.edge == edge
                        let edgeX = edge == .leading
                            ? center.x - width / 2
                            : center.x + width / 2
                        Capsule(style: .continuous)
                            .fill(Color(white: 0.055))
                            .overlay {
                                Capsule(style: .continuous)
                                    .stroke(
                                        editorAccent.opacity(active ? 1 : 0.90),
                                        lineWidth: active ? 2.5 : 2
                                    )
                            }
                            .shadow(
                                color: active
                                    ? editorAccent.opacity(0.34)
                                    : .black.opacity(0.7),
                                radius: active ? 6 : 2
                            )
                            .frame(
                                width: 8,
                                height: min(max(bandHeight * 0.56, 14), 28)
                            )
                            .frame(width: 32, height: max(bandHeight, 34))
                            .contentShape(Rectangle())
                            .position(x: edgeX, y: center.y)
                            .scaleEffect(active ? 1.10 : 1)
                            .animation(SpringMotion.interactive, value: active)
                            .highPriorityGesture(progressResizeGesture(
                                edge: edge,
                                leading: Double((center.x - width / 2) / canvasSize.width),
                                trailing: Double((center.x + width / 2) / canvasSize.width),
                                canvasSize: canvasSize
                            ))
                            .help(edge == .leading ? "拖动调整左边界" : "拖动调整右边界")
                            .accessibilityHidden(true)
                            .zIndex(101)
                    }

                    let heightEdge = progressHeightResizeEdge(
                        for: progress.placement
                    )
                    let heightActive = progressHeightResizeOrigin?.edge == heightEdge
                    let heightY = heightActive
                        ? progressHeightDragHandleY ?? progressHeightHandleY(
                            edge: heightEdge,
                            centerY: center.y,
                            bandHeight: bandHeight
                        )
                        : progressHeightHandleY(
                            edge: heightEdge,
                            centerY: center.y,
                            bandHeight: bandHeight
                        )
                    Capsule(style: .continuous)
                        .fill(Color(white: 0.055))
                        .overlay {
                            Capsule(style: .continuous)
                                .stroke(
                                    editorAccent.opacity(heightActive ? 1 : 0.90),
                                    lineWidth: heightActive ? 2.5 : 2
                                )
                        }
                        .shadow(
                            color: heightActive
                                ? editorAccent.opacity(0.34)
                                : .black.opacity(0.7),
                            radius: heightActive ? 6 : 2
                        )
                        .frame(width: 22, height: 6)
                        .frame(width: 32, height: 26)
                        .contentShape(Rectangle())
                        .position(x: center.x, y: heightY)
                        .scaleEffect(heightActive ? 1.06 : 1)
                        .animation(SpringMotion.interactive, value: heightActive)
                        .highPriorityGesture(progressHeightResizeGesture(
                            edge: heightEdge,
                            placement: progress.placement,
                            centerY: center.y,
                            visibleHeight: bandHeight,
                            canvasSize: canvasSize
                        ))
                        .help("拖动调整条带高度")
                        .accessibilityHidden(true)
                        .zIndex(101)
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
                            normalizedSize: normalizedSize,
                            canvasSize: canvasSize
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
                            normalizedSize: normalizedSize,
                            canvasSize: canvasSize
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

    func progressResizeGesture(
        edge: ProgressResizeEdge,
        leading: Double,
        trailing: Double,
        canvasSize: CGSize
    ) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .global)
            .onChanged { value in
                if progressResizeOrigin == nil {
                    onCanvasFocused()
                    progressResizeOrigin = ProgressResizeGestureOrigin(
                        edge: edge,
                        leading: min(max(leading, 0), 1),
                        trailing: min(max(trailing, 0), 1)
                    )
                    editorStore.beginInteraction(
                        tool: .select,
                        selection: .progress
                    )
                }
                guard let origin = progressResizeOrigin,
                      origin.edge == edge else { return }
                // Projects created before the current 20% inspector minimum
                // may contain a narrower band. Preserve that width on pickup,
                // but never let the gesture shrink it further.
                let minimumWidth = min(
                    0.20,
                    max(origin.trailing - origin.leading, 0.05)
                )
                let delta = Double(
                    value.translation.width / max(canvasSize.width, 1)
                )
                let threshold = CanvasSnapMath.normalizedThreshold(
                    along: canvasSize.width
                )
                var leading = origin.leading
                var trailing = origin.trailing
                var guide: Double?
                switch edge {
                case .leading:
                    leading = min(max(origin.leading + delta, 0), trailing - minimumWidth)
                    if let anchor = [0.0, 0.5, 1.0].first(where: {
                        abs(leading - $0) <= threshold
                            && $0 <= trailing - minimumWidth
                    }) {
                        leading = anchor
                        guide = anchor
                    }
                case .trailing:
                    trailing = max(min(origin.trailing + delta, 1), leading + minimumWidth)
                    if let anchor = [0.0, 0.5, 1.0].first(where: {
                        abs(trailing - $0) <= threshold
                            && $0 >= leading + minimumWidth
                    }) {
                        trailing = anchor
                        guide = anchor
                    }
                }
                canvasSnapGuideX = guide
                editorStore.updateInteraction { project in
                    guard var progress = project.timeline.progressOverlay else {
                        return
                    }
                    progress.width = trailing - leading
                    progress.position = NormalizedPoint(
                        x: (leading + trailing) / 2,
                        y: progress.position.y
                    )
                    project.timeline.progressOverlay = progress
                }
            }
            .onEnded { _ in
                defer {
                    progressResizeOrigin = nil
                    canvasSnapGuideX = nil
                }
                do {
                    _ = try editorStore.commitInteraction(
                        actionName: "调整进度条宽度"
                    )
                } catch {
                    editorStore.cancelInteraction()
                    onError(error.localizedDescription)
                }
            }
    }

    func progressHeightResizeGesture(
        edge: ProgressHeightResizeEdge,
        placement: ProgressOverlayPlacement,
        centerY: CGFloat,
        visibleHeight: CGFloat,
        canvasSize: CGSize
    ) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .global)
            .onChanged { value in
                if progressHeightResizeOrigin == nil {
                    onCanvasFocused()
                    guard let progress = editorStore.project.timeline
                        .progressOverlay else { return }
                    let fixedCanvasY = switch edge {
                    case .top: centerY + visibleHeight / 2
                    case .bottom: centerY - visibleHeight / 2
                    }
                    let handleCanvasY = progressHeightHandleY(
                        edge: edge,
                        centerY: centerY,
                        bandHeight: visibleHeight
                    )
                    progressHeightResizeOrigin = ProgressHeightResizeGestureOrigin(
                        edge: edge,
                        bandHeight: progress.bandHeight,
                        positionY: progress.position.y,
                        fixedCanvasY: fixedCanvasY,
                        handleCanvasY: handleCanvasY,
                        placement: placement
                    )
                    progressHeightDragHandleY = handleCanvasY
                    editorStore.beginInteraction(
                        tool: .select,
                        selection: .progress
                    )
                }
                guard let origin = progressHeightResizeOrigin,
                      origin.edge == edge else { return }
                // Keep the visible grip attached to the pointer's original
                // canvas-space edge. Re-evaluating it from the resized band
                // makes SwiftUI's moving gesture surface jump toward the bar
                // on the first drag tick.
                progressHeightDragHandleY = origin.handleCanvasY
                    + value.translation.height
                let visualDelta = edge == .bottom
                    ? value.translation.height
                    : -value.translation.height
                if abs(visualDelta) <= 0.01 {
                    editorStore.updateInteraction { project in
                        guard var progress = project.timeline.progressOverlay else {
                            return
                        }
                        progress.bandHeight = origin.bandHeight
                        if origin.placement == .custom {
                            progress.position = NormalizedPoint(
                                x: progress.position.x,
                                y: origin.positionY
                            )
                        }
                        project.timeline.progressOverlay = progress
                    }
                    return
                }
                let canvasScale = max(Double(canvasSize.width) / 1_920, 0.001)
                let renderedFloor = 24 / canvasScale
                let baseHeight = visualDelta > 0
                    ? max(origin.bandHeight, renderedFloor)
                    : origin.bandHeight
                var maximumHeight = 180.0
                if origin.placement == .custom {
                    let availableHeight = switch edge {
                    case .top: origin.fixedCanvasY
                    case .bottom: canvasSize.height - origin.fixedCanvasY
                    }
                    maximumHeight = min(
                        maximumHeight,
                        max(Double(availableHeight) / canvasScale, 28)
                    )
                }
                let bandHeight = min(max(
                    baseHeight + Double(visualDelta) / canvasScale,
                    28
                ), maximumHeight)
                let renderedHeight = min(
                    max(CGFloat(bandHeight * canvasScale), 24),
                    canvasSize.height
                )
                editorStore.updateInteraction { project in
                    guard var progress = project.timeline.progressOverlay else {
                        return
                    }
                    progress.bandHeight = bandHeight
                    if origin.placement == .custom {
                        let centerY = switch edge {
                        case .top:
                            origin.fixedCanvasY - renderedHeight / 2
                        case .bottom:
                            origin.fixedCanvasY + renderedHeight / 2
                        }
                        progress.position = NormalizedPoint(
                            x: progress.position.x,
                            y: min(max(
                                Double(centerY / max(canvasSize.height, 1)),
                                0
                            ), 1)
                        )
                    }
                    project.timeline.progressOverlay = progress
                }
            }
            .onEnded { _ in
                defer {
                    progressHeightResizeOrigin = nil
                    progressHeightDragHandleY = nil
                }
                do {
                    _ = try editorStore.commitInteraction(
                        actionName: "调整进度条高度"
                    )
                } catch {
                    editorStore.cancelInteraction()
                    onError(error.localizedDescription)
                }
            }
    }

    func progressHeightResizeEdge(
        for placement: ProgressOverlayPlacement
    ) -> ProgressHeightResizeEdge {
        placement == .bottom ? .top : .bottom
    }

    func progressHeightHandleY(
        edge: ProgressHeightResizeEdge,
        centerY: CGFloat,
        bandHeight: CGFloat
    ) -> CGFloat {
        switch edge {
        case .top: centerY - bandHeight / 2
        case .bottom: centerY + bandHeight / 2
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
                let thresholds = mosaicSnapThresholds(screen: screen)
                let snapped = snappedMosaicRect(
                    proposed,
                    thresholdX: thresholds.x,
                    thresholdY: thresholds.y
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
                    corner: corner,
                    thresholds: mosaicSnapThresholds(screen: screen)
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
