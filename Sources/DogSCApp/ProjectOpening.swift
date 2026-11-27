import Foundation
import RecorderCore

/// A fully resolved project payload. Loading happens before AppModel publishes
/// any of these values, so the editor cannot observe mixed project/media state.
struct ProjectOpenSnapshot: Sendable {
    let normalizedURL: URL
    let session: RecordingSession
    let project: RecorderProject
    let recordingURL: URL?
    let cameraRecordingURL: URL?
    let microphoneRecordingURL: URL?
    let pointerEvents: [PointerEventRecord]
    let wasInterrupted: Bool
    let warnings: [String]

    var isSaved: Bool {
        !ProjectStore.isWorkingProject(normalizedURL)
    }

    static func load(at packageURL: URL) async throws -> ProjectOpenSnapshot {
        try Task.checkCancellation()
        let normalizedURL = packageURL.lastPathComponent == "project.json"
            ? packageURL.deletingLastPathComponent()
            : packageURL
        let wasInterrupted = ProjectStore.isRecoverableProject(at: normalizedURL)
        let loaded = try ProjectStore.loadProject(at: normalizedURL)
        var project = loaded.project
        var relocatedDeclarations = Set<String>()
        func relocated(
            _ path: String,
            directories: [String]
        ) -> String {
            guard ProjectStore.resolve(relativePath: path, session: loaded.session) == nil,
                  let repaired = ProjectStore.relocatedRelativePath(
                    for: path,
                    session: loaded.session,
                    allowedDirectories: directories
                  ) else { return path }
            relocatedDeclarations.insert("\(path) → \(repaired)")
            return repaired
        }

        if var media = project.media {
            media.screen.relativePath = relocated(
                media.screen.relativePath,
                directories: ["media"]
            )
            if var camera = media.camera {
                camera.relativePath = relocated(camera.relativePath, directories: ["media"])
                media.camera = camera
            }
            if var microphone = media.microphone {
                microphone.relativePath = relocated(
                    microphone.relativePath,
                    directories: ["media"]
                )
                media.microphone = microphone
            }
            if var pointerEvents = media.pointerEvents {
                pointerEvents.relativePath = relocated(
                    pointerEvents.relativePath,
                    directories: ["events"]
                )
                media.pointerEvents = pointerEvents
            }
            project.media = media
        }
        switch project.canvas.backgroundSource {
        case let .projectImage(relativePath):
            project.canvas.backgroundSource = .projectImage(
                relativePath: relocated(relativePath, directories: ["assets"])
            )
        case let .projectVideo(relativePath):
            project.canvas.backgroundSource = .projectVideo(
                relativePath: relocated(relativePath, directories: ["assets"])
            )
        default:
            break
        }
        if case var .edited(segments) = project.timeline.sourceSequence {
            for index in segments.indices {
                guard var style = segments[index].sceneStyle else { continue }
                switch style.canvas.backgroundSource {
                case let .projectImage(path):
                    style.canvas.backgroundSource = .projectImage(relativePath: relocated(path, directories: ["assets", "Sources"]))
                case let .projectVideo(path):
                    style.canvas.backgroundSource = .projectVideo(relativePath: relocated(path, directories: ["assets", "Sources"]))
                default: break
                }
                segments[index].sceneStyle = style
            }
            project.timeline.sourceSequence = .edited(segments)
        }
        for index in project.timeline.stickerClips.indices {
            project.timeline.stickerClips[index].relativePath = relocated(
                project.timeline.stickerClips[index].relativePath,
                directories: ["assets"]
            )
        }
        try Task.checkCancellation()

        let recordingURL = ProjectStore.resolve(
            relativePath: project.media?.screen.relativePath,
            session: loaded.session
        )
        // The automatically generated timestamp proxy did not restore real
        // lip sync and must not silently remain the project's source. Migrate
        // projects that autosaved that temporary path back to the untouched
        // camera recording before exposing the manual alignment workflow.
        if var camera = project.media?.camera,
           camera.relativePath.hasSuffix("-timestamp-repaired.mov") {
            let originalRelativePath = String(
                camera.relativePath.dropLast("-timestamp-repaired.mov".count)
            ) + ".mov"
            if ProjectStore.resolve(
                relativePath: originalRelativePath,
                session: loaded.session
            ) != nil {
                camera.relativePath = originalRelativePath
                camera.sourceTimeScale = nil
                camera.sourceEndTime = nil
                project.media?.camera = camera
            }
        }
        let cameraRecordingURL = ProjectStore.resolve(
            relativePath: project.media?.camera?.relativePath,
            session: loaded.session
        )
        let microphoneRecordingURL = ProjectStore.resolve(
            relativePath: project.media?.microphone?.relativePath,
            session: loaded.session
        )

        var warnings: [String] = []
        let videos = try await OverlayVideoSource.resolve(project.timeline.videoClips, in: loaded.session)
        project.timeline.videoClips = videos.clips
        if videos.shortened > 0 {
            warnings.append(String(format: appLocalized("已将 %ld 段叠加视频的末端对齐到源视频最后的画面。"), videos.shortened))
        }
        if videos.empty > 0 {
            warnings.append(String(format: appLocalized("已略过 %ld 段取材起点超出源视频的空片段。"), videos.empty))
        }
        if loaded.recoveredFromPreviousRevision {
            warnings.append(appLocalized("项目主文件损坏，已恢复到上一个完整保存版本。"))
        }
        if !relocatedDeclarations.isEmpty {
            warnings.append(String(format: appLocalized("已在项目包内安全重新定位 %ld 项素材。"), relocatedDeclarations.count))
        }
        if project.media == nil {
            warnings.append(appLocalized("项目没有主录屏素材引用。"))
        } else if recordingURL == nil {
            warnings.append(appLocalized("项目引用的主录屏素材不存在或路径无效。"))
        }
        if project.media?.camera != nil, cameraRecordingURL == nil {
            warnings.append(appLocalized("项目引用的摄像头素材不存在或路径无效。"))
        }
        if project.media?.microphone != nil, microphoneRecordingURL == nil {
            warnings.append(appLocalized("项目引用的麦克风素材不存在或路径无效。"))
        }
        if loaded.droppedSourceSegments > 0 {
            warnings.append(String(format: appLocalized("已丢弃 %ld 段主轨片段，它们引用的录制已不在项目中。"),
                                   loaded.droppedSourceSegments))
        }
        // An imported recording keeps its own media. Reporting it as the main
        // recording used to send the user hunting through a healthy file.
        for source in project.additionalSources {
            let name = source.name.trimmingCharacters(in: .whitespacesAndNewlines)
            let title = name.isEmpty ? appLocalized("未命名录制") : name
            func report(_ reference: ProjectMediaReference?, role: String) {
                guard let reference,
                      ProjectStore.resolveMediaPath(reference.relativePath, session: loaded.session) == nil
                else { return }
                warnings.append(String(format: appLocalized("项目引用的录制「%@」的%@素材不存在或路径无效。"),
                                       title, appLocalized(role)))
            }
            report(source.media.screen, role: "屏幕")
            report(source.media.camera, role: "摄像头")
            report(source.media.microphone, role: "麦克风")
            report(source.media.pointerEvents, role: "鼠标事件")
        }
        switch project.canvas.backgroundSource {
        case let .projectImage(relativePath), let .projectVideo(relativePath):
            if ProjectStore.resolve(
                relativePath: relativePath,
                session: loaded.session
            ) == nil {
                warnings.append(appLocalized("项目引用的背景素材不存在或路径无效。"))
            }
        case let .systemImage(absolutePath), let .systemVideo(absolutePath):
            if !FileManager.default.fileExists(atPath: absolutePath) {
                warnings.append(appLocalized("该系统背景在当前设备上不存在。"))
            }
        default:
            break
        }
        let missingStickerCount = Set(project.timeline.stickerClips.compactMap { clip in
            ProjectStore.resolveMediaPath(clip.relativePath, session: loaded.session) == nil ? clip.relativePath : nil
        }).count
        if missingStickerCount > 0 {
            warnings.append(String(format: appLocalized("有 %ld 项贴图素材不存在或路径无效。"), missingStickerCount))
        }
        let pointerEvents: [PointerEventRecord]
        do {
            pointerEvents = try ProjectStore.loadPointerEvents(
                project: project,
                session: loaded.session
            )
        } catch {
            pointerEvents = []
            warnings.append(String(format: appLocalized("鼠标事件轨损坏：%@"), appErrorDescription(error)))
        }

        try Task.checkCancellation()
        // Legacy repair can compare a complete automatic zoom track against
        // hundreds of thousands of pointer events. It belongs to the immutable
        // background snapshot, not the AppKit main-actor publication step.
        let originalMotion = project.motion
        let originalAutomaticTrack = project.zoomAnimations
        let regroupedAutomaticTrack = project.additionalSources.isEmpty ? AutoZoomPlanner.repairingLegacyAutomaticAnimations(
            originalAutomaticTrack,
            for: pointerEvents,
            easing: originalMotion.defaultZoomEasing,
            transitionDuration: originalMotion.defaultZoomTransitionDuration
        ) : originalAutomaticTrack
        let upgradedMotion = LegacyMotionDefaultsUpgrade.upgraded(originalMotion)
        project.motion = upgradedMotion
        if regroupedAutomaticTrack != originalAutomaticTrack,
           upgradedMotion.defaultZoomEasing != originalMotion.defaultZoomEasing {
            project.zoomAnimations = regroupedAutomaticTrack.map { clip in
                var upgraded = clip
                if upgraded.origin == .automatic,
                   upgraded.easing == originalMotion.defaultZoomEasing {
                    upgraded.easing = upgradedMotion.defaultZoomEasing
                }
                return upgraded
            }
        } else {
            project.zoomAnimations = regroupedAutomaticTrack
        }
        project.timeline = ProjectTimelineEditing.repairingPersistedRippleTransitions(
            project.timeline,
            defaultTransitionDuration: project.motion.defaultZoomTransitionDuration
        )
        try Task.checkCancellation()
        // Recovery already lost one revision; its older snapshot may not name
        // every directory the lost one still used, so nothing is collected.
        if !loaded.recoveredFromPreviousRevision {
            let collected = ProjectStore.collectUnusedImportedSources(
                project: project,
                session: loaded.session
            )
            if collected > 0 {
                warnings.append(String(format: appLocalized("已清理 %ld 份不再使用的导入录制素材。"), collected))
            }
        }

        return ProjectOpenSnapshot(
            normalizedURL: normalizedURL,
            session: loaded.session,
            project: project,
            recordingURL: recordingURL,
            cameraRecordingURL: cameraRecordingURL,
            microphoneRecordingURL: microphoneRecordingURL,
            pointerEvents: pointerEvents,
            wasInterrupted: wasInterrupted,
            warnings: warnings
        )
    }
}
