import RecorderCore
import SwiftUI

/// Four source-plane boundaries: solid = clear region, dashed = feather end.
/// The clear band moves as one region; boundary strokes and rotation stay on top.
struct EditorLinearFocusCanvasOverlay: View {
    @ObservedObject var editorStore: EditorStore
    let clipID: UUID
    let effect: FocusEffect
    let screen: FrameScreenScene
    let sourceAspect: CGFloat
    let canvasSize: CGSize
    let onError: (String) -> Void
    @State private var origin: FocusEffect?
    @State private var interactionID: UUID?
    @State private var hoveredHandle: Handle?
    private enum Handle: Equatable { case position, direction, region(Int), feather(Int) }

    private var crop: NormalizedCrop { screen.sourceCrop.clamped() }
    private var plane: CGRect {
        let w = crop.width * max(sourceAspect, 0.01), h = crop.height
        let base = screen.baseRect, final = screen.finalRect
        let scale = min(base.width / max(w, 0.001), base.height / max(h, 0.001))
            * final.width / max(base.width, 0.001)
        return CGRect(x: final.x + (final.width - w * scale) / 2,
                      y: final.y + (final.height - h * scale) / 2,
                      width: w * scale, height: h * scale)
    }
    private var shortEdge: CGFloat { min(plane.width, plane.height) }
    private var mapper: ProjectedScreenPointMapper? { screen.projectedQuad.projector(from: screen.projectionRect) }
    private func center(_ effect: FocusEffect) -> CGPoint {
        CGPoint(x: plane.minX + (effect.center.x - crop.x) / crop.width * plane.width,
                y: plane.minY + (effect.center.y - crop.y) / crop.height * plane.height)
    }
    private func projected(_ point: CGPoint) -> CGPoint {
        let result = mapper?.project(CompositionPoint(x: point.x, y: point.y))
        return CGPoint(x: result?.x ?? point.x, y: result?.y ?? point.y)
    }
    private func tangent(_ effect: FocusEffect) -> CGPoint {
        let angle = (effect.angleDegrees ?? 0) * .pi / 180
        return CGPoint(x: cos(angle), y: sin(angle))
    }
    private func offset(_ point: CGPoint, along direction: CGPoint, by distance: CGFloat) -> CGPoint {
        CGPoint(x: point.x + direction.x * distance, y: point.y + direction.y * distance)
    }
    private func projectedAngle(at point: CGPoint, along direction: CGPoint) -> Double {
        let a = projected(point), b = projected(offset(point, along: direction, by: 2))
        return atan2(b.y - a.y, b.x - a.x) * 180 / .pi
    }

    var body: some View {
        let c = center(effect), t = tangent(effect)
        let n = CGPoint(x: -t.y, y: t.x)
        let radius = effect.clearHalfWidth(shortEdge: shortEdge)
        let feather = effect.featherWidth(shortEdge: shortEdge)
        ZStack(alignment: .topLeading) {
            let band = clearBandPath(center: c, normal: n, radius: radius)
            band.fill(.clear)
                .contentShape(band)
                .gesture(drag(.position))
                .onHover { hoveredHandle = $0 ? .position : nil }
                .help(appLocalized("拖动清晰区域移动位置"))
                .accessibilityHidden(true)
            ForEach([-1, 1], id: \.self) { side in
                let inner = offset(c, along: n, by: radius * CGFloat(side))
                let outer = offset(c, along: n, by: (radius + feather) * CGFloat(side))
                guide(at: inner, tangent: t, dashed: false, role: .region(side))
                guide(at: outer, tangent: t, dashed: true, role: .feather(side))
            }
            handle("plus", at: c,
                   rotation: projectedAngle(at: c, along: t), role: .position, title: "移动清晰带")
            let rotationPoint = offset(c, along: t, by: shortEdge * 0.36)
            handle("arrow.triangle.2.circlepath", at: rotationPoint,
                   rotation: projectedAngle(at: rotationPoint, along: t), role: .direction, title: "旋转清晰带")
        }
        .frame(width: canvasSize.width, height: canvasSize.height)
        .coordinateSpace(name: "mainLinearFocus")
        // Rotation is pointer-driven; implicit animation would unwind 359°→0°.
        .transaction { $0.animation = nil }
        .onDisappear { finish() }
        .onChange(of: editorStore.interaction?.id) { _, id in
            if let owned = interactionID, owned != id { origin = nil; interactionID = nil }
        }
    }

    /// Clip the clear strip to the source image before projection. A rotated
    /// band must not become a rectangular hit target over the rest of the UI.
    private func clearBandPath(center: CGPoint, normal: CGPoint, radius: CGFloat) -> Path {
        guard mapper != nil, plane.width > 0, plane.height > 0 else { return Path() }
        var vertices = [
            CGPoint(x: plane.minX, y: plane.minY), CGPoint(x: plane.maxX, y: plane.minY),
            CGPoint(x: plane.maxX, y: plane.maxY), CGPoint(x: plane.minX, y: plane.maxY)
        ]
        for side in [CGFloat(-1), CGFloat(1)] {
            func distance(_ p: CGPoint) -> CGFloat {
                ((p.x - center.x) * normal.x + (p.y - center.y) * normal.y) * side - radius
            }
            guard var previous = vertices.last else { return Path() }
            var clipped: [CGPoint] = []
            var previousDistance = distance(previous)
            for current in vertices {
                let currentDistance = distance(current)
                if (previousDistance <= 0) != (currentDistance <= 0) {
                    let fraction = previousDistance / (previousDistance - currentDistance)
                    clipped.append(CGPoint(x: previous.x + (current.x - previous.x) * fraction,
                                           y: previous.y + (current.y - previous.y) * fraction))
                }
                if currentDistance <= 0 { clipped.append(current) }
                previous = current
                previousDistance = currentDistance
            }
            vertices = clipped
        }
        guard vertices.count >= 3, let first = vertices.first else { return Path() }
        return Path { path in
            path.move(to: projected(first))
            for vertex in vertices.dropFirst() { path.addLine(to: projected(vertex)) }
            path.closeSubpath()
        }
    }

    private func guide(at point: CGPoint, tangent: CGPoint, dashed: Bool, role: Handle) -> some View {
        let path = linePath(at: point, tangent: tangent)
        let stroke = StrokeStyle(lineWidth: hoveredHandle == role ? 1.5 : 1, dash: dashed ? [4, 6] : [])
        return path.stroke(.black.opacity(0.38), style: StrokeStyle(lineWidth: stroke.lineWidth + 1, dash: stroke.dash))
            .overlay(path.stroke(.white.opacity(hoveredHandle == role ? 1 : 0.8), style: stroke))
            .contentShape(path.strokedPath(StrokeStyle(lineWidth: 10)))
            .gesture(drag(role))
            .onHover { hoveredHandle = $0 ? role : nil }
            .help(appLocalized(dashed ? "拖动虚线调整羽化范围" : "拖动实线调整清晰区域"))
    }

    /// Intersect in source space before projecting, so the invisible hit area
    /// cannot extend past the displayed image and cover nearby UI.
    private func linePath(at point: CGPoint, tangent: CGPoint) -> Path {
        var lower = -CGFloat.greatestFiniteMagnitude, upper = CGFloat.greatestFiniteMagnitude
        for (position, direction, minimum, maximum) in [
            (point.x, tangent.x, plane.minX, plane.maxX),
            (point.y, tangent.y, plane.minY, plane.maxY)
        ] {
            if abs(direction) < 0.00001 {
                if position < minimum || position > maximum { return Path() }
            } else {
                let a = (minimum - position) / direction, b = (maximum - position) / direction
                lower = max(lower, min(a, b)); upper = min(upper, max(a, b))
            }
        }
        guard lower <= upper else { return Path() }
        return Path { path in
            path.move(to: projected(offset(point, along: tangent, by: lower)))
            path.addLine(to: projected(offset(point, along: tangent, by: upper)))
        }
    }

    private func handlePoint(_ point: CGPoint) -> CGPoint {
        let p = projected(point)
        return CGPoint(x: min(max(p.x, 18), max(canvasSize.width - 18, 18)),
                       y: min(max(p.y, 18), max(canvasSize.height - 18, 18)))
    }
    private func handle(_ symbol: String, at point: CGPoint, rotation: Double,
                        role: Handle, title: String) -> some View {
        Group {
            if role == .direction {
                EditorLinearFocusRotationHandle(rotation: rotation,
                    isActive: hoveredHandle == role || origin != nil)
            } else {
                Image(systemName: symbol).font(.system(size: 12, weight: .medium))
                    .rotationEffect(.degrees(rotation))
                    .foregroundStyle(.white)
                    .shadow(color: .black.opacity(0.8), radius: 1)
                    .opacity(hoveredHandle == role || origin != nil ? 1 : 0.65)
            }
        }
            .frame(width: 28, height: 28).contentShape(Circle())
            .position(handlePoint(point)).gesture(drag(role))
            .onHover { hoveredHandle = $0 ? role : nil }
            .help(appLocalized(title)).accessibilityLabel(appLocalized(title))
    }
    private func drag(_ role: Handle) -> some Gesture {
        DragGesture(minimumDistance: 2, coordinateSpace: .named("mainLinearFocus"))
            .onChanged { value in
                guard editorStore.selection == .screenMotion(clipID) else { return }
                if origin == nil {
                    origin = effect
                    _ = editorStore.beginContinuousInteraction(commandScope: .selection,
                        selection: .screenMotion(clipID))
                    interactionID = editorStore.interaction?.id
                }
                guard var updated = origin, editorStore.interaction?.id == interactionID,
                      let start = mapper?.unproject(CompositionPoint(x: value.startLocation.x, y: value.startLocation.y)),
                      let current = mapper?.unproject(CompositionPoint(x: value.location.x, y: value.location.y)) else { return }
                let c = center(updated), t = tangent(updated)
                let dx = current.x - start.x, dy = current.y - start.y
                let normalDelta = dx * -t.y + dy * t.x
                updated.shape = .linear; updated.target = .fixed; updated.dimming = 0
                switch role {
                case .position:
                    updated.center = NormalizedPoint(
                        x: min(max(updated.center.x + dx / max(plane.width, 1) * crop.width, crop.x), crop.x + crop.width),
                        y: min(max(updated.center.y + dy / max(plane.height, 1) * crop.height, crop.y), crop.y + crop.height))
                case .direction:
                    let initial = atan2(start.y - c.y, start.x - c.x)
                    let currentAngle = atan2(current.y - c.y, current.x - c.x)
                    let delta = atan2(sin(currentAngle - initial), cos(currentAngle - initial))
                    updated.angleDegrees = FocusEffect.normalizedAngle((updated.angleDegrees ?? 0) + delta * 180 / .pi)
                case let .region(side):
                    updated.size = min(max(updated.size + normalDelta * Double(side) * 2 / max(shortEdge, 1), 0.1), 1)
                case let .feather(side):
                    updated.softness = min(max(updated.softness + normalDelta * Double(side) / max(shortEdge * 0.4, 1), 0), 1)
                }
                editorStore.updateInteraction { project in
                    guard let index = project.timeline.screenMotionClips.firstIndex(where: { $0.id == clipID }) else { return }
                    project.timeline.screenMotionClips[index].focusEffect = updated
                }
            }.onEnded { _ in finish() }
    }
    private func finish() {
        defer { origin = nil; interactionID = nil }
        guard let owned = interactionID, editorStore.interaction?.id == owned else { return }
        do { _ = try editorStore.commitInteraction(actionName: "调整线性虚化") }
        catch { editorStore.cancelInteraction(); onError(error.localizedDescription) }
    }
}
