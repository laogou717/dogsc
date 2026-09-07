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

struct EditorTransactionalSliderRow: View {
    @ObservedObject var editorStore: EditorStore
    let title: String
    let value: Binding<Double>
    let range: ClosedRange<Double>
    let commandScope: EditorInteractionCommandScope
    var format: EditorSliderValueFormat = .decimal2
    let onError: (String) -> Void
    @State private var isSliderEditing = false
    @State private var isTextEditing = false
    @State private var hasTextPreview = false

    var body: some View {
        VStack(spacing: 2) {
            HStack(spacing: 12) {
                Text(appLocalized(title))
                    .font(.appUI(size: 13, weight: .regular))
                    .foregroundStyle(EditorTheme.chrome(0.76))
                    .lineLimit(1)
                Spacer(minLength: 8)
            EditorInspectorParameterReadout(
                title: title,
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
            .frame(width: 66, height: 32)
            }
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
            .accessibilityLabel(title)
            .accessibilityValue(format.text(for: value.wrappedValue))
        }
    }

    private func beginTextEditing() {
        isTextEditing = true
        hasTextPreview = false
        _ = editorStore.beginContinuousInteraction(commandScope: commandScope)
    }

    private func previewTextValue(_ text: String) -> Bool {
        guard let parsed = format.value(from: text) else { return false }
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
        get: { $0.canvas[keyPath: keyPath] },
        set: { $0.canvas[keyPath: keyPath] = $1 },
        replace: { try store.replaceCanvas(with: $0.canvas, actionName: actionName) },
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
        get: { $0.camera[keyPath: keyPath] },
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
        get: { $0.cursorStyle[keyPath: keyPath] },
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
        get: { $0.motion[keyPath: keyPath] },
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
            var replacement = store.project
            set(&replacement, value)
            do {
                try replace(replacement)
            } catch {
                onError(error.localizedDescription)
            }
        }
    )
}
