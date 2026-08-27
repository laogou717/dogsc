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
    let onError: (String) -> Void

    var body: some View {
        EditorSlider(
            value: transactionalValue,
            range: range,
            onEditingChanged: { isEditing in
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

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(title).font(.caption)
                Spacer()
                Text(format.text(for: value.wrappedValue))
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            // The adjustable control below already exposes this title and
            // formatted value. Keep the visual readout without making users
            // traverse a duplicate, non-interactive text stop first.
            .accessibilityHidden(true)
            EditorTransactionalSlider(
                editorStore: editorStore,
                value: value,
                range: range,
                commandScope: commandScope,
                actionName: title,
                onError: onError
            )
            .accessibilityLabel(title)
            .accessibilityValue(format.text(for: value.wrappedValue))
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
