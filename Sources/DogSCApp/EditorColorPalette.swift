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
        VStack(alignment: .leading, spacing: 10) {
            saturationBrightnessPlane
            hueStrip

            HStack(spacing: 6) {
                HStack(spacing: 6) {
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(Color(hex: lastPreview))
                        .overlay(RoundedRectangle(cornerRadius: 4, style: .continuous).strokeBorder(EditorTheme.hairline))
                        .frame(width: 14, height: 14)
                        .accessibilityHidden(true)
                    TextField("#RRGGBB", text: $hexText)
                        .textFieldStyle(.plain)
                        // Use the system text selection so selected hex values
                        // remain readable in both appearances.
                        .tint(nil)
                        .font(.appUI(size: 12.5, weight: .medium).monospacedDigit())
                        .accessibilityLabel(String(format: appLocalized("%@十六进制值"), appLocalized(title)))
                        .onChange(of: hexText) { _, text in
                            guard let color = HexColor(text), color != lastPreview else { return }
                            rebase(color)
                            onPreview(color)
                        }
                        .onSubmit { hexText = lastPreview.hexString; dismiss() }
                }
                .padding(.horizontal, 8)
                .frame(height: 30)
                .background(EditorTheme.controlWell, in: RoundedRectangle(cornerRadius: 7, style: .continuous))

                Button(action: sampleScreen) {
                    AppLineIcon(kind: .eyedropper, size: 16)
                        .frame(width: 30, height: 30)
                        .background(EditorTheme.controlWell, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.editorToolbarPress)
                .help(appLocalized("从画面取色"))
                .accessibilityLabel(appLocalized("从画面取色"))
            }
            if HexColor(hexText) == nil {
                Text("请输入六位色值，例如 #EDA647")
                    .font(.appUI(size: 11)).foregroundStyle(EditorTheme.popoverSecondaryText)
            }

            let recent = EditorColorHistory.colors.filter { $0 != lastPreview }.prefix(8)
            if !recent.isEmpty {
                chipSection("最近用过", Array(recent))
            }
            chipSection("常用", Self.common)
        }
        .padding(12).frame(width: 264)
        .focusEffectDisabled()
        .onChange(of: value) { _, color in
            guard color != lastPreview else { return }
            rebase(color)
        }
        .onDisappear {
            if lastPreview != value || EditorColorHistory.colors.first != lastPreview {
                EditorColorHistory.remember(lastPreview)
            }
        }
        .onExitCommand { dismiss() }
    }

    private static let common: [HexColor] = [
        "#000000", "#FFFFFF", "#E5484D", "#F5A524", "#30A46C", "#0091FF", "#8E4EC6", "#6B6962"
    ].compactMap { HexColor($0) }

    private func chipSection(_ heading: String, _ colors: [HexColor]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(appLocalized(heading))
                .font(.appUI(size: 11.5, weight: .medium))
                .foregroundStyle(EditorTheme.popoverSecondaryText)
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 8), spacing: 6) {
                ForEach(colors, id: \.hexString) { color in
                    Button {
                        rebase(color)
                        onPreview(color)
                    } label: {
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(Color(hex: color))
                            .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(.black.opacity(0.08)))
                            .aspectRatio(1, contentMode: .fit)
                    }
                    .buttonStyle(.editorSwatch)
                    .accessibilityLabel(color.hexString)
                }
            }
        }
    }

    /// The system sampler magnifies the screen; a click anywhere — the
    /// preview included — becomes the colour.
    private func sampleScreen() {
        NSColorSampler().show { picked in
            guard let srgb = picked?.usingColorSpace(.sRGB) else { return }
            let v = (UInt32((srgb.redComponent * 255).rounded()) << 16)
                | (UInt32((srgb.greenComponent * 255).rounded()) << 8)
                | UInt32((srgb.blueComponent * 255).rounded())
            let color = HexColor(rgb24: min(v, 0xFF_FF_FF))
            Task { @MainActor in
                rebase(color)
                onPreview(color)
            }
        }
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
            .clipShape(RoundedRectangle(cornerRadius: EditorInterfaceRadius.control, style: .continuous))
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { gesture in
                saturation = clamp(gesture.location.x / max(geometry.size.width, 1))
                brightness = 1 - clamp(gesture.location.y / max(geometry.size.height, 1))
                publishColor()
            })
        }
        .frame(height: 150)
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
                .frame(height: 12).clipShape(Capsule()).padding(.horizontal, inset)
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

/// Colours settled on recently, newest first, shared by every picker.
@MainActor
enum EditorColorHistory {
    private static let key = "editor.recentColors"
    static var colors: [HexColor] {
        (UserDefaults.standard.stringArray(forKey: key) ?? []).compactMap { HexColor($0) }
    }

    static func remember(_ color: HexColor) {
        var list = colors.filter { $0 != color }
        list.insert(color, at: 0)
        UserDefaults.standard.set(list.prefix(16).map(\.hexString), forKey: key)
    }
}

/// A swatch that opens the shared palette beside itself.
struct EditorColorWell: View {
    let title: String
    let value: HexColor
    let onPreview: (HexColor) -> Void
    @State private var showsPalette = false

    var body: some View {
        Button { showsPalette = true } label: {
            HStack(spacing: 6) {
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(Color(hex: value))
                    .overlay(RoundedRectangle(cornerRadius: 4, style: .continuous).strokeBorder(EditorTheme.hairline))
                    .frame(width: 14, height: 14)
                Text(value.hexString)
                    .font(.appUI(size: 12.5, weight: .medium).monospacedDigit())
                    .foregroundStyle(EditorTheme.primaryText)
            }
            .padding(.horizontal, 9)
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(height: 30)
            .background(EditorTheme.chrome(0.045), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.editorSwatch)
        .accessibilityLabel(String(format: appLocalized("选择%@"), appLocalized(title)))
        .editorPopover(isPresented: $showsPalette, arrowEdge: .trailing, establishesKeyboardEntry: false) {
            EditorColorPalette(title: title, value: value, onPreview: onPreview)
        }
    }
}
