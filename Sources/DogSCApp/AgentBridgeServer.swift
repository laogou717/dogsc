import AppKit
import AVFoundation
import CoreImage
import Foundation
import Network
import RecorderCore

/// EDT-054: a local JSON command endpoint so AI tools (through the bundled
/// `dogsc-mcp` bridge, a CLI or curl) can read and edit the open project.
/// Listens on 127.0.0.1 only, requires a random bearer token, runs only while
/// an editor is open, and applies every change through EditorStore so it is
/// previewed and undoable like a manual edit.
@MainActor
final class AgentBridgeServer {
    static let shared = AgentBridgeServer()

    private(set) var port: UInt16?
    let token = UUID().uuidString.replacingOccurrences(of: "-", with: "")
    private var listener: NWListener?
    private weak var store: EditorStore?
    private var playback: EditorPlaybackController?
    private var outputDuration: () -> TimeInterval = { 0 }
    /// Length of the original recording, for main-track inserts.
    private var recordingDurations: () -> [UUID: TimeInterval] = { [:] }
    /// Recorded pointer events (source time) of the open project.
    var pointerEventsBySource: () -> [UUID: [PointerEventRecord]] = { [:] }
    /// The export canvas in pixels (aspect and resolution as set by the user).
    private var canvasSize: () -> CGSize? = { nil }
    var snapshotWallpaperURL: (BackgroundSource) -> URL? = { _ in nil }
    /// Receives a short human summary after every successful edit or long
    /// operation, whichever client issued it, so the chat shows live progress.
    var activityHandler: ((String) -> Void)?
    /// Receives each edit as a step (title, what, where on the timeline).
    var stepHandler: ((AgentChatModel.Step) -> Void)?
    /// Long work in progress: (title, 0…1, detail such as "63 / 241 帧").
    var progressHandler: ((String, Double, String?) -> Void)?
    /// The timeline before each AI turn, so its result card can undo it.
    private var turnSnapshots: [UUID: ProjectTimeline] = [:]
    private var turnStart: ProjectTimeline?
    private var currentTurn: UUID?
    /// Latest recognizer ranges, tied to the source sequence they describe.
    private var lastTranscript: SystemTranscriber.Transcript?
    /// The cut the transcript was made from; after any cut its times are stale.
    private var transcriptSequence: SourceSequence?
    private struct SpeechContext: Equatable, Sendable {
        let sequence: SourceSequence
        let inputs: [EditorMediaInput]
        let manifests: [UUID: ProjectMediaManifest]
        let audio: AudioStyle
        let overrides: [UUID: PrimarySegmentAudioOverrides]
        let language: String
    }
    private var speechAnalysis: (context: SpeechContext, analysis: SpeechEditAnalysis)?
    private var pendingSpeechAnalysis: (id: UUID, context: SpeechContext, task: Task<SpeechEditAnalysis, Error>)?
    /// The open project's package, for the per-project AI workspace.
    var projectPackageURL: () -> URL? = { nil }

    /// Everything an agent creates for this project lives here (transcripts,
    /// Rive files, rendered overlays, downloaded music). New media files in
    /// it are picked up by the media bin.
    var workspaceURL: URL? {
        guard let package = projectPackageURL() else { return nil }
        ProjectFiles.setPackage(package)
        let url = package.appendingPathComponent("AI", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// When the current AI turn began: library files made after this are
    /// added to the open project's media bin when the turn ends.
    private var turnStartedAt = Date.distantFuture

    func beginUndoBatch(turn: UUID? = nil) {
        turnStartedAt = Date()
        currentTurn = turn
        turnStart = store?.project.timeline
        if let turn, let start = turnStart { turnSnapshots[turn] = start }
        store?.beginAgentUndoBatch(actionName: appLocalized("AI 编辑"))
    }

    /// Ends the turn's undo group and describes what it changed.
    @discardableResult
    func endUndoBatch() -> [AgentChatModel.Change] {
        store?.endAgentUndoBatch()
        defer { turnStart = nil; currentTurn = nil }
        guard let before = turnStart, let after = store?.project.timeline, before != after else {
            if let currentTurn { turnSnapshots[currentTurn] = nil }
            return []
        }
        return Self.changes(from: before, to: after)
    }

    /// Restores the timeline from before a turn (one undoable step).
    func revert(turn: UUID) -> Bool {
        guard let store, let snapshot = turnSnapshots[turn] else { return false }
        do {
            try store.replaceTimeline(with: snapshot, actionName: appLocalized("撤销 AI 修改"))
            turnSnapshots[turn] = nil
            return true
        } catch { return false }
    }

    func locate(_ time: Double) { playback?.seek(to: max(time, 0), pausing: true) }
    func preview(at time: Double) {
        playback?.seek(to: max(time, 0), pausing: false)
        playback?.play()
    }

    /// What the AI can read in the open project, as short labels.
    func contextLabels() -> [String] {
        guard let store else { return [] }
        let t = store.project.timeline
        var labels = [String(format: appLocalized("时长 %@"), Self.clock(outputDuration()))]
        if !t.subtitleCues.isEmpty { labels.append(String(format: appLocalized("%lld 条字幕"), Int64(t.subtitleCues.count))) }
        let motion = t.zoomClips.count + t.screenMotionClips.count
        if motion > 0 { labels.append(String(format: appLocalized("%lld 处运镜"), Int64(motion))) }
        if !t.mediaAssets.isEmpty { labels.append(String(format: appLocalized("%lld 个素材"), Int64(t.mediaAssets.count))) }
        return labels
    }

    static func clock(_ seconds: Double) -> String {
        let s = max(Int(seconds.rounded(.down)), 0)
        return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60) : String(format: "%d:%02d", s / 60, s % 60)
    }

    private static func span(_ start: Double, _ end: Double) -> String { clock(start) + "–" + clock(end) }

    /// One line per kind of thing that changed.
    static func changes(from a: ProjectTimeline, to b: ProjectTimeline) -> [AgentChatModel.Change] {
        var out: [AgentChatModel.Change] = []
        func list<T: Identifiable & Equatable>(_ label: String, _ old: [T], _ new: [T], time: (T) -> (Double, Double)) {
            let oldIDs = Set(old.map(\.id)), newIDs = Set(new.map(\.id))
            let added = new.filter { !oldIDs.contains($0.id) }
            let removed = old.filter { !newIDs.contains($0.id) }
            let edited = new.filter { item in old.first { $0.id == item.id }.map { $0 != item } ?? false }
            var parts: [String] = []
            if added.count == 1, let one = added.first { parts.append(appLocalized("新增") + " " + span(time(one).0, time(one).1)) }
            else if added.count > 1 { parts.append(String(format: appLocalized("新增 %lld 段"), Int64(added.count))) }
            if !edited.isEmpty { parts.append(String(format: appLocalized("调整 %lld 段"), Int64(edited.count))) }
            if !removed.isEmpty { parts.append(String(format: appLocalized("删除 %lld 段"), Int64(removed.count))) }
            if !parts.isEmpty { out.append(.init(label: appLocalized(label), value: parts.joined(separator: " · "))) }
        }
        if a.subtitleCues != b.subtitleCues {
            let value = a.subtitleCues.count == b.subtitleCues.count
                ? String(format: appLocalized("修改 %lld 条"), Int64(zip(a.subtitleCues, b.subtitleCues).filter { $0 != $1 }.count))
                : String(format: appLocalized("%lld 条 → %lld 条"), Int64(a.subtitleCues.count), Int64(b.subtitleCues.count))
            out.append(.init(label: appLocalized("字幕"), value: value))
        }
        if a.subtitleStyle != b.subtitleStyle { out.append(.init(label: appLocalized("字幕样式"), value: appLocalized("已调整"))) }
        list("动效", a.animationClips, b.animationClips) { ($0.timing.startTime, $0.timing.endTime) }
        list("音频", a.audioClips, b.audioClips) { ($0.timing.startTime, $0.timing.endTime) }
        list("视频", a.videoClips, b.videoClips) { ($0.timing.startTime, $0.timing.endTime) }
        list("贴纸", a.stickerClips, b.stickerClips) { ($0.timing.startTime, $0.timing.endTime) }
        list("柔化", a.mosaicClips, b.mosaicClips) { ($0.timing.startTime, $0.timing.endTime) }
        list("缩放", a.zoomClips, b.zoomClips) { ($0.startTime, $0.startTime + $0.duration) }
        let newMedia = b.mediaAssets.count - a.mediaAssets.count
        if newMedia > 0 { out.append(.init(label: appLocalized("素材"), value: String(format: appLocalized("导入 %lld 个"), Int64(newMedia)))) }
        if a.sourceSequence != b.sourceSequence { out.append(.init(label: appLocalized("剪辑"), value: appLocalized("主轨道已修改"))) }
        return out
    }

    /// Collect reusable library results; workspace files are scratch work
    /// unless the agent explicitly imports or places them.
    func collectWorkspaceMedia() {
        guard let store else { return }
        let known = Set(store.project.timeline.mediaAssets.map { ProjectFiles.resolve($0.path) })
        // Reusable results the AI saved into the library during this turn.
        let library = AssetLibrary.shared
        library.reload()
        let libraryFiles = library.entries
            .filter { $0.generated && $0.addedAt >= turnStartedAt.addingTimeInterval(-2) }
            .map { URL(fileURLWithPath: $0.path) }
        let fresh = libraryFiles.filter { !known.contains($0.path) }
        guard !fresh.isEmpty else { return }
        EditorStore.$isAgentMutation.withValue(true) {
            _ = store.importMediaAssets(fresh)
        }
        activityHandler?(String(format: appLocalized("%lld 个新文件已放入素材箱"), Int64(fresh.count)))
    }

    /// Where `dogsc-mcp` and scripts discover the endpoint.
    static var infoURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("DogSC", isDirectory: true)
            .appendingPathComponent("agent-bridge.json")
    }

    func attach(store: EditorStore, playback: EditorPlaybackController, outputDuration: @escaping () -> TimeInterval,
                recordingDurations: @escaping () -> [UUID: TimeInterval] = { [:] }, canvasSize: @escaping () -> CGSize? = { nil }) {
        if self.store !== store {
            if self.store != nil { AgentChatModel.shared.closeProjectConversation() }
            turnSnapshots.removeAll()
            lastTranscript = nil; transcriptSequence = nil
            speechAnalysis = nil
            pendingSpeechAnalysis?.task.cancel(); pendingSpeechAnalysis = nil
        }
        self.store = store
        self.playback = playback
        self.outputDuration = outputDuration
        self.recordingDurations = recordingDurations
        self.canvasSize = canvasSize
        start()
    }

    func detach(store: EditorStore) {
        guard self.store === store else { return }
        AgentChatModel.shared.closeProjectConversation()
        projectPackageURL = { nil }
        turnSnapshots.removeAll()
        outputDuration = { 0 }
        recordingDurations = { [:] }
        pointerEventsBySource = { [:] }
        canvasSize = { nil }
        snapshotWallpaperURL = { _ in nil }
        self.store = nil
        lastTranscript = nil; transcriptSequence = nil
        speechAnalysis = nil
        pendingSpeechAnalysis?.task.cancel(); pendingSpeechAnalysis = nil
        playback = nil
        listener?.cancel()
        listener = nil
        port = nil
        try? FileManager.default.removeItem(at: Self.infoURL)
    }

    private func start() {
        guard listener == nil else { return }
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: .any)
        guard let listener = try? NWListener(using: parameters) else { return }
        listener.newConnectionHandler = { connection in
            Task { @MainActor in AgentBridgeServer.shared.serve(connection) }
        }
        listener.stateUpdateHandler = { state in
            guard case .ready = state else { return }
            Task { @MainActor in AgentBridgeServer.shared.publishPort() }
        }
        listener.start(queue: .main)
        self.listener = listener
    }

    private func publishPort() {
        guard let value = listener?.port?.rawValue else { return }
        port = value
        let info: [String: Any] = ["port": Int(value), "token": token, "pid": ProcessInfo.processInfo.processIdentifier]
        try? FileManager.default.createDirectory(at: Self.infoURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let data = try? JSONSerialization.data(withJSONObject: info) {
            try? data.write(to: Self.infoURL, options: .atomic)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: Self.infoURL.path)
        }
    }

    // MARK: HTTP

    private func serve(_ connection: NWConnection) {
        connection.start(queue: .main)
        receive(connection, buffer: Data())
    }

    private func receive(_ connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { data, _, isComplete, error in
            Task { @MainActor in
                var buffer = buffer
                if let data { buffer.append(data) }
                if let request = Self.parse(buffer) {
                    let response = await self.handle(request)
                    connection.send(content: response, completion: .contentProcessed { _ in connection.cancel() })
                } else if isComplete || error != nil || buffer.count > 8 << 20 {
                    connection.cancel()
                } else {
                    self.receive(connection, buffer: buffer)
                }
            }
        }
    }

    private struct Request { let path: String; let headers: [String: String]; let body: Data }

    private static func parse(_ data: Data) -> Request? {
        guard let range = data.range(of: Data("\r\n\r\n".utf8)),
              let head = String(data: data[..<range.lowerBound], encoding: .utf8) else { return nil }
        let lines = head.components(separatedBy: "\r\n")
        let parts = lines.first?.split(separator: " ") ?? []
        guard parts.count >= 2 else { return nil }
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            headers[line[..<colon].lowercased()] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        let length = Int(headers["content-length"] ?? "0") ?? 0
        let body = data[range.upperBound...]
        guard body.count >= length else { return nil }
        return Request(path: String(parts[1]), headers: headers, body: Data(body.prefix(length)))
    }

    private func handle(_ request: Request) async -> Data {
        guard request.headers["authorization"] == "Bearer \(token)" else {
            return Self.http(401, ["error": "unauthorized"])
        }
        guard request.path == "/rpc",
              let json = try? JSONSerialization.jsonObject(with: request.body) as? [String: Any],
              let method = json["method"] as? String else {
            return Self.http(400, ["error": "POST /rpc with {\"method\":…, \"params\":{…}}"])
        }
        let params = json["params"] as? [String: Any] ?? [:]
        do {
            return Self.http(200, ["result": try await call(method, params)])
        } catch {
            return Self.http(200, ["error": error.localizedDescription])
        }
    }

    private static func http(_ status: Int, _ object: Any) -> Data {
        let body = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data()
        var head = "HTTP/1.1 \(status) \(status == 200 ? "OK" : "Error")\r\n"
        head += "Content-Type: application/json\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n"
        return Data(head.utf8) + body
    }

    // MARK: Commands

    struct BridgeError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    static let methods: [(name: String, summary: String)] = [
        ("project.summary", "Title, output duration (s), playhead, counts of clips, subtitles and media."),
        ("media.list", "List existing media: scope project (default), library, or all; optional kind video/image/audio/animation. Returns IDs, names, paths and missing status."),
        ("media.import", "params: {paths:[absolute file paths]} → adds to the bin by reference."),
        ("sound.download", "params: {url, sourceURL, licenseURL, name?} → downloads a CC0 audio file into the library and project bin, reusing existing files. Returns path and duration; place with timeline.addAudio or attach as an HTML main clip's soundPath."),
        ("timeline.addAudio", "params: {path, start, kind:'music'|'effect', volume?, fadeIn?, fadeOut?}."),
        ("timeline.addVideo", "params: {path, start, x?, y?, width?, volume?} → places a video over the recording (full frame by default)."),
        ("subtitles.get", "All subtitle cues with stable IDs, text and output times."),
        ("subtitles.updateText", "params: {cues:[{id,text?,secondary?}]} → corrects only the named captions; IDs, timing and all other cues are preserved."),
        ("subtitles.fromWords", "params: {analysisId?, cues:[{from,to,secondary?,start?,end?,holdToNext?}]} → uses the current transcript wording, filters profanity and aligns cue times. Use subtitles.updateText for specific recognition errors."),
        ("subtitles.set", "params: {cues:[{start,end,text,secondary?}]} → replaces all subtitles at the supplied times (one undo step). Use subtitles.updateText for local text corrections."),
        ("subtitles.style", "params: {fontScale?, bottomMargin?, backgroundOpacity?, showsSecondary?}."),
        ("audio.export", "params: {path?} → writes the edited program audio (M4A, output time) for transcription."),
        ("html.create", "params: {name, html, start, duration?, placement:'overlay'|'main', x?, y?, width?, framed?, soundPath?, sound?, copy?} → creates and places an HTML motion. soundPath attaches a local audio file to a main clip. Identical retries reuse the file and placement. Revise with html.update; copy:true explicitly creates an independent asset."),
        ("html.update", "params: {id OR path, html} → revises a library HTML motion used by this project in one undoable edit. IDs, timing, per-instance fields and user edits are preserved; the bin keeps one item. Returns the new path; other projects keep their existing source."),
        ("html.preview", "params: {path, times:[seconds]} → renders PNG frames of an HTML motion page so you can check your design."),
        ("sound.create", "params: {name, events:[{type, at, duration?, volume?, pitch?, pan?}], start?, volume?} → synthesises a sound effect (types: whoosh, swoosh_down, riser, hit, boom, click, tick, pop, ding, chime, shimmer, glitch, tone), saves it to the library and, when start is given, places it on an audio track."),
        ("timeline.insertBlack", "params: {start, duration?} → inserts a black clip into the main track (default 2 s); everything after it moves later."),
        ("timeline.get", "Everything on the timeline in output seconds, with ids: main-track segments, zooms, 3D moves, highlights, overlays, audio. Object IDs address individual occurrences. Zooms include authored transitions/easing; zoomJoins reports evaluated gap, leftExitDuration, rightEnterDuration, fullFrameHold at 1x and continuous handoff. These expose timing for editorial choices, not automatic merging. Overlays include layerIndex."),
        ("timeline.inspect", "Read native editable values for timeline objects, optionally filtered by ids. Returns a project revision and objects {id,kind,value}. Main clip value exposes source {start,end,speed}, audio, sceneStyle and media. source uses media seconds; output timing and availableSource bounds are reported separately."),
        ("timeline.update", "Apply partial patches to existing native objects in one undoable edit. changes [{id,patch}] uses the value shape from timeline_inspect; omitted fields stay unchanged. Supports zoom, 3D, camera motion, highlight, sticker, animation, video, audio, subtitle, and main clip source/media/appearance/audio. Main patch.source {start?,end?,speed?} trims or extends media-source edges and ripples dependent tracks, like manual edge dragging. Optional revision detects intervening edits. Returns actual updated values."),
        ("timeline.addSticker", "Place an image as a native editable sticker over the program. start/end are output seconds; x/y are canvas centre coordinates (0-1); width is canvas width fraction."),
        ("timeline.cut", "Cut output-time ranges in one undoable edit; dependent tracks follow. Use ranges [{start,end}], or analysisId with wordRanges [{from,to,start?,end?}] and pauses [{id,keep}]. Word IDs are inclusive; defaults are recognizer endpoints, optional start/end are exact overrides. keep is remaining pause seconds (default 0.25, minimum 0). Acoustic evidence is advisory, not permission. analysisId checks the audio snapshot; explicit ranges may be included with it. Optional revision from timeline_get binds any cut to that project state. Returns appliedRanges and, when matching speech analysis is cached, cutReview for every new join: fine edge waveform, retained quiet, utterance context and current segment IDs/source bounds for further timeline_update edits. remainingPauses lists all retained pause candidates, including those within kept sentences, in the new output clock."),
        ("timeline.remove", "params: {ids:[...]} → deletes clips by id (zoom, 3D, highlight, overlay, audio, subtitle, video, main-track segment) in one undoable step."),
        ("pointer.events", "params: {from?, to?, kinds?:['click'|'move']} → recorded mouse clicks (and optionally moves) in output seconds with x,y (0-1 of the recording). Clicks are where the viewer's attention was."),
        ("zoom.add", "params: {start, end, x, y, scale?, transition?} → Add a purposeful camera push-in on the recording. x,y = source focus (0-1), scale 1.05-4 (default: the project's). start begins entrance; end begins return; transition is seconds per leg. Choose the span around the actual explanation or action. Touching clips continue without a 1x reset. Existing startTime/endTime, focus, scale and separate transition durations are editable with timeline_update; timeline_get reports zoomJoins."),
        ("motion3d.add", "params: {start, end, rotationX?, rotationY?, rotationZ?, scale?, x?, y?, perspective?, leadIn?} → a 3D move of the recording (degrees; small values like 8-18 look best)."),
        ("highlight.add", "params: {start, end, x, y, width, height, style:'spotlight'|'blur', dim?} → spotlight dims everything outside the box (draw attention); blur hides the box (redact). Box is 0-1 of the recording, top-left origin."),
        ("settings.get", "The whole-video settings as JSON (background, layout padding/corners, device frame, cursor, camera bubble, audio levels, motion defaults, export settings)."),
        ("settings.set", "params: {patch:{...}} → merges a JSON patch into the whole-video settings (same shape as settings.get). One undoable step; invalid values are refused with the reason."),
        ("app.help", "params: {topic?} → how DogSC itself is used: where each setting lives, shortcuts, and step-by-step paths. Use it to answer 'how do I…' questions."),
        ("canvas.snapshot", "Render a specified output time independently of the editor playhead. Returns PNG path, requested/rendered time, decoded source timestamp, source/clip IDs and coordinate geometry. view canvas (default) includes all effects; source shows the uncropped recording. maxDimension defaults to 1280 (64...8192)."),
        ("audio.transcribe", "params: {language?} → transcribes the edited program's voice with the macOS recognizer; returns phrases and numbered tokens with recognizer timing ranges (output seconds)."),
        ("audio.analyzeEdits", "params: {language?,from?,to?,includeWords?,includeWaveform?,refresh?} → Raw speech, independent local waveform evidence, suggested cut times, pause IDs, utterance context spanning pauses, nearby repeated phrases with surrounding takes, and existing edit joins in output seconds. Suggestions can fall inside recognizer ranges; none is an automatic deletion or sentence verdict. from/to select a window (default 180 s, pages up to 300 s). includeWords adds token boundaries; includeWaveform adds broad peak dBFS bins. Joins always include fine local waveform; utterance context is not split by silence. pauseGroups combines brief-noise-separated pauses with text context and optional acousticInterior cut ranges. Cached with audio_transcribe; refresh reanalyses. analysisId ties word IDs and pauses to this audio snapshot. Frame counts use the current export videoFrameRate, independently of the audio measurementStep. Existing joins expose leftQuietFrames/rightQuietFrames; cutReview exposes left/right quietFrames and total retainedQuietFrames. Short includeWaveform windows give finer local detail."),
        ("subtitles.fromWords", "Caption word ranges from the current analysis; optional start/end override exact times. Optional holdToNext on each cue extends its end to the next cue's start (true), preserves a gap (false), or retains ASR gap cleanup (omitted); explicit end takes priority. No duration threshold is imposed. Returns actual cue IDs/times and remaining gaps in seconds and video frames. Local alignment evidence is returned; display text does not change audio."),
        ("subtitles.alignToSpeech", "params: {} → keeps text and refines measured silence inside each cue's existing edges; no neighboring cues move."),
    ]

    /// In-process entry used by the editor's own chat.
    func perform(_ method: String, _ params: [String: Any]) async throws -> Any {
        try await call(method, params)
    }

    /// Development-only observer. The project snapshot is a value copy;
    /// encoding and file I/O happen on the diagnostic writer's queue.
    func recordDiagnostics(_ event: String, turn: UUID?, fields: [String: Any], includeProject: Bool = true) {
        guard let log = AgentOperationLog.shared else { return }
        let context = diagnosticContext(turn: turn).merging(fields) { _, value in value }
        log.record(event, fields: context, project: includeProject ? store?.project : nil)
    }

    private func diagnosticContext(turn: UUID?) -> [String: Any] {
        var fields: [String: Any] = [
            "turnId": turn?.uuidString as Any? ?? NSNull(),
            "projectPath": projectPackageURL()?.path as Any? ?? NSNull(),
            "projectTitle": store?.project.title as Any? ?? NSNull(),
            "playhead": playback?.outputTime as Any? ?? NSNull(),
            "outputDuration": outputDuration(),
        ]
        if let callID = AgentOperationLog.callID { fields["callId"] = callID.uuidString }
        return fields
    }

    private func report(_ method: String, _ params: [String: Any], _ result: Any) {
        let summary: String? = switch method {
        case "subtitles.set": String(format: appLocalized("写入了 %lld 条字幕"), Int64((result as? [String: Any])?["count"] as? Int ?? 0))
        case "subtitles.updateText": appLocalized("AI 修改字幕文字")
        case "subtitles.style": appLocalized("调整了字幕样式")
        case "timeline.insertBlack": appLocalized("在主轨道插入了黑场")
        case "timeline.cut": String(format: appLocalized("剪掉了 %lld 处"), Int64((result as? [String: Any])?["removed"] as? Int ?? 0))
        case "timeline.remove": String(format: appLocalized("删除了 %lld 个片段"), Int64((result as? [String: Any])?["removed"] as? Int ?? 0))
        case "zoom.add": appLocalized("添加了一段缩放")
        case "motion3d.add": appLocalized("添加了一段 3D 运镜")
        case "highlight.add": appLocalized((params["style"] as? String) == "blur" ? "添加了一处柔化" : "添加了一处聚光")
        case "settings.set": appLocalized("调整了全片设置")
        case "timeline.get": appLocalized("查看了时间线")
        case "pointer.events": appLocalized("查看了鼠标点击")
        case "sound.create": String(format: appLocalized("制作了音效 %@"), (params["name"] as? String) ?? "")
        case "sound.download": appLocalized("下载了音效")
        case "html.create": String(format: appLocalized("创作了动效 %@"), (params["name"] as? String) ?? "")
        case "html.update": appLocalized("更新了动效")
        case "html.preview": appLocalized("预览了动效画面")
        case "canvas.snapshot": appLocalized("查看了画面")
        case "timeline.inspect": appLocalized("查看了时间线")
        case "timeline.update": appLocalized("AI 编辑")
        case "timeline.addSticker": appLocalized("添加贴图")
        case "timeline.addAudio": appLocalized((params["kind"] as? String) == "effect" ? "添加了一段音效" : "添加了一段音乐")
        case "media.import": appLocalized("导入了素材")
        case "timeline.addVideo": appLocalized("添加了一段视频")
        case "audio.export": appLocalized("导出了节目音频")
        case "audio.transcribe": String(format: appLocalized("转写了音频，共 %lld 段"), Int64(((result as? [String: Any])?["phrases"] as? [Any])?.count ?? 0))
        case "audio.analyzeEdits": appLocalized("分析了语音与停顿")
        case "subtitles.fromWords": String(format: appLocalized("按语音时间写入了 %lld 条字幕"), Int64((result as? [String: Any])?["count"] as? Int ?? 0))
        case "subtitles.alignToSpeech": appLocalized("把字幕对齐到了语音")
        case "project.summary": appLocalized("读取了项目信息")
        case "subtitles.get": appLocalized("读取了现有字幕")
        case "media.list": appLocalized("查看了素材箱")
        default: nil
        }
        guard let summary else { return }
        if let stepHandler {
            // Preview frames are shown right in the step, as soon as they exist.
            let images = method == "html.preview"
                ? (result as? [String])?.prefix(6).map { $0 } : nil
            stepHandler(AgentChatModel.Step(title: summary, detail: Self.stepDetail(method, params, result),
                                            time: Self.stepTime(method, params), images: images, method: method))
        } else {
            activityHandler?(summary)
        }
    }

    /// EDT-073: every HTML motion on the timeline with the user's own changes
    /// to its elements (moved, hidden, retexted), so a later edit keeps them.
    static func motionSummary(_ t: ProjectTimeline) -> [[String: Any]] {
        func edits(_ e: [String: MotionElementEdit]) -> [String: Any] {
            e.mapValues { edit in
                var d: [String: Any] = [:]
                if edit.dx != 0 || edit.dy != 0 { d["movedBy"] = ["x": edit.dx, "y": edit.dy] }
                if edit.hidden { d["hidden"] = true }
                if let text = edit.text { d["text"] = text }
                if let family = edit.fontFamily { d["fontFamily"] = family }
                if let weight = edit.fontWeight { d["fontWeight"] = weight }
                return d
            }
        }
        var result: [[String: Any]] = []
        var start: TimeInterval = 0
        if case let .edited(segments) = t.sourceSequence {
            for segment in segments {
                if let media = segment.media, let path = media.motionPath {
                    result.append(["placement": "main", "segmentId": segment.id.uuidString, "path": ProjectFiles.resolve(path),
                                   "start": start, "duration": segment.outputDuration, "userEdits": edits(media.elementEdits)])
                }
                start += segment.outputDuration
            }
        }
        for clip in t.animationClips where HTMLMotion.isHTMLMotion(clip.sourcePath) {
            result.append(["placement": "overlay", "clipId": clip.id.uuidString, "path": ProjectFiles.resolve(clip.sourcePath),
                           "start": clip.timing.startTime, "duration": clip.timing.duration,
                           "userEdits": edits(clip.elementEdits)])
        }
        return result
    }

    /// A retry must address the same placement, not a nearby occurrence.
    static func insertedSegment(motionPath: String, at time: TimeInterval, in timeline: ProjectTimeline) -> UUID? {
        guard case let .edited(segments) = timeline.sourceSequence else { return nil }
        let wanted = ProjectFiles.resolve(motionPath)
        var start: TimeInterval = 0
        for segment in segments {
            if let path = segment.media?.motionPath, ProjectFiles.resolve(path) == wanted, abs(start - time) <= 1.0 / 600 {
                return segment.id
            }
            start += segment.outputDuration
        }
        return nil
    }

    static func insertedOverlay(motionPath: String, at time: TimeInterval, in timeline: ProjectTimeline) -> AnimationClip? {
        let wanted = ProjectFiles.resolve(motionPath)
        return timeline.animationClips.first {
            ProjectFiles.resolve($0.sourcePath) == wanted && abs($0.timing.startTime - time) <= 1.0 / 600
        }
    }

    static func insertedAudio(path: String, at time: TimeInterval, kind: AudioClipKind, in timeline: ProjectTimeline) -> AudioClip? {
        let wanted = AssetLibrary.fileKey(ProjectFiles.resolve(path))
        return timeline.audioClips.first {
            $0.kind == kind && AssetLibrary.fileKey(ProjectFiles.resolve($0.sourcePath)) == wanted
                && abs($0.timing.startTime - time) <= 1.0 / 600
        }
    }

    /// Where on the timeline an edit landed, so its row can 定位.
    /// EDT-075: where in time a cue's text is split. With a transcription
    /// that still matches the edit, it is where the first word after the
    /// caret starts (pulled back to the quiet just before it, when there is
    /// one); otherwise by the share of characters. The first line then ends
    /// exactly where the second begins — no gap, no overlap.
    func splitTime(for cue: SubtitleCue, atCharacter offset: Int) -> TimeInterval {
        let chars = Array(cue.text)
        let count = max(chars.count, 1)
        let clampedOffset = min(max(offset, 0), count)
        let lower = cue.timing.startTime + 0.15, upper = cue.timing.endTime - 0.15
        let byShare = cue.timing.startTime + cue.timing.duration * Double(clampedOffset) / Double(count)
        func clamp(_ t: TimeInterval) -> TimeInterval { upper > lower ? min(max(t, lower), upper) : byShare }
        guard let store, let transcript = lastTranscript, transcriptSequence == store.project.timeline.sourceSequence else {
            return clamp(byShare)
        }
        let words = transcript.words.filter { $0.end > cue.timing.startTime - 0.05 && $0.start < cue.timing.endTime + 0.05 }
        guard !words.isEmpty else { return clamp(byShare) }
        // Match the cue's own characters (spaces and punctuation ignored) to
        // the recognised words in order; the split lands on the word that
        // holds the first character after the caret.
        func significant(_ c: Character) -> Bool { c.isLetter || c.isNumber }
        let before = chars.prefix(clampedOffset).filter(significant).count
        var seen = 0
        for (index, word) in words.enumerated() {
            let length = word.text.filter(significant).count
            guard length > 0 else { continue }
            if seen + length > before {
                // Caret inside this word: split by its share; at its start:
                // the quiet between it and the previous word.
                var t = word.start
                if seen < before {
                    t = word.start + (word.end - word.start) * Double(before - seen) / Double(length)
                } else if index > 0 {
                    let previous = words[index - 1]
                    if word.start - previous.end > 0.08 { t = previous.end + (word.start - previous.end) * 0.6 }
                }
                return clamp(t)
            }
            seen += length
        }
        return clamp(byShare)
    }

    // MARK: Editing tools (EDT-074)

    private func editingStore() throws -> EditorStore {
        guard let store else { throw BridgeError(message: "No DogSC editor is open.") }
        return store
    }

    private func speechContext(store: EditorStore, language: String) throws -> SpeechContext {
        guard let prepared = playback?.preparedMedia,
              prepared.request.sourceSequence.withoutSceneStyles == store.project.timeline.sourceSequence.withoutSceneStyles,
              prepared.request.matchesPreparationManifests(store.project),
              prepared.request.canReuseSourceTracks(from: prepared.request) else {
            throw BridgeError(message: "Audio for the current cut is still preparing or its source files changed. Retry analysis when the media is ready.")
        }
        let request = prepared.request
        let inputs = ([request.source, request.microphone] + request.additionalSources.keys.sorted { $0.uuidString < $1.uuidString }.flatMap {
            [request.additionalSources[$0]?.screen, request.additionalSources[$0]?.microphone]
        }).compactMap { $0 }
        let manifests = Dictionary(uniqueKeysWithValues: store.project.sources.map { ($0.id, $0.media) })
        return SpeechContext(sequence: store.project.timeline.sourceSequence.withoutSceneStyles,
                             inputs: inputs, manifests: manifests, audio: store.project.audio,
                             overrides: store.project.timeline.primarySegmentAudioOverrides, language: language)
    }

    /// Transcription and waveform evidence share one export and one cached
    /// snapshot. Paging, token inspection and subtitle generation reuse it.
    /// Sequence, media versions, language and audio mix all participate in
    /// invalidation; a stale token ID can never cut a changed program.
    private func analyzeSpeech(language: String?, refresh: Bool = false) async throws -> SpeechEditAnalysis {
        let store = try editingStore()
        let language = language ?? speechAnalysis?.context.language ?? Locale.preferredLanguages.first ?? "zh-CN"
        let context = try speechContext(store: store, language: language)
        if !refresh, let cached = speechAnalysis, cached.context == context {
            lastTranscript = cached.analysis.transcript
            transcriptSequence = store.project.timeline.sourceSequence
            return cached.analysis
        }
        let pending: (id: UUID, context: SpeechContext, task: Task<SpeechEditAnalysis, Error>)
        if !refresh, let running = pendingSpeechAnalysis, running.context == context {
            pending = running
        } else {
            pendingSpeechAnalysis?.task.cancel()
            guard let media = playback?.preparedMedia?.composition else {
                throw BridgeError(message: "The project audio is not ready.")
            }
            let project = store.project
            let regions = media.plan.timelineMap.segments.map { segment -> SpeechEditAnalysis.Region in
                let tracks = media.recordingSources[segment.sourceID]
                let overrides = project.timeline.primarySegmentAudioOverrides[segment.id]
                let system = tracks?.systemAudio != nil && !(overrides?.isSystemMuted ?? project.audio.isSystemMuted)
                    && (overrides?.systemVolume ?? project.audio.systemVolume) > 0
                let microphone = tracks?.microphone != nil && !(overrides?.isMicrophoneMuted ?? project.audio.isMicrophoneMuted)
                    && (overrides?.microphoneVolume ?? project.audio.microphoneVolume) > 0
                return SpeechEditAnalysis.Region(segmentID: segment.id, sourceID: segment.sourceID,
                    start: segment.outputStart, end: segment.outputEnd, audible: !segment.isInserted && (system || microphone))
            }
            let task = Task { @MainActor in
                let url = FileManager.default.temporaryDirectory.appendingPathComponent("dogsc-speech-\(UUID().uuidString).m4a")
                defer { try? FileManager.default.removeItem(at: url) }
                try await AudioOnlyExportPipeline(media: media, outputURL: url, project: project,
                                                   voiceOnly: true, progressHandler: nil).run()
                return try await SpeechEditAnalysis.analyze(url: url, language: language,
                                                            duration: media.plan.outputDuration, regions: regions)
            }
            pending = (UUID(), context, task)
            pendingSpeechAnalysis = pending
        }
        defer { if pendingSpeechAnalysis?.id == pending.id { pendingSpeechAnalysis = nil } }
        let analysis = try await withTaskCancellationHandler { try await pending.task.value } onCancel: { pending.task.cancel() }
        try Task.checkCancellation()
        guard self.store === store, try speechContext(store: store, language: language) == context else {
            throw BridgeError(message: "The project or audio changed during analysis. Analyze the current program again.")
        }
        if speechAnalysis?.analysis.id != analysis.id, let log = AgentOperationLog.shared {
            var fields = diagnosticContext(turn: currentTurn)
            fields["language"] = language
            fields["videoFrameRate"] = store.project.exportSettings.frameRate.rawValue
            log.recordSpeech(analysis, fields: fields)
        }
        speechAnalysis = (context, analysis)
        lastTranscript = analysis.transcript
        transcriptSequence = store.project.timeline.sourceSequence
        return analysis
    }

    private func cutAnalyzedSpeech(_ params: [String: Any]) async throws -> [String: Any] {
        let store = try editingStore()
        guard let id = params["analysisId"] as? String, let cached = speechAnalysis, id == cached.analysis.id,
              try speechContext(store: store, language: cached.context.language) == cached.context else {
            throw BridgeError(message: "Speech analysis is missing or stale. Call audio_analyze_edits for the current timeline and use its analysisId; nothing was changed.")
        }
        for key in ["wordRanges", "pauses", "ranges"] where params[key] != nil {
            guard params[key] is [[String: Any]] else {
                throw BridgeError(message: "\(key) must be an array of edit objects; nothing was changed.")
            }
        }
        let words = params["wordRanges"] as? [[String: Any]] ?? []
        let pauses = params["pauses"] as? [[String: Any]] ?? []
        let explicit = params["ranges"] as? [[String: Any]] ?? []
        guard !words.isEmpty || !pauses.isEmpty || !explicit.isEmpty else {
            throw BridgeError(message: "Supply wordRanges [{from,to}] and/or pauses [{id,keep}]; nothing was changed.")
        }
        let resolution = try cached.analysis.resolve(wordRanges: words, pauses: pauses)
        let ranges = resolution.ranges.map { ["start": $0.start, "end": $0.end] } + explicit
        if ranges.isEmpty { return ["removed": 0, "removedSeconds": 0, "outputDuration": outputDuration()] }
        recordDiagnostics("timeline.cut.evidence", turn: currentTurn, fields: [
            "analysisId": id, "evidence": resolution.evidence,
        ])
        var result = try await cutRanges(ranges, analyzedContext: cached.context)
        result["boundaryEvidence"] = resolution.evidence
        result["timingBasis"] = "Explicit times take priority; otherwise word ranges use recognizer endpoints. Acoustic evidence is advisory."

        return result
    }

    /// The timeline as the AI sees it: every clip with its id and output span.
    private func timelineDescription() throws -> [String: Any] {
        let store = try editingStore()
        let t = store.project.timeline
        let motionNames = HTMLMotionEditing.DisplayNames(assets: t.mediaAssets)
        var main: [[String: Any]] = []
        if !recordingDurations().isEmpty, let map = try? TimelineMap(sourceSequence: t.sourceSequence, sourceDurations: recordingDurations()) {
            for s in map.segments {
                var row: [String: Any] = ["id": s.id.uuidString, "start": s.outputStart, "end": s.outputStart + s.outputDuration]
                if !s.isInserted {
                    row["source"] = ["id": s.sourceID.uuidString, "name": store.project.source(s.sourceID)?.name ?? "",
                                     "start": s.sourceStart, "end": s.sourceEnd]
                }
                if s.playbackRate != 1 { row["speed"] = s.playbackRate }
                if let media = s.media { row["inserted"] = media.name; if media.motionPath != nil { row["kind"] = "htmlMotion" } }
                main.append(row)
            }
        }
        func span(_ start: Double, _ end: Double) -> [String: Any] { ["start": start, "end": end] }
        let orderedZooms = t.zoomClips.sorted { $0.startTime < $1.startTime }
        let evaluatedZooms = ZoomTransitionResolution.resolve(orderedZooms, outputDuration: outputDuration())
        let zoomJoins = evaluatedZooms.indices.dropFirst().map { i -> [String: Any] in
            let left = evaluatedZooms[i - 1], right = evaluatedZooms[i]
            let gap = right.startTime - left.endTime
            let continuous = abs(gap) <= ZoomInterpolator.adjacencyTolerance
            let rightEnter = continuous && right.enterDuration <= 0.001
                ? min(store.project.motion.defaultZoomTransitionDuration, right.duration) : right.enterDuration
            return ["leftId": left.id.uuidString, "rightId": right.id.uuidString,
                "gap": gap, "continuous": continuous,
                "leftExitDuration": left.exitDuration, "rightEnterDuration": rightEnter,
                "fullFrameHold": continuous ? 0 : max(0, right.startTime - left.endTime - left.exitDuration)]
        }
        return [
            "outputDuration": outputDuration(),
            "revision": try AgentTimelineAccess.revision(store.project),
            "mainTrack": main,
            "zooms": t.zoomClips.map { span($0.startTime, $0.endTime).merging(
                ["id": $0.id.uuidString, "scale": $0.scale, "x": $0.focus.x, "y": $0.focus.y,
                 "enterDuration": $0.enterDuration,
                 "exitDuration": $0.requestedExitDuration(defaultTransition: store.project.motion.defaultZoomTransitionDuration),
                 "easing": $0.easing.rawValue,
                 "automatic": $0.origin == .automatic]) { a, _ in a } },
            "zoomJoins": zoomJoins,
            "zoomTiming": "start begins the entrance; end finishes the hold and starts the return. zoomJoins reports evaluated transitions and time held at 1x before the next entrance. Touching clips continue directly from the preceding camera state. Timing/continuity choices are editable, not automatic merge decisions.",
            "motion3d": t.screenMotionClips.map { span($0.timing.startTime, $0.timing.endTime).merging(
                ["id": $0.id.uuidString, "rotationX": $0.target.rotationX, "rotationY": $0.target.rotationY,
                 "rotationZ": $0.target.rotationZ, "scale": $0.target.scale]) { a, _ in a } },
            "highlights": t.mosaicClips.map { span($0.timing.startTime, $0.timing.endTime).merging(
                ["id": $0.id.uuidString, "style": $0.style.rawValue,
                 "box": ["x": $0.sourceRect.x, "y": $0.sourceRect.y, "width": $0.sourceRect.width, "height": $0.sourceRect.height]]) { a, _ in a } },
            "overlays": t.animationClips.map { span($0.timing.startTime, $0.timing.endTime).merging(
                ["id": $0.id.uuidString, "kind": "motion", "layerIndex": $0.layerIndex, "name": motionNames.name(for: $0.sourcePath)]) { a, _ in a } }
                + t.stickerClips.map { span($0.timing.startTime, $0.timing.endTime).merging(["id": $0.id.uuidString, "kind": "image", "layerIndex": $0.layerIndex]) { a, _ in a } }
                + t.videoClips.map { span($0.timing.startTime, $0.timing.endTime).merging(["id": $0.id.uuidString, "kind": "video", "layerIndex": $0.layerIndex]) { a, _ in a } },
            "audio": t.audioClips.map { span($0.timing.startTime, $0.timing.endTime).merging(
                ["id": $0.id.uuidString, "kind": $0.kind == .effect ? "effect" : "music",
                 "name": URL(fileURLWithPath: $0.sourcePath).deletingPathExtension().lastPathComponent]) { a, _ in a } },
            "subtitles": t.subtitleCues.count,
        ]
    }

    /// Removes output-time ranges from the main track as one edit: each range
    /// is split out and its pieces deleted, latest first so earlier ranges
    /// keep their times; everything after ripples earlier.
    private func cutRanges(_ raw: [[String: Any]], analyzedContext: SpeechContext? = nil) async throws -> [String: Any] {
        let store = try editingStore()
        let full = recordingDurations()
        guard !full.isEmpty else { throw BridgeError(message: "The project media is not ready yet.") }
        let originalMap = try TimelineMap(sourceSequence: store.project.timeline.sourceSequence, sourceDurations: full)
        var requested: [(Double, Double)] = []
        for r in raw {
            guard let a = (r["start"] as? NSNumber)?.doubleValue, let b = (r["end"] as? NSNumber)?.doubleValue,
                  a.isFinite, b.isFinite, a >= 0, b <= originalMap.outputDuration + 0.000_01, b - a > 1.0 / 120_000 else {
                throw BridgeError(message: "Every cut must be a finite range within the current program, longer than the timeline precision (1/120000 s); nothing was changed.")
            }
            requested.append((a, min(b, originalMap.outputDuration)))
        }
        requested.sort { $0.0 < $1.0 }
        var ranges: [(Double, Double)] = []
        for range in requested {
            if let last = ranges.last, range.0 <= last.1 {
                ranges[ranges.count - 1].1 = max(last.1, range.1)
            } else { ranges.append(range) }
        }
        guard !ranges.isEmpty else { throw BridgeError(message: "ranges [{start,end}] (output seconds) are required.") }
        // Normalize overlaps BEFORE ripple deletion, so one part of the
        // requested original interval cannot be deleted twice at shifted times.
        ranges.reverse()
        let original = store.project
        let reviewSnapshot = speechAnalysis.flatMap { cached in
            (try? speechContext(store: store, language: cached.context.language)) == cached.context ? cached : nil
        }
        let validatedRanges = ranges
        if AgentOperationLog.shared != nil {
            recordDiagnostics("timeline.cut.resolved", turn: currentTurn, fields: [
                "analysisId": reviewSnapshot?.analysis.id as Any? ?? NSNull(),
                "analysisSnapshotMatched": reviewSnapshot != nil,
                "resolvedRanges": ranges.map { ["start": $0.0, "end": $0.1] },
            ])
        }
        let worker = Task.detached(priority: .userInitiated) {
            var timeline = original.timeline
            var removed = 0, removedSeconds = 0.0
            var appliedRanges: [(Double, Double)] = []
            let transition = original.motion.defaultZoomTransitionDuration
            for (start, end) in validatedRanges {
                try Task.checkCancellation()
                for edge in [end, start] {
                    let currentMap = try TimelineMap(sourceSequence: timeline.sourceSequence, sourceDurations: full)
                    if currentMap.segments.contains(where: { edge > $0.outputStart + 1.0 / 120_000 && edge < $0.outputEnd - 1.0 / 120_000 }) {
                        timeline = try ProjectTimelineEditing.splitPrimarySegment(
                            in: timeline, atOutputTime: edge, newRightSegmentID: UUID(), sourceDurations: full)
                    }
                }
                let after = try TimelineMap(sourceSequence: timeline.sourceSequence, sourceDurations: full)
                let inside = after.segments.filter {
                    $0.outputStart >= start - 1.0 / 120_000 && $0.outputEnd <= end + 1.0 / 120_000
                }
                if let first = inside.first, let last = inside.last {
                    appliedRanges.append((first.outputStart, last.outputEnd))
                }
                for segment in inside.reversed() {
                    try Task.checkCancellation()
                    timeline = try ProjectTimelineEditing.removePrimarySegment(
                        from: timeline, segmentID: segment.id, sourceDurations: full, defaultTransitionDuration: transition)
                }
                if !inside.isEmpty { removed += 1; removedSeconds += inside.reduce(0) { $0 + $1.outputDuration } }
            }
            let duration = try TimelineMap(sourceSequence: timeline.sourceSequence, sourceDurations: full).outputDuration
            return (timeline, removed, removedSeconds, duration, appliedRanges)
        }
        let (timeline, removed, removedSeconds, duration, appliedRanges) = try await withTaskCancellationHandler {
            try await worker.value
        } onCancel: { worker.cancel() }
        try Task.checkCancellation()
        guard self.store === store, store.project.timeline == original.timeline, recordingDurations() == full,
              store.project.motion.defaultZoomTransitionDuration == original.motion.defaultZoomTransitionDuration else {
            throw BridgeError(message: "The project changed while preparing cuts; nothing was written. Read the current timeline again.")
        }
        if let context = analyzedContext, try speechContext(store: store, language: context.language) != context {
            throw BridgeError(message: "The analysed audio changed while preparing cuts; nothing was written.")
        }
        var cutReview: [String: Any] = ["available": false, "reason": "No matching speech analysis for the pre-cut audio."]
        if let cached = reviewSnapshot,
           (try? speechContext(store: store, language: cached.context.language)) == cached.context {
            cutReview = cached.analysis.cutReview(cuts: appliedRanges.map { .init(start: $0.0, end: $0.1) },
                before: originalMap, after: try TimelineMap(sourceSequence: timeline.sourceSequence, sourceDurations: full),
                frameRate: store.project.exportSettings.frameRate.rawValue)
        }
        if removed > 0 { try store.replaceTimeline(with: timeline, actionName: "AI 剪辑") }
        let applied = appliedRanges.reversed().map { ["start": $0.0, "end": $0.1] }
        let sourceSpans = appliedRanges.reversed().flatMap { start, end in
            originalMap.segments.compactMap { segment -> [String: Any]? in
                let a = max(start, segment.outputStart), b = min(end, segment.outputEnd)
                guard b > a else { return nil }
                var row: [String: Any] = ["segmentId": segment.id.uuidString, "start": a, "end": b,
                    "sourceStart": segment.sourceStart + (a - segment.outputStart) * segment.playbackRate,
                    "sourceEnd": segment.sourceStart + (b - segment.outputStart) * segment.playbackRate]
                if let media = segment.media { row["mediaPath"] = media.path }
                else { row["sourceId"] = segment.sourceID.uuidString }
                return row
            }
        }
        recordDiagnostics("timeline.cut.applied", turn: currentTurn, fields: [
            "appliedRanges": applied, "sourceSpans": sourceSpans, "outputDuration": duration,
            "removedSeconds": removedSeconds, "cutReview": cutReview,
        ])
        return ["removed": removed, "removedSeconds": removedSeconds, "outputDuration": duration,
                "appliedRanges": applied, "sourceSpans": sourceSpans, "cutReview": cutReview,
                "revision": try AgentTimelineAccess.revision(store.project)]
    }

    /// Deletes clips of any kind by id, as one edit.
    private func removeClips(_ ids: [UUID]) throws -> [String: Any] {
        let store = try editingStore()
        guard !ids.isEmpty else { throw BridgeError(message: "ids are required (from timeline.get).") }
        let wanted = Set(ids)
        var t = store.project.timeline
        let removedVisual = t.animationClips.contains { wanted.contains($0.id) }
            || t.stickerClips.contains { wanted.contains($0.id) }
            || t.videoClips.contains { wanted.contains($0.id) }
        let before = t.zoomClips.count + t.screenMotionClips.count + t.cameraMotionClips.count + t.mosaicClips.count + t.animationClips.count
            + t.stickerClips.count + t.videoClips.count + t.audioClips.count + t.subtitleCues.count
        t.zoomClips.removeAll { wanted.contains($0.id) }
        t.screenMotionClips.removeAll { wanted.contains($0.id) }
        t.cameraMotionClips.removeAll { wanted.contains($0.id) }
        t.mosaicClips.removeAll { wanted.contains($0.id) }
        t.animationClips.removeAll { wanted.contains($0.id) }
        t.stickerClips.removeAll { wanted.contains($0.id) }
        t.videoClips.removeAll { wanted.contains($0.id) }
        t.audioClips.removeAll { wanted.contains($0.id) }
        t.subtitleCues.removeAll { wanted.contains($0.id) }
        var removed = before - (t.zoomClips.count + t.screenMotionClips.count + t.cameraMotionClips.count + t.mosaicClips.count + t.animationClips.count
            + t.stickerClips.count + t.videoClips.count + t.audioClips.count + t.subtitleCues.count)
        let full = recordingDurations()
        if !full.isEmpty, case let .edited(segments) = t.sourceSequence {
            for segment in segments where wanted.contains(segment.id) {
                t = try ProjectTimelineEditing.removePrimarySegment(
                    from: t, segmentID: segment.id, sourceDurations: full,
                    defaultTransitionDuration: store.project.motion.defaultZoomTransitionDuration)
                removed += 1
            }
        }
        guard removed > 0 else { throw BridgeError(message: "None of those ids are on the timeline (see timeline.get).") }
        if removedVisual { t.organizeVisualLayers() }
        try store.replaceTimeline(with: t, actionName: "AI 删除片段")
        return ["removed": removed]
    }

    /// Recorded pointer events mapped to output time (cut spans dropped).
    private func pointerEvents(from: Double?, to: Double?, kinds: [String]) -> [[String: Any]] {
        guard let store, !recordingDurations().isEmpty,
              let map = try? TimelineMap(sourceSequence: store.project.timeline.sourceSequence,
                                         sourceDurations: recordingDurations()) else { return [] }
        let wantsMoves = kinds.contains("move")
        var result: [[String: Any]] = []
        for segment in map.mapPointerEventSegments(eventsBySource: pointerEventsBySource()) {
            var lastMove = -1.0
            for event in segment.events {
                let click = event.kind != PointerEventKind.move
                let time = event.time
                guard click || wantsMoves else { continue }
                if let from, time < from { continue }
                if let to, time > to { break }
                if !click {
                    guard time - lastMove >= 0.5 else { continue }
                    lastMove = time
                }
                result.append([
                    "t": (time * 100).rounded() / 100,
                    "kind": click ? "click" : "move",
                    "x": (event.location.x * 1000).rounded() / 1000,
                    "y": (event.location.y * 1000).rounded() / 1000,
                    "source": segment.sourceID.uuidString,
                    "segmentId": segment.id.uuidString,
                ])
                if result.count >= 600 { return result }
            }
        }
        return result
    }

    private static let settingKeys = ["canvas", "camera", "audio", "motion", "cursorStyle", "exportSettings"]

    private func settingsJSON() throws -> [String: Any] {
        let store = try editingStore()
        let data = try JSONEncoder().encode(store.project)
        guard let all = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
        return all.filter { Self.settingKeys.contains($0.key) }
    }

    private func canvasSnapshot(_ params: [String: Any]) async throws -> [String: Any] {
        let allowed = Set(["time", "view", "maxDimension"])
        guard Set(params.keys).isSubset(of: allowed) else {
            throw BridgeError(message: "canvas_snapshot accepts time, view (canvas/source), and maxDimension.")
        }
        for key in ["time", "maxDimension"] where params[key] != nil && !(params[key] is NSNumber) {
            throw BridgeError(message: "\(key) must be a number.")
        }
        let store = try editingStore()
        let project = store.project
        guard let prepared = playback?.preparedMedia,
              prepared.request.sourceSequence.withoutSceneStyles == project.timeline.sourceSequence.withoutSceneStyles,
              prepared.request.matchesPreparationManifests(project),
              let canvas = canvasSize(), canvas.width > 0, canvas.height > 0,
              let package = projectPackageURL(), let workspace = workspaceURL else {
            throw BridgeError(message: "Media for the current project is still preparing.")
        }
        let requested = (params["time"] as? NSNumber)?.doubleValue ?? playback?.outputTime ?? 0
        let maxDimension = (params["maxDimension"] as? NSNumber)?.doubleValue ?? 1280
        let view = params["view"] as? String ?? "canvas"
        guard requested.isFinite, requested >= 0, requested <= prepared.outputDuration,
              maxDimension.isFinite, maxDimension >= 64, maxDimension <= 8192,
              ["canvas", "source"].contains(view) else {
            throw BridgeError(message: "time must be within the program; view is canvas/source; maxDimension is 64...8192 pixels.")
        }
        let time = min(requested, prepared.outputDuration.nextDown)
        let revision = try AgentTimelineAccess.revision(project)
        let backgrounds = Dictionary(uniqueKeysWithValues: project.sceneBackgroundSources.compactMap { source -> (String, URL)? in
            guard let key = source.sceneResourceKey, let url = snapshotWallpaperURL(source) else { return nil }
            return (key, url)
        })
        let cursors = Dictionary(uniqueKeysWithValues: CursorAssetLibrary.renderAssets.compactMap { asset in
            asset.renderSource().map { (asset.id, $0) }
        })
        let renderer = AgentCanvasSnapshot(project: project, media: prepared.composition, canvas: canvas,
            backgrounds: backgrounds, cursors: cursors, package: package)
        let task = Task.detached(priority: .userInitiated) {
            try await renderer.render(at: time, sourceOnly: view == "source", maxDimension: maxDimension)
        }
        let snapshot = try await withTaskCancellationHandler { try await task.value } onCancel: {
            renderer.cancel(); task.cancel()
        }
        try Task.checkCancellation()
        guard self.store === store, projectPackageURL() == package else {
            throw BridgeError(message: "The open project changed during the snapshot.")
        }
        let name = "preview-\(view)-\(revision.prefix(12))-\(UUID().uuidString).png"
        let path = workspace.appendingPathComponent(name)
        guard let png = NSBitmapImageRep(cgImage: snapshot.image).representation(using: .png, properties: [:]) else {
            throw BridgeError(message: "Could not encode the snapshot.")
        }
        try png.write(to: path, options: .atomic)
        let screen = snapshot.scene.screen
        func point(_ value: CompositionPoint) -> [String: Double] { ["x": value.x, "y": value.y] }
        func rect(_ value: CompositionRect) -> [String: Double] {
            ["x": value.x, "y": value.y, "width": value.width, "height": value.height]
        }
        let content = screen.sourceContentRect
        let contentCorners = [CompositionPoint(x: content.x, y: content.y),
            CompositionPoint(x: content.x + content.width, y: content.y),
            CompositionPoint(x: content.x + content.width, y: content.y + content.height),
            CompositionPoint(x: content.x, y: content.y + content.height)]
        var result: [String: Any] = ["path": path.path, "width": snapshot.image.width, "height": snapshot.image.height,
            "view": view, "requestedTime": requested, "time": time, "revision": revision,
            "projectChangedDuringRead": store.project != project, "segmentId": snapshot.segmentID.uuidString,
            "geometry": ["canvasWidth": snapshot.scene.canvasSize.width, "canvasHeight": snapshot.scene.canvasSize.height,
                         "recordingCrop": ["x": screen.sourceCrop.x, "y": screen.sourceCrop.y,
                                           "width": screen.sourceCrop.width, "height": screen.sourceCrop.height],
                         "screenQuad": screen.projectedQuad.corners.map(point),
                         "contentQuad": contentCorners.compactMap { screen.projectedQuad.project($0, from: screen.projectionRect) }.map(point),
                         "coordinates": "Canvas pixel coordinates, top-left origin. source view is the uncropped recording; zoom/highlight coordinates use that recording, not the canvas."] as [String: Any]]
        if let camera = snapshot.scene.camera { result["cameraRect"] = rect(camera.rect) }
        if let sourceID = snapshot.sourceID { result["sourceId"] = sourceID.uuidString }
        if let actual = snapshot.decodedSourceTime { result["decodedSourceTime"] = actual }
        return result
    }

    /// Deep-merges a patch into the whole-video settings; the result must
    /// decode and validate, or nothing changes.
    private func applySettings(_ patch: [String: Any]) throws -> [String: Any] {
        let store = try editingStore()
        let unknown = patch.keys.filter { !Self.settingKeys.contains($0) }
        guard unknown.isEmpty else {
            throw BridgeError(message: "Unknown settings: \(unknown.joined(separator: ", ")). Allowed: \(Self.settingKeys.joined(separator: ", ")).")
        }
        let data = try JSONEncoder().encode(store.project)
        guard var all = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
        func merge(_ base: Any?, _ change: Any) -> Any {
            guard let b = base as? [String: Any], let c = change as? [String: Any] else { return change }
            var out = b
            for (k, v) in c { out[k] = merge(b[k], v) }
            return out
        }
        for (key, value) in patch { all[key] = merge(all[key], value) }
        let merged = try JSONSerialization.data(withJSONObject: all)
        let next: RecorderProject
        do { next = try JSONDecoder().decode(RecorderProject.self, from: merged) }
        catch { throw BridgeError(message: "That patch does not fit the settings shape: \(error.localizedDescription)") }
        do { try ProjectValidator.validate(next) }
        catch { throw BridgeError(message: "Refused: \(error.localizedDescription)") }
        try store.replaceProject(with: next, actionName: "AI 调整全片设置")
        return try settingsJSON()
    }

    /// The app's own manual, from the bundled guide.
    static func appHelp(topic: String?) -> [String: Any] {
        let guide = Bundle.main.url(forResource: "DogSC-Guide", withExtension: "md", subdirectory: "Agent")
            .flatMap { try? String(contentsOf: $0, encoding: .utf8) } ?? ""
        guard let topic = topic?.trimmingCharacters(in: .whitespaces), !topic.isEmpty else { return ["guide": guide] }
        // Sections whose heading or text mention the topic, else the whole guide.
        let sections = guide.components(separatedBy: "\n## ").filter { $0.localizedCaseInsensitiveContains(topic) }
        return ["guide": sections.isEmpty ? guide : sections.map { "## " + $0 }.joined(separator: "\n")]
    }

    private static func stepTime(_ method: String, _ p: [String: Any]) -> Double? {
        switch method {
        case "timeline.addAudio", "timeline.addVideo", "timeline.addSticker", "timeline.insertBlack", "html.create",
             "zoom.add", "motion3d.add", "highlight.add":
            return (p["start"] as? NSNumber)?.doubleValue ?? 0
        case "canvas.snapshot":
            return (p["time"] as? NSNumber)?.doubleValue
        case "sound.create":
            return (p["start"] as? NSNumber)?.doubleValue
        default: return nil
        }
    }

    /// A short technical line under the step title.
    private static func stepDetail(_ method: String, _ p: [String: Any], _ result: Any) -> String? {
        func n(_ key: String) -> Double? { (p[key] as? NSNumber)?.doubleValue }
        switch method {
        case "timeline.addAudio", "timeline.addVideo", "timeline.insertBlack":
            let start = n("start") ?? 0
            if let d = n("duration") { return span(start, start + d) }
            return clock(start)
        case "media.import":
            return ((p["paths"] as? [String]) ?? []).map { ($0 as NSString).lastPathComponent }.prefix(3).joined(separator: "、")
        case "subtitles.style":
            return p.keys.sorted().joined(separator: " · ")
        default:
            return nil
        }
    }

    struct WordLine {
        let from: Int; let to: Int; let text: String?; let secondary: String?
        var start: Double? = nil
        var end: Double? = nil
        var holdToNext: Bool? = nil
    }

    /// Use the supplied aligned word endpoints or exact cue overrides. Display
    /// text cleanup and translation do not recompute those times.
    static func timed(_ lines: [WordLine], words: [SystemTranscriber.Word],
                      alignment: SpeechSubtitleAlignment? = nil) -> [SubtitleCue] {
        let transcriptText = words.map { $0.displayText ?? $0.text }
        let captionText = SubtitleText.censoredSpeechTokens(transcriptText)
        var rawBounds: [(start: Double, end: Double)] = []
        var cues = lines.map { line in
            let spoken = words[line.from...line.to]
            let voiced = spoken.filter { $0.text.contains { $0.isLetter || $0.isNumber } }
            let first = voiced.first ?? spoken.first!
            let last = voiced.last ?? spoken.last!
            let range = line.from...line.to
            let reference = transcriptText[range].joined()
            let primary = line.text.map { SubtitleText.preservingNumericNotation($0, from: reference) }
                ?? captionText[range].joined()
            rawBounds.append((first.start, last.end))
            let bounds = alignment?.bounds(from: line.from, to: line.to)
            let start = line.start ?? bounds?.start ?? first.start
            let end = line.end ?? bounds?.end ?? last.end
            return SubtitleCue(timing: OverlayTiming(startTime: start, duration: end - start),
                text: SubtitleText.speechDisplay(primary),
                secondaryText: line.secondary.map {
                    SubtitleText.speechDisplay(SubtitleText.preservingNumericNotation($0, from: reference))
                }.flatMap { $0.isEmpty ? nil : $0 })
        }
        // A caller may decide each gap individually. Explicit ends take
        // priority; holding only extends the previous cue and never moves a
        // following cue. Omitted choices retain the existing ASR cleanup.
        for i in cues.indices where i > 0 {
            guard lines[i - 1].end == nil,
                  cues[i - 1].timing.endTime < cues[i].timing.startTime else { continue }
            let correctionGap = alignment != nil && lines[i].start == nil
                && abs(rawBounds[i - 1].end - rawBounds[i].start) < 0.000_01
                && cues[i].timing.startTime > rawBounds[i].start
            guard lines[i - 1].holdToNext ?? correctionGap else { continue }
            cues[i - 1].timing.duration = cues[i].timing.startTime - cues[i - 1].timing.startTime
        }
        return cues
    }

    /// Explicit edge cleanup stays inside each cue and never reassigns words.
    static func settled(_ cues: [SubtitleCue], speech: SpeechActivity?) -> [SubtitleCue] {
        guard let speech, let acoustics = try? SpeechAcousticEvidence(activity: speech, regions: [
            .init(segmentID: UUID(), sourceID: RecordingSource.primaryID, start: 0, end: speech.duration, audible: true)
        ]) else { return cues }
        return cues.map { original in
            var cue = original
            let bounds = SpeechSubtitleAlignment.refined(start: cue.timing.startTime, end: cue.timing.endTime,
                first: .init(start: cue.timing.startTime, end: cue.timing.endTime, text: ""), acoustics: acoustics)
            cue.timing = OverlayTiming(startTime: bounds.start, duration: bounds.end - bounds.start)
            return cue
        }
    }

    private static func validateSubtitleTimes(_ cues: [SubtitleCue], duration: Double) throws {
        var previousEnd: Double = 0
        var ids = Set<UUID>()
        for (index, cue) in cues.sorted(by: { $0.timing.startTime < $1.timing.startTime }).enumerated() {
            let timing = cue.timing
            guard timing.startTime.isFinite, timing.duration.isFinite, timing.startTime >= 0,
                  timing.duration > 0, timing.endTime <= duration + 0.05,
                  timing.startTime >= previousEnd - 0.000_5, ids.insert(cue.id).inserted else {
                throw BridgeError(message: "cue \(index): invalid, overlapping or out-of-program times; nothing was written.")
            }
            previousEnd = timing.endTime
        }
    }

    private func call(_ method: String, _ p: [String: Any]) async throws -> Any {
        // Each call runs as a task the user's Stop can cancel (long renders
        // check for cancellation between frames).
        final class Box: @unchecked Sendable { let value: Any; init(_ v: Any) { value = v } }
        nonisolated(unsafe) let params = p
        let id = UUID()
        let turn = currentTurn
        let startedAt = ProcessInfo.processInfo.systemUptime
        recordDiagnostics("tool.started", turn: turn, fields: [
            "callId": id.uuidString, "method": method, "parameters": p,
        ])
        let task = Task { @MainActor in
            try await AgentOperationLog.$callID.withValue(id) {
                try await EditorStore.$isAgentMutation.withValue(true) {
                    try Task.checkCancellation()
                    return Box(try await self.execute(method, params))
                }
            }
        }
        running[id] = { task.cancel() }
        defer { running[id] = nil }
        do {
            let result = try await task.value.value
            guard !task.isCancelled else { throw CancellationError() }
            recordDiagnostics("tool.finished", turn: turn, fields: [
                "callId": id.uuidString, "method": method, "status": "succeeded",
                "durationMS": (ProcessInfo.processInfo.systemUptime - startedAt) * 1_000,
                "result": result,
            ])
            if turn == currentTurn { report(method, p, result) }
            return result
        } catch {
            let failure = error as NSError
            recordDiagnostics("tool.finished", turn: turn, fields: [
                "callId": id.uuidString, "method": method,
                "status": task.isCancelled || error is CancellationError ? "cancelled" : "failed",
                "durationMS": (ProcessInfo.processInfo.systemUptime - startedAt) * 1_000,
                "error": ["message": error.localizedDescription, "domain": failure.domain, "code": failure.code],
            ])
            throw error
        }
    }

    private var running: [UUID: () -> Void] = [:]

    /// Cancels whatever DogSC is still doing for the stopped turn.
    func cancelRunning() {
        running.values.forEach { $0() }
        running = [:]
    }

    private func execute(_ method: String, _ p: [String: Any]) async throws -> Any {
        guard let store else { throw BridgeError(message: "No DogSC editor is open.") }
        let duration = outputDuration()
        func num(_ key: String) -> Double? { (p[key] as? NSNumber)?.doubleValue }
        switch method {
        case "methods":
            return Self.methods.map { ["name": $0.name, "summary": $0.summary] }
        case "project.summary":
            let t = store.project.timeline
            return [
                "workspace": workspaceURL?.path ?? "",
                "canvas": canvasSize().map { ["width": Int($0.width), "height": Int($0.height),
                                              "htmlViewport": ["width": Int(HTMLMotionRenderer.viewport(for: $0).width),
                                                               "height": Int(HTMLMotionRenderer.viewport(for: $0).height)]] as [String: Any] } ?? [:],
                "library": AssetLibrary.shared.folder.path,
                "libraryFolders": Dictionary(uniqueKeysWithValues: [MediaAssetKind.animation, .image, .audio, .video].map {
                    ($0.rawValue, AssetLibrary.shared.folder(for: $0).path)
                }),
                "title": store.project.title,
                "outputDuration": duration,
                "playhead": playback?.outputTime ?? 0,
                "animations": t.animationClips.count,
                "audioClips": t.audioClips.count,
                "stickers": t.stickerClips.count,
                "subtitles": t.subtitleCues.count,
                "media": t.mediaAssets.count,
                "motions": Self.motionSummary(t),
            ] as [String: Any]
        case "media.list":
            let scope = p["scope"] as? String ?? "project"
            guard ["project", "library", "all"].contains(scope) else { throw BridgeError(message: "scope is project, library or all.") }
            let kind = p["kind"] as? String
            var rows: [[String: Any]] = []
            if scope != "library" {
                rows += store.project.timeline.mediaAssets.filter { kind == nil || $0.kind.rawValue == kind }.map {
                    ["id": $0.id.uuidString, "name": $0.name, "kind": $0.kind.rawValue, "path": ProjectFiles.resolve($0.path),
                     "scope": "project", "missing": !ProjectFiles.exists($0.path)] as [String: Any]
                }
            }
            if scope != "project" {
                AssetLibrary.shared.reload()
                rows += AssetLibrary.shared.entries.filter { kind == nil || $0.kind.rawValue == kind }.map {
                    ["id": $0.id.uuidString, "name": $0.name, "kind": $0.kind.rawValue, "path": $0.path,
                     "scope": "library", "favorite": $0.favorite, "generated": $0.generated, "missing": !$0.exists] as [String: Any]
                }
            }
            return rows
        case "media.import":
            let paths = p["paths"] as? [String] ?? []
            return store.importMediaAssets(paths.map { URL(fileURLWithPath: $0) }).map { $0.id.uuidString }
        case "sound.download":
            guard let url = p["url"] as? String, let page = p["sourceURL"] as? String,
                  let license = p["licenseURL"] as? String else {
                throw BridgeError(message: "url, sourceURL and verified CC0 licenseURL are required.")
            }
            guard RemoteSoundDownloader.isCC0(license) else { throw BridgeError(message: "Only CC0 sounds are supported.") }
            _ = try RemoteSoundDownloader.remoteURL(url)
            _ = try RemoteSoundDownloader.remoteURL(page)
            let library = AssetLibrary.shared
            library.reload()
            let result: RemoteSoundImport.Result
            let length: Double
            if let existing = RemoteSoundImport.existing(url: url, library: library) {
                result = .init(entry: existing, reused: true)
                length = try await AVURLAsset(url: URL(fileURLWithPath: existing.path)).load(.duration).seconds
            } else {
                let download = try await RemoteSoundDownloader.shared.download(url: url, sourceURL: page, licenseURL: license)
                defer { try? FileManager.default.removeItem(at: download.file) }
                try Task.checkCancellation()
                guard self.store === store else { throw BridgeError(message: "The project changed during the download; try again in the current project.") }
                length = download.duration
                result = try RemoteSoundImport.save(download, name: p["name"] as? String, library: library)
            }
            try Task.checkCancellation()
            guard self.store === store else { throw BridgeError(message: "The project changed during the download; try again in the current project.") }
            let assetID = try RemoteSoundImport.register(result.entry, store: store)
            return ["path": result.entry.path, "assetId": assetID.uuidString, "duration": length,
                    "reused": result.reused, "license": "CC0", "sourceURL": result.entry.remoteSource?.pageURL ?? page] as [String: Any]
        case "timeline.addAudio":
            guard let path = p["path"] as? String else { throw BridgeError(message: "path is required") }
            store.importMediaAssets([URL(fileURLWithPath: path)])
            let kind: AudioClipKind = (p["kind"] as? String) == "effect" ? .effect : .music
            let start = min(max(num("start") ?? 0, 0), max(duration - 0.25, 0))
            let id = try Self.insertedAudio(path: path, at: start, kind: kind, in: store.project.timeline)?.id
                ?? store.addAudioClip(sourcePath: ProjectFiles.portable(path), kind: kind, at: start, outputDuration: duration)
            commitTimelineEdit(store, action: "AI 调整音频") { timeline in
                guard let i = timeline.audioClips.firstIndex(where: { $0.id == id }) else { return }
                if let v = num("volume") { timeline.audioClips[i].volume = v }
                if let f = num("fadeIn") { timeline.audioClips[i].fadeIn = f }
                if let f = num("fadeOut") { timeline.audioClips[i].fadeOut = f }
            }
            return id.uuidString
        case "timeline.addVideo":
            guard let path = p["path"] as? String else { throw BridgeError(message: "path is required") }
            store.importMediaAssets([URL(fileURLWithPath: path)])
            let id = try await store.addVideoClip(sourcePath: ProjectFiles.portable(path), at: num("start") ?? 0, outputDuration: duration)
            commitTimelineEdit(store, action: "AI 调整视频") { timeline in
                guard let i = timeline.videoClips.firstIndex(where: { $0.id == id }) else { return }
                if let w = num("width") { timeline.videoClips[i].width = w }
                if let x = num("x") { timeline.videoClips[i].position.x = x }
                if let y = num("y") { timeline.videoClips[i].position.y = y }
                if let v = num("volume") { timeline.videoClips[i].volume = v }
                timeline.organizeVisualLayers()
            }
            return id.uuidString
        case "subtitles.get":
            return store.project.timeline.subtitleCues.map {
                ["id": $0.id.uuidString, "start": $0.timing.startTime, "end": $0.timing.endTime,
                 "text": $0.text, "secondary": $0.secondaryText ?? ""] as [String: Any]
            }
        case "subtitles.updateText":
            guard let patches = p["cues"] as? [[String: Any]], !patches.isEmpty else {
                throw BridgeError(message: "cues is required: [{id, text?, secondary?}]. Read subtitles_get for IDs.")
            }
            var timeline = store.project.timeline
            var updated = Set<UUID>()
            for patch in patches {
                guard Set(patch.keys).isSubset(of: ["id", "text", "secondary"]),
                      let value = patch["id"] as? String, let id = UUID(uuidString: value),
                      let index = timeline.subtitleCues.firstIndex(where: { $0.id == id }),
                      updated.insert(id).inserted, patch["text"] != nil || patch["secondary"] != nil else {
                    throw BridgeError(message: "Each patch needs an existing unique subtitle id and text or secondary. Timing fields are not accepted; nothing was written.")
                }
                if let value = patch["text"] {
                    guard let text = value as? String, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                        throw BridgeError(message: "Subtitle text must be a nonempty string; nothing was written.")
                    }
                    timeline.subtitleCues[index].text = text
                }
                if let value = patch["secondary"] {
                    guard let text = value as? String else {
                        throw BridgeError(message: "secondary must be a string (empty to clear); nothing was written.")
                    }
                    timeline.subtitleCues[index].secondaryText = text.isEmpty ? nil : text
                }
            }
            try store.replaceTimeline(with: timeline, actionName: "AI 修改字幕文字")
            return ["updated": updated.count, "timingUnchanged": true] as [String: Any]
        case "subtitles.set":
            guard let raw = p["cues"] as? [[String: Any]] else { throw BridgeError(message: "cues is required") }
            let previous = store.project.timeline.subtitleCues
            let cues: [SubtitleCue] = try raw.map { item in
                guard let start = (item["start"] as? NSNumber)?.doubleValue,
                      let end = (item["end"] as? NSNumber)?.doubleValue, end > start,
                      let text = item["text"] as? String, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    throw BridgeError(message: "Every cue needs finite start/end times and nonempty text; nothing was written.")
                }
                let id: UUID
                if let rawID = item["id"] {
                    guard let value = rawID as? String, let parsed = UUID(uuidString: value) else {
                        throw BridgeError(message: "Invalid subtitle id; nothing was written.")
                    }
                    id = parsed
                } else {
                    id = previous.first { abs($0.timing.startTime - start) < 0.000_001 && abs($0.timing.endTime - end) < 0.000_001 }?.id ?? UUID()
                }
                return SubtitleCue(id: id, timing: OverlayTiming(startTime: start, duration: end - start),
                    text: text, secondaryText: (item["secondary"] as? String).flatMap { $0.isEmpty ? nil : $0 })
            }
            try Self.validateSubtitleTimes(cues, duration: duration)
            try store.replaceSubtitles(cues, actionName: "更新字幕")
            return ["count": cues.count, "note": "Supplied text and times preserved. Use subtitles_update_text for local corrections."] as [String: Any]
        case "subtitles.style":
            commitTimelineEdit(store, action: "AI 调整字幕样式") { timeline in
                if let v = num("fontScale") { timeline.subtitleStyle.fontScale = v }
                if let v = num("bottomMargin") { timeline.subtitleStyle.bottomMargin = v }
                if let v = num("backgroundOpacity") { timeline.subtitleStyle.backgroundOpacity = v }
                if let v = p["showsSecondary"] as? Bool { timeline.subtitleStyle.showsSecondary = v }
            }
            return ["ok": true]
        case "audio.export":
            guard let media = playback?.preparedMedia?.composition else {
                throw BridgeError(message: "The project media is not ready yet.")
            }
            let url = (p["path"] as? String).map { URL(fileURLWithPath: $0) }
                ?? FileManager.default.temporaryDirectory.appendingPathComponent("dogsc-audio-\(UUID().uuidString).m4a")
            try? FileManager.default.removeItem(at: url)
            let pipeline = try AudioOnlyExportPipeline(
                media: media, outputURL: url, project: store.project, progressHandler: nil)
            try await pipeline.run()
            return ["path": url.path, "duration": duration]
        case "html.create":
            guard let html = p["html"] as? String, html.contains("<") else {
                throw BridgeError(message: "html is required: a complete HTML motion page.")
            }
            let file = try HTMLMotionEditing.create(name: (p["name"] as? String) ?? "", html: html,
                copy: (p["copy"] as? Bool) ?? false, library: .shared)
            let url = file.url
            let name = (file.entry.name as NSString).deletingPathExtension
            let length = max(num("duration") ?? HTMLMotion.declaredDuration(path: url.path) ?? 3, 0.2)
            let start = min(max(num("start") ?? playback?.outputTime ?? 0, 0), duration)
            if (p["placement"] as? String) == "main" {
                let source = recordingDurations()
                guard !source.isEmpty else { throw BridgeError(message: "The project media is not ready yet.") }
                if file.reused, let existing = Self.insertedSegment(motionPath: url.path, at: start, in: store.project.timeline) {
                    var actualDuration = length
                    if case let .edited(segments) = store.project.timeline.sourceSequence {
                        actualDuration = segments.first(where: { $0.id == existing })?.outputDuration ?? length
                    }
                    return ["path": url.path, "segmentId": existing.uuidString, "start": start, "duration": actualDuration,
                            "note": "This motion is already on the main track here; nothing was added."] as [String: Any]
                }
                var soundURL: URL?
                var temporarySound = false
                if let path = p["soundPath"] as? String {
                    let local = ProjectFiles.url(path)
                    guard ProjectFiles.exists(path), MediaAssetKind.kind(forExtension: local.pathExtension) == .audio else {
                        throw BridgeError(message: "soundPath must be a downloaded or imported local audio file.")
                    }
                    soundURL = local
                } else if let raw = p["sound"], JSONSerialization.isValidJSONObject(raw) {
                    let events = try JSONDecoder().decode([SoundSynth.Event].self, from: JSONSerialization.data(withJSONObject: raw))
                    let temp = FileManager.default.temporaryDirectory.appendingPathComponent("dogsc-sound-\(UUID().uuidString).m4a")
                    try SoundSynth.render(events, length: length, to: temp)
                    soundURL = temp
                    temporarySound = true
                }
                defer { if temporarySound, let soundURL { try? FileManager.default.removeItem(at: soundURL) } }
                store.importMediaAssets([url])
                let id = try await store.insertHTMLMotionOnMainTrack(
                    path: url.path, name: name, at: start, duration: length,
                    usesFrameStyle: (p["framed"] as? Bool) ?? false, sound: soundURL, sourceDurations: source)
                return ["path": url.path, "segmentId": id.uuidString, "start": start, "duration": length] as [String: Any]
            }
            if file.reused, let existing = Self.insertedOverlay(motionPath: url.path, at: start, in: store.project.timeline) {
                return ["path": url.path, "clipId": existing.id.uuidString, "start": existing.timing.startTime,
                        "duration": existing.timing.duration, "note": "This motion is already placed here; nothing was added."] as [String: Any]
            }
            store.importMediaAssets([url])
            let id = try store.addAnimation(sourcePath: ProjectFiles.portable(url.path), at: start, outputDuration: duration)
            commitTimelineEdit(store, action: "AI 调整动效") { timeline in
                guard let i = timeline.animationClips.firstIndex(where: { $0.id == id }) else { return }
                timeline.animationClips[i].timing.duration = length
                timeline.animationClips[i].layerIndex = timeline.visualLayer(for: timeline.animationClips[i].timing, excluding: id)
                timeline.animationClips[i].width = num("width") ?? 1
                if let x = num("x") { timeline.animationClips[i].position.x = x }
                if let y = num("y") { timeline.animationClips[i].position.y = y }
                timeline.organizeVisualLayers()
            }
            return ["path": url.path, "clipId": id.uuidString, "start": start, "duration": length] as [String: Any]
        case "html.update":
            guard let html = p["html"] as? String else { throw BridgeError(message: "html is required") }
            let id: UUID?
            if let raw = p["id"] {
                guard let value = raw as? String, let parsed = UUID(uuidString: value) else {
                    throw BridgeError(message: "id must be a current clip or asset UUID.")
                }
                id = parsed
            } else { id = nil }
            let result = try HTMLMotionEditing.update(id: id, path: p["path"] as? String,
                html: html, store: store, library: .shared)
            return ["path": result.path, "assetId": result.assetID.uuidString, "unchanged": result.unchanged] as [String: Any]
        case "html.preview":
            guard let path = p["path"] as? String, let workspace = workspaceURL else { throw BridgeError(message: "path is required") }
            let resolved = ProjectFiles.resolve(path)
            let times = (p["times"] as? [NSNumber])?.map(\.doubleValue) ?? [0.3, 1, 2]
            var outputs: [String] = []
            let context = CIContext()
            var overrides: [String: AnimationPropertyValue] = [:]
            for (key, value) in p["params"] as? [String: Any] ?? [:] {
                if let s = value as? String { overrides[key] = s.hasPrefix("#") ? HexColor(s).map { .color($0) } ?? .string(s) : .string(s) }
                else if let n = value as? NSNumber { overrides[key] = .number(n.doubleValue) }
            }
            for time in times.prefix(8) {
                let canvas = canvasSize() ?? CGSize(width: 1920, height: 1080)
                let scale = min(1280 / max(canvas.width, 1), 1280 / max(canvas.height, 1), 1)
                let size = CGSize(width: (canvas.width * scale).rounded(), height: (canvas.height * scale).rounded())
                guard let image = await HTMLMotion.image(path: resolved, properties: overrides, time: time, pixelSize: size),
                      let cg = context.createCGImage(image, from: CGRect(origin: .zero, size: size)) else { continue }
                // Over a checkerboard-free dark grey so transparent areas read.
                let out = workspace.appendingPathComponent("preview-\(URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent)-\(String(format: "%.2f", time)).png")
                try NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:])?.write(to: out)
                outputs.append(out.path)
            }
            return outputs
        case "sound.create":
            guard let raw = p["events"], JSONSerialization.isValidJSONObject(raw) else {
                throw BridgeError(message: "events is required: [{type, at, duration?, volume?, pitch?, pan?}]")
            }
            let events = try JSONDecoder().decode([SoundSynth.Event].self, from: JSONSerialization.data(withJSONObject: raw))
            let rawName = (p["name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let name = (rawName.isEmpty ? "音效" : rawName).replacingOccurrences(of: "/", with: "-")
            let folder = AssetLibrary.shared.folder(for: .audio)
            var url = folder.appendingPathComponent(name).appendingPathExtension("m4a")
            var copy = 2
            while FileManager.default.fileExists(atPath: url.path) {
                url = folder.appendingPathComponent("\(name) \(copy)").appendingPathExtension("m4a"); copy += 1
            }
            let length = try SoundSynth.render(events, to: url)
            AssetLibrary.shared.addGenerated(url)
            store.importMediaAssets([url])
            var result: [String: Any] = ["path": url.path, "duration": length]
            if let start = num("start") {
                let id = try store.addAudioClip(sourcePath: ProjectFiles.portable(url.path), kind: .effect,
                                                at: start, outputDuration: duration)
                if let v = num("volume") {
                    commitTimelineEdit(store, action: "AI 调整音效") { timeline in
                        if let i = timeline.audioClips.firstIndex(where: { $0.id == id }) { timeline.audioClips[i].volume = v }
                    }
                }
                result["clipId"] = id.uuidString
            }
            return result
        case "timeline.insertBlack":
            let source = recordingDurations()
            guard !source.isEmpty else { throw BridgeError(message: "The project media is not ready yet.") }
            let start = min(max(num("start") ?? 0, 0), duration)
            try await store.insertBlackOnMainTrack(at: start, duration: max(num("duration") ?? 2, 0.2), sourceDurations: source)
            return ["ok": true, "start": start]
        case "timeline.get":
            return try timelineDescription()
        case "timeline.inspect":
            var ids: Set<UUID>?
            if let value = p["ids"] {
                guard let raw = value as? [String], raw.allSatisfy({ UUID(uuidString: $0) != nil }) else {
                    throw BridgeError(message: "ids must be an array of timeline UUIDs.")
                }
                ids = Set(raw.compactMap(UUID.init(uuidString:)))
            }
            return try AgentTimelineAccess.inspect(project: store.project, durations: recordingDurations(), ids: ids)
        case "timeline.update":
            if let value = p["revision"] {
                guard let revision = value as? String, revision == (try AgentTimelineAccess.revision(store.project)) else {
                    throw BridgeError(message: "The supplied project revision is invalid or stale; nothing was changed.")
                }
            }
            guard let changes = p["changes"] as? [[String: Any]] else { throw BridgeError(message: "changes [{id,patch}] is required.") }
            let next = try AgentTimelineAccess.updated(project: store.project, changes: changes, durations: recordingDurations())
            try store.replaceTimeline(with: next, actionName: appLocalized("AI 编辑"))
            let ids = Set(changes.compactMap { ($0["id"] as? String).flatMap(UUID.init(uuidString:)) })
            return try AgentTimelineAccess.inspect(project: store.project, durations: recordingDurations(), ids: ids)
        case "timeline.addSticker":
            guard let path = p["path"] as? String, let start = num("start"), let end = num("end"),
                  start.isFinite, end.isFinite, start >= 0, end > start, end <= duration,
                  MediaAssetKind.kind(forExtension: URL(fileURLWithPath: path).pathExtension) == .image,
                  FileManager.default.fileExists(atPath: ProjectFiles.resolve(path)) else {
                throw BridgeError(message: "A readable local image path and start/end within the program are required.")
            }
            let portable = ProjectFiles.portable(path)
            var t = store.project.timeline
            var clip = StickerClip(timing: .init(startTime: start, duration: end - start), relativePath: portable,
                position: .init(x: num("x") ?? 0.5, y: num("y") ?? 0.5), width: num("width") ?? 0.38)
            clip.layerIndex = t.visualLayer(for: clip.timing)
            if let opacity = num("opacity") { clip.opacity = opacity }
            t.stickerClips.append(clip)
            t.organizeVisualLayers()
            if !t.mediaAssets.contains(where: { $0.path == portable }) { t.mediaAssets.append(MediaAsset(path: portable, kind: .image)) }
            try store.replaceTimeline(with: t, actionName: appLocalized("添加贴图"))
            return ["id": clip.id.uuidString, "value": try AgentTimelineAccess.object(clip)] as [String: Any]
        case "timeline.cut":
            if let value = p["revision"] {
                guard let revision = value as? String, revision == (try AgentTimelineAccess.revision(store.project)) else {
                    throw BridgeError(message: "The supplied project revision is invalid or stale; nothing was changed.")
                }
            }
            if p["analysisId"] != nil || p["wordRanges"] != nil || p["pauses"] != nil { return try await cutAnalyzedSpeech(p) }
            return try await cutRanges(p["ranges"] as? [[String: Any]] ?? [])
        case "timeline.remove":
            return try removeClips((p["ids"] as? [String] ?? []).compactMap(UUID.init(uuidString:)))
        case "pointer.events":
            return pointerEvents(from: num("from"), to: num("to"), kinds: p["kinds"] as? [String] ?? ["click"])
        case "zoom.add":
            guard let start = num("start"), let end = num("end"), end > start else {
                throw BridgeError(message: "start and end (output seconds, end > start) are required.")
            }
            let motion = store.project.motion
            let transition = num("transition") ?? motion.defaultZoomTransitionDuration
            let clip = ZoomAnimationClip(
                startTime: max(start, 0), endTime: min(end, duration),
                scale: min(max(num("scale") ?? motion.defaultZoomScale ?? 1.6, 1.05), 4),
                focus: NormalizedPoint(x: min(max(num("x") ?? 0.5, 0), 1), y: min(max(num("y") ?? 0.5, 0), 1)),
                easing: motion.defaultZoomEasing, enterDuration: transition, exitDuration: transition)
            try store.insertZoom(clip, actionName: "AI 添加缩放")
            return ["id": clip.id.uuidString, "start": clip.startTime, "end": clip.endTime]
        case "motion3d.add":
            guard let start = num("start"), let end = num("end"), end > start else {
                throw BridgeError(message: "start and end (output seconds, end > start) are required.")
            }
            let lead = num("leadIn") ?? store.project.motion.defaultZoomTransitionDuration
            let target = ScreenMotionState(
                position: NormalizedPoint(x: num("x") ?? 0.5, y: num("y") ?? 0.5),
                scale: num("scale") ?? 0.9,
                rotationX: num("rotationX") ?? 0, rotationY: num("rotationY") ?? -14, rotationZ: num("rotationZ") ?? 0,
                perspective: num("perspective") ?? 0.65)
            let clip = ScreenMotionClip(
                timing: TransitionTiming(startTime: max(start, 0), duration: min(end, duration) - max(start, 0),
                                         leadInDuration: lead, easing: store.project.motion.defaultZoomEasing,
                                         returnDuration: lead),
                target: target)
            try store.insertScreenMotion(clip, actionName: "AI 添加 3D 运镜")
            return ["id": clip.id.uuidString, "start": clip.timing.startTime, "end": clip.timing.endTime]
        case "highlight.add":
            guard let start = num("start"), let end = num("end"), end > start else {
                throw BridgeError(message: "start and end (output seconds, end > start) are required.")
            }
            let style: MosaicEffectStyle = (p["style"] as? String) == "blur" ? .blur : .spotlight
            var clip = MosaicClip(
                timing: OverlayTiming(startTime: max(start, 0), duration: min(end, duration) - max(start, 0)),
                sourceRect: NormalizedOverlayRect(x: num("x") ?? 0.35, y: num("y") ?? 0.39,
                                                  width: num("width") ?? 0.3, height: num("height") ?? 0.22).clamped(),
                style: style,
                transitionStyle: .smooth)
            if let dim = num("dim") { clip.spotlightDimming = min(max(dim, 0), 0.9) }
            var timeline = store.project.timeline
            timeline.mosaicClips.append(clip)
            try store.replaceTimeline(with: timeline, actionName: style == .blur ? "AI 添加柔化" : "AI 添加聚光")
            return ["id": clip.id.uuidString]
        case "settings.get":
            return try settingsJSON()
        case "settings.set":
            guard let patch = p["patch"] as? [String: Any] else { throw BridgeError(message: "patch (object) is required.") }
            return try applySettings(patch)
        case "app.help":
            return Self.appHelp(topic: p["topic"] as? String)
        case "canvas.snapshot":
            return try await canvasSnapshot(p)
        case "audio.transcribe":
            let analysis = try await analyzeSpeech(language: p["language"] as? String, refresh: p["refresh"] as? Bool ?? false)
            let transcript = analysis.transcript
            func r(_ t: Double) -> Double { (t * 100).rounded() / 100 }
            return [
                "analysisId": analysis.id,
                "videoFrameRate": store.project.exportSettings.frameRate.rawValue,
                "subtitleAlignment": analysis.subtitleAlignment.description(raw: transcript.words),
                "phrases": transcript.segments.map {
                    ["start": r($0.start), "end": r($0.end), "text": $0.text, "from": $0.firstWord, "to": $0.lastWord] as [String: Any]
                },
                "words": transcript.words.enumerated().map { index, word in
                    ["i": index, "s": r(word.start), "e": r(word.end), "t": word.text] as [String: Any]
                },
                "next": "For captions, use subtitles_set_from_words with from/to and omit text to preserve the spoken wording. For speech editing use audio_analyze_edits for waveform evidence and cut candidates.",
            ] as [String: Any]
        case "audio.analyzeEdits":
            let analysis = try await analyzeSpeech(language: p["language"] as? String, refresh: p["refresh"] as? Bool ?? false)
            let from = num("from") ?? 0
            let requestedEnd = num("to") ?? min(from + 180, analysis.duration)
            guard from.isFinite, requestedEnd.isFinite, from >= 0, from < analysis.duration, requestedEnd > from else {
                throw BridgeError(message: "from/to must be a positive output-time window within the program.")
            }
            return analysis.description(from: from, to: min(requestedEnd, from + 300, analysis.duration),
                                        includeWords: p["includeWords"] as? Bool ?? false,
                                        includeWaveform: p["includeWaveform"] as? Bool ?? false,
                                        frameRate: store.project.exportSettings.frameRate.rawValue)
        case "subtitles.fromWords":
            guard let transcript = lastTranscript, !transcript.words.isEmpty else {
                throw BridgeError(message: "Call audio_transcribe first: lines are timed from its words.")
            }
            guard let cached = speechAnalysis,
                  transcriptSequence?.withoutSceneStyles == store.project.timeline.sourceSequence.withoutSceneStyles,
                  try speechContext(store: store, language: cached.context.language) == cached.context,
                  p["analysisId"] == nil || p["analysisId"] as? String == cached.analysis.id else {
                throw BridgeError(message: "The transcript does not match the current audio. Transcribe the current program before using word IDs.")
            }
            let words = transcript.words
            guard let raw = p["cues"] as? [[String: Any]], !raw.isEmpty else {
                throw BridgeError(message: "cues is required: [{from,to,secondary?}]. The transcript supplies the text by default.")
            }
            var lines: [WordLine] = []
            var previousTo = -1
            for (index, item) in raw.enumerated() {
                guard let fromNumber = item["from"] as? NSNumber, let toNumber = item["to"] as? NSNumber,
                      fromNumber.doubleValue.isFinite, toNumber.doubleValue.isFinite,
                      fromNumber.doubleValue >= 0, fromNumber.doubleValue <= toNumber.doubleValue,
                      toNumber.doubleValue < Double(words.count),
                      fromNumber.doubleValue.rounded() == fromNumber.doubleValue,
                      toNumber.doubleValue.rounded() == toNumber.doubleValue else {
                    throw BridgeError(message: "cue \(index): invalid word indexes; nothing was written.")
                }
                let text = item["text"] as? String
                if item["text"] != nil, text?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false {
                    throw BridgeError(message: "cue \(index): omit text for transcript wording or provide a nonempty string.")
                }
                let from = fromNumber.intValue, to = toNumber.intValue
                guard from > previousTo, to >= from else {
                    throw BridgeError(message: "cue \(index): word range \(from)-\(to) overlaps or is out of order; nothing was written.")
                }
                for key in ["start", "end"] where item[key] != nil && !(item[key] is NSNumber) {
                    throw BridgeError(message: "cue \(index): \(key) must be an output time in seconds.")
                }
                if let hold = item["holdToNext"], !(hold is Bool) {
                    throw BridgeError(message: "cue \(index): holdToNext must be a boolean.")
                }
                lines.append(WordLine(from: from, to: to, text: text,
                    secondary: (item["secondary"] as? String).flatMap { $0.isEmpty ? nil : $0 },
                    start: (item["start"] as? NSNumber)?.doubleValue,
                    end: (item["end"] as? NSNumber)?.doubleValue,
                    holdToNext: item["holdToNext"] as? Bool))
                previousTo = to
            }
            let alignment = cached.analysis.subtitleAlignment
            let timedCues = Self.timed(lines, words: words, alignment: alignment)
            try Self.validateSubtitleTimes(timedCues, duration: duration)
            let cues = timedCues.filter { !$0.text.isEmpty }
            try store.replaceSubtitles(cues, actionName: "AI 生成字幕")
            let covered = Set(lines.flatMap { Array($0.from...$0.to) })
            let uncovered = words.indices.filter { !covered.contains($0) && SpeechEditAnalysis.isSpoken(words[$0].text) }
            let frameRate = store.project.exportSettings.frameRate.rawValue
            let gaps = cues.indices.dropFirst().compactMap { i -> [String: Any]? in
                let previous = cues[i - 1], next = cues[i]
                let gap = next.timing.startTime - previous.timing.endTime
                guard gap > 0.000_01 else { return nil }
                return ["previousId": previous.id.uuidString, "nextId": next.id.uuidString,
                    "start": previous.timing.endTime, "end": next.timing.startTime,
                    "duration": gap, "durationFrames": gap * Double(frameRate)]
            }
            return ["count": cues.count, "analysisId": cached.analysis.id,
                    "omittedEmptyCues": timedCues.count - cues.count,
                    "uncoveredWords": uncovered, "alignment": alignment.description(raw: words),
                    "videoFrameRate": frameRate, "gaps": gaps,
                    "cueTimes": cues.map { ["id": $0.id.uuidString, "start": $0.timing.startTime, "end": $0.timing.endTime, "text": $0.text] as [String: Any] },
                    "note": "Cue edges retain waveform-supported alignment. holdToNext on the preceding cue extends its end to the next cue's start; false preserves a gap. Explicit end takes priority. Omitted choices retain existing ASR gap cleanup. No duration threshold is imposed. Next starts and audio are unchanged."] as [String: Any]

        case "subtitles.alignToSpeech":
            guard let prepared = playback?.preparedMedia,
                  prepared.request.sourceSequence == store.project.timeline.sourceSequence else {
                throw BridgeError(message: "Audio for the current cut is still preparing; try again once it is ready.")
            }
            let media = prepared.composition
            let sequence = store.project.timeline.sourceSequence
            let originalCues = store.project.timeline.subtitleCues
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("dogsc-voice-\(UUID().uuidString).m4a")
            defer { try? FileManager.default.removeItem(at: url) }
            try await AudioOnlyExportPipeline(media: media, outputURL: url, project: store.project,
                                              voiceOnly: true, progressHandler: nil).run()
            let speech = try await Task.detached(priority: .userInitiated) { try SpeechActivity.measure(url: url) }.value
            guard self.store === store, store.project.timeline.sourceSequence == sequence,
                  store.project.timeline.subtitleCues == originalCues else {
                throw BridgeError(message: "The project or captions changed during speech analysis; nothing was written.")
            }
            let cues = Self.settled(originalCues, speech: speech)
            try store.replaceSubtitles(cues, actionName: "字幕对齐语音")
            return ["count": cues.count] as [String: Any]
        default:
            throw BridgeError(message: "Unknown method \(method). Call 'methods' for the list.")
        }
    }
}
