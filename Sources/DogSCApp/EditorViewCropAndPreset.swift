import AppKit
import Foundation
import RecorderCore
import SwiftUI

extension EditorView {
    @ViewBuilder
    var stylePresetControl: some View {
        if savedStylePresets.isEmpty {
            Button {
                stylePresetName = "我的样式 1"
                isNamingStylePreset = true
            } label: {
                stylePresetToolbarLabel(
                    title: "保存样式",
                    systemImage: "square.and.arrow.down",
                    showsMenuIndicator: false
                )
            }
            .buttonStyle(.plain)
        } else {
            Menu {
                Section("我的样式") {
                    ForEach(savedStylePresets) { preset in
                        Button {
                            applyStylePreset(preset)
                        } label: {
                            Label(preset.name, systemImage: "paintbrush")
                        }
                    }
                }

                Divider()
                Button {
                    stylePresetName = nextStylePresetName
                    isNamingStylePreset = true
                } label: {
                    Label("保存当前样式…", systemImage: "square.and.arrow.down")
                }

                Menu("删除样式", systemImage: "trash") {
                    ForEach(savedStylePresets) { preset in
                        Button("删除“\(preset.name)”", role: .destructive) {
                            deleteStylePreset(preset)
                        }
                    }
                }
            } label: {
                stylePresetToolbarLabel(
                    title: "样式",
                    systemImage: "paintpalette",
                    showsMenuIndicator: true
                )
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
        }
    }

    private func stylePresetToolbarLabel(
        title: String,
        systemImage: String,
        showsMenuIndicator: Bool
    ) -> some View {
        HStack(spacing: 6) {
            Image(systemName: systemImage)
            Text(title)
            if showsMenuIndicator {
                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
        }
        .font(.caption.weight(.semibold))
        .foregroundStyle(Color.primary.opacity(0.88))
        .padding(.horizontal, 8)
        .frame(height: 26)
        .contentShape(Rectangle())
    }

    func canvasBinding<Value>(
        _ keyPath: WritableKeyPath<CanvasStyle, Value>,
        actionName: String
    ) -> Binding<Value> {
        Binding(
            get: { editorStore.project.canvas[keyPath: keyPath] },
            set: { value in
                var style = editorStore.project.canvas
                style[keyPath: keyPath] = value
                performEditorCommand { try editorStore.replaceCanvas(with: style, actionName: actionName) }
            }
        )
    }

    func performEditorCommand(_ operation: () throws -> Void) {
        do {
            try operation()
        } catch {
            hostActions.reportError(error.localizedDescription)
        }
    }

    func setCanvasAspectRatio(_ aspectRatio: CanvasAspectRatio) {
        guard cropPresentation.permits(.changeCanvasAspectRatio) else { return }
        var canvas = editorStore.project.canvas
        canvas.aspectRatio = aspectRatio
        performEditorCommand {
            try editorStore.replaceCanvas(with: canvas, actionName: "调整画布比例")
        }
    }

    func beginCrop() {
        guard cropPresentation.permits(.beginCrop) else { return }
        playbackController.pause()
        // 裁切期间检查器由裁切面板接管，完成/取消后选择回到屏幕初始状态，
        // 都落在合并后的"画面"页，无需在此预设页签。
        editorStore.beginInteraction(tool: .crop, selection: .crop)
    }

    func confirmCrop() {
        guard cropPresentation.permits(.confirmCrop) else { return }
        do {
            _ = try editorStore.commitInteraction(actionName: "裁切屏幕")
        } catch {
            editorStore.cancelInteraction()
            hostActions.reportError(error.localizedDescription)
        }
        editorStore.selection = .screen
    }

    func discardCrop() {
        guard cropPresentation.permits(.cancelCrop) else { return }
        editorStore.cancelInteraction()
        editorStore.selection = .screen
    }

    func resetCrop() {
        guard cropPresentation.permits(.resetCrop) else { return }
        cropDraftBinding.wrappedValue = .full
    }

    var cropDraft: NormalizedCrop {
        cropPresentation.draft ?? editorStore.project.canvas.crop.clamped()
    }

    var cropDraftBinding: Binding<NormalizedCrop> {
        Binding(
            get: { editorStore.previewProject.canvas.crop.clamped() },
            set: { crop in
                guard cropPresentation.isActive else { return }
                editorStore.updateInteraction { project in
                    project.canvas.crop = crop.clamped()
                }
            }
        )
    }

    func resolveExternalAction(_ action: EditorExternalAction) {
        let wasCropping = isCropping
        _ = editorStore.prepareForExternalAction(action)
        guard wasCropping else { return }
        if editorStore.selection == .crop {
            editorStore.selection = .screen
        }
    }

    var nextStylePresetName: String {
        var index = 1
        while savedStylePresets.contains(where: {
            $0.name.localizedCaseInsensitiveCompare("我的样式 \(index)") == .orderedSame
        }) {
            index += 1
        }
        return "我的样式 \(index)"
    }

    func saveCurrentStylePreset() {
        let name = stylePresetName.trimmingCharacters(
            in: CharacterSet.whitespacesAndNewlines
        )
        guard !name.isEmpty else { return }

        let existingID = savedStylePresets.first(where: {
            $0.name.localizedCaseInsensitiveCompare(name) == .orderedSame
        })?.id
        let preset = EditorStylePreset(
            id: existingID ?? UUID(),
            name: name,
            project: editorStore.project
        )
        var updated = savedStylePresets.filter { $0.id != preset.id }
        updated.append(preset)
        savedStylePresets = updated
        EditorStylePresetStore.save(updated)
    }

    func applyStylePreset(_ preset: EditorStylePreset) {
        let replacement = preset.applying(to: editorStore.project)
        performEditorCommand {
            try editorStore.replaceProject(
                with: replacement,
                actionName: "应用工作样式“\(preset.name)”"
            )
        }
    }

    func deleteStylePreset(_ preset: EditorStylePreset) {
        let updated = savedStylePresets.filter { $0.id != preset.id }
        savedStylePresets = updated
        EditorStylePresetStore.save(updated)
    }
}
