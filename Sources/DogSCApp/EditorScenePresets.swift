import AppKit
import RecorderCore
import SwiftUI

extension EditorView {
    var activeScenePreset: EditorStylePreset? {
        let selectedID = scenePresetCurrentSegment?.sceneStyle?.presetID
        let id = selectedID ?? (editorStore.project.segmentSceneStyles.isEmpty ? activeStylePresetID : nil)
        return savedStylePresets.first { $0.id == id }
    }

    var scenePresetIsModified: Bool {
        guard let activeStyleSnapshot, activeScenePreset?.id == activeStylePresetID else { return false }
        var current = scenePresetEditingProject
        if let preset = activeScenePreset,
           isKnownScenePresetBackground(current.canvas.backgroundSource, for: preset) {
            current.canvas.backgroundSource = activeStyleSnapshot.canvas.backgroundSource
        }
        return !activeStyleSnapshot.matchesConfiguration(of: current, zoomCreationScale: AppPreferences.rememberedZoomCreationScale)
    }

    private func isKnownScenePresetBackground(_ source: BackgroundSource, for preset: EditorStylePreset) -> Bool {
        guard activeStylePresetID == preset.id,
              let asset = preset.backgroundAsset, asset.isAvailable,
              activeStyleSnapshot?.backgroundAsset == asset,
              activeStylePresetBackgroundSources.contains(source),
              let url = context.wallpaperURL(for: source)
        else { return false }
        return FileManager.default.fileExists(atPath: url.path)
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
    func stylePresetControl() -> some View {
        if savedStylePresets.isEmpty {
            Button { beginSavingScenePreset() } label: {
                scenePresetLabel(title: appLocalized("保存场景"), showsMenu: false)
            }
            .buttonStyle(EditorToolbarPressButtonStyle())
        } else {
            Button { showsScenePresetPopover.toggle() } label: {
                scenePresetLabel(title: activeScenePreset?.name ?? appLocalized("场景预设"), showsMenu: true)
            }
            .buttonStyle(EditorToolbarPressButtonStyle())
            .focusEffectDisabled()
            .editorPopoverKeyboardEntry { showsScenePresetPopover = true }
            .editorPopover(isPresented: $showsScenePresetPopover, arrowEdge: .bottom) {
                scenePresetMenu
            }
        }
    }

    private var scenePresetMenu: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(savedStylePresets) { preset in
                        EditorScenePresetRow(
                            name: preset.name,
                            isActive: preset.id == activeScenePreset?.id,
                            isDefault: defaultStylePresetID == preset.id,
                            onApply: {
                                showsScenePresetPopover = false
                                requestScenePresetApplication(preset)
                            },
                            onToggleDefault: {
                                setDefaultScenePreset(defaultStylePresetID == preset.id ? nil : preset.id)
                            },
                            onDelete: { deleteStylePreset(preset) }
                        )
                    }
                }
            }
            .scrollIndicators(.hidden)
            .frame(height: min(CGFloat(savedStylePresets.count) * 32, 288))
            Rectangle().fill(EditorTheme.hairline).frame(height: 1).padding(.vertical, 4)
            if let active = activeScenePreset {
                menuAction(String(format: appLocalized("更新“%@”…"), active.name), systemImage: "arrow.triangle.2.circlepath") {
                    showsScenePresetPopover = false
                    beginSavingScenePreset(updating: active)
                }
            }
            menuAction("另存为新预设…", systemImage: "plus") {
                showsScenePresetPopover = false
                beginSavingScenePreset()
            }
            Text(appLocalized(defaultStylePresetID == nil ? "新录制沿用上次外观" : "星标预设会用于新录制"))
                .font(EditorTypography.helper).foregroundStyle(EditorTheme.popoverSecondaryText)
                .padding(.horizontal, 8).padding(.top, 6).padding(.bottom, 2)
        }
        .padding(4).frame(width: 260)
    }

    private func menuAction(_ title: String, systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                EditorSymbol(systemImage, size: 13).foregroundStyle(EditorTheme.secondaryText).frame(width: 16)
                Text(appLocalized(title)).font(.appUI(size: 13)).lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8).frame(height: 28)
        }
        .buttonStyle(EditorActionRowStyle(selected: false))
    }

    private func scenePresetLabel(title: String, showsMenu: Bool) -> some View {
        EditorToolbarControlSurface(accessibilityTitle: title) {
            HStack(spacing: 6) {
                AppLineIcon(kind: .layers, size: 15)
                Text(title)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: 160)
                    .fixedSize(horizontal: true, vertical: false)
                if scenePresetIsModified {
                    Circle()
                        .fill(EditorTheme.amberAccent)
                        .frame(width: 5, height: 5)
                        .accessibilityLabel("已修改")
                }
                if showsMenu {
                    AppLineIcon(kind: .chevronDown, size: 10)
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
        _ = editorStore.prepareForExternalAction(.export)
        playbackController.pause()
        stylePresetAppliedNotice = nil
        let segments = scenePresetSegments
        guard !segments.isEmpty else { return }
        var selected = Set(editorStore.groupSelection.compactMap { selection -> UUID? in
            if case let .primarySegment(id) = selection { return id }; return nil
        })
        selected.formUnion(selectedPrimarySegmentIDs)
        if case let .primarySegment(id) = editorStore.selection { selected.insert(id) }
        selected.formIntersection(segments.map(\.id))
        if selected.isEmpty, let id = scenePresetCurrentSegment?.id { selected.insert(id) }
        scenePresetSelectedIDs = selected
        scenePresetAppliesToAll = false
        if segments.count == 1 {
            applyStylePreset(preset, segmentIDs: Set(segments.map(\.id)))
        } else {
            pendingStylePreset = preset
        }
    }

    func saveCurrentStylePreset() {
        let name = stylePresetName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, !stylePresetNameConflict, !isSavingStylePreset else { return }
        let project = scenePresetEditingProject
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
                activeStyleSnapshot?.backgroundAsset = snapshot.backgroundAsset
                activeStylePresetBackgroundSources = snapshot.backgroundAsset == nil ? [] : [project.canvas.backgroundSource]
                isNamingStylePreset = false
            } catch {
                if let copiedAsset { await copiedAsset.discardUncommittedCopy() }
                if !Task.isCancelled {
                    stylePresetError = appLocalized("预设未保存。请确认背景文件可读取后重试。")
                }
            }
        }
    }

    func applyStylePreset(_ preset: EditorStylePreset, segmentIDs: Set<UUID>) {
        guard !isSavingStylePreset else { return }
        let baseline = editorStore.project
        let segments = scenePresetSegments
        guard !segmentIDs.isEmpty, segmentIDs.isSubset(of: Set(segments.map(\.id))) else { return }
        let knownBackgroundSources = activeStylePresetID == preset.id
            && activeStyleSnapshot?.backgroundAsset == preset.backgroundAsset
            ? activeStylePresetBackgroundSources : []
        isSavingStylePreset = true
        stylePresetTask = Task { @MainActor in
            var imported: ImportedProjectOverlayAsset?
            defer { isSavingStylePreset = false }
            do {
                var background: BackgroundSource?
                if let asset = preset.backgroundAsset, asset.isAvailable, let url = asset.url {
                    // Keep references proven to represent this asset during
                    // the current preset session, including references restored by Undo.
                    let currentSource = baseline.sceneProject(forSegmentID: segments.first { segmentIDs.contains($0.id) }?.id).canvas.backgroundSource
                    if isKnownScenePresetBackground(currentSource, for: preset) {
                        background = currentSource
                    } else {
                        let copy = try await context.projectAssetTransfer.importBackgroundAsset(from: url, isVideo: asset.isVideo)
                        imported = copy
                        background = asset.isVideo
                            ? .projectVideo(relativePath: copy.relativePath)
                            : .projectImage(relativePath: copy.relativePath)
                    }
                }
                try Task.checkCancellation()
                guard editorStore.project == baseline else {
                    throw ProjectCommandError.staleState(domain: "场景配置")
                }
                var result = baseline
                var authored = segments.map { segment in
                    RecordingSegment(id: segment.id, sourceStart: segment.sourceStart,
                        sourceDuration: segment.sourceDuration, playbackRate: segment.playbackRate,
                        media: segment.media, sourceID: segment.sourceID, sceneStyle: segment.sceneStyle,
                        crop: segment.crop)
                }
                for index in authored.indices where segmentIDs.contains(authored[index].id) {
                    let segment = authored[index]
                    let local = baseline.sceneProject(forSegmentID: segment.id)
                    let applied = preset.applying(to: local, backgroundOverride: background)
                    authored[index].sceneStyle = SegmentSceneStyle(project: applied, presetID: preset.id, presetName: preset.name)
                    if authored[index].media != nil { authored[index].media?.usesFrameStyle = true }
                    // A v2 preset still carries a crop, and the crop's owner is
                    // the recording, so it lands on the source itself — unless
                    // this clip was deliberately framed on its own, in which
                    // case a preset must not quietly widen it back.
                    if preset.includesCrop, segment.media == nil {
                        if segment.crop != nil {
                            authored[index].crop = applied.canvas.crop.clamped()
                        } else {
                            result.setCrop(applied.canvas.crop, for: segment.resolvedSourceID)
                        }
                    }
                }
                result.timeline.sourceSequence = .edited(authored)
                try editorStore.replaceProject(with: result, actionName: String(format: appLocalized("应用场景预设“%@”"), preset.name))
                stylePresetAppliedNotice = String(format: appLocalized("已将「%@」应用到 %lld 个片段"), preset.name, Int64(segmentIDs.count))
                stylePresetAppliedRevision = editorStore.revision
                pendingStylePreset = nil
                editorStore.scenePresetPreviewSegmentIDs = nil
                if let id = scenePresetCurrentSegment?.id { editorStore.sceneEditingSegmentID = id }
                activeStylePresetID = preset.id
                activeStyleSnapshot = EditorStylePreset(name: preset.name, project: scenePresetEditingProject, zoomCreationScale: AppPreferences.rememberedZoomCreationScale)
                activeStylePresetBackgroundSources = []
                if let background {
                    activeStyleSnapshot?.backgroundAsset = preset.backgroundAsset
                    activeStylePresetBackgroundSources = knownBackgroundSources
                    if !activeStylePresetBackgroundSources.contains(background) {
                        activeStylePresetBackgroundSources.append(background)
                    }
                }
                var notices: [String] = []
                if !preset.hasAvailableBackground {
                    notices.append(appLocalized("此预设的背景未包含或已不可用，已保留当前背景。"))
                }
                if !preset.includesCrop {
                    notices.append(appLocalized("这是旧版外观预设，已保留当前裁切和摄像头显隐。更新此预设后可保存完整场景。"))
                }
                if !preset.camera.isHidden, !baseline.sources.contains(where: { $0.media.camera != nil }) {
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
                activeStylePresetBackgroundSources = []
            }
        } catch {
            hostActions.reportError(error.localizedDescription)
        }
    }
}


/// One preset in the scene menu: click to apply; on hover a star marks it
/// as the default for new recordings and a bin deletes it.
private struct EditorScenePresetRow: View {
    let name: String
    let isActive: Bool
    let isDefault: Bool
    let onApply: () -> Void
    let onToggleDefault: () -> Void
    let onDelete: () -> Void
    @State private var hovered = false

    var body: some View {
        HStack(spacing: 4) {
            Button(action: onApply) {
                HStack(spacing: 8) {
                    EditorSymbol("checkmark", size: 12)
                        .opacity(isActive ? 1 : 0)
                        .frame(width: 16)
                    Text(name).font(.appUI(size: 13, weight: isActive ? .semibold : .regular))
                        .lineLimit(1).truncationMode(.middle)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 8).frame(height: 28)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(name)
            .accessibilityAddTraits(isActive ? .isSelected : [])
            if hovered || isDefault {
                Button(action: onToggleDefault) {
                    EditorSymbol(isDefault ? "star.fill" : "star", size: 12)
                        .foregroundStyle(isDefault ? EditorTheme.amberAccent : EditorTheme.secondaryText)
                        .frame(width: 24, height: 24)
                }
                .buttonStyle(EditorToolbarPressButtonStyle())
                .help(appLocalized(isDefault ? "取消新录制默认" : "设为新录制默认"))
                .accessibilityLabel(appLocalized(isDefault ? "取消新录制默认" : "设为新录制默认"))
            }
            if hovered {
                Button(action: onDelete) {
                    AppLineIcon(kind: .trash, size: 12)
                        .foregroundStyle(EditorTheme.secondaryText)
                        .frame(width: 24, height: 24)
                }
                .buttonStyle(EditorToolbarPressButtonStyle())
                .help(String(format: appLocalized("删除预设：%@"), name))
                .accessibilityLabel(String(format: appLocalized("删除预设：%@"), name))
            }
        }
        .padding(.trailing, 2)
        .background(RoundedRectangle(cornerRadius: EditorInterfaceRadius.control, style: .continuous)
            .fill(EditorTheme.chrome(hovered ? EditorStateWash.hover : 0)))
        .foregroundStyle(EditorTheme.primaryText)
        .onHover { hovered = $0 }
    }
}
