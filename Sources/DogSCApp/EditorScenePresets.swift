import AppKit
import RecorderCore
import SwiftUI

extension EditorView {
    var activeScenePreset: EditorStylePreset? {
        savedStylePresets.first { $0.id == activeStylePresetID }
    }

    var scenePresetIsModified: Bool {
        guard let activeStyleSnapshot else { return false }
        return !activeStyleSnapshot.matchesConfiguration(of: editorStore.project, zoomCreationScale: AppPreferences.rememberedZoomCreationScale)
    }

    var stylePresetNameConflict: Bool {
        let name = stylePresetName.trimmingCharacters(in: .whitespacesAndNewlines)
        return savedStylePresets.contains {
            $0.id != updatingStylePresetID && $0.name.localizedCaseInsensitiveCompare(name) == .orderedSame
        }
    }

    var nextStylePresetName: String {
        var index = 1
        let prefix = appLocalized("场景")
        while savedStylePresets.contains(where: {
            $0.name.localizedCaseInsensitiveCompare("\(prefix) \(index)") == .orderedSame
        }) { index += 1 }
        return "\(prefix) \(index)"
    }

    func beginSavingScenePreset(updating preset: EditorStylePreset? = nil) {
        updatingStylePresetID = preset?.id
        stylePresetName = preset?.name ?? nextStylePresetName
        stylePresetError = nil
        isNamingStylePreset = true
    }

    @ViewBuilder
    func stylePresetControl(compact: Bool) -> some View {
        if savedStylePresets.isEmpty {
            Button { beginSavingScenePreset() } label: {
                scenePresetLabel(title: appLocalized("保存场景"), compact: compact, showsMenu: false)
            }
            .buttonStyle(.editorToolbarPress)
        } else {
            Button { showsScenePresetPopover.toggle() } label: {
                scenePresetLabel(title: activeScenePreset?.name ?? appLocalized("场景预设"),
                                 compact: compact, showsMenu: true)
            }
            .buttonStyle(.editorToolbarPress)
            .focusEffectDisabled()
            .popover(isPresented: $showsScenePresetPopover, arrowEdge: .bottom) {
                scenePresetMenu.focusEffectDisabled()
            }
        }
    }

    private var scenePresetMenu: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("场景预设").font(.appUI(size: 14, weight: .medium))
                Spacer()
                Button {
                    showsScenePresetPopover = false
                    beginSavingScenePreset()
                } label: { Image(systemName: "plus").frame(width: 30, height: 30) }
                .buttonStyle(EditorSoftRaisedButtonStyle()).help("另存为新预设")
            }
            ScrollView {
                VStack(spacing: 8) {
                    ForEach(savedStylePresets) { preset in
                        VStack(spacing: 0) {
                            Button {
                                showsScenePresetPopover = false
                                requestScenePresetApplication(preset)
                            } label: {
                                HStack(spacing: 10) {
                                    Image(systemName: "rectangle.3.group")
                                    Text(preset.name).lineLimit(1).truncationMode(.middle)
                                    Spacer(minLength: 8)
                                    if preset.id == activeStylePresetID {
                                        Image(systemName: "checkmark").foregroundStyle(EditorTheme.selectionTint)
                                    }
                                }.font(.appUI(size: 13, weight: .medium))
                                    .padding(12).contentShape(Rectangle())
                            }.buttonStyle(.editorToolbarPress)
                            HStack(spacing: 8) {
                                Button {
                                    setDefaultScenePreset(defaultStylePresetID == preset.id ? nil : preset.id)
                                } label: {
                                    Label(defaultStylePresetID == preset.id ? "新录制默认" : "设为新录制默认",
                                          systemImage: defaultStylePresetID == preset.id ? "checkmark.circle.fill" : "circle")
                                }.buttonStyle(.plain)
                                Spacer(minLength: 4)
                                Button {
                                    deleteStylePreset(preset)
                                } label: { Image(systemName: "trash").frame(width: 26, height: 24) }
                                .buttonStyle(.editorToolbarPress).help("删除预设：\(preset.name)")
                            }
                            .font(.appUI(size: 11)).foregroundStyle(.secondary)
                            .padding(.horizontal, 12).padding(.bottom, 8)
                        }
                        .background(preset.id == activeStylePresetID ? EditorTheme.selectionWash : EditorTheme.chrome(0.035),
                                    in: RoundedRectangle(cornerRadius: 13))
                    }
                }
            }
            .scrollIndicators(.hidden)
            .frame(height: min(CGFloat(savedStylePresets.count) * 84, 320))
            if let active = activeScenePreset {
                Button {
                    showsScenePresetPopover = false
                    beginSavingScenePreset(updating: active)
                } label: {
                    Label("更新当前预设…", systemImage: "arrow.triangle.2.circlepath")
                        .font(.appUI(size: 13)).frame(maxWidth: .infinity).frame(height: 36)
                }.buttonStyle(EditorSoftRaisedButtonStyle())
            }
            Text(defaultStylePresetID == nil ? "新录制沿用上次外观" : "新录制将应用已选默认场景")
                .font(.appUI(size: 11)).foregroundStyle(.secondary)
        }
        .padding(18).frame(width: 320).background(EditorTheme.panelSurface)
    }

    private func scenePresetLabel(title: String, compact: Bool, showsMenu: Bool) -> some View {
        EditorToolbarControlSurface(accessibilityTitle: title) {
            HStack(spacing: 6) {
                Image(systemName: "rectangle.3.group")
                Text(title.count > 14 ? String(title.prefix(13)) + "…" : title)
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
                if scenePresetIsModified {
                    Image(systemName: "circle.fill")
                        .font(.appUI(size: 5))
                        .foregroundStyle(EditorTheme.amberAccent)
                        .accessibilityLabel("已修改")
                }
                if showsMenu {
                    Image(systemName: "chevron.down")
                        .font(.appUI(size: 9, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
            }
        }
        .accessibilityValue(scenePresetIsModified ? appLocalized("已修改") : appLocalized("场景预设"))
    }

    private func setDefaultScenePreset(_ id: UUID?) {
        defaultStylePresetID = id
        EditorStylePresetStore.defaultPresetID = id
    }

    func requestScenePresetApplication(_ preset: EditorStylePreset) {
        if preset.includesCrop, preset.canvas.crop != .full,
           let dimensions = preset.sourceDimensions, dimensions != scenePresetSourceDimensions {
            pendingStylePreset = preset
        } else {
            applyStylePreset(preset)
        }
    }

    func saveCurrentStylePreset() {
        let name = stylePresetName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, !stylePresetNameConflict, !isSavingStylePreset else { return }
        let project = editorStore.project
        let sourceURL = context.wallpaperURL(for: project.canvas.backgroundSource)
        var snapshot = EditorStylePreset(
            id: updatingStylePresetID ?? UUID(), name: name, project: project,
            sourceDimensions: scenePresetSourceDimensions,
            zoomCreationScale: AppPreferences.rememberedZoomCreationScale
        )
        isSavingStylePreset = true
        stylePresetError = nil
        stylePresetTask = Task { @MainActor in
            var copiedAsset: ScenePresetBackgroundAsset?
            defer { isSavingStylePreset = false }
            do {
                if project.canvas.backgroundSource.usesWallpaperMedia {
                    guard let sourceURL else { throw CocoaError(.fileReadNoSuchFile) }
                    let asset = try await ScenePresetBackgroundAsset.retain(
                        from: sourceURL, isVideo: project.canvas.backgroundSource.isVideo
                    )
                    copiedAsset = asset
                    snapshot.backgroundAsset = asset
                    snapshot.includesBackground = true
                    snapshot.canvas.backgroundSource = asset.availableSource ?? snapshot.canvas.backgroundSource
                }
                try Task.checkCancellation()
                var updated = savedStylePresets
                if let index = updated.firstIndex(where: { $0.id == snapshot.id }) {
                    updated[index] = snapshot
                } else {
                    updated.append(snapshot)
                }
                try EditorStylePresetStore.save(updated)
                savedStylePresets = updated
                activeStylePresetID = snapshot.id
                activeStyleSnapshot = EditorStylePreset(name: name, project: project, zoomCreationScale: AppPreferences.rememberedZoomCreationScale)
                isNamingStylePreset = false
            } catch {
                if let copiedAsset { await copiedAsset.discardUncommittedCopy() }
                if !Task.isCancelled {
                    stylePresetError = appLocalized("预设未保存。请确认背景文件可读取后重试。")
                }
            }
        }
    }

    func applyStylePreset(_ preset: EditorStylePreset) {
        guard !isSavingStylePreset else { return }
        let baseline = editorStore.project
        isSavingStylePreset = true
        stylePresetTask = Task { @MainActor in
            var imported: ImportedProjectOverlayAsset?
            defer { isSavingStylePreset = false }
            do {
                var background: BackgroundSource?
                if let asset = preset.backgroundAsset, asset.isAvailable, let url = asset.url {
                    let copy = try await context.projectAssetTransfer.importBackgroundAsset(from: url, isVideo: asset.isVideo)
                    imported = copy
                    background = asset.isVideo
                        ? .projectVideo(relativePath: copy.relativePath)
                        : .projectImage(relativePath: copy.relativePath)
                }
                try Task.checkCancellation()
                guard editorStore.project == baseline else {
                    throw ProjectCommandError.staleState(domain: "场景配置")
                }
                let result = preset.applying(to: baseline, backgroundOverride: background)
                try editorStore.performBatch([
                    ProjectCommand.replacingCanvas(in: baseline, with: result.canvas),
                    ProjectCommand.replacingCamera(in: baseline, with: result.camera),
                    ProjectCommand.replacingCursor(in: baseline, with: result.cursorStyle),
                    ProjectCommand.replacingMotion(in: baseline, with: result.motion),
                    ProjectCommand.replacingAudio(in: baseline, with: result.audio),
                    baseline.openingSequence == result.openingSequence ? nil
                        : .replaceOpening(before: baseline.openingSequence, after: result.openingSequence),
                ], actionName: "\(appLocalized("应用场景预设"))“\(preset.name)”")
                activeStylePresetID = preset.id
                activeStyleSnapshot = EditorStylePreset(name: preset.name, project: editorStore.project, zoomCreationScale: AppPreferences.rememberedZoomCreationScale)
                var notices: [String] = []
                if !preset.hasAvailableBackground {
                    notices.append(appLocalized("此预设的背景未包含或已不可用，已保留当前背景。"))
                }
                if !preset.includesCrop {
                    notices.append(appLocalized("这是旧版外观预设，已保留当前裁切和摄像头显隐。更新此预设后可保存完整场景。"))
                }
                if !result.camera.isHidden, baseline.media?.camera == nil {
                    notices.append(appLocalized("摄像头布局已应用；当前项目没有摄像头素材。"))
                }
                if !notices.isEmpty { stylePresetNotice = notices.joined(separator: "\n\n") }
            } catch {
                if let imported { try? await context.projectAssetTransfer.discard(imported) }
                if !Task.isCancelled { hostActions.reportError(error.localizedDescription) }
            }
        }
    }

    func deleteStylePreset(_ preset: EditorStylePreset) {
        do {
            let updated = savedStylePresets.filter { $0.id != preset.id }
            try EditorStylePresetStore.save(updated)
            savedStylePresets = updated
            if defaultStylePresetID == preset.id { setDefaultScenePreset(nil) }
            if activeStylePresetID == preset.id {
                activeStylePresetID = nil
                activeStyleSnapshot = nil
            }
        } catch {
            hostActions.reportError(error.localizedDescription)
        }
    }
}
