import RecorderCore
import SwiftUI

/// One quiet entry point; presets, orientation and custom input share a popover.
struct EditorCanvasRatioSelector: View {
    @Binding var canvas: CanvasStyle
    @State private var isPresented = false
    @State private var editingCustom = false
    @State private var widthText = "16"
    @State private var heightText = "9"
    @Namespace private var highlight

    private let presets: [CanvasAspectRatio] = [.adaptive, .landscape, .standard, .cinema, .square, .custom]
    private var portrait: Bool { (canvas.resolvedFixedAspectRatio ?? 1) < 1 }
    private var selectedPreset: CanvasAspectRatio {
        if editingCustom { return .custom }
        switch canvas.aspectRatio {
        case .portrait: return .landscape
        case .standardPortrait: return .standard
        case .cinemaPortrait: return .cinema
        default: return canvas.aspectRatio
        }
    }
    private var valueLabel: String {
        // Keep even very large user-entered pairs inside the popover; the
        // toolbar must never grow wider because of the authored ratio text.
        appLocalized(canvas.aspectRatio.rawValue)
    }
    private var customValue: CanvasCustomAspectRatio? {
        guard let width = Double(widthText), let height = Double(heightText),
              width.isFinite, height.isFinite, width > 0, height > 0,
              (0.1...10).contains(width / height) else { return nil }
        return .init(width: width, height: height)
    }

    var body: some View {
        entryButton
    }

    private func prepareFields() {
        editingCustom = canvas.aspectRatio == .custom
        widthText = number(canvas.customAspectRatio.width)
        heightText = number(canvas.customAspectRatio.height)
    }

    private var entryButton: some View {
        Button {
            prepareFields()
            isPresented = true
        } label: {
            EditorToolbarControlSurface(accessibilityTitle: "画布比例") { entryLabel }
        }
        .buttonStyle(EditorToolbarPressButtonStyle(cornerRadius: 9, cornerStyle: .continuous))
        .accessibilityLabel("画布比例")
        .accessibilityValue(valueLabel)
        .popover(isPresented: $isPresented, arrowEdge: .bottom) { panel }
    }

    private var entryLabel: some View {
        HStack(spacing: 8) {
            Image(systemName: "aspectratio")
            Text(valueLabel).lineLimit(1).fixedSize()
            Image(systemName: "chevron.down").font(.appUI(size: 9, weight: .medium))
                .foregroundStyle(.secondary)
        }
    }

    private var panel: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("画布比例").font(.appUI(size: 14, weight: .semibold))
                Spacer()
                Button { isPresented = false } label: { Image(systemName: "xmark") }
                    .buttonStyle(.editorGhost).accessibilityLabel("关闭")
            }
            controls
        }
        .padding(18).frame(width: 320)
        .background(EditorTheme.panelSurface)
        .animation(SpringMotion.fluid, value: editingCustom)
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: 12) {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 3), spacing: 8) {
                ForEach(presets) { ratio in presetButton(ratio) }
            }
            if editingCustom {
                HStack(spacing: 8) {
                    TextField("宽", text: $widthText)
                    Text(":").foregroundStyle(.secondary)
                    TextField("高", text: $heightText)
                    Button("应用") {
                        guard let value = customValue else { return }
                        var updated = canvas
                        updated.customAspectRatio = value
                        updated.aspectRatio = .custom
                        withAnimation(SpringMotion.fluid) { canvas = updated }
                    }.buttonStyle(.editorQuiet).disabled(customValue == nil)
                }
                .textFieldStyle(.plain).font(.appUI(size: 13)).padding(10)
                .background(EditorTheme.chrome(0.035), in: RoundedRectangle(cornerRadius: 10))
                Text("输入宽高比例，例如 3:2（支持 1:10 至 10:1）")
                    .font(.appUI(size: 11)).foregroundStyle(.secondary)
            } else if selectedPreset != .adaptive && selectedPreset != .square {
                HStack(spacing: 8) {
                    orientationButton("横向", symbol: "rectangle", isPortrait: false)
                    orientationButton("竖向", symbol: "rectangle.portrait", isPortrait: true)
                }
            }
        }
    }

    private func presetButton(_ ratio: CanvasAspectRatio) -> some View {
        let selected = selectedPreset == ratio
        let aspect: CGFloat = switch ratio {
        case .landscape: 16 / 9
        case .standard: 4 / 3
        case .cinema: 2.39
        default: 1
        }
        return Button {
            if ratio == .custom { editingCustom = true; return }
            editingCustom = false
            var updated = canvas
            updated.aspectRatio = oriented(ratio, portrait: portrait)
            withAnimation(SpringMotion.fluid) { canvas = updated }
        } label: {
            VStack(spacing: 7) {
                if ratio == .custom || ratio == .adaptive {
                    Image(systemName: ratio == .custom ? "slider.horizontal.3" : "arrow.up.left.and.arrow.down.right")
                        .frame(height: 24)
                } else {
                    RoundedRectangle(cornerRadius: 3).strokeBorder(lineWidth: 1.3)
                        .frame(width: min(24, 32 / aspect) * aspect, height: min(24, 32 / aspect)).frame(height: 24)
                }
                Text(appLocalized(ratio == .cinema ? "电影" : ratio.rawValue))
                    .font(.appUI(size: 12, weight: selected ? .medium : .regular)).lineLimit(1)
            }
            .foregroundStyle(selected ? EditorTheme.selectionTint : EditorTheme.chrome(0.65))
            .frame(maxWidth: .infinity).frame(height: 68)
            .background {
                if selected {
                    RoundedRectangle(cornerRadius: 11).fill(EditorTheme.selectionWash)
                        .matchedGeometryEffect(id: "ratio", in: highlight)
                } else { RoundedRectangle(cornerRadius: 11).fill(EditorTheme.chrome(0.025)) }
            }
            .contentShape(RoundedRectangle(cornerRadius: 11))
        }.buttonStyle(EditorToolbarPressButtonStyle(cornerRadius: 11, cornerStyle: .circular))
        .help(appLocalized(ratio.rawValue))
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func orientationButton(_ title: String, symbol: String, isPortrait: Bool) -> some View {
        Button {
            var updated = canvas
            updated.aspectRatio = oriented(selectedPreset, portrait: isPortrait)
            withAnimation(SpringMotion.fluid) { canvas = updated }
        } label: {
            Label(appLocalized(title), systemImage: symbol)
                .font(.appUI(size: 12, weight: .medium))
                .frame(maxWidth: .infinity).padding(.vertical, 9)
                .background(portrait == isPortrait ? EditorTheme.selectionWash : EditorTheme.chrome(0.025),
                    in: RoundedRectangle(cornerRadius: 9))
        }.buttonStyle(EditorToolbarPressButtonStyle(cornerRadius: 9, cornerStyle: .circular))
        .accessibilityAddTraits(portrait == isPortrait ? .isSelected : [])
    }

    private func oriented(_ ratio: CanvasAspectRatio, portrait: Bool) -> CanvasAspectRatio {
        guard portrait else { return ratio }
        switch ratio {
        case .landscape: return .portrait
        case .standard: return .standardPortrait
        case .cinema: return .cinemaPortrait
        default: return ratio
        }
    }

    private func number(_ value: Double) -> String {
        String(format: "%.3f", value).replacingOccurrences(of: "\\.?0+$", with: "", options: .regularExpression)
    }
}
