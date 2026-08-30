import RecorderCore
import SwiftUI

/// One 1:1 direct-manipulation surface for every normalized editor position.
/// The visual pad, exact X/Y entry and reset action all share the caller's
/// single continuous interaction instead of exposing three competing paths.
struct EditorPositionPad: View {
    @GestureState private var draggedPoint: NormalizedPoint?
    @State private var isCoordinateEditing = false

    let title: String
    var detail: String? = nil
    let point: NormalizedPoint
    let onChanged: (NormalizedPoint) -> Void
    let onEnded: () -> Void
    let onCancelled: () -> Void
    var snapsToGrid = true

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 8) {
                Text(title)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Color.white.opacity(0.84))

                Spacer(minLength: 8)

                Button {
                    withAnimation(SpringMotion.snappy) {
                        onChanged(NormalizedPoint(x: 0.5, y: 0.5))
                        onEnded()
                    }
                } label: {
                    Label("居中", systemImage: "scope")
                        .font(.caption2.weight(.semibold))
                }
                .buttonStyle(.editorGhost)
                .controlSize(.small)
                .disabled(isCentered)
                .accessibilityLabel("居中\(title)")
            }

            if let detail {
                Text(detail)
                    .font(.caption2)
                    .foregroundStyle(Color.white.opacity(0.50))
                    .fixedSize(horizontal: false, vertical: true)
            }

            positionSurface

            EditorPairedParameterReadouts(
                first: EditorPairedParameterValue(
                    title: "X",
                    value: clamp01(point.x),
                    range: 0...1,
                    displayText: EditorSliderValueFormat.percent.text(for: clamp01(point.x)),
                    inputFormat: .percent
                ),
                second: EditorPairedParameterValue(
                    title: "Y",
                    value: clamp01(point.y),
                    range: 0...1,
                    displayText: EditorSliderValueFormat.percent.text(for: clamp01(point.y)),
                    inputFormat: .percent
                ),
                onChanged: { x, y in
                    onChanged(NormalizedPoint(x: x, y: y))
                },
                onEnded: onEnded,
                onCancelled: onCancelled,
                onEditingChanged: { isCoordinateEditing = $0 }
            )
        }
    }

    private var positionSurface: some View {
        GeometryReader { proxy in
            let inset: CGFloat = 12
            let usableWidth = max(proxy.size.width - inset * 2, 1)
            let usableHeight = max(proxy.size.height - inset * 2, 1)
            let displayedPoint = draggedPoint ?? point
            let x = inset + CGFloat(clamp01(displayedPoint.x)) * usableWidth
            let y = inset + CGFloat(clamp01(displayedPoint.y)) * usableHeight
            let isDirectlyEditing = draggedPoint != nil || isCoordinateEditing

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
                                isDirectlyEditing
                                    ? EditorTheme.platinumAccent.opacity(0.22)
                                    : Color.white.opacity(0.075),
                                lineWidth: 0.75
                            )
                    }

                referenceGrid(
                    size: proxy.size,
                    inset: inset,
                    usableWidth: usableWidth,
                    usableHeight: usableHeight
                )

                if isDirectlyEditing {
                    Path { path in
                        path.move(to: CGPoint(x: x, y: inset))
                        path.addLine(to: CGPoint(x: x, y: inset + usableHeight))
                        path.move(to: CGPoint(x: inset, y: y))
                        path.addLine(to: CGPoint(x: inset + usableWidth, y: y))
                    }
                    .stroke(
                        EditorTheme.platinumAccent.opacity(0.26),
                        style: StrokeStyle(lineWidth: 0.75, dash: [2.5, 3.5])
                    )
                    .allowsHitTesting(false)
                }

                ZStack {
                    Circle()
                        .fill(
                            EditorTheme.platinumAccent.opacity(
                                isDirectlyEditing ? 0.20 : 0.09
                            )
                        )
                        .frame(width: isDirectlyEditing ? 28 : 24, height: isDirectlyEditing ? 28 : 24)

                    Circle()
                        .fill(
                            LinearGradient(
                                colors: [Color.white, EditorTheme.platinumAccent],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        )
                        .frame(width: isDirectlyEditing ? 16 : 14, height: isDirectlyEditing ? 16 : 14)
                        .overlay {
                            Circle()
                                .stroke(Color.white.opacity(0.78), lineWidth: 0.75)
                        }
                        .shadow(color: Color.black.opacity(0.42), radius: 3, y: 1.5)
                }
                .position(x: x, y: y)
                .transaction { $0.animation = nil }
            }
            .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .gesture(
                DragGesture(minimumDistance: 0)
                    .updating($draggedPoint) { gesture, state, _ in
                        state = gesturePoint(
                            location: gesture.location,
                            size: proxy.size,
                            inset: inset
                        )
                    }
                    .onChanged { gesture in
                        onChanged(
                            gesturePoint(
                                location: gesture.location,
                                size: proxy.size,
                                inset: inset
                            )
                        )
                    }
                    .onEnded { _ in onEnded() }
            )
            .allowsHitTesting(!isCoordinateEditing)
            .accessibilityHidden(true)
        }
        .frame(width: 184, height: 184)
        .frame(maxWidth: .infinity)
    }

    private func referenceGrid(
        size: CGSize,
        inset: CGFloat,
        usableWidth: CGFloat,
        usableHeight: CGFloat
    ) -> some View {
        ZStack {
            Path { path in
                for fraction in [1.0 / 3.0, 2.0 / 3.0] {
                    let x = inset + usableWidth * fraction
                    let y = inset + usableHeight * fraction
                    path.move(to: CGPoint(x: x, y: inset))
                    path.addLine(to: CGPoint(x: x, y: inset + usableHeight))
                    path.move(to: CGPoint(x: inset, y: y))
                    path.addLine(to: CGPoint(x: inset + usableWidth, y: y))
                }
            }
            .stroke(
                Color.white.opacity(0.065),
                style: StrokeStyle(lineWidth: 0.75, dash: [3, 4])
            )

            Path { path in
                path.move(to: CGPoint(x: size.width / 2, y: inset))
                path.addLine(to: CGPoint(x: size.width / 2, y: size.height - inset))
                path.move(to: CGPoint(x: inset, y: size.height / 2))
                path.addLine(to: CGPoint(x: size.width - inset, y: size.height / 2))
            }
            .stroke(
                EditorTheme.platinumAccent.opacity(0.14),
                style: StrokeStyle(lineWidth: 0.75, dash: [3, 4])
            )
        }
        .allowsHitTesting(false)
    }

    private var isCentered: Bool {
        abs(point.x - 0.5) < 0.000_5 && abs(point.y - 0.5) < 0.000_5
    }

    private func gesturePoint(
        location: CGPoint,
        size: CGSize,
        inset: CGFloat
    ) -> NormalizedPoint {
        let width = max(size.width - inset * 2, 1)
        let height = max(size.height - inset * 2, 1)
        let normalized = NormalizedPoint(
            x: clamp01(Double((location.x - inset) / width)),
            y: clamp01(Double((location.y - inset) / height))
        )
        return snapsToGrid ? snappedToGrid(normalized) : normalized
    }

    private func snappedToGrid(_ point: NormalizedPoint) -> NormalizedPoint {
        let anchors = [0.0, 1.0 / 3.0, 0.5, 2.0 / 3.0, 1.0]
        func snap(_ value: Double) -> Double {
            anchors.first(where: { abs(value - $0) <= 0.035 }) ?? value
        }
        return NormalizedPoint(x: snap(point.x), y: snap(point.y))
    }

    private func clamp01(_ value: Double) -> Double {
        min(max(value.isFinite ? value : 0.5, 0), 1)
    }
}

/// Transactional wrapper used by persistent canvas/camera style domains.
/// Animation and overlay inspectors keep their existing draft owners and use
/// `EditorPositionPad` directly.
struct EditorTransactionalPositionPad: View {
    @ObservedObject var editorStore: EditorStore
    let title: String
    let point: Binding<NormalizedPoint>
    let commandScope: EditorInteractionCommandScope
    var selection: EditorSelection? = nil
    let actionName: String
    var snapsToGrid = true
    let onError: (String) -> Void

    var body: some View {
        EditorPositionPad(
            title: title,
            point: point.wrappedValue,
            onChanged: updatePoint,
            onEnded: commitPoint,
            onCancelled: cancelPoint,
            snapsToGrid: snapsToGrid
        )
    }

    private func updatePoint(_ updated: NormalizedPoint) {
        _ = editorStore.beginContinuousInteraction(
            commandScope: commandScope,
            selection: selection
        )
        point.wrappedValue = updated
    }

    private func commitPoint() {
        updateEditorContinuousInteraction(
            store: editorStore,
            isEditing: false,
            commandScope: commandScope,
            actionName: actionName,
            onError: onError
        )
    }

    private func cancelPoint() {
        guard editorStore.interaction?.commandScope == commandScope else { return }
        if let selection, editorStore.interaction?.selection != selection { return }
        editorStore.cancelInteraction()
    }
}
