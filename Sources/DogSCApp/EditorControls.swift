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
    @Environment(\.consolePalette) private var palette
    @State private var isDragging = false
    @State private var dragStartValue: Double?
    @State private var isFocused = false
    @State private var isHovered = false

    private var fraction: Double { scale.fraction(value, in: range) }

    var body: some View {
        HStack(spacing: 14) {
            if let title {
                Text(appLocalized(title)).font(.appUI(size: 13)).foregroundStyle(EditorTheme.chrome(0.8))
                    .frame(width: 90, alignment: .leading).lineLimit(2)
            }
            GeometryReader { proxy in
                let width = max(proxy.size.width, 20)
                let inset: CGFloat = 7
                let travel = max(width - inset * 2, 1)
                let center = inset + fraction * travel
                let engaged = isDragging || (isHovered && isEnabled)
                // The rail spans the full column so its ends line up with the
                // title and readout above; the thumb travels inside it.
                ZStack(alignment: .leading) {
                    Capsule().fill(EditorTheme.sliderRail).frame(height: 3)
                    Capsule().fill(EditorTheme.sliderInk)
                        .frame(width: max(center, 3), height: 3)
                    Circle().fill(EditorTheme.sliderThumb)
                        .overlay { Circle().strokeBorder(EditorTheme.chrome(isFocused || engaged ? 0.28 : 0.12), lineWidth: 0.5) }
                        .shadow(color: .black.opacity(0.18), radius: 1.5, y: 1)
                        .frame(width: 14, height: 14)
                        .scaleEffect(isDragging ? 1.12 : 1)
                        .offset(x: center - 7)
                }
                .frame(height: 28)
                .animation(SpringMotion.micro, value: engaged)
                .contentShape(Rectangle())
                .onHover { isHovered = $0 }
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
            }.frame(height: 28)
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
    var centered = false

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
        .animation(SpringMotion.snappy, value: isActive)
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
            .font(.appUI(size: 12.5, design: .monospaced))
            .lineLimit(1)
            .minimumScaleFactor(0.8)
            .foregroundStyle(EditorTheme.primaryText.opacity(isEnabled ? 1 : 0.4))
            .opacity(showsValue ? 1 : 0)
            .padding(.horizontal, 7)
            .frame(minWidth: 44, minHeight: 26, maxHeight: 26, alignment: centered ? .center : .trailing)
            .background(valueBackground(isActive: isActive))
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
                        .multilineTextAlignment(centered ? .center : .trailing)
                        .padding(.horizontal, 7)
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
            .appButtonKeyboardFocus(in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            .onHover { hovering in
                withAnimation(SpringMotion.hover) {
                    isValueHovered = hovering
                }
            }
            .help(String(format: appLocalized("点击输入%@"), localizedInputTitle))
            .accessibilityLabel(String(format: appLocalized("编辑%@"), localizedInputTitle))
            .accessibilityValue(valueText)
            .disabled(!isEnabled)
        }
    }

    /// The value is plain text at rest; a soft well appears only while it is
    /// hovered, dragged or typed into, telling the user it is editable.
    private func valueBackground(isActive: Bool) -> some View {
        // EDT-079: the number sits in a filled box, a little darker when
        // hovered, dragged or typed into.
        RoundedRectangle(cornerRadius: 7, style: .continuous)
            .fill(EditorTheme.chrome(isEmbedded ? 0 : isTextEditing ? 0.10 : isActive ? 0.08 : 0.045))
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
        let layout = vertical ? AnyLayout(VStackLayout(alignment: .trailing, spacing: 6)) : AnyLayout(HStackLayout(spacing: 6))
        // EDT-079: two filled boxes; drag sideways on one to change it,
        // double-click to type.
        return layout {
            field(first, slot: .first)
            field(second, slot: .second)
        }
    }

    private func field(_ parameter: EditorPairedParameterValue, slot: Slot) -> some View {
        EditorScrubField(
            title: parameter.title,
            accessibilityTitle: parameter.accessibilityTitle,
            displayText: parameter.displayText,
            editingText: parameter.inputFormat.editingText(for: parameter.value),
            value: parameter.value,
            range: parameter.range,
            isActive: activeSlot == slot,
            onBegin: { begin(slot) },
            onScrub: { value in
                hasPreview = true
                switch slot {
                case .first: onChanged(value, second.value)
                case .second: onChanged(first.value, value)
                }
            },
            onPreviewText: { preview($0, slot: slot) },
            onFinish: { finish(slot, commits: $0) }
        )
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

/// One number box: a grey label, the value on the right. Dragging sideways
/// scrubs (a full range per 300 pt, ⇧ for fine steps); double-click types.
struct EditorScrubField: View {
    let title: String
    let accessibilityTitle: String
    let displayText: String
    let editingText: String
    let value: Double
    let range: ClosedRange<Double>
    let isActive: Bool
    let onBegin: () -> Void
    let onScrub: (Double) -> Void
    let onPreviewText: (String) -> Bool
    let onFinish: (Bool) -> Void

    @Environment(\.isEnabled) private var isEnabled
    @State private var hovered = false
    @State private var cursorPushed = false
    @State private var dragStart: Double?
    @State private var typing = false
    @State private var draft = ""
    @State private var draftValid = true
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 7) {
            Text(appLocalized(title))
                .font(.appUI(size: 12, design: .monospaced))
                .foregroundStyle(EditorTheme.tertiaryText)
            Spacer(minLength: 2)
            if typing {
                TextField("", text: $draft)
                    .textFieldStyle(.plain)
                    .tint(nil)
                    .multilineTextAlignment(.trailing)
                    .font(.appUI(size: 12, design: .monospaced))
                    .foregroundStyle(draftValid ? EditorTheme.primaryText : RecorderStyle.destructiveInk)
                    .focused($focused)
                    .onChange(of: draft) { _, text in draftValid = onPreviewText(text) }
                    .onSubmit { endTyping(commit: draftValid) }
                    .onExitCommand { endTyping(commit: false) }
                    .onChange(of: focused) { _, isFocused in if !isFocused, typing { endTyping(commit: draftValid) } }
                    .accessibilityLabel(String(format: appLocalized("输入%@"), appLocalized(accessibilityTitle)))
            } else {
                Text(displayText)
                    .font(.appUI(size: 12, design: .monospaced))
                    .foregroundStyle(EditorTheme.secondaryText)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
        }
        .padding(.horizontal, 9)
        .frame(maxWidth: .infinity)
        .frame(height: EditorPropertyRowMetrics.height)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(EditorTheme.chrome(isActive || typing ? 0.10 : hovered ? 0.08 : 0.045))
        )
        .contentShape(Rectangle())
        .onHover { inside in
            hovered = inside
            if inside, !typing, !cursorPushed { NSCursor.resizeLeftRight.push(); cursorPushed = true }
            else if !inside, cursorPushed { NSCursor.pop(); cursorPushed = false }
        }
        .gesture(
            DragGesture(minimumDistance: 2)
                .onChanged { gesture in
                    guard !typing, isEnabled else { return }
                    if dragStart == nil { dragStart = value; onBegin() }
                    let fine = NSEvent.modifierFlags.contains(.shift) ? 0.1 : 1
                    let span = range.upperBound - range.lowerBound
                    let next = (dragStart ?? value) + Double(gesture.translation.width) / 300 * span * fine
                    onScrub(min(max(next, range.lowerBound), range.upperBound))
                }
                .onEnded { _ in
                    guard dragStart != nil else { return }
                    dragStart = nil
                    onFinish(true)
                }
        )
        .simultaneousGesture(TapGesture(count: 2).onEnded { beginTyping() })
        .accessibilityElement(children: .combine)
        .accessibilityLabel(appLocalized(accessibilityTitle))
        .accessibilityValue(displayText)
        .accessibilityAction(named: Text(appLocalized("输入"))) { beginTyping() }
        .opacity(isEnabled ? 1 : 0.45)
    }

    private func beginTyping() {
        guard isEnabled, !typing else { return }
        if cursorPushed { NSCursor.pop(); cursorPushed = false }
        draft = editingText
        draftValid = true
        typing = true
        onBegin()
        DispatchQueue.main.async { focused = true }
    }

    private func endTyping(commit: Bool) {
        guard typing else { return }
        typing = false
        focused = false
        onFinish(commit)
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
                withAnimation(SpringMotion.standard) {
                    isOn.toggle()
                }
            } label: {
                Text(appLocalized(title))
                    .font(.appUI(size: 13))
                    .foregroundStyle(EditorTheme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(minHeight: EditorPropertyRowMetrics.height)
            }
            .buttonStyle(EditorToggleButtonStyle(isOn: isOn, showsTitle: true, isFocused: hasFocus))
            .focused($hasFocus)
            .accessibilityLabel(appLocalized(title))
            .accessibilityValue(appLocalized(isOn ? "开关状态 · 开启" : "开关状态 · 关闭"))
            .accessibilityAddTraits(.isToggle)
        } else {
            Button {
                withAnimation(SpringMotion.standard) {
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
        @Environment(\.recordingDesignControls) private var recordingColors
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
            // EDT-079: 30 × 18, ink when on, a 14 knob.
            let activeFill = recordingColors ? RecordingDesign.ink : EditorTheme.primaryText
            let knobFill = Color.white
            return ZStack(alignment: isOn ? .trailing : .leading) {
                Capsule(style: .continuous)
                    .fill(isOn ? activeFill : (recordingColors ? RecordingDesign.fill2 : EditorTheme.chrome(showsHover ? 0.16 : 0.11)))
                    .overlay {
                        Capsule(style: .continuous)
                            .strokeBorder(isOn ? Color.black.opacity(0.08) : EditorTheme.chrome(0.06), lineWidth: 0.5)
                    }
                // The knob stretches toward its destination while held.
                Capsule(style: .continuous)
                    .fill(knobFill)
                    .overlay {
                        Capsule(style: .continuous)
                            .strokeBorder(Color.black.opacity(0.06), lineWidth: 0.5)
                    }
                    .shadow(color: .black.opacity(0.14), radius: 1, y: 0.5)
                    .frame(width: 14, height: 14)
                    .padding(2)
            }
            .frame(width: 30, height: 18)
            .appKeyboardFocus(in: Capsule(), color: EditorTheme.chrome(0.40), isFocused: isFocused)
            .animation(SpringMotion.standard, value: isOn)
            .animation(SpringMotion.hover, value: showsHover)
            .animation(SpringMotion.snappy, value: isPressed)
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
    let showsTitle: Bool

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
        repeatsSteps: Bool = true,
        showsTitle: Bool = true
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
        self.showsTitle = showsTitle
    }

    var body: some View {
        HStack(spacing: 4) {
            if showsTitle {
                Text(appLocalized(title))
                    .font(.appUI(size: 11, weight: .medium))
                    .foregroundStyle(Color.primary.opacity(0.88))
                    .lineLimit(1)
            }

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
            in: RoundedRectangle(cornerRadius: 6, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .stroke(
                    EditorTheme.chrome(isHovered && isEnabled ? 0.12 : 0.065),
                    lineWidth: 0.75
                )
        }
        .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        .opacity(isEnabled ? 1 : 0.55)
        .onHover { hovering in
            withAnimation(SpringMotion.snappy) {
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
                .font(.appUI(size: 11, weight: .semibold, design: .monospaced))
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
            EditorSymbol(systemImage, size: 13)
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
                    in: RoundedRectangle(cornerRadius: 6, style: .continuous)
                )
                .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                .appKeyboardFocus(in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                .onHover { hovering in
                    withAnimation(SpringMotion.hover) {
                        isHovered = hovering
                    }
                }
                .animation(SpringMotion.snappy, value: configuration.isPressed)
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
        @Environment(\.editorInsideTile) private var insideTile
        @State private var isHovered = false
        let configuration: Configuration

        var body: some View {
            configuration.label
                .font(.appUI(size: 12, weight: .medium))
                .foregroundStyle(
                    isEnabled
                        ? EditorTheme.primaryText
                        : Color.secondary
                )
                .padding(.horizontal, 10)
                .frame(minHeight: EditorInterfaceHeight.compact)
                .background(
                    RoundedRectangle(cornerRadius: EditorInterfaceRadius.control, style: .continuous)
                        // Inside a tile the button is cut out of it in the
                        // panel tone; the state wash sits on top.
                        .fill(insideTile ? EditorTheme.panelSurface : .clear)
                        .overlay(RoundedRectangle(cornerRadius: EditorInterfaceRadius.control, style: .continuous).fill(
                            EditorTheme.chrome(
                                !isEnabled ? 0.02
                                    : configuration.isPressed ? EditorStateWash.pressed
                                    : isHovered ? EditorStateWash.hover : (insideTile ? 0 : 0.06)
                            )
                        ))
                        .overlay {
                            RoundedRectangle(cornerRadius: EditorInterfaceRadius.control, style: .continuous)
                                .strokeBorder(EditorTheme.chrome(isHovered && isEnabled ? 0.09 : 0.05), lineWidth: 0.5)
                        }
                )
                .contentShape(RoundedRectangle(cornerRadius: EditorInterfaceRadius.control, style: .continuous))
                .appKeyboardFocus(in: RoundedRectangle(cornerRadius: EditorInterfaceRadius.control, style: .continuous))
                .opacity(isEnabled ? 1 : 0.46)
                .onHover { isHovered = $0 }
                .animation(SpringMotion.hover, value: isHovered)

        }
    }
}

/// 主动作使用主题中的石墨色，与次级动作保持相同的边缘与按压节奏。
struct EditorPrimaryButtonStyle: ButtonStyle {
    var minHeight: CGFloat = EditorInterfaceHeight.selection

    func makeBody(configuration: Configuration) -> Body {
        Body(configuration: configuration, minHeight: minHeight)
    }

    /// 主按钮使用唯一强调色（EditorTheme.accent）。
    struct Body: View {
        @Environment(\.isEnabled) private var isEnabled
        @State private var isHovered = false
        let configuration: Configuration
        let minHeight: CGFloat

        var body: some View {
            let fill = EditorTheme.accent
            let ink = EditorTheme.onAccentFill
            configuration.label
                .font(.appUI(size: 12, weight: .semibold))
                .foregroundStyle(ink)
                .padding(.horizontal, 13)
                .frame(minHeight: minHeight)
                .background(RoundedRectangle(cornerRadius: EditorInterfaceRadius.control, style: .continuous).fill(fill))
                .overlay(
                    RoundedRectangle(cornerRadius: EditorInterfaceRadius.control, style: .continuous)
                        .fill(Color.black.opacity(
                            !isEnabled ? 0 : configuration.isPressed ? 0.18 : isHovered ? 0.12 : 0
                        ))
                        .allowsHitTesting(false)
                )
                .contentShape(RoundedRectangle(cornerRadius: EditorInterfaceRadius.control, style: .continuous))
                .appKeyboardFocus(in: RoundedRectangle(cornerRadius: EditorInterfaceRadius.control, style: .continuous), color: ink.opacity(0.65))
                .opacity(isEnabled ? 1 : 0.4)
                .onHover { isHovered = $0 }
                .animation(SpringMotion.hover, value: isHovered)

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
                .font(.appUI(size: 12, weight: .medium))
                .foregroundStyle(
                    isEnabled ? EditorTheme.primaryText.opacity(isHovered ? 1.0 : 0.82) : EditorTheme.tertiaryText
                )
                .padding(.horizontal, 10)
                .frame(minHeight: EditorInterfaceHeight.compact)
                .background(
                    RoundedRectangle(cornerRadius: EditorInterfaceRadius.control, style: .continuous)
                        .fill(
                            EditorTheme.chrome(
                                configuration.isPressed ? 0.10
                                    : isHovered && isEnabled ? 0.055 : 0
                            )
                        )
                )
                .contentShape(RoundedRectangle(cornerRadius: EditorInterfaceRadius.control, style: .continuous))
                .appKeyboardFocus(in: RoundedRectangle(cornerRadius: EditorInterfaceRadius.control, style: .continuous))
                .opacity(isEnabled ? 1 : 0.44)
                .onHover { isHovered = $0 }
                .animation(SpringMotion.hover, value: isHovered)

        }
    }
}

/// Shared hover and press feedback; the overlay never intercepts clicks.
/// Every free-standing button in the editor is a 6 pt rounded rectangle;
/// rows and cards pass their own radius explicitly.
struct EditorToolbarPressButtonStyle: ButtonStyle {
    var cornerRadius: CGFloat = EditorInterfaceRadius.control
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
            let lit = isEnabled && hovered && showsHover
            configuration.label
                .contentShape(RoundedRectangle(cornerRadius: cornerRadius, style: cornerStyle))
                .appKeyboardFocus(in: RoundedRectangle(cornerRadius: cornerRadius, style: cornerStyle))
                .overlay {
                    RoundedRectangle(cornerRadius: cornerRadius, style: cornerStyle)
                        .fill(EditorTheme.chrome(isEnabled ? (configuration.isPressed ? EditorStateWash.pressed : lit ? EditorStateWash.hover : 0) : 0))
                        .allowsHitTesting(false)
                }
                .opacity(isEnabled ? 1 : 0.48)
                .onHover { hovered = $0 }
                .animation(SpringMotion.micro, value: hovered)
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
                .onHover { hovering in
                    withAnimation(SpringMotion.hover) {
                        isHovered = hovering
                    }
                }
                .animation(SpringMotion.snappy, value: configuration.isPressed)
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
                .onHover { hovering in
                    withAnimation(SpringMotion.hover) {
                        isHovered = hovering
                    }
                }
                .animation(SpringMotion.snappy, value: configuration.isPressed)
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
            // EDT-079: red text at the foot of a page; a faint red ground
            // appears only under the pointer.
            HStack(spacing: 6) {
                AppLineIcon(kind: .trash, size: 15)
                configuration.label.lineLimit(1).fixedSize()
            }
                .font(.appUI(size: 13, weight: .medium))
                .foregroundStyle(
                    RecorderStyle.destructiveInk.opacity(!isEnabled ? 0.4 : 1)
                )
                .padding(.horizontal, 11)
                .frame(minHeight: 30)
                .background(
                    RoundedRectangle(cornerRadius: EditorInterfaceRadius.control, style: .continuous)
                        .fill(
                            RecorderStyle.recording.opacity(
                                !isEnabled ? 0
                                    : configuration.isPressed ? 0.16
                                    : isHovered ? 0.10 : 0
                            )
                        )
                )
                .frame(maxWidth: .infinity, alignment: .trailing)
                .contentShape(RoundedRectangle(cornerRadius: EditorInterfaceRadius.control, style: .continuous))
                .appKeyboardFocus(in: RoundedRectangle(cornerRadius: EditorInterfaceRadius.control, style: .continuous))
                .onHover { isHovered = $0 }
                .animation(SpringMotion.hover, value: isHovered)

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
                    Circle()
                        .fill(
                            Color.red.opacity(
                                configuration.isPressed ? 0.16
                                    : isHovered && isEnabled ? 0.10 : 0
                            )
                        )
                )
                .contentShape(Circle())
                .appKeyboardFocus(in: Circle())
                .onHover { hovering in
                    withAnimation(SpringMotion.hover) {
                        isHovered = hovering
                    }
                }
                .animation(SpringMotion.snappy, value: configuration.isPressed)
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
                .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                .appKeyboardFocus(in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                .opacity(isEnabled ? 1 : 0.44)
                .onHover { hovering in
                    withAnimation(SpringMotion.hover) {
                        isHovered = hovering
                    }
                }
                .animation(SpringMotion.snappy, value: configuration.isPressed)
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
                .contentShape(Rectangle())
                .opacity(isEnabled ? 1 : 0.44)
                .onHover { hovering in
                    withAnimation(SpringMotion.hover) {
                        isHovered = hovering
                    }
                }
                .animation(SpringMotion.snappy, value: configuration.isPressed)
        }
    }
}

extension ButtonStyle where Self == EditorQuietButtonStyle {
    static var editorQuiet: EditorQuietButtonStyle { EditorQuietButtonStyle() }
}

extension ButtonStyle where Self == EditorPrimaryButtonStyle {
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
            // An action, not a choice: it looks like every other secondary
            // button, with its picture on the left.
            HStack(spacing: 6) {
                EditorSymbol(icon, size: 13)
                Text(appLocalized(title))
                    .font(.appUI(size: 12, weight: .medium))
                    .lineLimit(1)
            }
            .foregroundStyle(EditorTheme.primaryText)
            .frame(maxWidth: .infinity)
            .frame(height: 28)
            .background {
                RoundedRectangle(cornerRadius: EditorInterfaceRadius.control, style: .continuous)
                    .fill(EditorTheme.chrome(isHovered ? EditorStateWash.hover + 0.02 : 0.05))
            }
            .contentShape(RoundedRectangle(cornerRadius: EditorInterfaceRadius.control, style: .continuous))
        }
        .buttonStyle(EditorToolbarPressButtonStyle(showsHover: false))
        .appButtonKeyboardFocus(in: RoundedRectangle(cornerRadius: EditorInterfaceRadius.control, style: .continuous))
        .onHover { isHovered = $0 }
        .animation(SpringMotion.micro, value: isHovered)
    }
}

// MARK: - Disclosure (平滑展开折叠卡片)

/// 卡片式折叠组：标题行 + 弹簧旋转箭头，展开时内容平滑淡入。
struct EditorDisclosure<Content: View>: View {
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.editorInsideTile) private var insideTile
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
                withAnimation(SpringMotion.standard) {
                    expansion.wrappedValue.toggle()
                }
            } label: {
                HStack(spacing: 8) {
                    if let icon {
                        EditorSymbol(icon, size: 14)
                            .foregroundStyle(iconTint ?? EditorTheme.secondaryText)
                            .frame(width: 18, height: 18)
                    }
                    Text(appLocalized(title))
                        .font(.appUI(size: 14, weight: .medium))
                        .foregroundStyle(EditorTheme.primaryText)
                        .lineLimit(1)
                    Spacer(minLength: 8)
                    if let detail {
                        Text(appLocalized(detail))
                            .font(.appUI(size: 13).monospacedDigit())
                            .foregroundStyle(EditorTheme.secondaryText)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                    AppLineIcon(kind: .chevron, size: 12)
                        .foregroundStyle(EditorTheme.tertiaryText)
                        .frame(width: 20, height: 20)
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .frame(minHeight: 44)
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(EditorTheme.chrome(!isEnabled ? 0 : isHovered ? 0.05 : 0))
                )
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.horizontal, -10)
            .onHover { isHovered = $0 }
            .animation(SpringMotion.micro, value: isHovered)
            .appButtonKeyboardFocus(in: RoundedRectangle(cornerRadius: EditorInterfaceRadius.card, style: .continuous))
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(appLocalized(title))
            .accessibilityValue(
                [detail.map(appLocalized), appLocalized(isExpanded ? "已展开" : "已折叠")]
                    .compactMap { $0 }
                    .joined(separator: appLocalized("，"))
            )
            .accessibilityAddTraits(.isButton)
            .accessibilityHint(accessibilityHint.map(appLocalized) ?? "")

            if isExpanded {
                VStack(alignment: .leading, spacing: 12) { content }
                    .padding(.top, 4)
                    .padding(.bottom, 8)
                    .transition(.opacity)
            }
        }
        .environment(\.editorInsideTile, true)
        .animation(SpringMotion.standard, value: isExpanded)
    }
}
