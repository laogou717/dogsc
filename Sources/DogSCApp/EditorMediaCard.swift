import AVFoundation
import AppKit
import RecorderCore
import SwiftUI

/// The thumbnail owns its height. Overlay controls never stretch a grid row.
struct EditorMediaThumbnail<Content: View>: View {
    var selected = false
    /// A bin that no longer has focus keeps its selection, the way a list
    /// does, but stops wearing the accent: an accent ring on a card the
    /// keyboard no longer talks to reads as "this is what you are editing".
    var isFocused = true
    @ViewBuilder let content: () -> Content

    var body: some View {
        Rectangle().fill(EditorTheme.controlWell)
            .aspectRatio(1.6, contentMode: .fit)
            .overlay { content() }
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay {
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(selected ? (isFocused ? EditorTheme.accent : EditorTheme.chrome(0.22)) : .clear,
                                  lineWidth: 1.5)
            }
    }
}

struct EditorMediaTimeBadge: View {
    let text: String
    var body: some View {
        Text(text).font(.system(size: 10.5, design: .monospaced))
            .foregroundStyle(.white).padding(.horizontal, 4).padding(.vertical, 1)
            .background(.black.opacity(0.35), in: RoundedRectangle(cornerRadius: 4))
    }
}

/// Shared quick actions for recordings and ordinary library assets.
struct EditorMediaCornerButton: View {
    let symbol: String
    let help: String
    var tint: Color = .white
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            EditorSymbol(symbol, size: 9)
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(tint)
                .frame(width: EditorMediaCardActions.size, height: EditorMediaCardActions.size)
                .background(RoundedRectangle(cornerRadius: EditorInterfaceRadius.control, style: .continuous)
                    .fill(.black.opacity(0.6)))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(appLocalized(help))
        .accessibilityLabel(appLocalized(help))
    }
}

/// The one row of quick actions a media card carries: add at the playhead,
/// audition, favourite. Removing is not among them — it is Delete and the
/// context menu — and a tile squeezed to its minimum width keeps the actions
/// that fit instead of spilling them past its edge.
struct EditorMediaCardActions: View {
    struct Item: Identifiable {
        let id: String
        let symbol: String
        let help: String
        var tint: Color = .white
        let action: () -> Void
    }

    static let size: CGFloat = 20
    static let spacing: CGFloat = 3

    let items: [Item]
    /// Width the row may use. 0 means "no limit" (a list row, a wide card).
    var available: CGFloat = 0

    private var fitting: [Item] {
        guard available > 0 else { return items }
        let count = Int((available + Self.spacing) / (Self.size + Self.spacing))
        return Array(items.prefix(max(count, 0)))
    }

    var body: some View {
        HStack(spacing: Self.spacing) {
            ForEach(fitting) { item in
                EditorMediaCornerButton(symbol: item.symbol, help: item.help, tint: item.tint, action: item.action)
            }
        }
    }
}

/// What the monitor shows instead of the programme. Clicking an item in the
/// bin previews that one file; the programme comes back from the notice's own
/// way out, from the next click on the timeline, or when the bin selection
/// goes. State only: the monitor renders it through
/// `EditorAssetMonitorOverlay`, which the editor stage puts over the canvas.
@MainActor
final class EditorAssetMonitor: ObservableObject {
    static let shared = EditorAssetMonitor()

    struct Previewing: Equatable {
        let asset: MediaAsset
        /// Absolute, so a library file and a project asset preview alike.
        let path: String
        var recording: RecordingSource? = nil
        var audio: AudioStyle? = nil
        var camera: CameraStyle? = nil
    }

    @Published private(set) var previewing: Previewing?
    /// The transport behind the preview. A separate object so a time tick
    /// redraws the transport row and not the picture.
    let playback = EditorAssetPreviewPlayback()
    var isPreviewing: Bool { previewing != nil }

    func preview(_ asset: MediaAsset, at path: String) {
        let next = Previewing(asset: asset, path: path)
        guard previewing != next else { return }
        previewing = next
        playback.load(kind: asset.kind, path: path, name: asset.name)
    }

    func previewRecording(_ source: RecordingSource, name: String, audio: AudioStyle, camera: CameraStyle) {
        guard let url = RecordingSourcePresentation.url(source) else { return }
        let next = Previewing(asset: MediaAsset(id: source.id, path: url.path, kind: .video, name: name),
            path: url.path, recording: source, audio: audio, camera: camera)
        guard previewing != next else { return }
        previewing = next
        playback.loadRecording(source, audio: audio, camera: camera)
    }

    /// Back to the edit. Safe to call from anywhere, including on every click
    /// on the timeline, and cheap when nothing is being previewed.
    func returnToProgramme() {
        guard previewing != nil else { return }
        MediaAudition.shared.stop()
        playback.unload()
        previewing = nil
    }

    /// The span of `path` the bin should add, or nil for the whole file. The
    /// marks describe the preview session, so they only answer for the file
    /// that is in the monitor right now.
    func sourceRange(forPath path: String) -> ClosedRange<TimeInterval>? {
        guard previewing?.path == path else { return nil }
        return playback.markedRange
    }
}

/// Playback for the one file in the monitor. A preview opens parked on its
/// first frame: the bin is a browser, and picking a two-hour recording out of
/// it must not start a loop the viewer then has to chase. Video and audio run
/// on an AVPlayer, an HTML motion on a frame clock, and both answer the same
/// transport. The in/out marks live here too — they describe this preview
/// session and never the project, so nothing about them is saved or undoable.
@MainActor
final class EditorAssetPreviewPlayback: ObservableObject {
    @Published private(set) var time: TimeInterval = 0
    @Published private(set) var duration: TimeInterval = 0
    @Published private(set) var isPlaying = false
    @Published private(set) var markIn: TimeInterval?
    @Published private(set) var markOut: TimeInterval?
    /// Off by default: one pass, then the file stays where it stopped.
    @Published var loops = false
    /// The rendered frame of an HTML motion; nil for every other kind.
    @Published private(set) var motionFrame: NSImage?

    private(set) var player: AVPlayer?
    private(set) var cameraPlayer: AVPlayer?
    private(set) var recordingScreenSize = CGSize(width: 1920, height: 1080)
    private(set) var recordingCameraSize: CGSize?
    private(set) var recordingCameraCrop = NormalizedCrop.full
    @Published private(set) var recordingCameraStyle: CameraStyle?
    @Published private(set) var loadError: String?
    @Published private(set) var kind: MediaAssetKind?
    private var path = ""
    private var timeObserver: Any?
    private var endObserver: NSObjectProtocol?
    private var clock: Task<Void, Never>?
    private var motionRender: Task<Void, Never>?
    private var motionScene: FrameAnimationScene?
    private var loader: Task<Void, Never>?

    /// A still has no length, so it gets no transport.
    var hasTransport: Bool { kind != nil && kind != .image }

    func loadRecording(_ source: RecordingSource, audio: AudioStyle, camera: CameraStyle) {
        unload()
        kind = .video
        path = ProjectFiles.resolve(source.media.screen.relativePath)
        let loadingPath = path
        MediaAudition.shared.stop()
        loader = Task { [weak self] in
            do {
                let result = try await EditorRecordingAssetPreview.load(source, audio: audio)
                try Task.checkCancellation()
                guard let self, self.path == loadingPath else { return }
                recordingScreenSize = result.screenSize
                recordingCameraSize = result.cameraSize
                recordingCameraCrop = result.cameraCrop
                cameraPlayer = result.camera.map { Self.makePlayer($0, muted: true) }
                installPlayer(result.item)
                duration = result.duration
                recordingCameraStyle = camera
            } catch is CancellationError { }
            catch {
                guard let self, self.path == loadingPath else { return }
                loadError = appErrorDescription(error)
            }
        }
    }

    private func installPlayer(_ item: AVPlayerItem) {
        let player = Self.makePlayer(item)
        self.player = player
        timeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.05, preferredTimescale: 600), queue: .main
        ) { [weak self] current in
            MainActor.assumeIsolated { self?.advanced(to: current.seconds) }
        }
        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.reachedEnd() }
        }
    }

    private static func makePlayer(_ item: AVPlayerItem, muted: Bool = false) -> AVPlayer {
        let player = AVPlayer(playerItem: item)
        // Host-clock synchronized starts reject AVPlayer's automatic waiting
        // mode. The programme transport uses the same configuration.
        player.automaticallyWaitsToMinimizeStalling = false
        player.isMuted = muted
        player.actionAtItemEnd = .pause
        return player
    }

    /// The marked span, or nil when nothing usable is marked. One mark is
    /// enough: an in point runs to the end, an out point from the start.
    var markedRange: ClosedRange<TimeInterval>? {
        guard duration > 0, markIn != nil || markOut != nil else { return nil }
        let start = min(max(markIn ?? 0, 0), duration)
        let end = min(max(markOut ?? duration, start), duration)
        guard end - start >= 0.05 else { return nil }
        return start...end
    }

    func load(kind: MediaAssetKind, path: String, name: String) {
        unload()
        self.kind = kind
        self.path = path
        // One sound at a time: the bin's audition and the monitor would
        // otherwise play over each other.
        MediaAudition.shared.stop()
        switch kind {
        case .video, .audio:
            let url = URL(fileURLWithPath: path)
            let item = AVPlayerItem(url: url)
            installPlayer(item)
            // The real length of the file, so a long recording shows how long
            // it is and the bar can be dragged across all of it.
            loader = Task { [weak self] in
                let seconds = (try? await AVURLAsset(url: url).load(.duration).seconds) ?? 0
                guard let self, self.path == path, seconds.isFinite, seconds > 0 else { return }
                duration = seconds
            }
        case .animation:
            motionScene = MediaThumbnailCache.motionScene(
                for: MediaAsset(path: path, kind: .animation, name: name), at: 0)
            let declared = HTMLMotion.declaredDuration(path: path) ?? 3
            duration = max(declared.isFinite ? declared : 3, 0.2)
            renderMotion()
        case .image:
            break
        }
    }

    func unload() {
        loader?.cancel(); loader = nil
        clock?.cancel(); clock = nil
        motionRender?.cancel(); motionRender = nil
        if let timeObserver, let player { player.removeTimeObserver(timeObserver) }
        timeObserver = nil
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        endObserver = nil
        player?.pause()
        player = nil
        cameraPlayer?.pause()
        cameraPlayer = nil
        recordingCameraStyle = nil
        recordingCameraSize = nil
        loadError = nil
        motionScene = nil
        motionFrame = nil
        kind = nil
        path = ""
        time = 0
        duration = 0
        isPlaying = false
        markIn = nil
        markOut = nil
        loops = false
    }

    func toggle() { isPlaying ? pause() : play() }

    func play() {
        guard hasTransport, duration > 0 else { return }
        let start = markedRange?.lowerBound ?? 0
        let end = markedRange?.upperBound ?? duration
        // Playing from the end, or from outside the marked span, starts again
        // at the top of what is going to be added.
        if time >= end - 0.01 || time < start - 0.01 { seek(to: start) }
        isPlaying = true
        if let player {
            let hostTime = CMClockGetTime(CMClockGetHostTimeClock()) + CMTime(seconds: 0.05, preferredTimescale: 60000)
            let itemTime = CMTime(seconds: time, preferredTimescale: 60000)
            player.setRate(1, time: itemTime, atHostTime: hostTime)
            cameraPlayer?.setRate(1, time: itemTime, atHostTime: hostTime)
        } else { startClock() }
    }

    func pause() {
        isPlaying = false
        player?.pause()
        cameraPlayer?.pause()
        clock?.cancel(); clock = nil
    }

    func seek(to target: TimeInterval) {
        guard hasTransport else { return }
        let clamped = min(max(target, 0), max(duration, 0))
        time = clamped
        if let player {
            player.seek(to: CMTime(seconds: clamped, preferredTimescale: 600),
                        toleranceBefore: .zero, toleranceAfter: .zero)
            cameraPlayer?.seek(to: CMTime(seconds: clamped, preferredTimescale: 600),
                        toleranceBefore: .zero, toleranceAfter: .zero)
        } else {
            renderMotion()
        }
    }

    /// Marks are set at the playhead, as an editor expects. An out point at
    /// or before the in point drops the in point rather than leaving a span
    /// that cannot be added.
    func markInHere() {
        markIn = time
        if let out = markOut, out <= time { markOut = nil }
    }

    func markOutHere() {
        markOut = time
        if let start = markIn, start >= time { markIn = nil }
    }

    func clearMarks() {
        markIn = nil
        markOut = nil
    }

    private func advanced(to seconds: TimeInterval) {
        guard seconds.isFinite else { return }
        time = min(max(seconds, 0), max(duration, seconds))
        guard isPlaying, let end = markedRange?.upperBound, time >= end - 0.01 else { return }
        reachedEnd()
    }

    /// The end of the file, or of the marked span: one pass and stop, unless
    /// the viewer asked for a loop.
    private func reachedEnd() {
        guard loops else { pause(); return }
        seek(to: markedRange?.lowerBound ?? 0)
        play()
    }

    /// An HTML motion has no player: a 30 fps clock carries the time and the
    /// renderer draws whatever frame that time lands on.
    private func startClock() {
        clock?.cancel()
        clock = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(33))
                guard let self, !Task.isCancelled, isPlaying else { return }
                let end = markedRange?.upperBound ?? duration
                let next = time + 1.0 / 30
                guard next < end else {
                    time = end
                    renderMotion()
                    reachedEnd()
                    return
                }
                time = next
                renderMotion()
            }
        }
    }

    /// One render in flight at a time, so a slow frame cannot queue up behind
    /// a drag along the progress line.
    private func renderMotion() {
        guard let scene0 = motionScene else { return }
        var scene = scene0
        scene.localTime = time
        motionRender?.cancel()
        motionRender = Task { @MainActor [weak self] in
            let frame = await AnimationFrames.image(
                for: scene, frameRate: 30, pixelSize: CGSize(width: 960, height: 600), projectURL: nil)
            guard !Task.isCancelled, let frame, let rendered = MediaThumbnailCache.nsImage(from: frame) else { return }
            self?.motionFrame = rendered
        }
    }
}

/// The bin's preview, filling the monitor: the file plays as itself and
/// nothing is drawn over it. The monitor's own bar underneath says what is
/// being previewed and carries the transport and the way back, so auditioning
/// a file never raises a second window of controls over the picture. Nothing
/// of the edit is rendered here, so a preview can never be mistaken for the
/// programme.
struct EditorAssetMonitorOverlay: View {
    @ObservedObject private var monitor = EditorAssetMonitor.shared

    var body: some View {
        if let previewing = monitor.previewing {
            ZStack {
                Color.black
                EditorAssetMonitorContent(previewing: previewing, playback: monitor.playback)
                    .id(previewing.path)
            }
            .transition(.opacity)
            .animation(SpringMotion.fade, value: previewing)
        }
    }
}

private struct EditorAssetMonitorContent: View {
    let previewing: EditorAssetMonitor.Previewing
    @ObservedObject var playback: EditorAssetPreviewPlayback
    @State private var image: NSImage?
    @State private var waveform: [Double] = []

    private var url: URL { URL(fileURLWithPath: previewing.path) }

    var body: some View {
        Group {
            switch previewing.asset.kind {
            case .video:
                if let error = playback.loadError {
                    Text(error).foregroundStyle(.white).padding()
                } else if let style = playback.recordingCameraStyle {
                    recordingVideo(style: style)
                } else { EditorAssetPlayerLayer(player: playback.player) }
            case .image:
                if let image { picture(image) } else { missing }
            case .animation:
                // The first frame arrives from the renderer a moment later;
                // the black stage is the right thing to show until it does.
                if let frame = playback.motionFrame { picture(frame) } else { Color.clear }
            case .audio:
                EditorAssetAudioStage(samples: waveform, playback: playback)
            }
        }
        .task(id: previewing.path) {
            switch previewing.asset.kind {
            case .image:
                image = NSImage(contentsOf: url)
            case .audio:
                waveform = await MediaThumbnailCache.shared.waveform(
                    for: MediaAsset(path: previewing.path, kind: .audio, name: previewing.asset.name))
            case .video, .animation:
                break
            }
        }
    }

    private func recordingVideo(style: CameraStyle) -> some View {
        GeometryReader { geometry in
            let screen = playback.recordingScreenSize
            let scale = min(geometry.size.width / max(screen.width, 1), geometry.size.height / max(screen.height, 1))
            let size = CGSize(width: screen.width * scale, height: screen.height * scale)
            let camera = playback.recordingCameraSize ?? CGSize(width: 4, height: 3)
            let crop = playback.recordingCameraCrop
            let sample = CameraMotionTrack([]).sample(at: 0, base: CameraMotionState(base: style),
                cameraAspectRatio: camera.width * crop.width / max(camera.height * crop.height, 1), canvasAspectRatio: size.width / max(size.height, 1))
            let scene = CompositionSceneEvaluator.evaluateCamera(style: style, motion: sample, screenZoomScale: 1,
                canvasWidth: size.width, canvasHeight: size.height, styleScale: scale)
            ZStack(alignment: .topLeading) {
                EditorAssetPlayerLayer(player: playback.player).frame(width: size.width, height: size.height)
                if playback.cameraPlayer != nil, !style.isHidden {
                    recordingCamera(camera, crop: crop, style: style, rect: scene.rect)
                        .scaleEffect(x: style.isMirrored ? -1 : 1, y: 1)
                        .clipShape(RoundedRectangle(cornerRadius: scene.cornerRadius))
                        .overlay(RoundedRectangle(cornerRadius: scene.cornerRadius).strokeBorder(.white, lineWidth: scene.borderWidth))
                        .offset(x: scene.rect.x, y: scene.rect.y)
                }
            }
            .frame(width: size.width, height: size.height).clipped()
            .position(x: geometry.size.width / 2, y: geometry.size.height / 2)
        }
    }

    @ViewBuilder
    private func recordingCamera(_ size: CGSize, crop: NormalizedCrop, style: CameraStyle, rect: CompositionRect) -> some View {
        if let fill = CameraContentFill.layout(sourceWidth: size.width * crop.width, sourceHeight: size.height * crop.height,
            target: CompositionRect(x: 0, y: 0, width: rect.width, height: rect.height),
            focus: style.contentPosition, contentScale: style.contentScale) {
            let scale = rect.width / fill.visibleSource.width
            EditorAssetPlayerLayer(player: playback.cameraPlayer)
                .frame(width: size.width * scale, height: size.height * scale)
                .offset(x: -(crop.x * size.width + fill.visibleSource.x) * scale,
                        y: -(crop.y * size.height + fill.visibleSource.y) * scale)
                .frame(width: rect.width, height: rect.height, alignment: .topLeading).clipped()
        }
    }

    private func picture(_ image: NSImage) -> some View {
        Image(nsImage: image).resizable().aspectRatio(contentMode: .fit)
    }

    private var missing: some View {
        Text(appLocalized("无法预览这个素材")).font(.appUI(size: 13)).foregroundStyle(EditorTheme.secondaryText)
    }
}

/// The audio stage: the waveform with the playhead on it and the marked span
/// washed in, so a sound reads the way the video does.
private struct EditorAssetAudioStage: View {
    let samples: [Double]
    @ObservedObject var playback: EditorAssetPreviewPlayback

    var body: some View {
        GeometryReader { geometry in
            let width = max(geometry.size.width, 1)
            let position = { (time: TimeInterval) -> CGFloat in
                playback.duration > 0 ? width * CGFloat(min(max(time / playback.duration, 0), 1)) : 0
            }
            ZStack(alignment: .leading) {
                WaveformBars(samples: samples)
                if let range = playback.markedRange {
                    Rectangle().fill(EditorTheme.accent.opacity(0.18))
                        .frame(width: max(position(range.upperBound) - position(range.lowerBound), 1))
                        .offset(x: position(range.lowerBound))
                }
                Rectangle().fill(EditorTheme.accent).frame(width: 1.5)
                    .offset(x: position(playback.time))
            }
        }
        .frame(height: 132)
        .padding(.horizontal, 40)
    }
}

/// An AVPlayerLayer in a plain NSView. AVKit's SwiftUI `VideoPlayer` aborts
/// inside `_swift_initClassMetadataImpl` while its own generic metadata is
/// built, which killed the app on the first preview, and the preview needs
/// none of its chrome: the transport underneath is the editor's own.
private struct EditorAssetPlayerLayer: NSViewRepresentable {
    let player: AVPlayer?

    func makeNSView(context: Context) -> EditorAssetPlayerNSView { EditorAssetPlayerNSView() }

    func updateNSView(_ view: EditorAssetPlayerNSView, context: Context) {
        view.player = player
    }

    static func dismantleNSView(_ view: EditorAssetPlayerNSView, coordinator: Void) {
        view.player = nil
    }
}

@MainActor
final class EditorAssetPlayerNSView: NSView {
    private let playerLayer = AVPlayerLayer()

    var player: AVPlayer? {
        get { playerLayer.player }
        set { if playerLayer.player !== newValue { playerLayer.player = newValue } }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        playerLayer.videoGravity = .resizeAspect
        playerLayer.actions = ["position": NSNull(), "bounds": NSNull(), "frame": NSNull()]
        layer?.addSublayer(playerLayer)
    }

    required init?(coder: NSCoder) { nil }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        playerLayer.frame = bounds
        CATransaction.commit()
    }
}

/// The transport bar's quiet text button, drawn exactly as the monitor bar
/// draws its own. A preview borrows that bar rather than bringing its own, so
/// its buttons must be the same object.
struct EditorAssetPreviewBarButton: View {
    let title: String
    let help: String
    var shortcut: KeyEquivalent?
    let action: () -> Void

    var body: some View {
        if let shortcut {
            button.keyboardShortcut(shortcut, modifiers: [])
        } else {
            button
        }
    }

    private var button: some View {
        Button(action: action) {
            EditorMonitorBarButtonSurface(accessibilityTitle: title) {
                Text(appLocalized(title)).font(.appUI(size: 13, weight: .medium))
            }
        }
        .buttonStyle(EditorToolbarPressButtonStyle(cornerRadius: 8, showsHover: false))
        .help(appLocalized(help))
    }
}

/// What is in the monitor, named in the bar's left group — the one place a
/// preview says it is a preview, where the canvas controls would otherwise be.
struct EditorAssetPreviewBarLeading: View {
    let previewing: EditorAssetMonitor.Previewing

    var body: some View {
        HStack(spacing: 6) {
            AppLineIcon(kind: .eye, size: 14).foregroundStyle(EditorTheme.secondaryText)
            Text(String(format: appLocalized("正在预览：%@"), previewing.asset.displayName))
                .font(.appUI(size: 13, weight: .medium))
                .foregroundStyle(EditorTheme.secondaryText)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: 220, alignment: .leading)
        }
        .padding(.horizontal, 7)
        .frame(height: 30)
        .accessibilityElement(children: .combine)
    }
}

/// The preview's transport, in the bar's centre group: the same play disc as
/// the programme, with the in and out marks standing where the frame steps do
/// — the picture is a file being auditioned, not a cut being trimmed.
struct EditorAssetPreviewBarCenter: View {
    @ObservedObject var playback: EditorAssetPreviewPlayback

    var body: some View {
        if playback.hasTransport {
            HStack(spacing: 6) {
                EditorAssetPreviewBarButton(title: "入点", help: "设为入点（I）") { playback.markInHere() }
                Button { playback.toggle() } label: {
                    AppLineIcon(kind: playback.isPlaying ? .pause : .play, size: 18)
                        .foregroundStyle(EditorTheme.onAccent)
                        .frame(width: 40, height: 40)
                        .background(EditorTheme.platinumAccent, in: Circle())
                }
                .buttonStyle(EditorMonitorPlayButtonStyle())
                .disabled(playback.duration <= 0)
                .help(appLocalized(playback.isPlaying ? "暂停（空格）" : "播放（空格）"))
                .accessibilityLabel(appLocalized(playback.isPlaying ? "暂停" : "播放"))
                EditorAssetPreviewBarButton(title: "出点", help: "设为出点（O）") { playback.markOutHere() }
            }
        }
    }
}

/// The bar's right group while a file is in the monitor: how much of it is
/// marked, where it is, the loop switch, and the way back to the programme.
struct EditorAssetPreviewBarTrailing: View {
    @ObservedObject var playback: EditorAssetPreviewPlayback
    let onReturn: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            if playback.hasTransport {
                if let range = playback.markedRange {
                    Text(String(format: appLocalized("选区 %@"),
                                EditorView.transportTimestamp(range.upperBound - range.lowerBound)))
                        .font(.system(size: 12, weight: .medium, design: .monospaced))
                        .foregroundStyle(EditorTheme.accent)
                        .fixedSize()
                    EditorAssetPreviewBarButton(title: "清除", help: "清除入出点") { playback.clearMarks() }
                }
                HStack(spacing: 4) {
                    Text(EditorView.transportTimestamp(playback.time))
                        .foregroundStyle(EditorTheme.primaryText)
                    Text("/ " + EditorView.transportTimestamp(playback.duration))
                        .foregroundStyle(EditorTheme.tertiaryText)
                }
                .font(.system(size: 14, weight: .medium, design: .monospaced))
                .fixedSize()
                Button { playback.loops.toggle() } label: {
                    EditorMonitorBarButtonSurface(accessibilityTitle: "循环播放",
                                                  isActive: playback.loops, iconOnly: true) {
                        AppLineIcon(kind: .refresh, size: 15)
                    }
                }
                .buttonStyle(EditorToolbarPressButtonStyle(cornerRadius: 8, showsHover: false))
                .help(appLocalized("循环播放"))
            }
            EditorAssetPreviewBarButton(title: "返回成片",
                                        help: "返回成片（Esc，或点击画布外的空白处、时间线）",
                                        shortcut: .escape,
                                        action: onReturn)
        }
    }
}

/// The preview's progress line, in the monitor's own progress row: the same
/// 3 pt as the programme's, with the marked span raised behind it so the part
/// that will be added is plain to see, and draggable anywhere along its
/// height. A still has no length, so it gets no line.
struct EditorAssetPreviewProgress: View {
    @ObservedObject var playback: EditorAssetPreviewPlayback

    var body: some View {
        if playback.hasTransport { line }
    }

    private var line: some View {
        GeometryReader { geometry in
            let width = max(geometry.size.width, 1)
            let duration = max(playback.duration, 0)
            let position = { (time: TimeInterval) -> CGFloat in
                duration > 0 ? width * CGFloat(min(max(time / duration, 0), 1)) : 0
            }
            ZStack(alignment: .leading) {
                Capsule().fill(EditorTheme.chrome(0.14)).frame(height: 3)
                if let range = playback.markedRange {
                    Capsule().fill(EditorTheme.accent.opacity(0.3))
                        .frame(width: max(position(range.upperBound) - position(range.lowerBound), 2), height: 9)
                        .offset(x: position(range.lowerBound))
                }
                Capsule().fill(EditorTheme.accent).frame(width: position(playback.time), height: 3)
                if let mark = playback.markIn { tick(at: position(mark)) }
                if let mark = playback.markOut { tick(at: position(mark)) }
                Circle().fill(.white)
                    .frame(width: 9, height: 9)
                    .shadow(color: .black.opacity(0.3), radius: 1, y: 0.5)
                    .offset(x: position(playback.time) - 4.5)
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        guard duration > 0 else { return }
                        playback.seek(to: duration * Double(min(max(value.location.x / width, 0), 1)))
                    }
            )
        }
        .frame(height: EditorCanvasBarMetrics.progressHitHeight)
        .help(appLocalized("拖动定位"))
    }

    private func tick(at x: CGFloat) -> some View {
        Capsule().fill(.white.opacity(0.9)).frame(width: 2, height: 11).offset(x: x - 1)
    }
}
