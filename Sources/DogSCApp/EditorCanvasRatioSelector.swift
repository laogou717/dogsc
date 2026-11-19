import RecorderCore
import SwiftUI

/// One quiet entry point; presets, orientation and custom input share a popover.
struct EditorCanvasRatioSelector: View {
    @Binding var canvas: CanvasStyle
    @State private var isPresented = false
    @State private var editingCustom = false
    @State private var widthText = "16"
    @State private var heightText = "9"
    @State private var showsPortrait = false
    @Namespace private var orientationThumb
    @FocusState private var customField: CustomField?

    private enum CustomField: Hashable { case width, height }

    /// The list follows the orientation switch: landscape shows the
    /// widescreen formats, portrait the phone ones (each with where it is
    /// used), so both sides get a real choice instead of a flipped copy.
    private struct Preset: Identifiable {
        let id: String
        let label: String
        let hint: String?
        let width: Double
        let height: Double
        let ratio: CanvasAspectRatio
    }

    private static let landscapePresets: [Preset] = [
        Preset(id: "16:9", label: "16:9", hint: "B站 · YouTube", width: 16, height: 9, ratio: .landscape),
        Preset(id: "4:3", label: "4:3", hint: "课件 · iPad", width: 4, height: 3, ratio: .standard),
        Preset(id: "2.39:1", label: "2.39:1", hint: "电影宽银幕", width: 2.39, height: 1, ratio: .cinema),
        Preset(id: "1:1", label: "1:1", hint: "方形", width: 1, height: 1, ratio: .square),
    ]
    private static let portraitPresets: [Preset] = [
        Preset(id: "9:16", label: "9:16", hint: "抖音 · 视频号 · Reels", width: 9, height: 16, ratio: .portrait),
        Preset(id: "3:4", label: "3:4", hint: "小红书", width: 3, height: 4, ratio: .standardPortrait),
        Preset(id: "4:5", label: "4:5", hint: "Instagram", width: 4, height: 5, ratio: .custom),
        Preset(id: "1:1", label: "1:1", hint: "方形", width: 1, height: 1, ratio: .square),
    ]

    private var presets: [Preset] { showsPortrait ? Self.portraitPresets : Self.landscapePresets }

    private func isSelected(_ preset: Preset) -> Bool {
        guard !editingCustom else { return false }
        if preset.ratio == .custom {
            return canvas.aspectRatio == .custom
                && abs(canvas.customAspectRatio.width / canvas.customAspectRatio.height - preset.width / preset.height) < 0.001
        }
        return canvas.aspectRatio == preset.ratio
    }

    private var customIsSelected: Bool {
        editingCustom || (canvas.aspectRatio == .custom && !presets.contains(where: isSelected))
    }
    private var valueLabel: String {
        // Keep even very large user-entered pairs inside the popover; the
        // toolbar must never grow wider because of the authored ratio text.
        if canvas.aspectRatio == .custom {
            let w = canvas.customAspectRatio.width, h = canvas.customAspectRatio.height
            if abs(w / h - 0.8) < 0.001 { return "4:5" }
            return w / h < 10 && number(w).count + number(h).count <= 6 ? "\(number(w)):\(number(h))" : appLocalized("自定义")
        }
        return appLocalized(canvas.aspectRatio.rawValue)
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
        showsPortrait = (canvas.resolvedFixedAspectRatio ?? 1) < 1
        editingCustom = false
        widthText = number(canvas.customAspectRatio.width)
        heightText = number(canvas.customAspectRatio.height)
    }

    private var entryButton: some View {
        Button(action: presentPanel) {
            EditorMonitorBarButtonSurface(accessibilityTitle: "画布比例", isActive: isPresented) { entryLabel }
        }
        .buttonStyle(EditorToolbarPressButtonStyle(cornerRadius: 8, showsHover: false))
        .accessibilityLabel("画布比例")
        .accessibilityValue(valueLabel)
        .editorPopoverKeyboardEntry(action: presentPanel)
        .editorPopover(isPresented: $isPresented, arrowEdge: .bottom) { panel }
    }

    private func presentPanel() {
        prepareFields()
        isPresented = true
    }

    private var entryLabel: some View {
        // 编辑器第二版: the ratio glyph and the value, no disclosure chevron.
        HStack(spacing: 6) {
            AppLineIcon(kind: .aspect, size: 16)
            Text(valueLabel).lineLimit(1).fixedSize()
        }
    }

    /// A short list in the editor's menu language: each ratio with a small
    /// outline of its shape, orientation as a two-way switch under it, and
    /// a custom pair that applies on Return.
    private var panel: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 2) {
                orientationButton("横屏", kind: .shapeWide, isPortrait: false)
                orientationButton("竖屏", kind: .portrait, isPortrait: true)
            }
            .padding(2)
            .background(EditorTheme.chrome(0.045), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            .padding(.horizontal, 4)
            .padding(.top, 2)
            .padding(.bottom, 6)
            simpleRow(title: "适应素材", kind: .expand, selected: canvas.aspectRatio == .adaptive && !editingCustom) {
                editingCustom = false
                var updated = canvas
                updated.aspectRatio = .adaptive
                canvas = updated
            }
            // The two lists cross-fade and slide toward the chosen side.
            VStack(spacing: 0) {
                ForEach(presets) { preset in presetRow(preset) }
            }
            .id(showsPortrait)
            .transition(.asymmetric(
                insertion: .opacity.combined(with: .offset(x: showsPortrait ? 14 : -14)),
                removal: .opacity.combined(with: .offset(x: showsPortrait ? -14 : 14))
            ))
            simpleRow(title: "自定义", kind: .pencil, selected: customIsSelected) {
                widthText = number(canvas.customAspectRatio.width)
                heightText = number(canvas.customAspectRatio.height)
                editingCustom = true
            }
            if editingCustom {
                Rectangle().fill(EditorTheme.hairline).frame(height: 1).padding(.vertical, 4)
                HStack(spacing: 6) {
                    customRatioField("宽", text: $widthText, field: .width)
                    Text(":").foregroundStyle(EditorTheme.tertiaryText)
                    customRatioField("高", text: $heightText, field: .height)
                    Button("应用") { applyCustom() }
                        .buttonStyle(.editorQuiet)
                        .disabled(customValue == nil)
                }
                .padding(.horizontal, 4)
                .padding(.bottom, 2)
                .onSubmit(applyCustom)
            }
        }
        .padding(4)
        .frame(width: 260)
        .animation(SpringMotion.canvasMorph, value: showsPortrait)
    }

    private func applyCustom() {
        guard let value = customValue else { return }
        var updated = canvas
        updated.customAspectRatio = value
        updated.aspectRatio = .custom
        canvas = updated
        editingCustom = false
    }

    private func presetRow(_ preset: Preset) -> some View {
        let selected = isSelected(preset)
        let aspect = CGFloat(preset.width / preset.height)
        return Button {
            editingCustom = false
            var updated = canvas
            if preset.ratio == .custom {
                updated.customAspectRatio = .init(width: preset.width, height: preset.height)
            }
            updated.aspectRatio = preset.ratio
            canvas = updated
        } label: {
            HStack(spacing: 8) {
                RoundedRectangle(cornerRadius: 1.5).strokeBorder(lineWidth: 1.2)
                    .frame(width: aspect >= 1 ? 16 : 16 * aspect, height: aspect >= 1 ? 16 / aspect : 16)
                    .foregroundStyle(EditorTheme.secondaryText)
                    .frame(width: 18, height: 16)
                Text(preset.label)
                    .font(.appUI(size: 13, weight: selected ? .semibold : .regular).monospacedDigit())
                if let hint = preset.hint {
                    Text(appLocalized(hint))
                        .font(.appUI(size: 11.5))
                        .foregroundStyle(EditorTheme.tertiaryText)
                        .lineLimit(1)
                }
                Spacer(minLength: 8)
                EditorSymbol("checkmark", size: 12).opacity(selected ? 1 : 0)
            }
            .foregroundStyle(EditorTheme.primaryText)
            .padding(.horizontal, 8)
            .frame(height: 30)
            .contentShape(Rectangle())
        }
        .buttonStyle(EditorActionRowStyle(selected: selected))
        .appButtonKeyboardFocus(in: RoundedRectangle(cornerRadius: EditorInterfaceRadius.control, style: .continuous))
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func simpleRow(title: String, kind: AppLineIcon.Kind, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                AppLineIcon(kind: kind, size: 13)
                    .foregroundStyle(EditorTheme.secondaryText)
                    .frame(width: 18, height: 16)
                Text(appLocalized(title))
                    .font(.appUI(size: 13, weight: selected ? .semibold : .regular))
                Spacer(minLength: 8)
                EditorSymbol("checkmark", size: 12).opacity(selected ? 1 : 0)
            }
            .foregroundStyle(EditorTheme.primaryText)
            .padding(.horizontal, 8)
            .frame(height: 30)
            .contentShape(Rectangle())
        }
        .buttonStyle(EditorActionRowStyle(selected: selected))
        .appButtonKeyboardFocus(in: RoundedRectangle(cornerRadius: EditorInterfaceRadius.control, style: .continuous))
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func customRatioField(_ title: LocalizedStringKey, text: Binding<String>, field: CustomField) -> some View {
        TextField(title, text: text)
            .textFieldStyle(.plain)
            // The workspace's pale graphite tint makes selected white text
            // disappear in Dark Aqua. Text editing uses the system highlight.
            .tint(nil)
            .font(.appUI(size: 12, weight: .medium))
            .monospacedDigit()
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity, minHeight: EditorInterfaceHeight.compact)
            .background(EditorTheme.controlWell, in: RoundedRectangle(cornerRadius: EditorInterfaceRadius.control, style: .continuous))
            .focused($customField, equals: field)
            .appKeyboardFocus(in: RoundedRectangle(cornerRadius: EditorInterfaceRadius.compact, style: .continuous),
                              isFocused: customField == field)
            .accessibilityLabel(Text(title))
            .accessibilityIdentifier(field == .width ? "editor.canvas.custom.width" : "editor.canvas.custom.height")
    }

    /// Switches the list; a preset already in use flips to its partner
    /// (16:9 ↔ 9:16, 4:3 ↔ 3:4). 适应、1:1 and custom values stay.
    private func orientationButton(_ title: String, kind: AppLineIcon.Kind, isPortrait: Bool) -> some View {
        let on = showsPortrait == isPortrait
        return Button {
            guard !on else { return }
            withAnimation(SpringMotion.canvasMorph) { showsPortrait = isPortrait }
            let flipped: CanvasAspectRatio? = switch canvas.aspectRatio {
            case .landscape where isPortrait: .portrait
            case .portrait where !isPortrait: .landscape
            case .standard where isPortrait: .standardPortrait
            case .standardPortrait where !isPortrait: .standard
            case .cinema where isPortrait: .portrait
            case .cinemaPortrait where !isPortrait: .cinema
            default: nil
            }
            if let flipped {
                var updated = canvas
                updated.aspectRatio = flipped
                canvas = updated
            } else if canvas.aspectRatio == .custom, isSelectedFourFive, !isPortrait {
                var updated = canvas
                updated.aspectRatio = .standard
                canvas = updated
            }
        } label: {
            HStack(spacing: 6) {
                AppLineIcon(kind: kind, size: 13)
                Text(appLocalized(title))
            }
            .font(.appUI(size: 12.5, weight: .medium))
            .foregroundStyle(on ? EditorTheme.primaryText : EditorTheme.secondaryText)
            .frame(maxWidth: .infinity).frame(height: 26)
            .background {
                if on {
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(EditorTheme.segmentThumb)
                        .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(EditorTheme.hairline, lineWidth: 0.5))
                        .shadow(color: .black.opacity(0.08), radius: 1, y: 1)
                        .matchedGeometryEffect(id: "orientationThumb", in: orientationThumb)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .appButtonKeyboardFocus(in: RoundedRectangle(cornerRadius: 7, style: .continuous))
        .accessibilityAddTraits(on ? .isSelected : [])
    }

    private var isSelectedFourFive: Bool {
        abs(canvas.customAspectRatio.width / canvas.customAspectRatio.height - 0.8) < 0.001
    }

    private func number(_ value: Double) -> String {
        String(format: "%.3f", value).replacingOccurrences(of: "\\.?0+$", with: "", options: .regularExpression)
    }
}
