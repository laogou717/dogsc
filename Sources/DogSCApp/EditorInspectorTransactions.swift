import RecorderCore
import SwiftUI

/// Semantic readout for inspector sliders. A raw "%.2f" for every control
/// produced pixel values like "38.28" next to ratios like "0.28"; each
/// semantic family now carries its own precision and unit.
enum EditorSliderValueFormat: Equatable, Hashable, Sendable {
    /// Pixel-like values: rounded integer, no unit ("38").
    case points
    /// 0...1 ratios presented as a rounded percentage ("38%").
    case percent
    /// Scale factors presented as a multiplier ("1.6×", "2.25×").
    case multiplier
    /// Durations in seconds ("0.7s", "1.25s").
    case seconds
    /// Angles in degrees ("180°").
    case degrees
    /// One decimal for small spring-like quantities ("1.2").
    case decimal1
    /// Legacy two-decimal readout where no clearer semantic exists.
    case decimal2

    func text(for value: Double) -> String {
        guard value.isFinite else { return "–" }
        switch self {
        case .points:
            return "\(Int(value.rounded()))"
        case .percent:
            return "\(Int((value * 100).rounded()))%"
        case .multiplier:
            return "\(Self.trimmed(value))×"
        case .seconds:
            return "\(Self.trimmed(value))s"
        case .degrees:
            return "\(Int(value.rounded()))°"
        case .decimal1:
            return String(format: "%.1f", value)
        case .decimal2:
            return String(format: "%.2f", value)
        }
    }

    /// Unit-free text used while the persistent readout is in exact-entry
    /// mode. The visible readout keeps its semantic unit; the field itself
    /// stays easy to select and replace.
    func editingText(for value: Double) -> String {
        guard value.isFinite else { return "" }
        switch self {
        case .points:
            return "\(Int(value.rounded()))"
        case .percent:
            return "\(Int((value * 100).rounded()))"
        case .multiplier, .seconds:
            return Self.trimmed(value)
        case .degrees:
            return "\(Int(value.rounded()))"
        case .decimal1:
            return String(format: "%.1f", value)
        case .decimal2:
            return Self.trimmed(value)
        }
    }

    /// Parses the same units shown by `text(for:)`. A user may type either
    /// the bare number or paste the visible value including its suffix.
    func value(from text: String) -> Double? {
        var normalized = text
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: "，", with: ".")
            .replacingOccurrences(of: ",", with: ".")

        for token in ["％", "%", "×", "x", "倍", "秒", "s", "°", "度"] {
            normalized = normalized.replacingOccurrences(of: token, with: "")
        }
        normalized = normalized.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let raw = Double(normalized), raw.isFinite else { return nil }
        return self == .percent ? raw / 100 : raw
    }

    /// Compact readout used everywhere a value is shown: no trailing zeros
    /// ("0.7s", "1.25×", "2×"), with a unit glued on.
    static func compact(_ value: Double, unit: String = "", digits: Int = 2) -> String {
        guard value.isFinite else { return "–" }
        var text = String(format: "%.\(digits)f", value)
        if text.contains(".") {
            while text.hasSuffix("0") { text.removeLast() }
            if text.hasSuffix(".") { text.removeLast() }
        }
        if text == "-0" { text = "0" }
        return text + unit
    }

    /// Up to two decimals, trailing zeros stripped ("1.60" → "1.6").
    private static func trimmed(_ value: Double) -> String {
        let raw = String(format: "%.2f", value)
        var trimmed = raw
        while trimmed.hasSuffix("0") { trimmed.removeLast() }
        if trimmed.hasSuffix(".") { trimmed.removeLast() }
        return trimmed
    }
}

struct EditorTransactionalSlider: View {
    @ObservedObject var editorStore: EditorStore
    let value: Binding<Double>
    let range: ClosedRange<Double>
    let commandScope: EditorInteractionCommandScope
    let actionName: String
    var title: String? = nil
    var formatValue: ((Double) -> String)? = nil
    var showsFloatingValue = true
    var scale: EditorSliderScale = .linear
    var onInteractionChanged: (Bool) -> Void = { _ in }
    let onError: (String) -> Void

    var body: some View {
        EditorSlider(
            value: transactionalValue,
            range: range,
            title: title,
            formatValue: formatValue,
            showsFloatingValue: showsFloatingValue,
            scale: scale,
            onEditingChanged: { isEditing in
                onInteractionChanged(isEditing)
                // 与旧系统滑块同一事务边界：按下开始（幂等），松手提交。
                if isEditing {
                    _ = editorStore.beginContinuousInteraction(commandScope: commandScope)
                } else {
                    commitIfNeeded()
                }
            }
        )
    }

    private var transactionalValue: Binding<Double> {
        Binding(
            get: { value.wrappedValue },
            set: { newValue in
                // Do not depend on whether SwiftUI delivers the setter or
                // onEditingChanged(true) first.
                _ = editorStore.beginContinuousInteraction(commandScope: commandScope)
                value.wrappedValue = newValue
            }
        )
    }

    private func commitIfNeeded() {
        updateEditorContinuousInteraction(
            store: editorStore,
            isEditing: false,
            commandScope: commandScope,
            actionName: actionName,
            onError: onError
        )
    }
}

/// Exact-entry fields keep valid previews on window deactivation. An invalid
/// draft only downgrades its own interaction; it never starts a new one.
/// Reacquiring before the value callback also keeps resumed typing continuous.
@MainActor
func updateEditorTextPreviewValidity(
    store: EditorStore,
    isValid: Bool,
    commandScope: EditorInteractionCommandScope,
    selection: EditorSelection? = nil,
    actionName: String
) {
    if isValid {
        _ = store.beginContinuousInteraction(
            commandScope: commandScope,
            selection: selection,
            commitsWhenReplacedAs: actionName
        )
    } else {
        store.setContinuousInteractionReplacementPolicy(
            commandScope: commandScope,
            selection: selection,
            commitsWhenReplacedAs: nil
        )
    }
}

/// Gives custom drag controls the same one-gesture/one-command lifecycle as
/// `EditorTransactionalSlider`. Beginning is deliberately idempotent because
/// SwiftUI controls do not promise whether their first value callback or their
/// editing callback arrives first.
@MainActor
func updateEditorContinuousInteraction(
    store: EditorStore,
    isEditing: Bool,
    commandScope: EditorInteractionCommandScope,
    actionName: String,
    onError: (String) -> Void
) {
    if isEditing {
        _ = store.beginContinuousInteraction(commandScope: commandScope)
        return
    }
    guard store.interaction?.commandScope == commandScope else { return }
    do {
        _ = try store.commitInteraction(actionName: actionName)
    } catch {
        store.cancelInteraction()
        onError(error.localizedDescription)
    }
}

/// One property per line: name, slider and value share fixed columns, so
/// every parameter in every page lines up on the same vertical edges.
/// Repositioning (not replacing) keeps an active text draft alive.
enum EditorPropertyRowMetrics {
    /// EDT-079 (界面细则): one line — name, track, number.
    static let labelWidth: CGFloat = 64
    static let valueWidth: CGFloat = 52
    static let gap: CGFloat = 10
    static let height: CGFloat = 30
    /// The number field's height inside the row.
    static let headHeight: CGFloat = 26
}

/// A parameter on one line: the name at the left (64), the track filling
/// the middle, and the editable number at the right (52). The thumb travels
/// inside the track, so nothing reaches the panel's edge.
struct EditorSliderRowLayout: Layout {
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        CGSize(width: proposal.width ?? 320, height: EditorPropertyRowMetrics.height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard subviews.count == 3 else { return }
        let m = EditorPropertyRowMetrics.self
        subviews[0].place(
            at: CGPoint(x: bounds.minX, y: bounds.midY), anchor: .leading,
            proposal: ProposedViewSize(width: m.labelWidth, height: m.height)
        )
        subviews[1].place(
            at: CGPoint(x: bounds.maxX, y: bounds.midY), anchor: .trailing,
            proposal: ProposedViewSize(width: m.valueWidth, height: m.headHeight)
        )
        let trackX = bounds.minX + m.labelWidth + m.gap
        let trackWidth = max(bounds.width - m.labelWidth - m.valueWidth - m.gap * 2, 40)
        subviews[2].place(
            at: CGPoint(x: trackX, y: bounds.midY), anchor: .leading,
            proposal: ProposedViewSize(width: trackWidth, height: m.height)
        )
    }
}

/// How a slider row draws its parameter. A bar suits a quantity that reads as
/// an extent (a duration, a size, an opacity); the slim rail stays for expert
/// tuning rows where only the number matters.
enum EditorSliderRowStyle {
    case bar
    case slim
}

struct EditorTransactionalSliderRow: View {
    @ObservedObject var editorStore: EditorStore
    let title: String
    let value: Binding<Double>
    let range: ClosedRange<Double>
    let commandScope: EditorInteractionCommandScope
    var format: EditorSliderValueFormat = .decimal2
    var accessibilityTitle: String? = nil
    var style: EditorSliderRowStyle = .bar
    let onError: (String) -> Void
    @State private var isSliderEditing = false
    @State private var isTextEditing = false
    @State private var hasTextPreview = false

    private var parameterTitle: String { accessibilityTitle ?? title }

    var body: some View {
        // One parameter grammar everywhere: label, rail, editable value.
        slimBody
    }

    /// The quiet rail with the number at the right, for expert tuning rows.
    private var slimBody: some View {
        EditorSliderRowLayout {
            Text(appLocalized(title))
                .font(.appUI(size: 13))
                .foregroundStyle(EditorTheme.secondaryText)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityHidden(true)
            EditorInspectorParameterReadout(
                title: parameterTitle,
                valueText: format.text(for: value.wrappedValue),
                isEditing: isSliderEditing || isTextEditing,
                editConfiguration: EditorInspectorParameterEditConfiguration(
                    draftText: format.editingText(for: value.wrappedValue),
                    onBegin: beginTextEditing,
                    onPreview: previewTextValue,
                    onCommit: commitTextEditing,
                    onCancel: cancelTextEditing
                ),
                showsTitle: false,
                isEmbedded: false
            )
            .frame(width: EditorPropertyRowMetrics.valueWidth, height: EditorPropertyRowMetrics.headHeight, alignment: .trailing)
            EditorTransactionalSlider(
                editorStore: editorStore,
                value: value,
                range: range,
                commandScope: commandScope,
                actionName: title,
                title: nil,
                formatValue: { format.text(for: $0) },
                showsFloatingValue: false,
                scale: format.sliderScale(in: range),
                onInteractionChanged: { editing in
                    isSliderEditing = editing
                },
                onError: onError
            )
            .disabled(isTextEditing)
            .accessibilityLabel(appLocalized(parameterTitle))
            .accessibilityValue(format.text(for: value.wrappedValue))
        }
    }

    private func beginTextEditing() {
        isTextEditing = true
        hasTextPreview = false
        _ = editorStore.beginContinuousInteraction(
            commandScope: commandScope,
            commitsWhenReplacedAs: title
        )
    }

    private func previewTextValue(_ text: String) -> Bool {
        guard let parsed = format.value(from: text) else {
            editorStore.setContinuousInteractionReplacementPolicy(
                commandScope: commandScope,
                commitsWhenReplacedAs: nil
            )
            return false
        }
        // An external focus change may already have committed the previous
        // valid draft. Start from that saved value when typing resumes, and
        // restore autosave after a formerly invalid draft becomes valid.
        _ = editorStore.beginContinuousInteraction(
            commandScope: commandScope,
            commitsWhenReplacedAs: title
        )
        hasTextPreview = true
        let clamped = min(max(parsed, range.lowerBound), range.upperBound)
        value.wrappedValue = clamped
        return true
    }

    private func commitTextEditing() {
        isTextEditing = false
        if hasTextPreview {
            updateEditorContinuousInteraction(
                store: editorStore,
                isEditing: false,
                commandScope: commandScope,
                actionName: title,
                onError: onError
            )
        } else if editorStore.interaction?.commandScope == commandScope {
            editorStore.cancelInteraction()
        }
        hasTextPreview = false
    }

    private func cancelTextEditing() {
        isTextEditing = false
        hasTextPreview = false
        if editorStore.interaction?.commandScope == commandScope {
            editorStore.cancelInteraction()
        }
    }
}

@MainActor
func editorCanvasBinding<Value>(
    store: EditorStore,
    keyPath: WritableKeyPath<CanvasStyle, Value>,
    actionName: String,
    onError: @escaping (String) -> Void
) -> Binding<Value> {
    editorDomainBinding(
        store: store,
        commandScope: .canvas,
        get: { $0.sceneProject(forSegmentID: store.sceneEditingSegmentID).canvas[keyPath: keyPath] },
        set: { $0.canvas[keyPath: keyPath] = $1 },
        replace: { try store.replaceCanvas(with: $0.canvas, actionName: actionName) },
        onError: onError
    )
}

@MainActor
func editorScreenAppearanceBinding<Value>(
    store: EditorStore,
    target: ScreenAppearanceTarget,
    keyPath: WritableKeyPath<CanvasStyle, Value>,
    actionName: String,
    onError: @escaping (String) -> Void
) -> Binding<Value> {
    editorDomainBinding(
        store: store,
        commandScope: .project,
        get: { $0.screenCanvas(for: target)[keyPath: keyPath] },
        set: { project, value in
            var canvas = project.screenCanvas(for: target)
            canvas[keyPath: keyPath] = value
            project.setScreenAppearance(ScreenCardAppearance(canvas: canvas), for: target)
        },
        replace: { try store.replaceProject(with: $0, actionName: actionName) },
        onError: onError
    )
}

@MainActor
func editorCameraBinding<Value>(
    store: EditorStore,
    keyPath: WritableKeyPath<CameraStyle, Value>,
    actionName: String,
    onError: @escaping (String) -> Void
) -> Binding<Value> {
    editorDomainBinding(
        store: store,
        commandScope: .camera,
        get: { $0.sceneProject(forSegmentID: store.sceneEditingSegmentID).camera[keyPath: keyPath] },
        set: { $0.camera[keyPath: keyPath] = $1 },
        replace: { try store.replaceCamera(with: $0.camera, actionName: actionName) },
        onError: onError
    )
}

@MainActor
func editorAudioBinding<Value>(
    store: EditorStore,
    keyPath: WritableKeyPath<AudioStyle, Value>,
    actionName: String,
    onError: @escaping (String) -> Void
) -> Binding<Value> {
    editorDomainBinding(
        store: store,
        commandScope: .audio,
        get: { $0.audio[keyPath: keyPath] },
        set: { $0.audio[keyPath: keyPath] = $1 },
        replace: { try store.replaceAudio(with: $0.audio, actionName: actionName) },
        onError: onError
    )
}

@MainActor
func editorCursorBinding<Value>(
    store: EditorStore,
    keyPath: WritableKeyPath<CursorStyle, Value>,
    actionName: String,
    onError: @escaping (String) -> Void
) -> Binding<Value> {
    editorDomainBinding(
        store: store,
        commandScope: .cursor,
        get: { $0.sceneProject(forSegmentID: store.sceneEditingSegmentID).cursorStyle[keyPath: keyPath] },
        set: { $0.cursorStyle[keyPath: keyPath] = $1 },
        replace: { try store.replaceCursor(with: $0.cursorStyle, actionName: actionName) },
        onError: onError
    )
}

@MainActor
func editorMotionBinding<Value>(
    store: EditorStore,
    keyPath: WritableKeyPath<MotionStyle, Value>,
    actionName: String,
    onError: @escaping (String) -> Void
) -> Binding<Value> {
    editorDomainBinding(
        store: store,
        commandScope: .motion,
        get: { $0.sceneProject(forSegmentID: store.sceneEditingSegmentID).motion[keyPath: keyPath] },
        set: { $0.motion[keyPath: keyPath] = $1 },
        replace: { try store.replaceMotion(with: $0.motion, actionName: actionName) },
        onError: onError
    )
}

@MainActor
func editorOpeningBinding<Value>(
    store: EditorStore,
    keyPath: WritableKeyPath<OpeningSequence, Value>,
    actionName: String,
    onError: @escaping (String) -> Void
) -> Binding<Value> {
    editorDomainBinding(
        store: store,
        commandScope: .project,
        get: { $0.openingSequence[keyPath: keyPath] },
        set: {
            $0.openingSequence[keyPath: keyPath] = $1
            $0.openingSequence.normalizeTiming()
        },
        replace: { try store.replaceProject(with: $0, actionName: actionName) },
        onError: onError
    )
}

@MainActor
func editorTimelineBinding<Value>(
    store: EditorStore,
    selection: EditorSelection,
    get: @escaping (ProjectTimeline) -> Value,
    set: @escaping (inout ProjectTimeline, Value) -> Void,
    actionName: String,
    onError: @escaping (String) -> Void
) -> Binding<Value> {
    Binding(
        get: { get(store.previewProject.timeline) },
        set: { value in
            if store.interaction?.commandScope == .selection,
               store.interaction?.selection == selection {
                store.updateInteraction { project in
                    set(&project.timeline, value)
                }
                return
            }
            var timeline = store.project.timeline
            set(&timeline, value)
            do {
                try store.replaceTimeline(with: timeline, actionName: actionName)
            } catch {
                onError(error.localizedDescription)
            }
        }
    )
}

@MainActor
func editorPrimarySegmentAudioBinding<Value>(
    store: EditorStore,
    segmentID: UUID,
    get: @escaping (RecorderProject, PrimarySegmentAudioOverrides) -> Value,
    set: @escaping (inout PrimarySegmentAudioOverrides, Value) -> Void,
    actionName: String,
    onError: @escaping (String) -> Void
) -> Binding<Value> {
    editorDomainBinding(
        store: store,
        commandScope: .selection,
        get: { project in
            get(
                project,
                project.timeline.primarySegmentAudioOverrides[segmentID]
                    ?? PrimarySegmentAudioOverrides()
            )
        },
        set: { project, value in
            var overrides = project.timeline.primarySegmentAudioOverrides[segmentID]
                ?? PrimarySegmentAudioOverrides()
            set(&overrides, value)
            if overrides.isEmpty {
                project.timeline.primarySegmentAudioOverrides.removeValue(
                    forKey: segmentID
                )
            } else {
                project.timeline.primarySegmentAudioOverrides[segmentID] = overrides
            }
        },
        replace: { try store.replaceProject(with: $0, actionName: actionName) },
        onError: onError
    )
}

@MainActor
func editorAudioClipBinding<Value>(
    store: EditorStore,
    clipID: UUID,
    default fallback: Value,
    keyPath: WritableKeyPath<AudioClip, Value>,
    actionName: String,
    onError: @escaping (String) -> Void
) -> Binding<Value> {
    editorDomainBinding(
        store: store,
        commandScope: .selection,
        get: { project in
            project.timeline.audioClips.first(where: { $0.id == clipID })?[keyPath: keyPath] ?? fallback
        },
        set: { project, value in
            guard let index = project.timeline.audioClips.firstIndex(where: { $0.id == clipID }) else { return }
            project.timeline.audioClips[index][keyPath: keyPath] = value
        },
        replace: { try store.replaceProject(with: $0, actionName: actionName) },
        onError: onError
    )
}

@MainActor
private func editorDomainBinding<Value>(
    store: EditorStore,
    commandScope: EditorInteractionCommandScope,
    get: @escaping (RecorderProject) -> Value,
    set: @escaping (inout RecorderProject, Value) -> Void,
    replace: @escaping (RecorderProject) throws -> Void,
    onError: @escaping (String) -> Void
) -> Binding<Value> {
    Binding(
        get: { get(store.previewProject) },
        set: { value in
            if store.interaction?.commandScope == commandScope {
                store.updateInteraction { set(&$0, value) }
                return
            }
            let editsScene = commandScope == .canvas || commandScope == .camera || commandScope == .cursor || commandScope == .motion
            var replacement = editsScene ? store.sceneEditingProject : store.project
            set(&replacement, value)
            do {
                try replace(replacement)
            } catch {
                onError(error.localizedDescription)
            }
        }
    )
}
