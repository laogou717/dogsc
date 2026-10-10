import SwiftUI

// MARK: - Slider

/// One drag/one undo command, with a thin track and a raised thumb. The
/// inspector pairs this control with a separate editable numeric readout.
struct EditorSlider: View {
    @Binding var value: Double
    let range: ClosedRange<Double>
    var title: String? = nil
    var formatValue: ((Double) -> String)? = nil
    var showsFloatingValue = true
    var scale: EditorSliderScale = .linear
    var onEditingChanged: (Bool) -> Void = { _ in }

    @Environment(\.isEnabled) private var isEnabled
    @State private var isDragging = false
    @State private var dragStartValue: Double?
    @State private var isFocused = false

    private var fraction: Double { scale.fraction(value, in: range) }

    var body: some View {
        HStack(spacing: 14) {
            if let title {
                Text(appLocalized(title)).font(.appUI(size: 13)).foregroundStyle(EditorTheme.chrome(0.8))
                    .frame(width: 90, alignment: .leading).lineLimit(2)
            }
            GeometryReader { proxy in
                let width = max(proxy.size.width, 20)
                let inset: CGFloat = 9
                let travel = max(width - inset * 2, 1)
                let center = inset + fraction * travel
                ZStack(alignment: .leading) {
                    Capsule().fill(EditorTheme.chrome(0.11)).frame(height: 4).padding(.horizontal, inset)
                    Capsule().fill(EditorTheme.platinumMuted.opacity(0.55))
                        .frame(width: fraction * travel, height: 4).offset(x: inset)
                    Circle().fill(EditorTheme.cardElevated)
                        .overlay { Circle().strokeBorder(EditorTheme.chrome(isFocused ? 0.35 : 0.10), lineWidth: 0.75) }
                        .shadow(color: EditorTheme.softShadow, radius: 3, y: 2)
                        .frame(width: 18, height: 18)
                        .scaleEffect(isDragging && !RecorderMotion.reduces ? 1.12 : 1)
                        .animation(RecorderMotion.quick, value: isDragging)
                        .offset(x: center - 9)
                }
                .frame(height: 32)
                .contentShape(Rectangle())
                .overlay(alignment: .topLeading) {
                    if showsFloatingValue && isDragging {
                        Text(formatValue?(value) ?? String(format: "%.0f", value))
                            .font(.appUI(size: 11)).monospacedDigit()
                            .foregroundStyle(EditorTheme.chrome(0.8)).padding(.horizontal, 8).padding(.vertical, 5)
                            .background(EditorTheme.cardElevated, in: RoundedRectangle(cornerRadius: 8))
                            .shadow(color: EditorTheme.softShadow, radius: 4, y: 2)
                            .offset(x: min(max(center - 25, 0), max(width - 50, 0)), y: -30)
                            .allowsHitTesting(false)
                    }
                }
                .gesture(DragGesture(minimumDistance: 0)
                    .onChanged { drag in
                        guard isEnabled else { return }
                        if !isDragging {
                            isDragging = true
                            if abs(drag.startLocation.x - center) <= 12 { dragStartValue = value }
                            onEditingChanged(true)
                        }
                        let proposed: Double
                        if let dragStartValue {
                            proposed = scale.fraction(dragStartValue, in: range) + Double(drag.translation.width / travel)
                        } else { proposed = Double((drag.location.x - inset) / travel) }
                        value = scale.value(proposed, in: range)
                    }
                    .onEnded { _ in
                        guard isDragging else { return }
                        isDragging = false; dragStartValue = nil; onEditingChanged(false)
                    })
            }.frame(height: 32)
        }
        .opacity(isEnabled ? 1 : 0.4)
        .background {
            EditorSliderKeyboardBridge(requestsFocus: isDragging, isEnabled: isEnabled,
                onFocusChange: { isFocused = $0 }, onStep: { direction, coarse in adjust(direction, coarse: coarse) })
                .allowsHitTesting(false).accessibilityHidden(true)
        }
        .appKeyboardFocusScrollTarget(isFocused: isFocused)
        .accessibilityElement()
        .accessibilityValue(formatValue?(value) ?? String(format: "%.0f", value))
        .accessibilityAdjustableAction { direction in
            guard isEnabled else { return }
            switch direction { case .increment: adjust(1); case .decrement: adjust(-1); @unknown default: break }
        }
        .onDisappear {
            if isDragging { isDragging = false; dragStartValue = nil; onEditingChanged(false) }
        }
    }

    private func adjust(_ direction: Double, coarse: Bool = false) {
        let step = 1.0 / (coarse ? 10 : 100)
        onEditingChanged(true)
        value = scale.value(fraction + direction * step, in: range)
        onEditingChanged(false)
    }

}

/// Optional direct-entry lifecycle for a parameter readout. Parsing belongs
/// to the semantic value format while this small configuration keeps the
/// visual control independent from any particular editor command domain.
struct EditorInspectorParameterEditConfiguration {
    let draftText: String
    let onBegin: () -> Void
    let onPreview: (String) -> Bool
    let onCommit: () -> Void
    let onCancel: () -> Void
}

/// A single visual header for inspector parameters. The value stays visible
/// before, during, and after a drag, while the active surface and numeric
/// transition make continuous edits readable without a second tooltip.
/// When an edit configuration is supplied, the readout itself becomes the
/// exact-value input instead of adding a second text field beside the slider.
struct EditorInspectorParameterReadout: View {
    @Environment(\.isEnabled) private var isEnabled

    let title: String
    let valueText: String
    var accessibilityTitle: String? = nil
    var isEditing = false
    var editConfiguration: EditorInspectorParameterEditConfiguration? = nil
    var showsTitle = true
    var isEmbedded = false
    var compact = false

    @State private var isValueHovered = false
    @State private var isTextEditing = false
    @State private var draftText = ""
    @State private var draftIsValid = true
    @State private var validationFailed = false
    @FocusState private var valueFieldFocused: Bool

    var body: some View {
        let isActive = isEditing || isTextEditing

        let readout = HStack(spacing: compact ? 6 : 10) {
            if showsTitle {
                Text(appLocalized(title))
                    .font(EditorTypography.controlLabel)
                    .foregroundStyle(
                        EditorTheme.chrome(
                            isEnabled ? (isActive ? 0.94 : 0.72) : 0.34
                        )
                    )
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityHidden(true)

                if !compact { Spacer(minLength: 8) }
            }

            if let editConfiguration {
                editableValue(editConfiguration, isActive: isActive)
            } else {
                valueLabel(isActive: isActive)
            }
        }

        // Only hide the read-only group. An explicit visible override on the
        // editable group can expose its decorative coordinate labels again.
        return Group {
            if editConfiguration == nil {
                readout.accessibilityHidden(true)
            } else {
                readout
            }
        }
        .animation(RecorderMotion.quick, value: isActive)
        .onDisappear {
            guard isTextEditing, let editConfiguration else { return }
            cancelTextEditing(editConfiguration)
        }
    }

    private var localizedInputTitle: String {
        appLocalized(accessibilityTitle ?? title)
    }

    private func valueLabel(isActive: Bool, showsValue: Bool = true) -> some View {
        Text(valueText)
            .font(EditorTypography.controlValue).monospacedDigit()
            .lineLimit(1)
            .minimumScaleFactor(0.8)
            .fixedSize(horizontal: false, vertical: true)
            .foregroundStyle(
                isActive
                    ? EditorTheme.platinumAccent
                    : EditorTheme.chrome(isEnabled ? 0.78 : 0.34)
            )
            .opacity(showsValue ? 1 : 0)
            .contentTransition(.numericText())
            .padding(.horizontal, 8)
            .frame(minWidth: 56, minHeight: 30, maxHeight: 30)
            .background(valueBackground(isActive: isActive))
            .overlay(valueBorder(isActive: isActive))
            .shadow(
                color: EditorTheme.platinumAccent.opacity(isActive && !isEmbedded ? 0.10 : 0),
                radius: 5
            )
    }

    @ViewBuilder
    private func editableValue(
        _ configuration: EditorInspectorParameterEditConfiguration,
        isActive: Bool
    ) -> some View {
        if isTextEditing {
            // The displayed value remains the layout anchor. An overlay cannot
            // introduce the native field's wider ideal size or move the capsule.
            valueLabel(isActive: true, showsValue: false)
                .overlay {
                    TextField("", text: $draftText)
                        .textFieldStyle(.plain)
                        .tint(nil)
                        .font(EditorTypography.controlValue).monospacedDigit()
                        .foregroundStyle(
                            validationFailed
                                ? Color.red.opacity(0.92)
                                : EditorTheme.platinumAccent
                        )
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 8)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .focused($valueFieldFocused)
                        .appKeyboardFocusScrollTarget(isFocused: valueFieldFocused)
                        .onSubmit { commitTextEditing(configuration) }
                        .onExitCommand { cancelTextEditing(configuration) }
                        .onChange(of: draftText) { _, newValue in
                            draftIsValid = configuration.onPreview(newValue)
                            validationFailed = false
                        }
                        .onChange(of: valueFieldFocused) { _, focused in
                            guard !focused, isTextEditing else { return }
                            if draftIsValid {
                                commitTextEditing(configuration)
                            } else {
                                cancelTextEditing(configuration)
                            }
                        }
                        .accessibilityLabel(String(format: appLocalized("输入%@"), localizedInputTitle))
                        .accessibilityValue(draftText)
                }
                .overlay {
                    if validationFailed {
                        Capsule(style: .continuous)
                            .stroke(Color.red.opacity(0.58), lineWidth: 1)
                            .allowsHitTesting(false)
                    }
                }
        } else {
            Button {
                beginTextEditing(configuration)
            } label: {
                valueLabel(isActive: isActive || isValueHovered)
            }
            .buttonStyle(.plain)
            .appButtonKeyboardFocus(in: Capsule(style: .continuous))
            .onHover { hovering in
                withAnimation(RecorderMotion.fade) {
                    isValueHovered = hovering
                }
            }
            .help(String(format: appLocalized("点击输入%@"), localizedInputTitle))
            .accessibilityLabel(String(format: appLocalized("编辑%@"), localizedInputTitle))
            .accessibilityValue(valueText)
            .disabled(!isEnabled)
        }
    }

    private func valueBackground(isActive: Bool) -> some View {
        Capsule(style: .continuous)
            .fill(
                isEmbedded ? Color.clear : isActive
                    ? EditorTheme.platinumAccent.opacity(0.13)
                    : EditorTheme.chrome(0.045)
            )
    }

    private func valueBorder(isActive: Bool) -> some View {
        Capsule(style: .continuous)
            .stroke(
                isActive
                    ? EditorTheme.platinumAccent.opacity(0.34)
                    : Color.clear,
                lineWidth: isEmbedded ? 0 : 0.75
            )
    }

    private func beginTextEditing(_ configuration: EditorInspectorParameterEditConfiguration) {
        draftText = configuration.draftText
        draftIsValid = true
        validationFailed = false
        isTextEditing = true
        configuration.onBegin()
        DispatchQueue.main.async {
            valueFieldFocused = true
        }
    }

    private func commitTextEditing(_ configuration: EditorInspectorParameterEditConfiguration) {
        guard isTextEditing else { return }
        guard draftIsValid else {
            validationFailed = true
            valueFieldFocused = true
            return
        }
        isTextEditing = false
        valueFieldFocused = false
        configuration.onCommit()
    }

    private func cancelTextEditing(_ configuration: EditorInspectorParameterEditConfiguration) {
        guard isTextEditing else { return }
        isTextEditing = false
        valueFieldFocused = false
        validationFailed = false
        configuration.onCancel()
    }
}

/// Two related scalar values presented as one compact row. Spatial controls
/// use this for X/Y coordinates and X/Y tilt so exact entry, validation,
/// preview, commit and cancellation stay identical without duplicating focus
/// state in every graphical pad.
struct EditorPairedParameterValue {
    let title: String
    let accessibilityTitle: String
    let value: Double
    let range: ClosedRange<Double>
    let displayText: String
    let inputFormat: EditorSliderValueFormat
}

struct EditorPairedParameterReadouts: View {
    private enum Slot: Hashable {
        case first
        case second
    }

    let first: EditorPairedParameterValue
    let second: EditorPairedParameterValue
    let onChanged: (Double, Double) -> Void
    let onEnded: () -> Void
    let onCancelled: () -> Void
    var onEditingChanged: (Bool) -> Void = { _ in }
    var onTextPreviewValidityChanged: (Bool) -> Void = { _ in }

    var vertical = false

    @State private var activeSlot: Slot?
    @State private var hasPreview = false

    var body: some View {
        let layout = vertical ? AnyLayout(VStackLayout(spacing: 14)) : AnyLayout(HStackLayout(spacing: 10))
        return layout {
            readout(first, slot: .first)
            readout(second, slot: .second)
        }
    }

    private func readout(
        _ parameter: EditorPairedParameterValue,
        slot: Slot
    ) -> some View {
        EditorInspectorParameterReadout(
            title: parameter.title,
            valueText: parameter.displayText,
            accessibilityTitle: parameter.accessibilityTitle,
            isEditing: activeSlot == slot,
            editConfiguration: EditorInspectorParameterEditConfiguration(
                draftText: parameter.inputFormat.editingText(for: parameter.value),
                onBegin: { begin(slot) },
                onPreview: { preview($0, slot: slot) },
                onCommit: { finish(slot, commits: true) },
                onCancel: { finish(slot, commits: false) }
            ),
            compact: true
        )
        .frame(maxWidth: .infinity)
    }

    private func begin(_ slot: Slot) {
        activeSlot = slot
        hasPreview = false
        onEditingChanged(true)
    }

    private func preview(_ text: String, slot: Slot) -> Bool {
        let parameter = slot == .first ? first : second
        guard let parsed = parameter.inputFormat.value(from: text) else {
            onTextPreviewValidityChanged(false)
            return false
        }
        onTextPreviewValidityChanged(true)
        let clamped = min(max(parsed, parameter.range.lowerBound), parameter.range.upperBound)
        hasPreview = true
        switch slot {
        case .first:
            onChanged(clamped, second.value)
        case .second:
            onChanged(first.value, clamped)
        }
        return true
    }

    private func finish(_ slot: Slot, commits: Bool) {
        guard activeSlot == slot else { return }
        activeSlot = nil
        onEditingChanged(false)
        if hasPreview {
            commits ? onEnded() : onCancelled()
        }
        hasPreview = false
    }
}

// MARK: - Toggle

/// 编辑器与设置共享语义：绿色表示开启，白色滑块跟随状态。
struct EditorToggle: View {
    @FocusState private var hasFocus: Bool
    @Binding var isOn: Bool
    var title: String? = nil

    @ViewBuilder
    var body: some View {
        if let title {
            Button {
                withAnimation(RecorderMotion.quick) {
                    isOn.toggle()
                }
            } label: {
                Text(appLocalized(title))
                    .font(EditorTypography.controlLabel)
                    .foregroundStyle(EditorTheme.primaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .buttonStyle(EditorToggleButtonStyle(isOn: isOn, showsTitle: true, isFocused: hasFocus))
            .focused($hasFocus)
            .accessibilityLabel(appLocalized(title))
            .accessibilityValue(appLocalized(isOn ? "开关状态 · 开启" : "开关状态 · 关闭"))
            .accessibilityAddTraits(.isToggle)
        } else {
            Button {
                withAnimation(RecorderMotion.quick) {
                    isOn.toggle()
                }
            } label: {
                EmptyView()
            }
            .buttonStyle(EditorToggleButtonStyle(isOn: isOn, showsTitle: false, isFocused: hasFocus))
            .focused($hasFocus)
            .accessibilityAddTraits(.isToggle)
            .accessibilityValue(appLocalized(isOn ? "开关状态 · 开启" : "开关状态 · 关闭"))
        }
    }
}

/// The row owns activation, but only the capsule owns visual feedback.
/// Do not reuse toolbar press styling here: it transforms the entire label.
private struct EditorToggleButtonStyle: ButtonStyle {
    let isOn: Bool
    let showsTitle: Bool
    let isFocused: Bool

    func makeBody(configuration: Configuration) -> some View {
        Surface(configuration: configuration, isOn: isOn, showsTitle: showsTitle, isFocused: isFocused)
    }

    private struct Surface: View {
        @Environment(\.isEnabled) private var isEnabled
        @State private var isHovered = false
        let configuration: Configuration
        let isOn: Bool
        let showsTitle: Bool
        let isFocused: Bool

        private var isPressed: Bool { isEnabled && configuration.isPressed }
        private var showsHover: Bool { isEnabled && isHovered }

        var body: some View {
            HStack {
                if showsTitle {
                    configuration.label
                    Spacer(minLength: 8)
                }
                toggleIndicator
            }
            .contentShape(RoundedRectangle(cornerRadius: showsTitle ? 0 : 11, style: .continuous))
            .opacity(isEnabled ? 1 : 0.48)
            .onHover { isHovered = $0 }
        }

        private var toggleIndicator: some View {
            ZStack(alignment: isOn ? .trailing : .leading) {
                Capsule(style: .continuous)
                    .fill(isOn ? EditorTheme.success : EditorTheme.chrome(showsHover ? 0.18 : 0.12))
                Circle()
                    .fill(.white)
                    .shadow(color: .black.opacity(0.16), radius: 2, y: 1)
                    .padding(2)
            }
            .frame(width: 40, height: 22)
            .overlay {
                Capsule().fill(.black.opacity(isPressed ? 0.10 : 0)).allowsHitTesting(false)
            }
            .appKeyboardFocus(in: Capsule(), color: EditorTheme.chrome(0.40), isFocused: isFocused)
            .scaleEffect(isPressed && !RecorderMotion.reduces ? 0.97 : 1)
            .animation(RecorderMotion.settle, value: isOn)
            .animation(RecorderMotion.fade, value: showsHover)
            .animation(RecorderMotion.quick, value: isPressed)
        }
    }
}

// MARK: - Numeric step control

struct EditorNumericStepEditConfiguration {
    let draftText: String
    var onBegin: () -> Void = {}
    let onPreview: (String) -> Bool
    var onCommit: () -> Void = {}
    /// Receives the exact draft text captured when editing began, so a local
    /// draft can restore only this value without cancelling its parent tool.
    let onCancel: (String) -> Void
}

/// Compact precision control used where dragging a timeline or canvas handle
/// is the primary interaction but exact increments still matter. It keeps the
/// current value visible, gives both directions a stable pointer target and
/// supports optional press-and-hold repetition plus a single adjustable AX
/// element. Persistent document values can keep repetition disabled when a
/// direct-entry surface is the safer fast path.
struct EditorNumericStepControl: View {
    let title: String
    let valueText: String
    let accessibilityTitle: String
    let canDecrease: Bool
    let canIncrease: Bool
    let onDecrease: () -> Void
    let onIncrease: () -> Void
    let editConfiguration: EditorNumericStepEditConfiguration?
    let repeatsSteps: Bool

    @Environment(\.isEnabled) private var isEnabled
    @State private var isHovered = false
    @State private var isDirectEditing = false
    @State private var directEditOriginText: String?

    init(
        _ title: String,
        valueText: String,
        accessibilityTitle: String? = nil,
        canDecrease: Bool,
        canIncrease: Bool,
        onDecrease: @escaping () -> Void,
        onIncrease: @escaping () -> Void,
        editConfiguration: EditorNumericStepEditConfiguration? = nil,
        repeatsSteps: Bool = true
    ) {
        self.title = title
        self.valueText = valueText
        self.accessibilityTitle = accessibilityTitle ?? title
        self.canDecrease = canDecrease
        self.canIncrease = canIncrease
        self.onDecrease = onDecrease
        self.onIncrease = onIncrease
        self.editConfiguration = editConfiguration
        self.repeatsSteps = repeatsSteps
    }

    var body: some View {
        HStack(spacing: 4) {
            Text(appLocalized(title))
                .font(.appUI(.caption, weight: .medium))
                .foregroundStyle(Color.primary.opacity(0.88))
                .lineLimit(1)

            Spacer(minLength: 0)

            numericValue

            HStack(spacing: 3) {
                stepButton(
                    systemImage: "minus",
                    help: String(format: appLocalized("减少%@"), appLocalized(title)),
                    isAvailable: canDecrease && !isDirectEditing,
                    action: onDecrease
                )
                stepButton(
                    systemImage: "plus",
                    help: String(format: appLocalized("增加%@"), appLocalized(title)),
                    isAvailable: canIncrease && !isDirectEditing,
                    action: onIncrease
                )
            }
        }
        .padding(.leading, 6)
        .padding(.trailing, 2)
        .frame(height: 36)
        .background(
            EditorTheme.chrome(isHovered && isEnabled ? 0.060 : 0.035),
            in: RoundedRectangle(cornerRadius: 8, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(
                    EditorTheme.chrome(isHovered && isEnabled ? 0.12 : 0.065),
                    lineWidth: 0.75
                )
        }
        .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .opacity(isEnabled ? 1 : 0.55)
        .onHover { hovering in
            withAnimation(RecorderMotion.quick) {
                isHovered = hovering
            }
        }
        .accessibilityElement(children: editConfiguration == nil ? .ignore : .contain)
        .accessibilityLabel(appLocalized(accessibilityTitle))
        .accessibilityValue(valueText)
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment where canIncrease:
                onIncrease()
            case .decrement where canDecrease:
                onDecrease()
            default:
                break
            }
        }
    }

    @ViewBuilder
    private var numericValue: some View {
        if let editConfiguration {
            EditorInspectorParameterReadout(
                title: accessibilityTitle,
                valueText: valueText,
                isEditing: isDirectEditing,
                editConfiguration: EditorInspectorParameterEditConfiguration(
                    draftText: editConfiguration.draftText,
                    onBegin: {
                        directEditOriginText = editConfiguration.draftText
                        isDirectEditing = true
                        editConfiguration.onBegin()
                    },
                    onPreview: editConfiguration.onPreview,
                    onCommit: {
                        isDirectEditing = false
                        directEditOriginText = nil
                        editConfiguration.onCommit()
                    },
                    onCancel: {
                        let origin = directEditOriginText
                            ?? editConfiguration.draftText
                        isDirectEditing = false
                        directEditOriginText = nil
                        editConfiguration.onCancel(origin)
                    }
                ),
                showsTitle: false
            )
            .frame(width: 58)
        } else {
            Text(valueText)
                .font(.appUI(size: 10.5, weight: .semibold, design: .monospaced))
                .foregroundStyle(Color.primary.opacity(0.82))
                .lineLimit(1)
                .minimumScaleFactor(0.75)
                .frame(width: 40, alignment: .trailing)
                .padding(.horizontal, 4)
                .frame(height: 24)
                .background(
                    EditorTheme.chrome(isHovered && isEnabled ? 0.09 : 0.045),
                    in: RoundedRectangle(cornerRadius: 6, style: .continuous)
                )
        }
    }

    private func stepButton(
        systemImage: String,
        help: String,
        isAvailable: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.appUI(size: 10, weight: .bold))
        }
        .buttonStyle(EditorStepButtonStyle())
        .buttonRepeatBehavior(repeatsSteps ? .enabled : .disabled)
        .disabled(!isAvailable)
        .help(help)
        .accessibilityHidden(true)
    }
}

private struct EditorStepButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> Body {
        Body(configuration: configuration)
    }

    struct Body: View {
        @Environment(\.isEnabled) private var isEnabled
        @State private var isHovered = false
        let configuration: Configuration

        var body: some View {
            configuration.label
                .foregroundStyle(
                    isEnabled
                        ? Color.primary.opacity(isHovered ? 1 : 0.82)
                        : Color.secondary.opacity(0.45)
                )
                .frame(width: 28, height: 28)
                .background(
                    EditorTheme.chrome(
                        !isEnabled ? 0.018
                            : configuration.isPressed ? 0.14
                            : isHovered ? 0.09 : 0.045
                    ),
                    in: RoundedRectangle(cornerRadius: 7, style: .continuous)
                )
                .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                .appKeyboardFocus(in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                .scaleEffect(configuration.isPressed && isEnabled && !RecorderMotion.reduces ? 0.90 : 1)
                .onHover { hovering in
                    withAnimation(RecorderMotion.fade) {
                        isHovered = hovering
                    }
                }
                .animation(RecorderMotion.quick, value: configuration.isPressed)
        }
    }
}

// MARK: - Button Styles

/// 次级动作与录制条同源：实心中性胶囊，悬停提亮，按压轻收。
struct EditorQuietButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> Body {
        Body(configuration: configuration)
    }

    struct Body: View {
        @Environment(\.isEnabled) private var isEnabled
        @State private var isHovered = false
        let configuration: Configuration

        var body: some View {
            configuration.label
                .font(.appUI(size: 13, weight: .medium))
                .foregroundStyle(
                    isEnabled
                        ? EditorTheme.primaryText
                        : Color.secondary
                )
                .padding(.horizontal, 10)
                .frame(minHeight: EditorInterfaceHeight.compact)
                .background(
                    Capsule(style: .continuous)
                        .fill(
                            EditorTheme.chrome(
                                !isEnabled ? 0.02
                                    : configuration.isPressed ? 0.16
                                    : isHovered ? 0.11 : 0.065
                            )
                        )
                )
                .contentShape(Capsule(style: .continuous))
                .appKeyboardFocus(in: Capsule(style: .continuous))
                .scaleEffect(configuration.isPressed && isEnabled && !RecorderMotion.reduces ? 0.96 : 1.0)
                .opacity(isEnabled ? 1 : 0.46)
                .onHover { isHovered = $0 }
                .animation(RecorderMotion.fade, value: isHovered)
                .animation(RecorderMotion.quick, value: configuration.isPressed)
        }
    }
}

/// 主动作使用主题中的石墨色，与次级动作保持相同的边缘与按压节奏。
struct EditorPrimaryButtonStyle: ButtonStyle {
    var minHeight: CGFloat = EditorInterfaceHeight.selection

    func makeBody(configuration: Configuration) -> Body {
        Body(configuration: configuration, minHeight: minHeight)
    }

    struct Body: View {
        @Environment(\.isEnabled) private var isEnabled
        @State private var isHovered = false
        let configuration: Configuration
        let minHeight: CGFloat

        var body: some View {
            configuration.label
                .font(.appUI(.callout, weight: .semibold))
                .foregroundStyle(EditorTheme.onAccent)
                .padding(.horizontal, 13)
                .frame(minHeight: minHeight)
                .background(
                    Capsule(style: .continuous)
                        .fill(EditorTheme.platinumAccent)
                )
                .overlay(
                    Capsule(style: .continuous)
                        .fill(EditorTheme.onAccent.opacity(
                            !isEnabled ? 0 : configuration.isPressed ? 0.16 : isHovered ? 0.08 : 0
                        ))
                        .allowsHitTesting(false)
                )
                .shadow(color: EditorTheme.softShadow.opacity(0.4), radius: 3, y: 1)
                .contentShape(Capsule(style: .continuous))
                .appKeyboardFocus(in: Capsule(style: .continuous), color: EditorTheme.onAccent.opacity(0.65))
                .scaleEffect(configuration.isPressed && isEnabled && !RecorderMotion.reduces ? 0.96 : 1.0)
                .opacity(isEnabled ? 1 : 0.4)
                .onHover { isHovered = $0 }
                .animation(RecorderMotion.fade, value: isHovered)
                .animation(RecorderMotion.quick, value: configuration.isPressed)
        }
    }
}

/// 低优先级按钮：默认透明，只在悬停或按压时出现表面。
struct EditorGhostButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> Body {
        Body(configuration: configuration)
    }

    struct Body: View {
        @Environment(\.isEnabled) private var isEnabled
        @State private var isHovered = false
        let configuration: Configuration

        var body: some View {
            configuration.label
                .font(.appUI(.caption, weight: .medium))
                .foregroundStyle(
                    isEnabled ? Color.primary.opacity(isHovered ? 1.0 : 0.85) : Color.secondary
                )
                .padding(.horizontal, 8)
                .frame(minHeight: EditorInterfaceHeight.compact)
                .background(
                    RoundedRectangle(cornerRadius: EditorInterfaceRadius.compact, style: .continuous)
                        .fill(
                            EditorTheme.chrome(
                                configuration.isPressed ? 0.11
                                    : isHovered && isEnabled ? 0.07 : 0
                            )
                        )
                )
                .contentShape(RoundedRectangle(cornerRadius: EditorInterfaceRadius.compact, style: .continuous))
                .appKeyboardFocus(in: RoundedRectangle(cornerRadius: EditorInterfaceRadius.compact, style: .continuous))
                .scaleEffect(configuration.isPressed && isEnabled && !RecorderMotion.reduces ? 0.97 : 1.0)
                .opacity(isEnabled ? 1 : 0.44)
                .onHover { isHovered = $0 }
                .animation(RecorderMotion.fade, value: isHovered)
                .animation(RecorderMotion.quick, value: configuration.isPressed)
        }
    }
}

/// Shared hover and press feedback; the overlay never intercepts clicks.
struct EditorToolbarPressButtonStyle: ButtonStyle {
    var cornerRadius: CGFloat = 9
    var cornerStyle: RoundedCornerStyle = .continuous
    var showsHover: Bool = true
    func makeBody(configuration: Configuration) -> Body {
        Body(configuration: configuration, cornerRadius: cornerRadius,
             cornerStyle: cornerStyle, showsHover: showsHover)
    }
    struct Body: View {
        @Environment(\.isEnabled) private var isEnabled
        @State private var hovered = false
        let configuration: Configuration
        let cornerRadius: CGFloat
        let cornerStyle: RoundedCornerStyle
        let showsHover: Bool
        var body: some View {
            configuration.label
                .contentShape(RoundedRectangle(cornerRadius: cornerRadius, style: cornerStyle))
                .appKeyboardFocus(in: RoundedRectangle(cornerRadius: cornerRadius, style: cornerStyle))
                .overlay {
                    RoundedRectangle(cornerRadius: cornerRadius, style: cornerStyle)
                        .fill(EditorTheme.chrome(isEnabled ? (configuration.isPressed ? 0.12 : hovered && showsHover ? 0.065 : 0) : 0))
                        .allowsHitTesting(false)
                }
                .scaleEffect(configuration.isPressed && isEnabled && !RecorderMotion.reduces ? 0.97 : 1)
                .opacity(isEnabled ? 1 : 0.48)
                .onHover { hovered = $0 }
                .animation(RecorderMotion.fade, value: hovered)
                .animation(RecorderMotion.quick, value: configuration.isPressed)
        }
    }
}

/// Icon-only dismiss controls use one neutral surface across sheets, banners
/// and lightweight reference panels. The style deliberately stays separate
/// from cancellation and destructive actions: it only removes the visible UI.
struct EditorDismissIconButtonStyle: ButtonStyle {
    var size: CGFloat = 30

    func makeBody(configuration: Configuration) -> Body {
        Body(configuration: configuration, size: size)
    }

    struct Body: View {
        @Environment(\.isEnabled) private var isEnabled
        @State private var isHovered = false
        let configuration: Configuration
        let size: CGFloat

        var body: some View {
            configuration.label
                .foregroundStyle(
                    isEnabled
                        ? Color.primary.opacity(isHovered ? 0.96 : 0.68)
                        : Color.secondary.opacity(0.38)
                )
                .frame(width: size, height: size)
                .background(
                    Circle()
                        .fill(
                            EditorTheme.chrome(
                                !isEnabled ? 0.02
                                    : configuration.isPressed ? 0.14
                                    : isHovered ? 0.10 : 0.05
                            )
                        )
                )
                .contentShape(Circle())
                .appKeyboardFocus(in: Circle())
                .scaleEffect(
                    !isEnabled || RecorderMotion.reduces ? 1
                        : configuration.isPressed ? 0.88
                        : 1
                )
                .onHover { hovering in
                    withAnimation(RecorderMotion.fade) {
                        isHovered = hovering
                    }
                }
                .animation(RecorderMotion.quick, value: configuration.isPressed)
        }
    }
}

/// Warning actions remain compact in editor chrome but must read as real
/// controls instead of coloured status text. This is intentionally not the
/// destructive style: activating it reveals recovery detail and changes no data.
struct EditorWarningButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> Body {
        Body(configuration: configuration)
    }

    struct Body: View {
        @Environment(\.isEnabled) private var isEnabled
        @State private var isHovered = false
        let configuration: Configuration

        var body: some View {
            configuration.label
                .font(.appUI(.caption, weight: .semibold))
                .foregroundStyle(
                    EditorTheme.amberAccent.opacity(
                        !isEnabled ? 0.38 : isHovered ? 1 : 0.88
                    )
                )
                .padding(.horizontal, 8)
                .frame(minHeight: 28)
                .background {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(
                            EditorTheme.amberAccent.opacity(
                                configuration.isPressed ? 0.18
                                    : isHovered && isEnabled ? 0.11 : 0.055
                            )
                        )
                }
                .overlay {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(
                            EditorTheme.amberAccent.opacity(
                                isHovered && isEnabled ? 0.34 : 0.16
                            ),
                            lineWidth: 0.75
                        )
                }
                .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .appKeyboardFocus(in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .scaleEffect(
                    !isEnabled ? 1
                        : configuration.isPressed ? 0.95
                        : isHovered ? 1.02 : 1
                )
                .onHover { hovering in
                    withAnimation(RecorderMotion.fade) {
                        isHovered = hovering
                    }
                }
                .animation(RecorderMotion.quick, value: configuration.isPressed)
        }
    }
}

/// Timeline junction controls already draw their own compact identity. This
/// style adds tactile hover/press feedback without adding another visible card
/// or changing the existing 28pt hit target.
struct EditorInlineActionButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> Body {
        Body(configuration: configuration)
    }

    struct Body: View {
        @Environment(\.isEnabled) private var isEnabled
        @State private var isHovered = false
        let configuration: Configuration

        var body: some View {
            configuration.label
                .brightness(isHovered && isEnabled ? 0.08 : 0)
                .shadow(
                    color: EditorTheme.softShadow.opacity(isHovered && isEnabled ? 1 : 0),
                    radius: 4,
                    y: 2
                )
                .scaleEffect(
                    !isEnabled ? 1
                        : configuration.isPressed ? 0.88
                        : isHovered ? 1.08 : 1
                )
                .onHover { hovering in
                    withAnimation(RecorderMotion.fade) {
                        isHovered = hovering
                    }
                }
                .animation(RecorderMotion.quick, value: configuration.isPressed)
        }
    }
}

/// Destructive inspector actions stay visually quiet until the pointer is
/// nearby, but keep a full-height target instead of falling back to tiny
/// borderless macOS text.
struct EditorDestructiveButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> Body {
        Body(configuration: configuration)
    }

    struct Body: View {
        @Environment(\.isEnabled) private var isEnabled
        @State private var isHovered = false
        let configuration: Configuration

        var body: some View {
            configuration.label
                .font(.appUI(.caption, weight: .medium))
                .foregroundStyle(
                    Color.red.opacity(
                        !isEnabled ? 0.35
                            : isHovered ? 0.96 : 0.78
                    )
                )
                .padding(.horizontal, 9)
                .frame(maxWidth: .infinity, minHeight: 30, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(
                            Color.red.opacity(
                                configuration.isPressed ? 0.16
                                    : isHovered && isEnabled ? 0.09 : 0
                            )
                        )
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .stroke(
                            Color.red.opacity(isHovered && isEnabled ? 0.20 : 0),
                            lineWidth: 0.75
                        )
                )
                .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                .appKeyboardFocus(in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                .scaleEffect(configuration.isPressed && isEnabled && !RecorderMotion.reduces ? 0.985 : 1)
                .onHover { hovering in
                    withAnimation(RecorderMotion.fade) {
                        isHovered = hovering
                    }
                }
                .animation(RecorderMotion.quick, value: configuration.isPressed)
        }
    }
}

/// Compact destructive icons used inside inspector rows. The glyph remains
/// small, while the pointer target and hover surface match nearby controls.
struct EditorDestructiveIconButtonStyle: ButtonStyle {
    var size: CGFloat = 28

    func makeBody(configuration: Configuration) -> Body {
        Body(configuration: configuration, size: size)
    }

    struct Body: View {
        @Environment(\.isEnabled) private var isEnabled
        @State private var isHovered = false
        let configuration: Configuration
        let size: CGFloat

        var body: some View {
            configuration.label
                .font(.appUI(size: 11, weight: .semibold))
                .foregroundStyle(
                    Color.red.opacity(
                        !isEnabled ? 0.32
                            : isHovered ? 0.98 : 0.76
                    )
                )
                .frame(width: size, height: size)
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(
                            Color.red.opacity(
                                configuration.isPressed ? 0.16
                                    : isHovered && isEnabled ? 0.10 : 0
                            )
                        )
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .stroke(
                            Color.red.opacity(isHovered && isEnabled ? 0.22 : 0),
                            lineWidth: 0.75
                        )
                )
                .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                .appKeyboardFocus(in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                .scaleEffect(configuration.isPressed && isEnabled && !RecorderMotion.reduces ? 0.93 : 1)
                .onHover { hovering in
                    withAnimation(RecorderMotion.fade) {
                        isHovered = hovering
                    }
                }
                .animation(RecorderMotion.quick, value: configuration.isPressed)
        }
    }
}

/// Visual preset cards lift on hover and settle under the pointer on press.
/// The card itself continues to own its selected border and preview artwork.
struct EditorThumbnailButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> Body {
        Body(configuration: configuration)
    }

    struct Body: View {
        @Environment(\.isEnabled) private var isEnabled
        @State private var isHovered = false
        let configuration: Configuration

        var body: some View {
            configuration.label
                .scaleEffect(
                    !isEnabled ? 1
                        : configuration.isPressed ? 0.975
                        : 1
                )
                .brightness(isHovered && isEnabled ? 0.025 : 0)
                .shadow(
                    color: EditorTheme.softShadow.opacity(isHovered && isEnabled ? 0.5 : 0),
                    radius: isHovered && isEnabled ? 8 : 2,
                    y: isHovered && isEnabled ? 4 : 1
                )
                .contentShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                .appKeyboardFocus(in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                .opacity(isEnabled ? 1 : 0.44)
                .onHover { hovering in
                    withAnimation(RecorderMotion.fade) {
                        isHovered = hovering
                    }
                }
                .animation(RecorderMotion.quick, value: configuration.isPressed)
        }
    }
}

/// Small colour and material swatches get a crisp hover lift without gaining
/// another card surface around their own shape.
struct EditorSwatchButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> Body {
        Body(configuration: configuration)
    }

    struct Body: View {
        @Environment(\.isEnabled) private var isEnabled
        @State private var isHovered = false
        let configuration: Configuration

        var body: some View {
            configuration.label
                .scaleEffect(
                    !isEnabled ? 1
                        : configuration.isPressed ? 0.90
                        : isHovered ? 1.12 : 1
                )
                .shadow(
                    color: Color.black.opacity(isHovered && isEnabled ? 0.09 : 0),
                    radius: 4,
                    y: 2
                )
                .contentShape(Rectangle())
                .opacity(isEnabled ? 1 : 0.44)
                .onHover { hovering in
                    withAnimation(RecorderMotion.fade) {
                        isHovered = hovering
                    }
                }
                .animation(RecorderMotion.quick, value: configuration.isPressed)
        }
    }
}

extension ButtonStyle where Self == EditorQuietButtonStyle {
    static var editorQuiet: EditorQuietButtonStyle { EditorQuietButtonStyle() }
}

extension ButtonStyle where Self == EditorPrimaryButtonStyle {
    static var editorPrimary: EditorPrimaryButtonStyle { EditorPrimaryButtonStyle() }
    static func editorPrimary(minHeight: CGFloat) -> EditorPrimaryButtonStyle {
        EditorPrimaryButtonStyle(minHeight: minHeight)
    }
}

extension ButtonStyle where Self == EditorGhostButtonStyle {
    static var editorGhost: EditorGhostButtonStyle { EditorGhostButtonStyle() }
}

extension ButtonStyle where Self == EditorToolbarPressButtonStyle {
    static var editorToolbarPress: EditorToolbarPressButtonStyle {
        EditorToolbarPressButtonStyle()
    }
}

extension ButtonStyle where Self == EditorDismissIconButtonStyle {
    static var editorDismissIcon: EditorDismissIconButtonStyle {
        EditorDismissIconButtonStyle()
    }

    static func editorDismissIcon(size: CGFloat) -> EditorDismissIconButtonStyle {
        EditorDismissIconButtonStyle(size: size)
    }
}

extension ButtonStyle where Self == EditorWarningButtonStyle {
    static var editorWarning: EditorWarningButtonStyle {
        EditorWarningButtonStyle()
    }
}

extension ButtonStyle where Self == EditorInlineActionButtonStyle {
    static var editorInlineAction: EditorInlineActionButtonStyle {
        EditorInlineActionButtonStyle()
    }
}

extension ButtonStyle where Self == EditorDestructiveButtonStyle {
    static var editorDestructive: EditorDestructiveButtonStyle {
        EditorDestructiveButtonStyle()
    }
}

extension ButtonStyle where Self == EditorDestructiveIconButtonStyle {
    static var editorDestructiveIcon: EditorDestructiveIconButtonStyle {
        EditorDestructiveIconButtonStyle()
    }
}

extension ButtonStyle where Self == EditorThumbnailButtonStyle {
    static var editorThumbnail: EditorThumbnailButtonStyle { EditorThumbnailButtonStyle() }
}

extension ButtonStyle where Self == EditorSwatchButtonStyle {
    static var editorSwatch: EditorSwatchButtonStyle { EditorSwatchButtonStyle() }
}

// MARK: - Camera layout preset tile

/// 布局预设卡片按钮：图标 + 标题的大块可点面，悬停时底与描边同步提亮并微浮起。
struct EditorCameraLayoutPresetButton: View {
    let title: String
    let icon: String
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            VStack(spacing: 5) {
                Image(systemName: icon)
                    .font(.appUI(size: 15, weight: .medium))
                Text(appLocalized(title))
                    .font(.appUI(size: 10, weight: .medium))
            }
            .foregroundStyle(Color.primary.opacity(isHovered ? 1 : 0.82))
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(EditorTheme.chrome(isHovered ? 0.10 : 0.05))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .stroke(
                        LinearGradient(
                            colors: [
                                EditorTheme.chrome(isHovered ? 0.20 : 0.09),
                                EditorTheme.chrome(isHovered ? 0.10 : 0.04)
                            ],
                            startPoint: .top,
                            endPoint: .bottom
                        ),
                        lineWidth: 0.75
                    )
            )
            .contentShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        }
        .buttonStyle(.editorToolbarPress)
        .appButtonKeyboardFocus(in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        .onHover { isHovered = $0 }
        .animation(RecorderMotion.fade, value: isHovered)
    }
}

// MARK: - Disclosure (平滑展开折叠卡片)

/// 卡片式折叠组：标题行 + 弹簧旋转箭头，展开时内容平滑淡入。
struct EditorDisclosure<Content: View>: View {
    @Environment(\.isEnabled) private var isEnabled
    let title: String
    let detail: String?
    let icon: String?
    let iconTint: Color?
    let accessibilityHint: String?
    private let externalExpansion: Binding<Bool>?
    @State private var localExpanded = false
    @State private var isHovered = false
    let content: Content

    init(
        _ title: String,
        detail: String? = nil,
        icon: String? = nil,
        iconTint: Color? = nil,
        expanded externalExpansion: Binding<Bool>? = nil,
        accessibilityHint: String? = nil,
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.detail = detail
        self.icon = icon
        self.iconTint = iconTint
        self.externalExpansion = externalExpansion
        self.accessibilityHint = accessibilityHint
        self.content = content()
    }

    private var expansion: Binding<Bool> {
        externalExpansion ?? $localExpanded
    }

    var body: some View {
        let isExpanded = expansion.wrappedValue
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(RecorderMotion.settle) {
                    expansion.wrappedValue.toggle()
                }
            } label: {
                HStack(spacing: 8) {
                    if let icon {
                        Image(systemName: icon)
                            .font(.appUI(size: 12, weight: .semibold))
                            .foregroundStyle(
                                iconTint ?? EditorTheme.chrome(0.65)
                            )
                            .frame(width: 26, height: 26)
                            .background(
                                (iconTint ?? EditorTheme.platinumAccent).opacity(
                                    isExpanded ? 0.10 : 0.06
                                ),
                                in: RoundedRectangle(cornerRadius: EditorInterfaceRadius.compact, style: .continuous)
                            )
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        Text(appLocalized(title))
                            .font(EditorTypography.controlLabel)
                            .foregroundStyle(
                                Color.primary.opacity(isExpanded ? 0.96 : 0.82)
                            )
                            .lineLimit(2)
                            .fixedSize(horizontal: false, vertical: true)
                        if let detail {
                            Text(appLocalized(detail))
                                .font(EditorTypography.caption).monospacedDigit()
                                .foregroundStyle(EditorTheme.secondaryText)
                                .lineLimit(2)
                                .fixedSize(horizontal: false, vertical: true)
                                .contentTransition(.numericText())
                        }
                    }
                    Spacer(minLength: 4)
                    AppLineIcon(kind: .chevron, size: 12)
                        .foregroundStyle(
                            EditorTheme.chrome(isExpanded ? 0.86 : 0.46)
                        )
                        .frame(width: 24, height: 24)
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                        .animation(RecorderMotion.settle, value: isExpanded)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .frame(minHeight: detail == nil ? 36 : 48)
                .background(
                    RoundedRectangle(cornerRadius: EditorInterfaceRadius.control, style: .continuous)
                        .fill(
                            EditorTheme.chrome(
                                !isEnabled ? 0
                                    : isHovered ? 0.045 : 0
                            )
                        )
                )
                .contentShape(RoundedRectangle(cornerRadius: EditorInterfaceRadius.control, style: .continuous))
            }
            .buttonStyle(.editorToolbarPress)
            .onHover { hovering in
                withAnimation(RecorderMotion.quick) {
                    isHovered = hovering
                }
            }
            .animation(RecorderMotion.fade, value: isHovered)
            .appButtonKeyboardFocus(in: RoundedRectangle(cornerRadius: EditorInterfaceRadius.control, style: .continuous))
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(appLocalized(title))
            .accessibilityValue(
                [detail.map(appLocalized), appLocalized(isExpanded ? "已展开" : "已折叠")]
                    .compactMap { $0 }
                    .joined(separator: "，")
            )
            .accessibilityAddTraits(.isButton)
            .accessibilityHint(accessibilityHint.map(appLocalized) ?? "")

            if isExpanded {
                Rectangle()
                    .fill(EditorTheme.hairline)
                    .frame(height: 1)
                    .padding(.horizontal, 12)

                content
                    .padding(.horizontal, 12)
                    .padding(.vertical, 12)
                    .transition(
                        .opacity
                    )
            }
        }
        .background {
            RoundedRectangle(cornerRadius: EditorInterfaceRadius.group, style: .continuous)
                .fill(EditorTheme.groupSurface)
        }
        .animation(RecorderMotion.settle, value: isExpanded)
    }
}
