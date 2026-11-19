import AppKit
import RecorderCore
import SwiftUI

/// EDT-053: placement and visibility of one Rive clip. File-declared
/// parameters (text, numbers, colours) follow in the next step.
struct EditorAnimationInspector: View {
    @ObservedObject var editorStore: EditorStore
    let clipID: UUID
    @State private var declared: [AnimationFrames.DeclaredProperty] = []

    private var clip: AnimationClip? {
        editorStore.previewProject.timeline.animationClips.first { $0.id == clipID }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: EditorInterfaceSpacing.sectionGap) {
            if let clip {
                Color.clear.frame(height: 0)
                    .task(id: clip.sourcePath) {
                        declared = await AnimationFrames.declaredProperties(sourcePath: clip.sourcePath)
                    }
                Text(URL(fileURLWithPath: clip.sourcePath).lastPathComponent)
                    .font(EditorTypography.helper)
                    .foregroundStyle(EditorTheme.tertiaryText)
                    .lineLimit(1)
                    .truncationMode(.middle)
                EditorInspectorSection("布局") {
                    EditorTransactionalPositionPad(
                        editorStore: editorStore,
                        title: "位置",
                        point: positionBinding,
                        commandScope: .selection,
                        selection: .animation(clipID),
                        actionName: "移动动效",
                        onError: { editorStore.reportError?($0) }
                    )
                    clipSlider("大小", \.width, 0.05...1.5)
                }
                EditorInspectorSection("外观") {
                    clipSlider("不透明度", \.opacity, 0...1)
                }
                if clip.soundtrack != nil {
                    EditorInspectorSection("声音") {
                        timelineSlider(editorStore, "音量", 0...1, format: .percent,
                            get: { $0.animationClips.first { $0.id == clipID }?.soundtrack?.volume ?? 1 },
                            set: { timeline, value in
                                guard let i = timeline.animationClips.firstIndex(where: { $0.id == clipID }) else { return }
                                timeline.animationClips[i].soundtrack?.volume = value
                            })
                    }
                }
                if HTMLMotion.isHTMLMotion(clip.sourcePath) {
                    EditorMotionElementsSection(editorStore: editorStore, target: .overlay(clipID))
                }
                if !declared.isEmpty {
                    EditorInspectorSection("动效参数") {
                        ForEach(declared) { property in propertyControl(property, clip: clip) }
                    }
                }
                Button(role: .destructive) {
                    do { try editorStore.removeSelectedOverlay(actionName: "删除动效") }
                    catch { editorStore.reportError?(error.localizedDescription) }
                } label: {
                    Text("删除动效").frame(maxWidth: .infinity)
                }
                .buttonStyle(.editorDestructive)
            }
        }
    }

    private var positionBinding: Binding<NormalizedPoint> {
        let id = clipID
        return Binding(
            get: { editorStore.previewProject.timeline.animationClips.first { $0.id == id }?.position ?? NormalizedPoint(x: 0.5, y: 0.5) },
            set: { value in
                editorStore.updateInteraction { project in
                    guard let i = project.timeline.animationClips.firstIndex(where: { $0.id == id }) else { return }
                    project.timeline.animationClips[i].position = value
                }
            }
        )
    }

    private func clipSlider(_ title: String, _ keyPath: WritableKeyPath<AnimationClip, Double>,
                            _ range: ClosedRange<Double>) -> some View {
        let id = clipID
        return timelineSlider(editorStore, title, range, format: .percent,
            get: { $0.animationClips.first { $0.id == id }?[keyPath: keyPath] ?? 0 },
            set: { timeline, value in
                guard let i = timeline.animationClips.firstIndex(where: { $0.id == id }) else { return }
                timeline.animationClips[i][keyPath: keyPath] = value
            })
    }

    private func setProperty(_ name: String, _ value: AnimationPropertyValue?) {
        commitTimelineEdit(editorStore, action: "调整动效参数") { timeline in
            guard let i = timeline.animationClips.firstIndex(where: { $0.id == clipID }) else { return }
            timeline.animationClips[i].properties[name] = value
        }
    }

    @ViewBuilder
    private func propertyControl(_ property: AnimationFrames.DeclaredProperty, clip: AnimationClip) -> some View {
        let current = clip.properties[property.name] ?? property.defaultValue
        switch property.kind {
        case .string:
            EditorCommittingTextField(
                title: property.name,
                text: { if case let .string(text) = current { text } else { "" } }(),
                onCommit: { setProperty(property.name, $0.isEmpty ? nil : .string($0)) }
            )
        case .number:
            HStack {
                Text(property.name).font(EditorTypography.controlLabel).foregroundStyle(EditorTheme.secondaryText)
                Spacer()
                EditorCommittingTextField(
                    title: property.name,
                    text: { if case let .number(value) = current { String(format: "%g", value) } else { "0" } }(),
                    showsTitle: false,
                    onCommit: { if let value = Double($0) { setProperty(property.name, .number(value)) } }
                )
                .frame(width: 80)
            }
        case .boolean:
            EditorToggle(isOn: Binding(
                get: { if case let .boolean(flag) = current { flag } else { false } },
                set: { setProperty(property.name, .boolean($0)) }
            ), title: property.name)
        case .color:
            EditorTransactionalColorInput(
                editorStore: editorStore,
                title: property.name,
                value: Binding(
                    get: {
                        if case let .color(hex) = editorStore.previewProject.timeline.animationClips
                            .first(where: { $0.id == clipID })?.properties[property.name] ?? property.defaultValue { return hex }
                        return HexColor(rgb24: 0xFF_FF_FF)
                    },
                    set: { color in
                        editorStore.updateInteraction { project in
                            guard let i = project.timeline.animationClips.firstIndex(where: { $0.id == clipID }) else { return }
                            project.timeline.animationClips[i].properties[property.name] = .color(color)
                        }
                    }
                ),
                commandScope: .selection,
                actionName: "调整动效参数",
                onError: { editorStore.reportError?($0) }
            )
        }
    }
}

/// EDT-071: the fields a main-track HTML motion declares (title, date,
/// colours…). Edits change the live page at once; nothing is re-rendered.
struct EditorInsertedMotionFields: View {
    @ObservedObject var editorStore: EditorStore
    let segmentID: UUID
    @State private var declared: [AnimationFrames.DeclaredProperty] = []

    private var media: InsertedMedia? {
        guard case let .edited(segments) = editorStore.previewProject.timeline.sourceSequence else { return nil }
        return segments.first { $0.id == segmentID }?.media
    }

    var body: some View {
        if let media, let motionPath = media.motionPath {
            VStack(alignment: .leading, spacing: 10) {
                Color.clear.frame(height: 0)
                    .task(id: motionPath) { declared = await AnimationFrames.declaredProperties(sourcePath: motionPath) }
                if declared.isEmpty {
                    Text(appLocalized("这段动效没有可编辑的文字或颜色。"))
                        .font(.appUI(size: 13))
                        .foregroundStyle(EditorTheme.secondaryText)
                } else {
                    ForEach(declared) { property in control(property, media: media) }
                }
            }
        }
    }

    private func set(_ name: String, _ value: AnimationPropertyValue?) {
        editorStore.setInsertedMotionProperty(segmentID, name: name, value: value)
    }

    @ViewBuilder
    private func control(_ property: AnimationFrames.DeclaredProperty, media: InsertedMedia) -> some View {
        let current = media.properties[property.name] ?? property.defaultValue
        switch property.kind {
        case .string:
            EditorCommittingTextField(
                title: property.name,
                text: { if case let .string(text) = current { text } else { "" } }(),
                onCommit: { set(property.name, $0.isEmpty ? nil : .string($0)) }
            )
        case .number:
            HStack {
                Text(property.name).font(EditorTypography.controlLabel).foregroundStyle(EditorTheme.secondaryText)
                Spacer()
                EditorCommittingTextField(
                    title: property.name,
                    text: { if case let .number(value) = current { String(format: "%g", value) } else { "0" } }(),
                    showsTitle: false,
                    onCommit: { if let value = Double($0) { set(property.name, .number(value)) } }
                )
                .frame(width: 80)
            }
        case .boolean:
            EditorToggle(isOn: Binding(
                get: { if case let .boolean(flag) = current { flag } else { false } },
                set: { set(property.name, .boolean($0)) }
            ), title: property.name)
        case .color:
            EditorTransactionalColorInput(
                editorStore: editorStore,
                title: property.name,
                value: Binding(
                    get: {
                        if case let .color(hex) = self.media?.properties[property.name] ?? property.defaultValue { return hex }
                        return HexColor(rgb24: 0xFF_FF_FF)
                    },
                    set: { color in
                        let id = segmentID
                        editorStore.updateInteraction { project in
                            guard case var .edited(segments) = project.timeline.sourceSequence,
                                  let i = segments.firstIndex(where: { $0.id == id }) else { return }
                            segments[i].media?.properties[property.name] = .color(color)
                            project.timeline.sourceSequence = .edited(segments)
                        }
                    }
                ),
                commandScope: .selection,
                actionName: "调整动效参数",
                onError: { editorStore.reportError?($0) }
            )
        }
    }
}

/// EDT-073: the element list of the motion being edited on the canvas.
struct EditorMotionElementsSection: View {
    @ObservedObject var editorStore: EditorStore
    @ObservedObject private var editor = MotionElementEditor.shared
    let target: MotionElementTarget

    var body: some View {
        if editor.target == target {
            EditorInspectorSection("画面元素") {
                MotionElementInspector(editorStore: editorStore, editor: editor, target: target)
            }
        }
    }
}

/// A text field that edits a local draft and writes once, on Return or when
/// focus leaves — one undo step per edit instead of one per keystroke.
struct EditorCommittingTextField: View {
    let title: String
    let text: String
    var showsTitle = true
    var focusesOnAppear = false
    var onSubmitAction: (() -> Void)? = nil
    let onCommit: (String) -> Void
    @State private var draft: String?
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if showsTitle {
                Text(title).font(EditorTypography.controlLabel).foregroundStyle(EditorTheme.secondaryText)
            }
            TextField("", text: Binding(get: { draft ?? text }, set: { draft = $0 }))
                .textFieldStyle(.plain)
                .font(.appUI(size: 12))
                .padding(.horizontal, 8)
                .frame(height: 28)
                .background(EditorTheme.controlWell, in: RoundedRectangle(cornerRadius: EditorInterfaceRadius.control, style: .continuous))
                .focused($focused)
                .onAppear { if focusesOnAppear { focused = true } }
                .onSubmit { commit(); onSubmitAction?() }
                .onChange(of: focused) { _, isFocused in if !isFocused { commit() } }
                .onDisappear(perform: commit)
                .accessibilityLabel(title)
        }
    }

    private func commit() {
        guard let value = draft else { return }
        draft = nil
        if value != text { onCommit(value) }
    }
}
