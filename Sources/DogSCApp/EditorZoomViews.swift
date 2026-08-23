import AppKit
import Combine
import QuartzCore
import RecorderCore
import SwiftUI

struct ZoomFocusMap: View {
    @ObservedObject var mediaSession: EditorMediaSession
    let outputTime: TimeInterval
    let sourcePixelSize: CGSize
    @Binding var focus: NormalizedPoint
    var onEditingChanged: (Bool) -> Void = { _ in }
    @State private var thumbnail: NSImage?
    @State private var isEditingFocus = false

    var body: some View {
        GeometryReader { geometry in
            let mapRect = focusMapRect(in: geometry.size)
            let guideInset = ZoomViewportTransform.compositionGuideInset

            ZStack {
                Color.black.opacity(0.5)

                if let thumbnail {
                    Image(nsImage: thumbnail)
                        .resizable()
                        .scaledToFit()
                        .frame(width: mapRect.width, height: mapRect.height)
                        .position(x: mapRect.midX, y: mapRect.midY)
                        .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                } else {
                    Color.black.opacity(0.42)
                        .frame(width: mapRect.width, height: mapRect.height)
                        .position(x: mapRect.midX, y: mapRect.midY)
                        .overlay {
                            ProgressView()
                                .controlSize(.small)
                        }
                }

                Color.black.opacity(0.08)

                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .stroke(
                        Color.white.opacity(0.22),
                        style: StrokeStyle(lineWidth: 1, dash: [4, 4])
                    )
                    .frame(
                        width: mapRect.width * CGFloat(1 - guideInset * 2),
                        height: mapRect.height * CGFloat(1 - guideInset * 2)
                    )
                    .position(x: mapRect.midX, y: mapRect.midY)
                    .allowsHitTesting(false)

                Circle()
                    .fill(Color.black.opacity(0.2))
                    .overlay(Circle().stroke(.white.opacity(0.92), lineWidth: 1.5))
                    .overlay(Circle().stroke(editorAccent.opacity(0.9), lineWidth: 4).padding(4))
                    .frame(width: 34, height: 34)
                    .shadow(color: .black.opacity(0.5), radius: 5, y: 2)
                    .position(
                        x: mapRect.minX + CGFloat(focus.x) * mapRect.width,
                        y: mapRect.minY + CGFloat(focus.y) * mapRect.height
                    )
                    .gesture(
                        DragGesture(minimumDistance: 0)
                            .onChanged { value in
                                beginFocusEditingIfNeeded()
                                focus = normalizedFocus(at: value.location, in: mapRect)
                            }
                            .onEnded { _ in endFocusEditing() }
                    )
                    .accessibilityLabel("缩放焦点")
                    .accessibilityValue(
                        "水平 \(Int(focus.x * 100))%，垂直 \(Int(focus.y * 100))%"
                    )
                    .accessibilityHint("拖动以选择缩放锚点，可以移动到四个角")
            }
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(Color.white.opacity(0.14), lineWidth: 1)
            )
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        beginFocusEditingIfNeeded()
                        focus = normalizedFocus(at: value.location, in: mapRect)
                    }
                    .onEnded { _ in endFocusEditing() }
            )
        }
        .frame(height: 148)
        .task(id: thumbnailRequestID) {
            await loadThumbnail()
        }
    }

    private func focusMapRect(in size: CGSize) -> CGRect {
        let padded = CGRect(origin: .zero, size: size).insetBy(dx: 18, dy: 12)
        let sourceAspect = max(sourcePixelSize.width / max(sourcePixelSize.height, 1), 0.01)
        let widthFromHeight = padded.height * sourceAspect
        if widthFromHeight <= padded.width {
            return CGRect(
                x: padded.midX - widthFromHeight / 2,
                y: padded.minY,
                width: widthFromHeight,
                height: padded.height
            )
        }
        let heightFromWidth = padded.width / sourceAspect
        return CGRect(
            x: padded.minX,
            y: padded.midY - heightFromWidth / 2,
            width: padded.width,
            height: heightFromWidth
        )
    }

    private func normalizedFocus(at point: CGPoint, in rect: CGRect) -> NormalizedPoint {
        NormalizedPoint(
            x: min(max(Double((point.x - rect.minX) / max(rect.width, 1)), 0), 1),
            y: min(max(Double((point.y - rect.minY) / max(rect.height, 1)), 0), 1)
        )
    }

    private func beginFocusEditingIfNeeded() {
        guard !isEditingFocus else { return }
        isEditingFocus = true
        onEditingChanged(true)
    }

    private func endFocusEditing() {
        guard isEditingFocus else { return }
        isEditingFocus = false
        onEditingChanged(false)
    }

    private var thumbnailRequestID: String {
        let generation = mediaSession.prepared?.generation.description ?? "none"
        return "\(generation)#\(String(format: "%.3f", outputTime))"
    }

    @MainActor
    private func loadThumbnail() async {
        guard let image = await mediaSession.thumbnail(atOutputTime: outputTime) else {
            thumbnail = nil
            return
        }
        thumbnail = NSImage(cgImage: image, size: .zero)
    }
}

private enum ZoomCurveControlHandle: Equatable {
    case first
    case second
}

struct ZoomCurveEditor: View {
    @Binding var preset: ZoomEasingPreset
    @Binding var customCurve: ZoomBezierCurve
    let motion: MotionStyle
    var onEditingChanged: (Bool) -> Void = { _ in }
    @State private var draggedHandle: ZoomCurveControlHandle?
    @State private var previewStartedAt = Date()

    private let columns = Array(
        repeating: GridItem(.flexible(), spacing: 6),
        count: 3
    )

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            LazyVGrid(columns: columns, spacing: 6) {
                ForEach(ZoomEasingPreset.allCases) { candidate in
                    Button {
                        preset = candidate
                        previewStartedAt = Date()
                    } label: {
                        VStack(spacing: 3) {
                            ZoomCurvePresetGlyph(
                                preset: candidate,
                                customCurve: customCurve,
                                motion: motion
                            )
                            .frame(height: 22)
                            Text(candidate.shortName)
                                .font(.system(size: 9, weight: .medium))
                                .lineLimit(1)
                        }
                        .padding(.horizontal, 5)
                        .padding(.vertical, 5)
                        .frame(maxWidth: .infinity)
                        .background(
                            preset == candidate
                                ? Color.white.opacity(0.16) : Color.white.opacity(0.055),
                            in: RoundedRectangle(cornerRadius: 8, style: .continuous)
                        )
                    }
                    .buttonStyle(.plain)
                    .help("点击选择并重播曲线预览")
                }
            }

            curveGraph
                .frame(height: 142)

            curveMotionPreview
                .frame(height: 58)

            Label(
                preset == .spring
                    ? "弹簧使用高级面板中的质量、刚度和阻尼"
                    : "拖动曲线上的两个圆点，当前预设会自动变为自定义",
                systemImage: "hand.draw"
            )
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
    }

    private var displayedCurve: ZoomBezierCurve {
        preset == .custom ? customCurve : preset.curve
    }

    private var curveGraph: some View {
        GeometryReader { geometry in
            let size = geometry.size
            let inset: CGFloat = 12
            let plotSize = CGSize(
                width: max(size.width - inset * 2, 1),
                height: max(size.height - inset * 2, 1)
            )
            let curve = displayedCurve

            Canvas { context, _ in
                func graphPoint(_ point: NormalizedPoint) -> CGPoint {
                    CGPoint(
                        x: inset + CGFloat(point.x) * plotSize.width,
                        y: inset + CGFloat(1 - point.y) * plotSize.height
                    )
                }

                var grid = Path()
                for index in 0...4 {
                    let fraction = CGFloat(index) / 4
                    grid.move(to: CGPoint(x: inset + plotSize.width * fraction, y: inset))
                    grid.addLine(to: CGPoint(x: inset + plotSize.width * fraction, y: inset + plotSize.height))
                    grid.move(to: CGPoint(x: inset, y: inset + plotSize.height * fraction))
                    grid.addLine(to: CGPoint(x: inset + plotSize.width, y: inset + plotSize.height * fraction))
                }
                context.stroke(grid, with: .color(.white.opacity(0.065)), lineWidth: 1)

                var curvePath = Path()
                for index in 0...80 {
                    let parameter = Double(index) / 80
                    let normalized: NormalizedPoint
                    if preset == .spring {
                        normalized = NormalizedPoint(
                            x: parameter,
                            y: ZoomInterpolator.easedProgress(
                                parameter,
                                preset: .spring,
                                motion: motion
                            )
                        )
                    } else {
                        normalized = curve.point(at: parameter)
                    }
                    let point = graphPoint(normalized)
                    if index == 0 { curvePath.move(to: point) } else { curvePath.addLine(to: point) }
                }
                context.stroke(
                    curvePath,
                    with: .linearGradient(
                        Gradient(colors: [Color(white: 0.94), Color(white: 0.42)]),
                        startPoint: CGPoint(x: inset, y: inset + plotSize.height),
                        endPoint: CGPoint(x: inset + plotSize.width, y: inset)
                    ),
                    style: StrokeStyle(lineWidth: 3, lineCap: .round, lineJoin: .round)
                )

                if preset != .spring {
                    let start = graphPoint(NormalizedPoint(x: 0, y: 0))
                    let end = graphPoint(NormalizedPoint(x: 1, y: 1))
                    let first = graphPoint(NormalizedPoint(x: curve.x1, y: curve.y1))
                    let second = graphPoint(NormalizedPoint(x: curve.x2, y: curve.y2))
                    var handles = Path()
                    handles.move(to: start)
                    handles.addLine(to: first)
                    handles.move(to: end)
                    handles.addLine(to: second)
                    context.stroke(
                        handles,
                        with: .color(.white.opacity(0.36)),
                        style: StrokeStyle(lineWidth: 1, dash: [4, 3])
                    )
                    context.fill(
                        Path(ellipseIn: CGRect(x: first.x - 7, y: first.y - 7, width: 14, height: 14)),
                        with: .color(draggedHandle == .first ? .white : Color(white: 0.78))
                    )
                    context.fill(
                        Path(ellipseIn: CGRect(x: second.x - 7, y: second.y - 7, width: 14, height: 14)),
                        with: .color(draggedHandle == .second ? .white : Color(white: 0.78))
                    )
                }
            }
            .background(Color.black.opacity(0.22), in: RoundedRectangle(cornerRadius: 10))
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(Color.white.opacity(0.1), lineWidth: 1)
            )
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        guard preset != .spring else { return }
                        var editable = displayedCurve
                        func graphPoint(_ point: NormalizedPoint) -> CGPoint {
                            CGPoint(
                                x: inset + CGFloat(point.x) * plotSize.width,
                                y: inset + CGFloat(1 - point.y) * plotSize.height
                            )
                        }
                        if draggedHandle == nil {
                            onEditingChanged(true)
                            let first = graphPoint(NormalizedPoint(x: editable.x1, y: editable.y1))
                            let second = graphPoint(NormalizedPoint(x: editable.x2, y: editable.y2))
                            let firstDistance = hypot(value.startLocation.x - first.x, value.startLocation.y - first.y)
                            let secondDistance = hypot(value.startLocation.x - second.x, value.startLocation.y - second.y)
                            draggedHandle = firstDistance <= secondDistance ? .first : .second
                            if preset != .custom {
                                customCurve = editable
                                preset = .custom
                            }
                        } else {
                            editable = customCurve
                        }
                        let x = min(max(Double((value.location.x - inset) / plotSize.width), 0), 1)
                        let y = min(max(Double(1 - (value.location.y - inset) / plotSize.height), 0), 1)
                        switch draggedHandle {
                        case .first:
                            editable = ZoomBezierCurve(x1: x, y1: y, x2: editable.x2, y2: editable.y2)
                        case .second:
                            editable = ZoomBezierCurve(x1: editable.x1, y1: editable.y1, x2: x, y2: y)
                        case nil:
                            break
                        }
                        customCurve = editable
                        previewStartedAt = Date()
                    }
                    .onEnded { _ in
                        let wasDragging = draggedHandle != nil
                        draggedHandle = nil
                        previewStartedAt = Date()
                        if wasDragging { onEditingChanged(false) }
                    }
            )
            .accessibilityElement()
            .accessibilityLabel("动画贝塞尔曲线")
            .accessibilityValue(preset.rawValue)
            .accessibilityHint("拖动两个控制点调整加速和减速")
        }
    }

    private var curveMotionPreview: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 120.0)) { context in
            GeometryReader { geometry in
                let progress = previewProgress(at: context.date)
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .fill(Color.black.opacity(0.2))
                    Capsule()
                        .fill(Color.white.opacity(0.08))
                        .frame(height: 4)
                        .padding(.horizontal, 18)
                    Image(systemName: "rectangle.inset.filled")
                        .font(.system(size: 22, weight: .medium))
                        .foregroundStyle(.white, Color(white: 0.45))
                        .scaleEffect(0.78 + progress * 0.28)
                        .offset(x: 18 + progress * max(geometry.size.width - 62, 0))

                    Text("点击预设即时重播")
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                        .padding(.trailing, 10)
                        .allowsHitTesting(false)
                }
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { previewStartedAt = Date() }
        .accessibilityLabel("当前曲线动画预览")
    }

    private func previewProgress(at date: Date) -> Double {
        let elapsed = max(date.timeIntervalSince(previewStartedAt), 0)
        let phase = elapsed.truncatingRemainder(dividingBy: 2.2)
        let linear: Double
        let isExiting: Bool
        if phase < 0.72 {
            linear = phase / 0.72
            isExiting = false
        } else if phase < 1.35 {
            linear = 1
            isExiting = false
        } else if phase < 2.07 {
            linear = (phase - 1.35) / 0.72
            isExiting = true
        } else {
            linear = 1
            isExiting = true
        }
        let eased = ZoomInterpolator.easedProgress(
            linear,
            preset: preset,
            customCurve: customCurve,
            motion: motion
        )
        return isExiting ? 1 - eased : eased
    }
}

private struct ZoomCurvePresetGlyph: View {
    let preset: ZoomEasingPreset
    let customCurve: ZoomBezierCurve
    let motion: MotionStyle

    var body: some View {
        Canvas { context, size in
            var path = Path()
            for index in 0...24 {
                let time = Double(index) / 24
                let progress = ZoomInterpolator.easedProgress(
                    time,
                    preset: preset,
                    customCurve: customCurve,
                    motion: motion
                )
                let point = CGPoint(
                    x: CGFloat(time) * size.width,
                    y: CGFloat(1 - min(max(progress, 0), 1)) * size.height
                )
                if index == 0 { path.move(to: point) } else { path.addLine(to: point) }
            }
            context.stroke(path, with: .color(.white.opacity(0.9)), lineWidth: 1.4)
        }
    }
}
