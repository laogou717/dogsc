import RecorderCore
import SwiftUI

/// The shape of one zoom, drawn the way a synthesiser draws an envelope:
/// time runs right, magnification rises (on a log scale, so 2× and 4× feel
/// equally far apart). Drag the first node to set how long the push-in
/// takes and how far it goes, the middle node to set how far, and the last
/// node to set how long the pull-out takes. The dot follows the playhead.
struct EditorZoomEnvelope: View {
    @ObservedObject var editorStore: EditorStore
    let animation: ZoomAnimationClip
    let track: ZoomAnimationTrack
    let scale: Binding<Double>
    let enter: Binding<Double>
    let exit: Binding<Double>
    let playbackTime: TimeInterval
    let onError: (String) -> Void

    @Environment(\.consolePalette) private var palette
    @Environment(\.consoleReveal) private var reveals
    @State private var activeNode: Node?
    @State private var hoveredNode: Node?
    @State private var frozenTotal: Double?
    @State private var wipe: CGFloat = 1
    @State private var curveCache = EnvelopeCurveCache()

    private enum Node: CaseIterable { case enterEnd, holdEnd, exitEnd }

    private let height: CGFloat = 156
    private let plotInsets = EdgeInsets(top: 16, leading: 12, bottom: 26, trailing: 12)
    private let maxScale = 6.0
    private let minimumPeak = 1.05

    /// The zoom clip's own amber, the same hue as its lane on the timeline.
    private var accent: Color { palette?.stroke ?? EditorTheme.timelineZoomAccent }

    private var total: Double {
        frozenTotal ?? max(curveDuration, 0.001)
    }

    private var curveDuration: Double { animation.duration + animation.exitDuration }
    private var effectiveEnter: Double {
        if animation.enterDuration <= 0.001, track.adjacentPreviousClip(to: animation) != nil {
            return min(editorStore.previewProject.motion.defaultZoomTransitionDuration, animation.duration)
        }
        return animation.enterDuration
    }
    private var visibleNodes: [Node] {
        animation.exitDuration > 0.001 ? Node.allCases : [.enterEnd, .holdEnd]
    }

    var body: some View {
        GeometryReader { proxy in
            let plot = plotRect(in: proxy.size)
            // The curve is drawn by an Equatable view from plain values, so
            // an unrelated editor update (a timeline drag elsewhere) does not
            // redraw it, and the axis text is laid out once as ordinary Text
            // instead of being resolved again inside every Canvas pass.
            EnvelopeCanvas(drawing: drawing(plot: plot))
                .equatable()
                .overlay(alignment: .topLeading) { axisLabels(plot: plot) }
            .mask(alignment: .leading) {
                Rectangle().scaleEffect(x: wipe, anchor: .leading)
            }
            .contentShape(Rectangle())
            .onContinuousHover { phase in
                switch phase {
                case let .active(location):
                    hoveredNode = nearestNode(to: location, plot: plot, within: 22)
                case .ended:
                    hoveredNode = nil
                }
            }
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { drag in
                        if activeNode == nil {
                            guard let node = nearestNode(to: drag.startLocation, plot: plot, within: 26) else { return }
                            activeNode = node
                            frozenTotal = total
                            _ = editorStore.beginContinuousInteraction(commandScope: .selection)
                        }
                        guard let node = activeNode else { return }
                        _ = editorStore.beginContinuousInteraction(commandScope: .selection)
                        move(node, to: drag.location, plot: plot)
                    }
                    .onEnded { _ in
                        guard activeNode != nil else { return }
                        activeNode = nil
                        frozenTotal = nil
                        EditorConsoleHUD.shared.release()
                        updateEditorContinuousInteraction(
                            store: editorStore, isEditing: false, commandScope: .selection,
                            actionName: "调整缩放曲线", onError: onError
                        )
                    }
            )
        }
        .frame(height: height)
        .animation(SpringMotion.hover, value: hoveredNode)
        .onAppear {
            guard reveals, !RecorderMotion.reduces else { return }
            wipe = 0
            withAnimation(.timingCurve(0.3, 0.8, 0.3, 1, duration: 1.1).delay(0.45)) { wipe = 1 }
        }
        .onDisappear {
            if activeNode != nil {
                activeNode = nil
                frozenTotal = nil
                updateEditorContinuousInteraction(
                    store: editorStore, isEditing: false, commandScope: .selection,
                    actionName: "调整缩放曲线", onError: onError
                )
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(appLocalized("缩放曲线"))
        .accessibilityValue(String(
            format: appLocalized("放大 %@，进入 %@，退出 %@"),
            EditorSliderValueFormat.multiplier.text(for: animation.scale),
            EditorSliderValueFormat.seconds.text(for: effectiveEnter),
            EditorSliderValueFormat.seconds.text(for: animation.exitDuration)
        ))
    }

    // MARK: Geometry

    private func plotRect(in size: CGSize) -> CGRect {
        CGRect(
            x: plotInsets.leading, y: plotInsets.top,
            width: max(size.width - plotInsets.leading - plotInsets.trailing, 1),
            height: max(size.height - plotInsets.top - plotInsets.bottom, 1)
        )
    }

    private func x(_ time: Double, plot: CGRect) -> CGFloat {
        plot.minX + CGFloat(min(max(time / total, 0), 1)) * plot.width
    }

    private func y(_ magnification: Double, plot: CGRect) -> CGFloat {
        let clamped = min(max(magnification, 0.9), maxScale + 0.4)
        return plot.maxY - CGFloat(log(clamped) / log(maxScale)) * plot.height
    }

    private func time(atX x: CGFloat, plot: CGRect) -> Double {
        Double((x - plot.minX) / plot.width) * total
    }

    private func magnification(atY y: CGFloat, plot: CGRect) -> Double {
        exp(Double((plot.maxY - y) / plot.height) * log(maxScale))
    }

    private func position(of node: Node, plot: CGRect) -> CGPoint {
        switch node {
        case .enterEnd:
            return CGPoint(x: x(effectiveEnter, plot: plot), y: y(magnificationAt(effectiveEnter), plot: plot))
        case .holdEnd:
            return CGPoint(x: x(animation.duration, plot: plot), y: y(magnificationAt(animation.duration), plot: plot))
        case .exitEnd:
            return CGPoint(x: x(animation.duration + animation.exitDuration, plot: plot), y: y(1, plot: plot))
        }
    }

    private func nearestNode(to point: CGPoint, plot: CGRect, within radius: CGFloat) -> Node? {
        var best: (Node, CGFloat)?
        for node in visibleNodes {
            let p = position(of: node, plot: plot)
            let distance = hypot(p.x - point.x, p.y - point.y)
            if distance <= radius, distance < (best?.1 ?? .infinity) { best = (node, distance) }
        }
        return best?.0
    }

    private func move(_ node: Node, to point: CGPoint, plot: CGRect) {
        let peak = min(max(magnification(atY: point.y, plot: plot), minimumPeak), maxScale)
        let t = time(atX: point.x, plot: plot)
        switch node {
        case .enterEnd:
            enter.wrappedValue = min(max(t, 0), min(animation.duration, 3))
            scale.wrappedValue = peak
            EditorConsoleHUD.shared.show(
                label: "进入", value: EditorSliderValueFormat.seconds.text(for: enter.wrappedValue)
                    + " · " + EditorSliderValueFormat.multiplier.text(for: peak)
            )
        case .holdEnd:
            scale.wrappedValue = peak
            EditorConsoleHUD.shared.show(label: "放大", value: EditorSliderValueFormat.multiplier.text(for: peak))
        case .exitEnd:
            exit.wrappedValue = min(max(t - animation.duration, 0), 3)
            EditorConsoleHUD.shared.show(
                label: "退出", value: EditorSliderValueFormat.seconds.text(for: exit.wrappedValue)
            )
        }
    }

    // MARK: Curve

    private func magnificationAt(_ t: Double) -> Double {
        // Sample the evaluated track, including adjacent hand-offs and saved
        // phase offsets. Authoring knobs still retain the requested durations.
        track.sample(
            at: animation.startTime + min(max(t, 0), curveDuration),
            motion: editorStore.previewProject.motion
        ).scale
    }

    private func curvePoints(plot: CGRect) -> [CGPoint] {
        let steps = max(Int(plot.width / 3), 24)
        let key = EnvelopeCurveCache.Key(
            track: track, animationID: animation.id, motion: editorStore.previewProject.motion,
            steps: steps, plot: plot, total: total
        )
        if curveCache.key == key { return curveCache.points }
        let points = (0...steps).map { step -> CGPoint in
            let t = Double(step) / Double(steps) * curveDuration
            return CGPoint(x: x(t, plot: plot), y: y(magnificationAt(t), plot: plot))
        }
        curveCache.key = key
        curveCache.points = points
        return points
    }

    private func drawing(plot: CGRect) -> EnvelopeDrawing {
        let relative = playbackTime - animation.startTime
        let playhead: CGPoint? = relative >= 0 && relative <= curveDuration
            ? CGPoint(x: x(relative, plot: plot), y: y(magnificationAt(relative), plot: plot))
            : nil
        return EnvelopeDrawing(
            plot: plot,
            curve: curvePoints(plot: plot),
            rules: [1.0, 2.0, 3.0, 4.0, 6.0].map { y($0, plot: plot) },
            nodes: visibleNodes.map { node in
                EnvelopeDrawing.NodeMark(point: position(of: node, plot: plot), lit: activeNode == node || hoveredNode == node)
            },
            playhead: playhead,
            color: accent
        )
    }

    private func axisLabels(plot: CGRect) -> some View {
        let spans: [(String, CGFloat, CGFloat)] = [
            ("进入", x(0, plot: plot), x(effectiveEnter, plot: plot)),
            ("保持", x(effectiveEnter, plot: plot), x(animation.duration, plot: plot)),
            ("退出", x(animation.duration, plot: plot), x(animation.duration + animation.exitDuration, plot: plot))
        ]
        return ZStack(alignment: .topLeading) {
            ForEach([1, 2, 3, 4, 6], id: \.self) { level in
                Text("\(level)×")
                    .font(.appUI(size: 10, weight: .medium).monospacedDigit())
                    .foregroundStyle(EditorTheme.tertiaryText)
                    .fixedSize()
                    .frame(width: 40, alignment: .trailing)
                    .position(x: plot.maxX - 20, y: y(Double(level), plot: plot) - 7)
            }
            ForEach(spans.filter { $0.2 - $0.1 > 30 }, id: \.0) { span in
                Text(appLocalized(span.0))
                    .font(.appUI(size: 10, weight: .medium))
                    .foregroundStyle(EditorTheme.tertiaryText)
                    .fixedSize()
                    .position(x: (span.1 + span.2) / 2, y: plot.maxY + 15)
            }
        }
        .allowsHitTesting(false)
    }
}

/// The last sampled curve, reused while the clip, its neighbours and the
/// plot are unchanged (sampling the resolved track is the costly part).
private final class EnvelopeCurveCache {
    struct Key: Equatable {
        let track: ZoomAnimationTrack
        let animationID: UUID
        let motion: MotionStyle
        let steps: Int
        let plot: CGRect
        let total: Double
    }

    var key: Key?
    var points: [CGPoint] = []
}

private struct EnvelopeDrawing: Equatable {
    struct NodeMark: Equatable {
        let point: CGPoint
        let lit: Bool
    }

    let plot: CGRect
    let curve: [CGPoint]
    let rules: [CGFloat]
    let nodes: [NodeMark]
    let playhead: CGPoint?
    let color: Color
}

private struct EnvelopeCanvas: View, Equatable {
    let drawing: EnvelopeDrawing

    var body: some View {
        Canvas { context, _ in
            let plot = drawing.plot
            let stroke = drawing.color
            for (index, ruleY) in drawing.rules.enumerated() {
                var rule = Path()
                rule.move(to: CGPoint(x: plot.minX, y: ruleY))
                rule.addLine(to: CGPoint(x: plot.maxX, y: ruleY))
                context.stroke(
                    rule, with: .color(EditorTheme.chrome(index == 0 ? 0.16 : 0.07)),
                    style: StrokeStyle(lineWidth: 0.75, dash: index == 0 ? [] : [2, 4])
                )
            }
            guard let first = drawing.curve.first else { return }
            var curve = Path()
            curve.move(to: first)
            for point in drawing.curve.dropFirst() { curve.addLine(to: point) }
            var area = curve
            area.addLine(to: CGPoint(x: plot.maxX, y: plot.maxY))
            area.addLine(to: CGPoint(x: plot.minX, y: plot.maxY))
            area.closeSubpath()
            // A flat wash under the curve, no gradient.
            context.fill(area, with: .color(stroke.opacity(0.12)))
            context.stroke(curve, with: .color(stroke), style: StrokeStyle(lineWidth: 2.6, lineCap: .round, lineJoin: .round))
            if let dot = drawing.playhead {
                var line = Path()
                line.move(to: CGPoint(x: dot.x, y: plot.minY - 6))
                line.addLine(to: CGPoint(x: dot.x, y: plot.maxY))
                context.stroke(line, with: .color(stroke.opacity(0.55)), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
                let rect = CGRect(x: dot.x - 5, y: dot.y - 5, width: 10, height: 10)
                context.fill(Path(ellipseIn: rect), with: .color(.white))
                context.stroke(Path(ellipseIn: rect), with: .color(stroke), lineWidth: 2.5)
            }
            for node in drawing.nodes {
                let p = node.point
                if node.lit {
                    context.fill(Path(ellipseIn: CGRect(x: p.x - 15, y: p.y - 15, width: 30, height: 30)), with: .color(stroke.opacity(0.22)))
                }
                let r: CGFloat = node.lit ? 8 : 6.5
                let rect = CGRect(x: p.x - r, y: p.y - r, width: r * 2, height: r * 2)
                context.fill(Path(ellipseIn: rect), with: .color(EditorTheme.panelSurface))
                context.stroke(Path(ellipseIn: rect), with: .color(stroke), lineWidth: 3)
            }
        }
    }
}
