import RecorderCore
import SwiftUI

/// Spatial edge inputs and one shared slider keep all linkage modes in one control.
struct EditorCanvasPaddingControls: View {
    @ObservedObject var editorStore: EditorStore
    let onError: (String) -> Void
    @State private var selectedEdge = EditorCanvasPaddingEdge.top
    @State private var isSliderEditing = false

    private var padding: Binding<CanvasPadding> {
        editorCanvasBinding(store: editorStore, keyPath: \.paddingInsets,
                            actionName: "调整画布边距", onError: onError)
    }

    private var activeTitle: String {
        switch padding.wrappedValue.mode {
        case .uniform: "四边边距"
        case .axes: selectedEdge.isHorizontal ? "左右边距" : "上下边距"
        case .independent: selectedEdge.title
        }
    }

    var body: some View {
        VStack(spacing: 12) {
            HStack {
                Spacer(minLength: 0)
                linkageControl
            }

            VStack(spacing: 12) {
                edgeInput(.top)
                HStack(spacing: 12) {
                    edgeInput(.left)
                    Spacer(minLength: 0)
                    Image(systemName: linkageSymbol)
                        .font(.appUI(size: 16, weight: .regular))
                        .foregroundStyle(EditorTheme.chrome(0.32))
                        .frame(width: 56, height: 48)
                        .accessibilityHidden(true)
                    Spacer(minLength: 0)
                    edgeInput(.right)
                }
                edgeInput(.bottom)
            }
            .frame(maxWidth: .infinity)

            Rectangle().fill(EditorTheme.chrome(0.06)).frame(height: 0.5)

            EditorTransactionalSlider(
                editorStore: editorStore, value: edgeBinding(selectedEdge), range: 0...360,
                commandScope: .canvas, actionName: "调整画布边距", title: activeTitle,
                formatValue: { EditorSliderValueFormat.points.text(for: $0) },
                showsFloatingValue: false,
                onInteractionChanged: { isSliderEditing = $0 }, onError: onError
            )
            .accessibilityLabel(appLocalized(activeTitle))
            .accessibilityValue(EditorSliderValueFormat.points.text(for: edgeBinding(selectedEdge).wrappedValue))
            .accessibilityIdentifier("editor.canvas.padding.slider")
        }
        .padding(12)
        .background(EditorTheme.groupSurface,
                    in: RoundedRectangle(cornerRadius: EditorInterfaceRadius.group))
        .overlay {
            RoundedRectangle(cornerRadius: EditorInterfaceRadius.group)
                .stroke(EditorTheme.controlBorder, lineWidth: 0.75)
        }
    }

    private func edgeInput(_ edge: EditorCanvasPaddingEdge) -> some View {
        EditorCanvasPaddingValue(
            editorStore: editorStore, edge: edge, value: edgeBinding(edge),
            isSelected: isLinked(edge), isSliderEditing: isSliderEditing,
            onSelect: { selectedEdge = edge }, onError: onError
        )
    }

    private var linkageControl: some View {
        EditorActionMenu(title: "边距联动", items: CanvasPaddingMode.allCases.map { mode in
            RecorderMenuItem.action(
                mode.title, systemImage: mode.symbol, isOn: padding.wrappedValue.mode == mode
            ) {
                var updated = padding.wrappedValue
                updated.setMode(mode)
                padding.wrappedValue = updated
            }
        }) {
            HStack(spacing: 5) {
                Text(appLocalized(padding.wrappedValue.mode.shortTitle))
                    .font(.appUI(size: 11, weight: .medium))
                Image(systemName: "chevron.down")
                    .font(.appUI(size: 8, weight: .medium))
            }
            .foregroundStyle(EditorTheme.secondaryText)
            .padding(.horizontal, 6)
            .frame(height: 22)
        }
        .accessibilityValue(appLocalized(padding.wrappedValue.mode.title))
        .accessibilityIdentifier("editor.canvas.padding.mode")
        .help("点击切换联动方式")
    }

    private var linkageSymbol: String {
        if padding.wrappedValue.mode == .axes {
            return selectedEdge.isHorizontal ? "arrow.left.and.right" : "arrow.up.and.down"
        }
        return padding.wrappedValue.mode.symbol
    }

    private func isLinked(_ edge: EditorCanvasPaddingEdge) -> Bool {
        switch padding.wrappedValue.mode {
        case .uniform: true
        case .axes: edge.isHorizontal == selectedEdge.isHorizontal
        case .independent: edge == selectedEdge
        }
    }

    private func edgeBinding(_ edge: EditorCanvasPaddingEdge) -> Binding<Double> {
        Binding(get: { padding.wrappedValue[keyPath: edge.keyPath] }, set: { newValue in
            var updated = padding.wrappedValue
            updated.setValue(newValue, for: edge.keyPath)
            padding.wrappedValue = updated
        })
    }
}

private extension CanvasPaddingMode {
    var title: String {
        switch self {
        case .uniform: "四边联动"
        case .axes: "左右 / 上下联动"
        case .independent: "四边独立"
        }
    }

    var shortTitle: String {
        switch self {
        case .uniform: "统一"
        case .axes: "左右 / 上下"
        case .independent: "独立"
        }
    }

    var symbol: String {
        switch self {
        case .uniform: "link"
        case .axes: "arrow.left.and.right"
        case .independent: "arrow.up.left.and.arrow.down.right"
        }
    }
}
