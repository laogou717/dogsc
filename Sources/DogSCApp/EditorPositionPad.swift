import RecorderCore
import SwiftUI

/// A compact direct-manipulation surface for normalized editor positions.
/// The visual pad, exact X/Y entry and reset action all share the caller's
/// single continuous interaction instead of exposing three competing paths.
struct EditorPositionPad: View {
    @Environment(\.consolePalette) private var palette
    @Environment(\.editorInsideTile) private var insideTile
    @State private var isCoordinateEditing = false

    let title: String
    var detail: String? = nil
    let point: NormalizedPoint
    let onChanged: (NormalizedPoint) -> Void
    let onEnded: () -> Void
    let onCancelled: () -> Void
    var onTextPreviewValidityChanged: (Bool) -> Void = { _ in }
    var snapsToGrid = true
    var compactLayout = false
    /// Where the nine anchors put the point. Positions that already keep an
    /// edge margin (camera, zoom anchor, clamped regions) use the full
    /// 0 / 50 / 100 %; a centre point (stickers) stays 15 % in.
    var anchorSteps: [Double] = [0, 0.5, 1]

    /// EDT-079: the name, a 56 pt nine-point anchor (one click puts it at a
    /// corner, an edge or the centre) and the exact X / Y beside it. The
    /// object itself is dragged on the canvas, so the big pad is gone.
    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            Text(appLocalized(title))
                .font(.appUI(size: 13))
                .foregroundStyle(EditorTheme.secondaryText)
                .lineLimit(1)
                .frame(width: EditorPropertyRowMetrics.labelWidth, alignment: .leading)
            anchorGrid
            coordinateReadouts
                .frame(maxWidth: .infinity)
        }
        .frame(minHeight: 56)
        .help(detail.map { appLocalized($0) } ?? "")
    }

    private var anchorGrid: some View {
        let current = nearestAnchor(point)
        return VStack(spacing: 3) {
            ForEach(0..<3, id: \.self) { row in
                HStack(spacing: 3) {
                    ForEach(0..<3, id: \.self) { column in
                        let on = current?.row == row && current?.column == column
                        Button {
                            withAnimation(SpringMotion.standard) {
                                onChanged(NormalizedPoint(x: anchorSteps[column], y: anchorSteps[row]))
                                onEnded()
                            }
                        } label: {
                            ZStack {
                                RoundedRectangle(cornerRadius: 4, style: .continuous)
                                    .fill(on ? EditorTheme.panelRaised : Color.clear)
                                    .shadow(color: .black.opacity(on ? 0.1 : 0), radius: 1, y: 0.5)
                                Circle().fill(on ? EditorTheme.primaryText : EditorTheme.tertiaryText)
                                    .frame(width: on ? 6 : 4, height: on ? 6 : 4)
                            }
                            .frame(width: 14, height: 14)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(appLocalized(Self.anchorNames[row * 3 + column]))
                    }
                }
            }
        }
        .padding(4)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(EditorTheme.controlWell))
    }

    private static let anchorNames = ["左上", "上", "右上", "左", "居中", "右", "左下", "下", "右下"]

    private var coordinateReadouts: some View {
            EditorPairedParameterReadouts(
                first: EditorPairedParameterValue(
                    title: "X",
                    accessibilityTitle: String(format: appLocalized("%@ X 坐标"), appLocalized(title)),
                    value: clamp01(point.x),
                    range: 0...1,
                    displayText: EditorSliderValueFormat.percent.text(for: clamp01(point.x)),
                    inputFormat: .percent
                ),
                second: EditorPairedParameterValue(
                    title: "Y",
                    accessibilityTitle: String(format: appLocalized("%@ Y 坐标"), appLocalized(title)),
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
                onEditingChanged: { isCoordinateEditing = $0 },
                onTextPreviewValidityChanged: onTextPreviewValidityChanged,
                vertical: compactLayout
            )
    }

    /// Which of the nine anchors the point sits on.
    private func nearestAnchor(_ point: NormalizedPoint) -> (row: Int, column: Int)? {
        let steps = anchorSteps
        guard let column = steps.firstIndex(where: { abs(point.x - $0) < 0.04 }),
              let row = steps.firstIndex(where: { abs(point.y - $0) < 0.04 }) else { return nil }
        return (row, column)
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
    var compactLayout = false
    let onError: (String) -> Void

    var body: some View {
        EditorPositionPad(
            title: title,
            point: point.wrappedValue,
            onChanged: updatePoint,
            onEnded: commitPoint,
            onCancelled: cancelPoint,
            onTextPreviewValidityChanged: {
                updateEditorTextPreviewValidity(
                    store: editorStore, isValid: $0,
                    commandScope: commandScope, selection: selection,
                    actionName: actionName
                )
            },
            snapsToGrid: snapsToGrid,
            compactLayout: compactLayout
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
