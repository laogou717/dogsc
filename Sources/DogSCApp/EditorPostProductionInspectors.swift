import AVFoundation
import CoreImage
import CoreText
import ImageIO
import AppKit
import RecorderCore
import SwiftUI
import UniformTypeIdentifiers

/// One undoable edit of the timeline from an inspector control.
@MainActor
func commitTimelineEdit(_ store: EditorStore, action: String, _ body: @escaping (inout ProjectTimeline) -> Void) {
    _ = store.beginContinuousInteraction(commandScope: .selection)
    store.updateInteraction { project in body(&project.timeline) }
    do { _ = try store.commitInteraction(actionName: action) }
    catch {
        store.cancelInteraction()
        store.reportError?(error.localizedDescription)
    }
}

extension EditorStore {
    /// EDT-054: music or effect at the playhead, as long as the file allows.
    func addAudioClip(sourcePath: String, kind: AudioClipKind, at time: TimeInterval, outputDuration: TimeInterval,
                      sourceRange: ClosedRange<TimeInterval>? = nil) throws -> UUID {
        let start = min(max(time, 0), max(outputDuration - 0.25, 0))
        let fileDuration = AVURLAsset(url: ProjectFiles.url(sourcePath)).duration.seconds
        let whole = fileDuration.isFinite && fileDuration > 0 ? fileDuration : 10
        let wanted = sourceRange.map { max($0.upperBound - $0.lowerBound, 0.05) } ?? whole
        let length = max(min(wanted, outputDuration - start), 0.25)
        let clip = AudioClip(
            timing: OverlayTiming(startTime: start, duration: length),
            sourcePath: sourcePath,
            sourceStart: max(sourceRange?.lowerBound ?? 0, 0),
            volume: kind == .music ? 0.4 : 0.9,
            fadeIn: kind == .music ? 0.8 : 0,
            fadeOut: kind == .music ? 1.5 : 0,
            kind: kind
        )
        var timeline = project.timeline
        timeline.audioClips.append(clip)
        try replaceTimeline(with: timeline, actionName: kind == .music ? "添加音乐" : "添加音效")
        selection = .audioClip(clip.id)
        return clip.id
    }

    /// Adds files to the bin by reference; already-present paths are reused.
    @discardableResult
    func importMediaAssets(_ urls: [URL], library: AssetLibrary? = nil) -> [MediaAsset] {
        var timeline = project.timeline
        var result: [MediaAsset] = []
        var recordingProjects: [URL] = []
        for url in urls {
            if url.pathExtension.lowercased() == "dogscproject" {
                recordingProjects.append(url)
                continue
            }
            let stored = ProjectFiles.portable(url.path)
            if HTMLMotion.isHTMLMotion(url.path), let entry = (library ?? .shared).motionEntry(for: url.path) {
                let file = HTMLMotionEditing.File(url: url, entry: entry, reused: true)
                let id = HTMLMotionEditing.register(file, in: &timeline)
                if let asset = timeline.mediaAssets.first(where: { $0.id == id }) { result.append(asset) }
                continue
            }
            if let existing = timeline.mediaAssets.first(where: { $0.path == stored || ProjectFiles.resolve($0.path) == url.path }) {
                result.append(existing)
                continue
            }
            guard let kind = MediaAssetKind.kind(forExtension: url.pathExtension) else { continue }
            let asset = MediaAsset(path: stored, kind: kind, name: url.lastPathComponent)
            timeline.mediaAssets.append(asset)
            result.append(asset)
        }
        if timeline != project.timeline { try? replaceTimeline(with: timeline, actionName: "导入素材") }
        if !recordingProjects.isEmpty { requestRecordingImports(recordingProjects, nil) }
        return result
    }

    /// EDT-054: inserts a video (or a still image, as a generated still
    /// video) into the main track at an output time; the programme grows and
    /// everything after it moves later.
    /// `sourceRange` is the span of the file to insert; nil inserts all of it.
    /// A still has no span, and a main-track HTML motion plays from its own
    /// start, so there the marks only say how long the card runs.
    func insertOnMainTrack(_ asset: MediaAsset, at time: TimeInterval, sourceDurations: [UUID: TimeInterval],
                           sourceRange: ClosedRange<TimeInterval>? = nil) async throws {
        let path: String
        let fileDuration: TimeInterval
        let length: TimeInterval
        let marked = sourceRange.map { max($0.upperBound - $0.lowerBound, 0.1) }
        var imagePath: String?
        var aspectRatio: Double?
        switch asset.kind {
        case .video:
            path = asset.path
            fileDuration = (try? await AVURLAsset(url: ProjectFiles.url(asset.path)).load(.duration).seconds) ?? 0
            length = marked ?? fileDuration
        case .image:
            guard let package = ProjectFiles.package else { return }
            let imageURL = ProjectFiles.url(asset.path)
            let information = await Task.detached(priority: .userInitiated) {
                let information = ImageMediaFrameCache.shared.information(at: imageURL)
                _ = ImageMediaFrameCache.shared.frame(at: imageURL, time: 0)
                return information
            }.value
            guard let information else {
                throw CocoaError(.fileReadCorruptFile)
            }
            let still = try await StillVideoMaker.makeImageStandIn(into: package.appendingPathComponent("Inserted", isDirectory: true))
            path = ProjectFiles.portable(still.path)
            imagePath = asset.path
            aspectRatio = information.aspectRatio
            fileDuration = StillVideoMaker.fileDuration
            length = 3
        case .animation:
            guard HTMLMotion.isHTMLMotion(asset.path) else { return }
            let declared = HTMLMotion.declaredDuration(path: ProjectFiles.resolve(asset.path)) ?? 3
            let duration = marked ?? (declared.isFinite && declared > 0 ? max(declared, 0.2) : 3)
            _ = try await insertHTMLMotionOnMainTrack(path: asset.path, name: asset.name, at: time,
                duration: duration, usesFrameStyle: false, sound: nil, sourceDurations: sourceDurations)
            return
        default:
            return
        }
        guard fileDuration.isFinite, fileDuration > 0.1 else { return }
        if imagePath == nil,
           let track = try? await AVURLAsset(url: ProjectFiles.url(path)).loadTracks(withMediaType: .video).first,
           let size = try? await track.load(.naturalSize), let transform = try? await track.load(.preferredTransform) {
            let displayed = CGRect(origin: .zero, size: size).applying(transform)
            if abs(displayed.height) > 0 { aspectRatio = abs(displayed.width / displayed.height) }
        }
        let id = UUID()
        let timeline = try ProjectTimelineEditing.insertMediaSegment(
            in: project.timeline,
            media: InsertedMedia(path: path, fileDuration: fileDuration, name: asset.name,
                sourceAspectRatio: aspectRatio, imagePath: imagePath),
            atOutputTime: time,
            duration: length,
            newSegmentID: id,
            sourceDurations: sourceDurations,
            // A still stands in for itself, so only a real file has an in point.
            sourceStart: imagePath == nil ? max(sourceRange?.lowerBound ?? 0, 0) : 0
        )
        try replaceTimeline(with: timeline, actionName: "插入到主轨")
        selection = .primarySegment(id)
    }

    /// EDT-067: a black (or solid colour) card on the main track. Everything
    /// after it — subtitles, music, overlays, camera moves — moves later.
    func insertBlackOnMainTrack(at time: TimeInterval, duration: TimeInterval = 2, sourceDurations: [UUID: TimeInterval]) async throws {
        guard let package = ProjectFiles.package else { return }
        let file = try await StillVideoMaker.makeSolid(color: CGColor(gray: 0, alpha: 1),
                                                       into: package.appendingPathComponent("Inserted", isDirectory: true),
                                                       duration: StillVideoMaker.fileDuration)
        try insertMedia(InsertedMedia(path: ProjectFiles.portable(file.path), fileDuration: StillVideoMaker.fileDuration,
                                      name: appLocalized("黑场")),
                        at: time, duration: duration, sourceDurations: sourceDurations, actionName: "插入黑场")
    }

    /// EDT-071: an HTML motion on the main track, drawn live from its page in
    /// preview and export (no video is rendered), so its fields stay
    /// editable. A black stand-in gives the span its video track; the sound,
    /// if any, is the clip's own file and moves with it.
    func insertHTMLMotionOnMainTrack(path: String, name: String, at time: TimeInterval, duration: TimeInterval,
                                     usesFrameStyle: Bool, sound: URL?, sourceDurations: [UUID: TimeInterval]) async throws -> UUID {
        guard let package = ProjectFiles.package else { throw CocoaError(.fileNoSuchFile) }
        let folder = package.appendingPathComponent("Inserted", isDirectory: true)
        let standIn = try await StillVideoMaker.makeSolid(color: CGColor(gray: 0, alpha: 1), into: folder,
                                                          duration: max(duration, 0.2) + 0.1)
        do { try Task.checkCancellation() }
        catch {
            try? FileManager.default.removeItem(at: standIn)
            throw error
        }
        var soundPath: String?
        if let sound {
            let kept = folder.appendingPathComponent("sound-" + UUID().uuidString.prefix(6) + "." + sound.pathExtension)
            try FileManager.default.copyItem(at: sound, to: kept)
            soundPath = ProjectFiles.portable(kept.path)
        }
        return try insertMedia(InsertedMedia(path: ProjectFiles.portable(standIn.path), fileDuration: duration,
                                             name: name, usesFrameStyle: usesFrameStyle,
                                             motionPath: ProjectFiles.portable(path), soundPath: soundPath),
                               at: time, duration: duration, sourceDurations: sourceDurations, actionName: "插入开场")
    }

    /// EDT-071: one field of a main-track HTML motion (nil restores the
    /// page's own value).
    func setInsertedMotionProperty(_ id: UUID, name: String, value: AnimationPropertyValue?) {
        commitTimelineEdit(self, action: "调整动效参数") { timeline in
            guard case var .edited(segments) = timeline.sourceSequence,
                  let index = segments.firstIndex(where: { $0.id == id }), segments[index].media?.motionPath != nil else { return }
            segments[index].media?.properties[name] = value
            timeline.sourceSequence = .edited(segments)
        }
    }

    @discardableResult
    private func insertMedia(_ media: InsertedMedia, at time: TimeInterval, duration: TimeInterval,
                             sourceDurations: [UUID: TimeInterval], actionName: String) throws -> UUID {
        let id = UUID()
        let timeline = try ProjectTimelineEditing.insertMediaSegment(
            in: project.timeline, media: media, atOutputTime: time, duration: duration,
            newSegmentID: id, sourceDurations: sourceDurations)
        try replaceTimeline(with: timeline, actionName: actionName)
        selection = .primarySegment(id)
        return id
    }

    /// EDT-067: whether a main-track insert fills the canvas or sits inside
    /// the recording's frame styling.
    func setInsertedSegmentUsesFrameStyle(_ id: UUID, _ value: Bool) {
        guard case var .edited(segments) = project.timeline.sourceSequence,
              let index = segments.firstIndex(where: { $0.id == id }), segments[index].media != nil else { return }
        segments[index].media?.usesFrameStyle = value
        var timeline = project.timeline
        timeline.sourceSequence = .edited(segments)
        try? replaceTimeline(with: timeline, actionName: value ? "应用画面样式" : "全屏显示")
    }

    /// EDT-054: an overlay video at the playhead, sized to its own aspect.
    func addVideoClip(sourcePath: String, at time: TimeInterval, outputDuration: TimeInterval,
                      sourceRange: ClosedRange<TimeInterval>? = nil) async throws -> UUID {
        let asset = AVURLAsset(url: ProjectFiles.url(sourcePath))
        let fileDuration = (try? await asset.load(.duration).seconds) ?? 5
        var aspect = 9.0 / 16.0
        if let track = try? await asset.loadTracks(withMediaType: .video).first,
           let size = try? await track.load(.naturalSize),
           let transform = try? await track.load(.preferredTransform) {
            let rect = CGRect(origin: .zero, size: size).applying(transform)
            if rect.width > 0 { aspect = abs(rect.height) / abs(rect.width) }
        }
        let start = min(max(time, 0), max(outputDuration - 0.25, 0))
        let whole = fileDuration.isFinite && fileDuration > 0 ? fileDuration : 5
        let wanted = sourceRange.map { max($0.upperBound - $0.lowerBound, 0.05) } ?? whole
        let length = max(min(wanted, outputDuration - start), 0.25)
        let canvasAspect = PreviewSnapshot.latest.map { Double($0.extent.height / max($0.extent.width, 1)) } ?? (9.0 / 16.0)
        // Full width when it fits the frame, otherwise full height.
        let width = aspect <= canvasAspect ? 1 : canvasAspect / aspect
        let timing = OverlayTiming(startTime: start, duration: length)
        let clip = VideoClip(
            timing: timing,
            sourcePath: sourcePath,
            sourceStart: max(sourceRange?.lowerBound ?? 0, 0),
            width: width,
            aspect: aspect,
            layerIndex: project.timeline.visualLayer(for: timing)
        )
        var timeline = project.timeline
        timeline.videoClips.append(clip)
        try replaceTimeline(with: timeline, actionName: "添加视频")
        selection = .videoClip(clip.id)
        return clip.id
    }

    /// Replaces every subtitle at once (AI generation, SRT import).
    func replaceSubtitles(_ cues: [SubtitleCue], actionName: String = "更新字幕") throws {
        var timeline = project.timeline
        if timeline.subtitleCues.isEmpty, !cues.isEmpty, timeline.subtitleStyle == .legacyDefault {
            timeline.subtitleStyle = SubtitleStyle()
        }
        timeline.subtitleCues = cues.sorted { $0.timing.startTime < $1.timing.startTime }
        try replaceTimeline(with: timeline, actionName: actionName)
        if let first = timeline.subtitleCues.first { selection = .subtitle(first.id) }
    }
}

struct EditorAudioClipInspector: View {
    @ObservedObject var editorStore: EditorStore
    let clipID: UUID

    private var clip: AudioClip? {
        editorStore.previewProject.timeline.audioClips.first { $0.id == clipID }
    }

    private func audioSlider(_ title: String, _ keyPath: WritableKeyPath<AudioClip, Double>,
                             _ range: ClosedRange<Double>, _ format: EditorSliderValueFormat) -> some View {
        let id = clipID
        return timelineSlider(editorStore, title, range, format: format,
            get: { $0.audioClips.first { $0.id == id }?[keyPath: keyPath] ?? 0 },
            set: { timeline, value in
                guard let i = timeline.audioClips.firstIndex(where: { $0.id == id }) else { return }
                timeline.audioClips[i][keyPath: keyPath] = value
            })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: EditorInterfaceSpacing.sectionGap) {
            if let clip {
                Text(URL(fileURLWithPath: clip.sourcePath).lastPathComponent)
                    .font(EditorTypography.helper).foregroundStyle(EditorTheme.tertiaryText)
                    .lineLimit(1).truncationMode(.middle)
                EditorInspectorSection("类型") {
                    EditorSegmentedControl(
                        options: [AudioClipKind.music, .effect],
                        title: { appLocalized($0 == .music ? "音乐" : "音效") },
                        selection: Binding(
                            get: { clip.kind },
                            set: { kind in
                                commitTimelineEdit(editorStore, action: "更改音频类型") { timeline in
                                    guard let i = timeline.audioClips.firstIndex(where: { $0.id == clipID }) else { return }
                                    timeline.audioClips[i].kind = kind
                                }
                            }
                        )
                    )
                }
                EditorInspectorSection("音量") {
                    audioSlider("音量", \.volume, 0...1, .percent)
                    EditorToggle(isOn: Binding(
                        get: { clip.isMuted },
                        set: { value in
                            commitTimelineEdit(editorStore, action: "切换音频静音") { timeline in
                                guard let i = timeline.audioClips.firstIndex(where: { $0.id == clipID }) else { return }
                                timeline.audioClips[i].isMuted = value
                            }
                        }
                    ), title: "静音")
                    EditorToggle(isOn: Binding(
                        get: { clip.ducksUnderSpeech },
                        set: { value in
                            commitTimelineEdit(editorStore, action: "切换人声避让") { timeline in
                                guard let i = timeline.audioClips.firstIndex(where: { $0.id == clipID }) else { return }
                                timeline.audioClips[i].ducksUnderSpeech = value
                            }
                        }
                    ), title: "有人说话时自动压低")
                }
                EditorInspectorSection("进入与退出") {
                    audioSlider("淡入", \.fadeIn, 0...5, .seconds)
                    audioSlider("淡出", \.fadeOut, 0...5, .seconds)
                }
                Button(role: .destructive) {
                    do { try editorStore.removeSelectedOverlay(actionName: "删除音频") }
                    catch { editorStore.reportError?(error.localizedDescription) }
                } label: { Text(appLocalized("删除音频")) }
                .buttonStyle(.editorDestructive)
            }
        }
    }
}

extension EditorStore {
    /// A new subtitle at the playhead (two seconds, never overlapping).
    func addSubtitleAtPlayhead() {
        let duration = outputDuration()
        var start = min(max(playheadTime(), 0), max(duration - 0.3, 0))
        let cues = project.timeline.subtitleCues
        if let current = cues.first(where: { $0.timing.contains(start) }) { start = current.timing.endTime }
        var end = min(start + 2, duration)
        if let next = cues.first(where: { $0.timing.startTime > start }) { end = min(end, next.timing.startTime) }
        guard end - start > 0.1 else { return }
        let cue = SubtitleCue(timing: OverlayTiming(startTime: start, duration: end - start), text: appLocalized("新字幕"))
        var timeline = project.timeline
        timeline.subtitleCues.append(cue)
        timeline.subtitleCues.sort { $0.timing.startTime < $1.timing.startTime }
        try? replaceTimeline(with: timeline, actionName: "添加字幕")
        selection = .subtitle(cue.id)
    }

    func importSRT() {
        AppFilePanel.open(configure: { panel in
            panel.allowedContentTypes = [UTType(filenameExtension: "srt") ?? .plainText]
        }) { urls in
            guard let url = urls?.first,
                  let text = try? String(contentsOf: url, encoding: .utf8) else { return }
            try? self.replaceSubtitles(SubtitleSRT.decode(text), actionName: "导入字幕")
        }
    }

    func exportSRT() {
        let cues = project.timeline.subtitleCues
        let title = project.title
        Task { @MainActor in
            guard let url = await AppFilePanel.save(configure: { panel in
                panel.allowedContentTypes = [UTType(filenameExtension: "srt") ?? .plainText]
                panel.nameFieldStringValue = "\(title).srt"
            }) else { return }
            try? SubtitleSRT.encode(cues).write(to: url, atomically: true, encoding: .utf8)
            if cues.contains(where: { $0.secondaryText?.isEmpty == false }) {
                let second = url.deletingPathExtension().appendingPathExtension("secondary.srt")
                try? SubtitleSRT.encode(cues, secondary: true).write(to: second, atomically: true, encoding: .utf8)
            }
        }
    }

}

/// The look shared by every subtitle. Lives on the left 字幕 page beside the
/// lines it styles; the right inspector stays free for the picture.
struct EditorSubtitleStyleControls: View {
    @ObservedObject var editorStore: EditorStore
    @State private var showsFonts = false

    private var style: SubtitleStyle { editorStore.previewProject.timeline.subtitleStyle }

    private func styleSlider(_ title: String, _ keyPath: WritableKeyPath<SubtitleStyle, Double>,
                             _ range: ClosedRange<Double>) -> some View {
        timelineSlider(editorStore, title, range, format: .percent,
            get: { $0.subtitleStyle[keyPath: keyPath] },
            set: { timeline, value in timeline.subtitleStyle[keyPath: keyPath] = value })
    }

    private func setStyle(_ action: String, _ body: @escaping (inout SubtitleStyle) -> Void) {
        commitTimelineEdit(editorStore, action: action) { body(&$0.subtitleStyle) }
    }

    private var fontName: String {
        style.fontFamily ?? {
            switch style.font {
            case .system: appLocalized("系统默认")
            case .rounded: appLocalized("系统圆体")
            case .serif: appLocalized("系统衬线")
            case .mono: appLocalized("系统等宽")
            }
        }()
    }

    private var colorBinding: Binding<HexColor> {
        Binding(
            get: { editorStore.previewProject.timeline.subtitleStyle.textColor },
            set: { color in editorStore.updateInteraction { $0.timeline.subtitleStyle.textColor = color } }
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Button { showsFonts = true } label: {
                    HStack {
                        Text(fontName).lineLimit(1)
                        Spacer(minLength: 4)
                        AppLineIcon(kind: .chevronDown, size: 9)
                            .foregroundStyle(EditorTheme.secondaryText)
                    }
                    .font(EditorTypography.controlLabel)
                    .foregroundStyle(EditorTheme.primaryText)
                    .padding(.horizontal, 8)
                    .frame(height: 28)
                    .background(EditorTheme.controlWell, in: RoundedRectangle(cornerRadius: EditorInterfaceRadius.control, style: .continuous))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(appLocalized("字体"))
                .editorPopover(isPresented: $showsFonts, arrowEdge: .trailing) {
                    FontFamilyPicker(selected: style.fontFamily) { family in
                        setStyle("更改字幕字体") { $0.fontFamily = family }
                    }
                }
                Button { setStyle("切换字幕粗体") { $0.bold.toggle() } } label: {
                    Text("B")
                        .font(.appUI(size: 13, weight: .bold))
                        .frame(width: 28, height: 28)
                        .background(style.bold ? EditorTheme.selectionWash : EditorTheme.controlWell,
                                    in: RoundedRectangle(cornerRadius: EditorInterfaceRadius.control, style: .continuous))
                }
                .buttonStyle(.plain)
                .foregroundStyle(EditorTheme.primaryText)
                .help(appLocalized("粗体"))
                .accessibilityLabel(appLocalized("粗体"))
                .accessibilityAddTraits(style.bold ? .isSelected : [])
            }
            EditorTransactionalColorInput(
                editorStore: editorStore,
                title: "文字颜色",
                value: colorBinding,
                commandScope: .selection,
                actionName: "更改字幕颜色",
                onError: { editorStore.reportError?($0) }
            )
            styleSlider("字号", \.fontScale, 0.02...0.09)
            styleSlider("底框", \.backgroundOpacity, 0...1)
            styleSlider("离底部", \.bottomMargin, 0.02...0.6)
            EditorSegmentedControl(
                options: SubtitleEntrance.allCases,
                title: { entrance in
                    switch entrance {
                    case .none: appLocalized("无")
                    case .fade: appLocalized("淡入")
                    case .rise: appLocalized("上浮")
                    case .pop: appLocalized("弹出")
                    case .typewriter: appLocalized("打字")
                    }
                },
                selection: Binding(get: { style.entrance }, set: { value in setStyle("更改字幕动画") { $0.entrance = value } })
            )
            EditorToggle(isOn: Binding(
                get: { style.showsSecondary },
                set: { value in setStyle("切换第二语言") { $0.showsSecondary = value } }
            ), title: "显示第二语言")
        }
    }
}

/// Right inspector for a selected subtitle: its words (and second
/// language), its time, and the style shared by every subtitle.
struct EditorSubtitleInspector: View {
    @ObservedObject var editorStore: EditorStore
    let selectedID: UUID?

    private func setText(_ id: UUID, _ value: String, secondary: Bool) {
        var timeline = editorStore.project.timeline
        guard let i = timeline.subtitleCues.firstIndex(where: { $0.id == id }) else { return }
        if secondary { timeline.subtitleCues[i].secondaryText = value.isEmpty ? nil : value }
        else { timeline.subtitleCues[i].text = value }
        do { try editorStore.replaceTimeline(with: timeline, actionName: "编辑字幕") }
        catch { editorStore.reportError?(error.localizedDescription) }
    }

    private var cue: SubtitleCue? {
        editorStore.previewProject.timeline.subtitleCues.first { $0.id == selectedID }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: EditorInterfaceSpacing.sectionGap) {
            if let cue {
                EditorInspectorSection("字幕") {
                    EditorCommittingTextField(
                        title: appLocalized("文字"),
                        text: cue.text,
                        onCommit: { value in setText(cue.id, value, secondary: false) }
                    )
                    .id("text-\(cue.id)-\(cue.text)")
                    if editorStore.previewProject.timeline.subtitleStyle.showsSecondary {
                        EditorCommittingTextField(
                            title: appLocalized("第二语言"),
                            text: cue.secondaryText ?? "",
                            onCommit: { value in setText(cue.id, value, secondary: true) }
                        )
                        .id("secondary-\(cue.id)-\(cue.secondaryText ?? "")")
                    }
                    Text(SubtitleSRTDisplay.time(cue.timing.startTime) + " – " + SubtitleSRTDisplay.time(cue.timing.endTime))
                        .font(EditorTypography.helper.monospacedDigit())
                        .foregroundStyle(EditorTheme.tertiaryText)
                }
                EditorInspectorSection("全部字幕的样式") {
                    EditorSubtitleStyleControls(editorStore: editorStore)
                }
                Button(role: .destructive) {
                    do { try editorStore.removeSelectedOverlay(actionName: "删除字幕") }
                    catch { editorStore.reportError?(error.localizedDescription) }
                } label: { Text(appLocalized("删除字幕")) }
                .buttonStyle(.editorDestructive)
            }
        }
    }
}

/// Enumerate fonts away from the menu's first render. Core Text is safe to
/// query on a background task; NSFontManager's initial catalog lookup was
/// blocking the main thread before the popover could appear.
@MainActor
final class EditorFontFamilyCatalog: ObservableObject {
    static let shared = EditorFontFamilyCatalog()
    @Published private(set) var families: [String] = []
    private var task: Task<Void, Never>?

    func prepare() {
        guard task == nil else { return }
        task = Task {
            let names = await Task.detached(priority: .userInitiated) {
                (CTFontManagerCopyAvailableFontFamilyNames() as? [String] ?? [])
                    .filter { !$0.hasPrefix(".") }
                    .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
            }.value
            families = names
        }
    }
}

/// Every installed font family, searchable, each shown in its own face.
struct FontFamilyPicker: View {
    let selected: String?
    var defaultTitle = "系统默认"
    let onPick: (String?) -> Void
    @State private var query = ""
    @ObservedObject private var catalog = EditorFontFamilyCatalog.shared

    private var results: [String] {
        query.isEmpty ? catalog.families : catalog.families.filter { $0.localizedCaseInsensitiveContains(query) }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                EditorSymbol("magnifyingglass", size: 11).font(.system(size: 11)).foregroundStyle(EditorTheme.secondaryText)
                TextField(appLocalized("搜索字体"), text: $query).textFieldStyle(.plain).font(.appUI(size: 12))
            }
            .padding(10)
            Rectangle().fill(EditorTheme.hairline).frame(height: 1)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    row(nil, title: appLocalized(defaultTitle))
                    ForEach(results, id: \.self) { family in
                        row(family, title: family)
                    }
                }
                .padding(4)
            }
        }
        .frame(width: 260, height: 360)
        .task { catalog.prepare() }
    }

    private func row(_ family: String?, title: String) -> some View {
        let isSelected = family == selected
        return Button { onPick(family) } label: {
            HStack {
                Text(title).font(family.map { .custom($0, size: 13) } ?? .appUI(size: 13)).lineLimit(1)
                Spacer(minLength: 4)
                if isSelected { EditorSymbol("checkmark", size: 10).font(.system(size: 10, weight: .bold)) }
            }
            .foregroundStyle(EditorTheme.primaryText)
            .padding(.horizontal, 8)
            .frame(height: 28)
            .background(RoundedRectangle(cornerRadius: 6).fill(isSelected ? EditorTheme.chrome(0.07) : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// Left 字幕 page: add subtitles, bring them in or out, ask the AI, proofread
/// every line in one list, and set the look all subtitles share.
struct EditorTextLibrary: View {
    @ObservedObject var editorStore: EditorStore
    @ObservedObject private var timelinePreview: EditorTimelineInteractionState
    let onAskAI: () -> Void
    @AppStorage("editor.subtitles.styleExpanded") private var showsStyle = false

    init(editorStore: EditorStore, onAskAI: @escaping () -> Void) {
        self.editorStore = editorStore
        self.onAskAI = onAskAI
        _timelinePreview = ObservedObject(wrappedValue: editorStore.timelinePreview)
    }

    private var cues: [SubtitleCue] { editorStore.previewProject.timeline.subtitleCues }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 6) {
                Button { editorStore.addSubtitleAtPlayhead() } label: {
                    HStack(spacing: 5) {
                        AppLineIcon(kind: .plus, size: 12)
                        Text(appLocalized("在播放头添加"))
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.editorQuiet)
                EditorActionMenu(title: "更多字幕操作", items: [
                    .action("用 AI 生成字幕", systemImage: "sparkles") { onAskAI() },
                    .action("整理字幕", systemImage: "wand.and.stars", detail: "整理文字，保留字幕时间",
                            isEnabled: !cues.isEmpty) { tidy() },
                    .action("对齐语音", systemImage: "waveform", detail: "微调字幕两端的短暂静音",
                            isEnabled: !cues.isEmpty) { alignToSpeech() },
                    .separator,
                    .action("导入 SRT…", systemImage: "square.and.arrow.down") { editorStore.importSRT() },
                    .action("导出 SRT…", systemImage: "square.and.arrow.up", isEnabled: !cues.isEmpty) { editorStore.exportSRT() }
                ]) {
                    EditorToolbarIconSurface(systemName: "ellipsis")
                        .background(EditorTheme.controlWell, in: RoundedRectangle(cornerRadius: EditorInterfaceRadius.control, style: .continuous))
                }
            }

            EditorDisclosure("全部字幕的样式", expanded: $showsStyle) {
                EditorSubtitleStyleControls(editorStore: editorStore)
            }

            if cues.isEmpty {
                VStack(spacing: 6) {
                    Text(appLocalized("还没有字幕"))
                        .font(.appUI(size: 13, weight: .medium))
                        .foregroundStyle(EditorTheme.secondaryText)
                    Text(appLocalized("在播放头添加，或用 AI 从语音生成"))
                        .font(EditorTypography.helper)
                        .foregroundStyle(EditorTheme.tertiaryText)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 28)
            } else {
                LazyVStack(spacing: 2) {
                    ForEach(cues) { cue in
                        EditorSubtitleLine(editorStore: editorStore, cue: cue,
                                           selected: editorStore.selection == .subtitle(cue.id))
                            .equatable()
                    }
                }
            }
        }
    }

    private func tidy() {
        do { try editorStore.replaceSubtitles(SubtitleText.normalized(cues), actionName: "整理字幕") }
        catch { editorStore.reportError?(error.localizedDescription) }
    }

    private func alignToSpeech() {
        Task { @MainActor in
            do { _ = try await AgentBridgeServer.shared.perform("subtitles.alignToSpeech", [:]) }
            catch { editorStore.reportError?(error.localizedDescription) }
        }
    }
}

/// One subtitle line. Typing previews live (canvas and inspector follow
/// each keystroke) and is written to the project once, when focus leaves,
/// as one undo step. Return with the caret inside the text splits the line
/// there into two, timed from the speech; clicking a line moves the
/// playhead to it.
private struct EditorSubtitleLine: View, @MainActor Equatable {
    let editorStore: EditorStore
    let cue: SubtitleCue
    let selected: Bool
    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.editorStore === rhs.editorStore && lhs.cue == rhs.cue && lhs.selected == rhs.selected
    }

    @State private var draft: String?
    @State private var hovered = false

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(SubtitleSRTDisplay.time(cue.timing.startTime))
                .font(.appUI(size: 13).monospacedDigit())
                .foregroundStyle(EditorTheme.tertiaryText)
                .frame(width: 64, alignment: .leading)
            SubtitleLineField(
                text: Binding(get: { draft ?? cue.text }, set: { value in
                    draft = value
                    preview(value)
                }),
                onSplit: split,
                onCommit: commit,
                onFocus: { isFocused in
                    if isFocused { select() } else { commit() }
                })
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 9)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
            .fill(selected ? EditorTheme.controlWell : EditorTheme.controlWell.opacity(hovered ? 0.55 : 0)))
        .contentShape(Rectangle())
        .onHover { hovered = $0 }
        .animation(.easeOut(duration: 0.12), value: hovered)
        .onTapGesture(perform: select)
        .onDisappear(perform: commit)
    }

    /// Splits a translation at about `share` of its length, on the closest
    /// break (space or punctuation) so words stay whole. Either half can be
    /// nil when the translation is too short to split.
    static func splitSecondary(_ text: String, share: Double) -> (String?, String?) {
        let chars = Array(text)
        guard chars.count > 1 else { return (text.isEmpty ? nil : text, nil) }
        let target = Int((Double(chars.count) * share).rounded())
        let breaks = chars.indices.filter { i in
            i > 0 && i < chars.count && (chars[i] == " " || ",.;:!?，。；：！？、".contains(chars[i - 1]))
        }
        let cut = breaks.min { abs($0 - target) < abs($1 - target) } ?? min(max(target, 1), chars.count - 1)
        let head = String(chars[..<cut]).trimmingCharacters(in: .whitespaces)
        let tail = String(chars[cut...]).trimmingCharacters(in: .whitespaces)
        return (head.isEmpty ? nil : head, tail.isEmpty ? nil : tail)
    }

    /// Selecting a line puts the playhead on it, so the picture shows it.
    private func select() {
        if editorStore.selection != .subtitle(cue.id) { editorStore.selection = .subtitle(cue.id) }
        let t = editorStore.playheadTime()
        if t < cue.timing.startTime || t >= cue.timing.endTime {
            editorStore.seekPlayhead(cue.timing.startTime + 0.01)
        }
    }

    /// The draft shows on the canvas and in the inspector as it is typed.
    private func preview(_ value: String) {
        let id = cue.id
        if editorStore.interaction?.selection != .subtitle(id) {
            editorStore.beginInteraction(tool: .select, selection: .subtitle(id),
                                         replacementPolicy: .commit(actionName: "编辑字幕"))
        }
        editorStore.updateTimelineInteraction { project in
            guard let i = project.timeline.subtitleCues.firstIndex(where: { $0.id == id }) else { return }
            project.timeline.subtitleCues[i].text = value
        }
    }

    private func commit() {
        guard draft != nil else { return }
        draft = nil
        guard editorStore.interaction?.selection == .subtitle(cue.id) else { return }
        do { _ = try editorStore.commitInteraction(actionName: "编辑字幕") }
        catch {
            editorStore.cancelInteraction()
            editorStore.reportError?(error.localizedDescription)
        }
    }

    /// Splits at the caret into two lines with matching times.
    private func split(at offset: Int) {
        let text = draft ?? cue.text
        guard offset > 0, offset < text.count else { return }
        let head = String(text.prefix(offset)).trimmingCharacters(in: .whitespaces)
        let tail = String(text.dropFirst(offset)).trimmingCharacters(in: .whitespaces)
        guard !head.isEmpty, !tail.isEmpty else { return }
        draft = nil
        editorStore.cancelInteraction()
        var timeline = editorStore.project.timeline
        guard let i = timeline.subtitleCues.firstIndex(where: { $0.id == cue.id }) else { return }
        var original = timeline.subtitleCues[i]
        original.text = text
        let at = AgentBridgeServer.shared.splitTime(for: original, atCharacter: offset)
        var first = original
        first.text = head
        first.timing = OverlayTiming(startTime: original.timing.startTime, duration: max(at - original.timing.startTime, 0.1))
        // The second language is split too, at the same share of its text,
        // nudged to the nearest space or punctuation so no word is cut.
        let secondary = original.secondaryText.map { Self.splitSecondary($0, share: Double(offset) / Double(max(text.count, 1))) }
        first.secondaryText = secondary?.0
        let second = SubtitleCue(timing: OverlayTiming(startTime: at, duration: max(original.timing.endTime - at, 0.1)),
                                 text: tail, secondaryText: secondary?.1)
        timeline.subtitleCues[i] = first
        timeline.subtitleCues.insert(second, at: i + 1)
        do {
            try editorStore.replaceTimeline(with: timeline, actionName: "拆分字幕")
            editorStore.selection = .subtitle(second.id)
        } catch { editorStore.reportError?(error.localizedDescription) }
    }
}

/// An AppKit text field: it knows the caret, so Return can split there, and
/// keeps its own typing undo while it has focus.
private struct SubtitleLineField: NSViewRepresentable {
    @Binding var text: String
    let onSplit: (Int) -> Void
    let onCommit: () -> Void
    let onFocus: (Bool) -> Void

    func makeNSView(context: Context) -> NSTextField {
        let field = SplittingTextField()
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.lineBreakMode = .byWordWrapping
        field.usesSingleLineMode = false
        field.cell?.wraps = true
        field.cell?.isScrollable = false
        field.font = NSFont(name: "AlibabaPuHuiTi_3_55_Regular", size: 14) ?? .systemFont(ofSize: 14)
        field.textColor = NSColor(EditorTheme.primaryText)
        field.delegate = context.coordinator
        field.stringValue = text
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return field
    }

    func updateNSView(_ field: NSTextField, context: Context) {
        context.coordinator.parent = self
        if field.currentEditor() == nil, field.stringValue != text { field.stringValue = text }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSTextField, context: Context) -> CGSize? {
        let width = proposal.width ?? 200
        let height = nsView.cell?.cellSize(forBounds: NSRect(x: 0, y: 0, width: width, height: 1000)).height ?? 18
        return CGSize(width: width, height: max(height, 18))
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: SubtitleLineField
        init(_ parent: SubtitleLineField) { self.parent = parent }

        func controlTextDidBeginEditing(_ obj: Notification) { parent.onFocus(true) }
        func controlTextDidEndEditing(_ obj: Notification) { parent.onFocus(false) }
        func controlTextDidChange(_ obj: Notification) {
            guard let field = obj.object as? NSTextField else { return }
            parent.text = field.stringValue
        }

        /// Return splits the line at the caret into two lines (at either end
        /// it just finishes the edit). ⌥Return or ⇧Return inserts nothing and
        /// finishes too.
        func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            guard selector == #selector(NSResponder.insertNewline(_:))
                    || selector == #selector(NSResponder.insertNewlineIgnoringFieldEditor(_:)) else { return false }
            let location = textView.selectedRange().location
            let text = textView.string
            let offset = (text as NSString).substring(to: min(location, (text as NSString).length)).count
            let modifiers = NSEvent.modifierFlags.intersection([.option, .shift])
            if modifiers.isEmpty, offset > 0, offset < text.count {
                parent.text = text
                DispatchQueue.main.async { [parent] in parent.onSplit(offset) }
            } else {
                parent.onCommit()
            }
            control.window?.makeFirstResponder(nil)
            return true
        }
    }
}

private final class SplittingTextField: NSTextField {
    override var acceptsFirstResponder: Bool { true }
}

enum SubtitleSRTDisplay {
    static func time(_ t: TimeInterval) -> String {
        let total = Int(max(t, 0) * 100)
        return String(format: "%02d:%02d.%02d", total / 6000, total / 100 % 60, total % 100)
    }
}

/// The editor's own bar slider for post-production values: live preview while
/// dragging, one undo step on release, double-click for precise entry.
@MainActor
func timelineSlider(
    _ store: EditorStore,
    _ title: String,
    _ range: ClosedRange<Double>,
    format: EditorSliderValueFormat,
    get: @escaping (ProjectTimeline) -> Double,
    set: @escaping (inout ProjectTimeline, Double) -> Void
) -> some View {
    EditorTransactionalSliderRow(
        editorStore: store,
        title: title,
        value: Binding(
            get: { get(store.previewProject.timeline) },
            set: { value in store.updateInteraction { set(&$0.timeline, value) } }
        ),
        range: range,
        commandScope: .selection,
        format: format,
        onError: { store.reportError?($0) }
    )
}

struct EditorVideoClipInspector: View {
    @ObservedObject var editorStore: EditorStore
    let clipID: UUID

    private var clip: VideoClip? {
        editorStore.previewProject.timeline.videoClips.first { $0.id == clipID }
    }

    private func slider(_ title: String, _ keyPath: WritableKeyPath<VideoClip, Double>,
                        _ range: ClosedRange<Double>, _ format: EditorSliderValueFormat = .percent) -> some View {
        let id = clipID
        return timelineSlider(editorStore, title, range, format: format,
            get: { $0.videoClips.first { $0.id == id }?[keyPath: keyPath] ?? 0 },
            set: { timeline, value in
                guard let i = timeline.videoClips.firstIndex(where: { $0.id == id }) else { return }
                timeline.videoClips[i][keyPath: keyPath] = value
            })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: EditorInterfaceSpacing.sectionGap) {
            if let clip {
                Text(URL(fileURLWithPath: clip.sourcePath).lastPathComponent)
                    .font(EditorTypography.helper).foregroundStyle(EditorTheme.tertiaryText)
                    .lineLimit(1).truncationMode(.middle)
                EditorInspectorSection("布局") {
                    HStack(spacing: 8) {
                        Button { place(width: 1, x: 0.5, y: 0.5) } label: { Text(appLocalized("铺满")).frame(maxWidth: .infinity) }
                        Button { place(width: 0.32, x: 0.78, y: 0.76) } label: { Text(appLocalized("画中画")).frame(maxWidth: .infinity) }
                    }
                    .buttonStyle(.editorQuiet)
                    EditorTransactionalPositionPad(
                        editorStore: editorStore,
                        title: "位置",
                        point: positionBinding,
                        commandScope: .selection,
                        selection: .videoClip(clipID),
                        actionName: "移动视频",
                        onError: { editorStore.reportError?($0) }
                    )
                    slider("大小", \.width, 0.1...1.5)
                }
                EditorInspectorSection("外观") {
                    slider("不透明度", \.opacity, 0...1)
                    slider("音量", \.volume, 0...1)
                }
                Button(role: .destructive) {
                    do { try editorStore.removeSelectedOverlay(actionName: "删除视频") }
                    catch { editorStore.reportError?(error.localizedDescription) }
                } label: { Text(appLocalized("删除视频")) }
                .buttonStyle(.editorDestructive)
            }
        }
    }

    private var positionBinding: Binding<NormalizedPoint> {
        let id = clipID
        return Binding(
            get: { editorStore.previewProject.timeline.videoClips.first { $0.id == id }?.position ?? NormalizedPoint(x: 0.5, y: 0.5) },
            set: { value in
                editorStore.updateInteraction { project in
                    guard let i = project.timeline.videoClips.firstIndex(where: { $0.id == id }) else { return }
                    project.timeline.videoClips[i].position = value
                }
            }
        )
    }

    private func place(width: Double, x: Double, y: Double) {
        commitTimelineEdit(editorStore, action: "调整视频位置") { timeline in
            guard let i = timeline.videoClips.firstIndex(where: { $0.id == clipID }) else { return }
            timeline.videoClips[i].width = width
            timeline.videoClips[i].position = NormalizedPoint(x: x, y: y)
        }
    }
}

/// Turns a still image into a short constant video so it can sit on the main
/// track like any other clip (and be trimmed up to `fileDuration`).
enum StillVideoMaker {
    static let fileDuration: TimeInterval = 60

    /// Only supplies a video clock. Original image/GIF pixels are composited
    /// directly, so dropping an image does not encode 60 seconds of pictures.
    static func makeImageStandIn(into folder: URL, duration: TimeInterval = fileDuration) async throws -> URL {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let output = folder.appendingPathComponent("image-clock-" + UUID().uuidString.prefix(8) + ".mov")
        do {
            try await write(to: output, width: 16, height: 16, fps: 1, duration: duration) { context, _ in
                context.setFillColor(CGColor(gray: 0, alpha: 1))
                context.fill(CGRect(x: 0, y: 0, width: 16, height: 16))
            }
            return output
        } catch {
            try? FileManager.default.removeItem(at: output)
            throw error
        }
    }

    /// A solid colour clip (black by default), small and cheap to decode.
    static func makeSolid(color: CGColor, into folder: URL, duration: TimeInterval) async throws -> URL {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let output = folder.appendingPathComponent("black-" + UUID().uuidString.prefix(6) + ".mov")
        do {
            try await write(to: output, width: 1920, height: 1080, fps: 5, duration: duration) { context, _ in
                context.setFillColor(color)
                context.fill(CGRect(x: 0, y: 0, width: 1920, height: 1080))
            }
            return output
        } catch {
            try? FileManager.default.removeItem(at: output)
            throw error
        }
    }

    /// Joins the rendered picture with its soundtrack into one file, so the
    /// clip's sound moves, trims and deletes with it on the main track.
    private static func mux(video: URL, audio: URL, duration: TimeInterval, to output: URL) async throws {
        let composition = AVMutableComposition()
        let range = CMTimeRange(start: .zero, duration: CMTime(seconds: duration, preferredTimescale: 600))
        let videoAsset = AVURLAsset(url: video), audioAsset = AVURLAsset(url: audio)
        if let track = try await videoAsset.loadTracks(withMediaType: .video).first,
           let destination = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) {
            try destination.insertTimeRange(range, of: track, at: .zero)
        }
        if let track = try await audioAsset.loadTracks(withMediaType: .audio).first,
           let destination = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) {
            let audioDuration = try await audioAsset.load(.duration)
            try destination.insertTimeRange(CMTimeRange(start: .zero, duration: min(audioDuration, range.duration)), of: track, at: .zero)
        }
        guard let export = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetPassthrough) else {
            throw CocoaError(.fileWriteUnknown)
        }
        try? FileManager.default.removeItem(at: output)
        try await export.export(to: output, as: .mov)
    }

    /// One H.264 file, drawing each frame with `draw` (time in seconds).
    private static func write(to output: URL, width: Int, height: Int, fps: Int32, duration: TimeInterval,
                              draw: (CGContext, Double) -> Void) async throws {
        let writer = try AVAssetWriter(outputURL: output, fileType: .mov)
        defer { if writer.status == .writing { writer.cancelWriting() } }
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: width, AVVideoHeightKey: height,
        ])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width, kCVPixelBufferHeightKey as String: height,
        ])
        writer.add(input)
        writer.startWriting()
        writer.startSession(atSourceTime: .zero)
        let frames = max(Int((duration * Double(fps)).rounded(.up)), 1)
        for frame in 0...frames {
            try Task.checkCancellation()
            var buffer: CVPixelBuffer?
            CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_32BGRA, nil, &buffer)
            guard let buffer else { throw CocoaError(.fileWriteUnknown) }
            CVPixelBufferLockBaseAddress(buffer, [])
            if let context = CGContext(data: CVPixelBufferGetBaseAddress(buffer), width: width, height: height,
                                       bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
                                       space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                       bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue) {
                draw(context, Double(frame) / Double(fps))
            }
            CVPixelBufferUnlockBaseAddress(buffer, [])
            while !input.isReadyForMoreMediaData { try await Task.sleep(for: .milliseconds(2)) }
            adaptor.append(buffer, withPresentationTime: CMTime(value: CMTimeValue(frame), timescale: fps))
        }
        input.markAsFinished()
        await writer.finishWriting()
        try Task.checkCancellation()
        guard writer.status == .completed else { throw writer.error ?? CocoaError(.fileWriteUnknown) }
    }

}
