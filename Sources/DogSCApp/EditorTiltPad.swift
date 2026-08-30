import SwiftUI

/// Direct 3D orientation control for the screen-motion target. Vertical drag
/// controls X tilt, horizontal drag controls Y tilt; exact angles live beside
/// the same surface and share its draft/commit lifecycle.
struct EditorTiltPad: View {
    @GestureState private var isDragging = false
    @State private var isAngleEditing = false

    let rotationX: Double
    let rotationY: Double
    let onChanged: (Double, Double) -> Void
    let onEnded: () -> Void
    let onCancelled: () -> Void

    private let maximumX = 28.0
    private let maximumY = 32.0

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("3D 倾斜")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Color.white.opacity(0.84))
                    Text("上下控制 X · 左右控制 Y")
                        .font(.system(size: 9.5, weight: .medium))
                        .foregroundStyle(Color.white.opacity(0.38))
                }

                Spacer(minLength: 8)

                Button {
                    withAnimation(SpringMotion.snappy) {
                        onChanged(0, 0)
                        onEnded()
                    }
                } label: {
                    Label("归零", systemImage: "scope")
                        .font(.caption2.weight(.semibold))
                }
                .buttonStyle(.editorGhost)
                .controlSize(.small)
                .disabled(isNeutral)
                .accessibilityLabel("归零 3D 倾斜")
            }

            tiltSurface

            EditorPairedParameterReadouts(
                first: EditorPairedParameterValue(
                    title: "X",
                    value: clamped(rotationX, to: -maximumX...maximumX),
                    range: -maximumX...maximumX,
                    displayText: String(format: "%.1f°", rotationX),
                    inputFormat: .decimal1
                ),
                second: EditorPairedParameterValue(
                    title: "Y",
                    value: clamped(rotationY, to: -maximumY...maximumY),
                    range: -maximumY...maximumY,
                    displayText: String(format: "%.1f°", rotationY),
                    inputFormat: .decimal1
                ),
                onChanged: onChanged,
                onEnded: onEnded,
                onCancelled: onCancelled,
                onEditingChanged: { isAngleEditing = $0 }
            )
        }
    }

    private var tiltSurface: some View {
        GeometryReader { proxy in
            let inset: CGFloat = 12
            let point = handlePoint(in: proxy.size, inset: inset)
            let active = isDragging || isAngleEditing

            ZStack {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [
                                Color.black.opacity(0.38),
                                Color.black.opacity(0.20),
                            ],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                    .overlay {
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .stroke(
                                active
                                    ? EditorTheme.platinumAccent.opacity(0.22)
                                    : Color.white.opacity(0.075),
                                lineWidth: 0.75
                            )
                    }

                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [
                                EditorTheme.platinumAccent.opacity(0.11),
                                Color.white.opacity(0.025),
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .overlay {
                        RoundedRectangle(cornerRadius: 9, style: .continuous)
                            .stroke(
                                LinearGradient(
                                    colors: [
                                        Color.white.opacity(0.34),
                                        EditorTheme.platinumAccent.opacity(0.10),
                                    ],
                                    startPoint: .top,
                                    endPoint: .bottom
                                ),
                                lineWidth: 0.8
                            )
                    }
                    .padding(.horizontal, 24)
                    .padding(.vertical, 18)
                    .rotation3DEffect(
                        .degrees(clamped(rotationX, to: -maximumX...maximumX) * 0.55),
                        axis: (x: 1, y: 0, z: 0),
                        perspective: 0.72
                    )
                    .rotation3DEffect(
                        .degrees(clamped(rotationY, to: -maximumY...maximumY) * 0.55),
                        axis: (x: 0, y: 1, z: 0),
                        perspective: 0.72
                    )
                    .allowsHitTesting(false)

                Path { path in
                    path.move(to: CGPoint(x: proxy.size.width / 2, y: inset))
                    path.addLine(to: CGPoint(x: proxy.size.width / 2, y: proxy.size.height - inset))
                    path.move(to: CGPoint(x: inset, y: proxy.size.height / 2))
                    path.addLine(to: CGPoint(x: proxy.size.width - inset, y: proxy.size.height / 2))
                }
                .stroke(
                    EditorTheme.platinumAccent.opacity(0.13),
                    style: StrokeStyle(lineWidth: 0.75, dash: [3, 4])
                )
                .allowsHitTesting(false)

                if active {
                    Path { path in
                        path.move(to: CGPoint(x: point.x, y: inset))
                        path.addLine(to: CGPoint(x: point.x, y: proxy.size.height - inset))
                        path.move(to: CGPoint(x: inset, y: point.y))
                        path.addLine(to: CGPoint(x: proxy.size.width - inset, y: point.y))
                    }
                    .stroke(
                        EditorTheme.platinumAccent.opacity(0.27),
                        style: StrokeStyle(lineWidth: 0.75, dash: [2.5, 3.5])
                    )
                    .allowsHitTesting(false)
                }

                ZStack {
                    Circle()
                        .fill(EditorTheme.platinumAccent.opacity(active ? 0.20 : 0.09))
                        .frame(width: active ? 28 : 24, height: active ? 28 : 24)
                    Circle()
                        .fill(
                            LinearGradient(
                                colors: [Color.white, EditorTheme.platinumAccent],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        )
                        .frame(width: active ? 16 : 14, height: active ? 16 : 14)
                        .overlay {
                            Circle().stroke(Color.white.opacity(0.78), lineWidth: 0.75)
                        }
                        .shadow(color: Color.black.opacity(0.42), radius: 3, y: 1.5)
                }
                .position(point)
                .transaction { $0.animation = nil }
            }
            .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .gesture(
                DragGesture(minimumDistance: 0)
                    .updating($isDragging) { _, state, _ in state = true }
                    .onChanged { gesture in
                        let tilt = tilt(at: gesture.location, in: proxy.size, inset: inset)
                        onChanged(tilt.x, tilt.y)
                    }
                    .onEnded { _ in onEnded() }
            )
            .allowsHitTesting(!isAngleEditing)
            .accessibilityHidden(true)
        }
        .frame(width: 184, height: 126)
        .frame(maxWidth: .infinity)
        .accessibilityIdentifier("screen-motion.tilt-pad")
    }

    private var isNeutral: Bool {
        abs(rotationX) < 0.000_5 && abs(rotationY) < 0.000_5
    }

    private func handlePoint(in size: CGSize, inset: CGFloat) -> CGPoint {
        let width = max(size.width - inset * 2, 1)
        let height = max(size.height - inset * 2, 1)
        let x = (clamped(rotationY, to: -maximumY...maximumY) / (maximumY * 2)) + 0.5
        let y = 0.5 - (clamped(rotationX, to: -maximumX...maximumX) / (maximumX * 2))
        return CGPoint(
            x: inset + CGFloat(x) * width,
            y: inset + CGFloat(y) * height
        )
    }

    private func tilt(
        at location: CGPoint,
        in size: CGSize,
        inset: CGFloat
    ) -> (x: Double, y: Double) {
        let width = max(size.width - inset * 2, 1)
        let height = max(size.height - inset * 2, 1)
        let horizontal = min(max(Double((location.x - inset) / width), 0), 1)
        let vertical = min(max(Double((location.y - inset) / height), 0), 1)
        var x = (0.5 - vertical) * maximumX * 2
        var y = (horizontal - 0.5) * maximumY * 2
        if abs(x) <= 1.4 { x = 0 }
        if abs(y) <= 1.4 { y = 0 }
        return (x, y)
    }

    private func clamped(_ value: Double, to range: ClosedRange<Double>) -> Double {
        min(max(value.isFinite ? value : 0, range.lowerBound), range.upperBound)
    }
}
