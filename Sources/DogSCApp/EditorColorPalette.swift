import AppKit
import RecorderCore
import SwiftUI

/// A complete color editor in one popover. The owning input groups this
/// session into one undo command, including both dragging and hex entry.
struct EditorColorPalette: View {
    let title: String
    let value: HexColor
    let onPreview: (HexColor) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var hue: Double
    @State private var saturation: Double
    @State private var brightness: Double
    @State private var hexText: String
    @State private var lastPreview: HexColor

    init(title: String, value: HexColor, onPreview: @escaping (HexColor) -> Void) {
        self.title = title
        self.value = value
        self.onPreview = onPreview
        let hsb = Self.components(of: value)
        _hue = State(initialValue: hsb.hue)
        _saturation = State(initialValue: hsb.saturation)
        _brightness = State(initialValue: hsb.brightness)
        _hexText = State(initialValue: value.hexString)
        _lastPreview = State(initialValue: value)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text(appLocalized(title)).font(.appUI(size: 13, weight: .semibold))
                Spacer()
                Button { dismiss() } label: {
                    Image(systemName: "xmark").font(.appUI(size: 10, weight: .medium))
                        .frame(width: 24, height: 24)
                }
                .buttonStyle(.editorToolbarPress)
                .appButtonKeyboardFocus(in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                .accessibilityLabel("关闭调色面板")
            }

            saturationBrightnessPlane
            hueStrip

            HStack(spacing: 10) {
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color(hex: lastPreview))
                    .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(EditorTheme.hairline))
                    .frame(width: 32, height: 32)
                    .accessibilityHidden(true)
                Text("HEX").font(.appUI(size: 10, weight: .medium))
                    .foregroundStyle(EditorTheme.popoverSecondaryText)
                TextField("#RRGGBB", text: $hexText)
                    .textFieldStyle(.plain)
                    // Use the system text selection so selected hex values
                    // remain readable in both appearances.
                    .tint(nil)
                    .font(.appUI(size: 12, weight: .medium, design: .monospaced))
                    .padding(.horizontal, 10).frame(height: 32)
                    .background(EditorTheme.chrome(0.045), in: RoundedRectangle(cornerRadius: 8))
                    .accessibilityLabel(String(format: appLocalized("%@十六进制值"), appLocalized(title)))
                    .onChange(of: hexText) { _, text in
                        guard let color = HexColor(text), color != lastPreview else { return }
                        rebase(color)
                        onPreview(color)
                    }
                    .onSubmit { hexText = lastPreview.hexString }
            }
            if HexColor(hexText) == nil {
                Text("请输入六位色值，例如 #EDA647")
                    .font(.appUI(size: 10)).foregroundStyle(EditorTheme.popoverSecondaryText)
            }
        }
        .padding(16).frame(width: 272)
        .focusEffectDisabled()
        .onChange(of: value) { _, color in
            guard color != lastPreview else { return }
            rebase(color)
        }
        .onExitCommand { dismiss() }
    }

    private var saturationBrightnessPlane: some View {
        GeometryReader { geometry in
            ZStack(alignment: .topLeading) {
                Rectangle().fill(Color(hue: hue, saturation: 1, brightness: 1))
                LinearGradient(colors: [.white, .white.opacity(0)], startPoint: .leading, endPoint: .trailing)
                LinearGradient(colors: [.black.opacity(0), .black], startPoint: .top, endPoint: .bottom)
                Circle().fill(Color(hex: lastPreview))
                    .overlay(Circle().strokeBorder(.white, lineWidth: 2))
                    .shadow(color: .black.opacity(0.35), radius: 2, y: 1)
                    .frame(width: 16, height: 16)
                    .position(
                        x: min(max(geometry.size.width * saturation, 8), geometry.size.width - 8),
                        y: min(max(geometry.size.height * (1 - brightness), 8), geometry.size.height - 8)
                    )
            }
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { gesture in
                saturation = clamp(gesture.location.x / max(geometry.size.width, 1))
                brightness = 1 - clamp(gesture.location.y / max(geometry.size.height, 1))
                publishColor()
            })
        }
        .frame(height: 164)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("饱和度与亮度")
        .accessibilityValue(String(format: appLocalized("饱和度 %d%%，亮度 %d%%"), Int(saturation * 100), Int(brightness * 100)))
        .accessibilityAdjustableAction { direction in
            brightness = clamp(brightness + (direction == .increment ? 0.05 : -0.05))
            publishColor()
        }
        .accessibilityAction(named: "增加饱和度") { saturation = clamp(saturation + 0.05); publishColor() }
        .accessibilityAction(named: "降低饱和度") { saturation = clamp(saturation - 0.05); publishColor() }
    }

    private var hueStrip: some View {
        GeometryReader { geometry in
            let inset: CGFloat = 8
            let travel = max(geometry.size.width - inset * 2, 1)
            ZStack(alignment: .leading) {
                LinearGradient(
                    colors: (0...6).map { Color(hue: Double($0) / 6, saturation: 1, brightness: 1) },
                    startPoint: .leading, endPoint: .trailing
                )
                .frame(height: 10).clipShape(Capsule()).padding(.horizontal, inset)
                Circle().fill(Color(hue: hue, saturation: 1, brightness: 1))
                    .overlay(Circle().strokeBorder(.white, lineWidth: 2))
                    .shadow(color: .black.opacity(0.20), radius: 2, y: 1)
                    .frame(width: 16, height: 16).offset(x: hue * travel)
            }
            .frame(height: 20)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { gesture in
                hue = clamp((gesture.location.x - inset) / travel)
                publishColor()
            })
        }
        .frame(height: 20)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("色相")
        .accessibilityValue(String(format: appLocalized("%d 度"), Int(hue * 360)))
        .accessibilityAdjustableAction { direction in
            hue = clamp(hue + (direction == .increment ? 0.025 : -0.025))
            publishColor()
        }
    }

    private func publishColor() {
        let color = Color(hue: hue, saturation: saturation, brightness: brightness).hexColor
        hexText = color.hexString
        guard color != lastPreview else { return }
        lastPreview = color
        onPreview(color)
    }

    private func rebase(_ color: HexColor) {
        let hsb = Self.components(of: color)
        // Black and gray have no meaningful hue. Retain the user's hue so
        // increasing brightness/saturation does not unexpectedly jump to red.
        if hsb.saturation > 0.0001 { hue = hsb.hue }
        saturation = hsb.saturation
        brightness = hsb.brightness
        lastPreview = color
        hexText = color.hexString
    }

    private func clamp(_ value: Double) -> Double { min(max(value, 0), 1) }

    private static func components(of color: HexColor) -> (hue: Double, saturation: Double, brightness: Double) {
        let rgb = color.components
        let nsColor = NSColor(srgbRed: rgb.red, green: rgb.green, blue: rgb.blue, alpha: 1)
        return (nsColor.hueComponent, nsColor.saturationComponent, nsColor.brightnessComponent)
    }
}
