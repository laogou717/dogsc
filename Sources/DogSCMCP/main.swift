import Foundation

// dogsc-mcp: a stdio MCP server that forwards tool calls to the open DogSC
// editor's local bridge (EDT-054). It holds no project state itself.

let infoURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    .appendingPathComponent("DogSC/agent-bridge.json")

struct Tool {
    let name: String
    let method: String
    let description: String
    let properties: [String: Any]
    let required: [String]
}

let number: [String: Any] = ["type": "number"]
let string: [String: Any] = ["type": "string"]
let tools: [Tool] = [
    Tool(name: "project_summary", method: "project.summary",
         description: "Open project's title, output duration in seconds, playhead and clip counts.", properties: [:], required: []),
    Tool(name: "media_list", method: "media.list",
         description: "List existing media: scope project (default), library, or all; optional kind video/image/audio/animation. Returns IDs, names, paths and missing status.",
         properties: ["scope": string, "kind": string], required: []),
    Tool(name: "media_import", method: "media.import",
         description: "Add files to the media bin by reference (never copied).",
         properties: ["paths": ["type": "array", "items": string]], required: ["paths"]),
    Tool(name: "sound_download", method: "sound.download",
         description: "Download an existing CC0 sound into the library and project bin; retries reuse files. Supply its direct audio url, source page sourceURL and verified CC0 licenseURL. Returns local path/duration; place with timeline_add_audio or attach via html_create soundPath.",
         properties: ["url": string, "sourceURL": string, "licenseURL": string, "name": string], required: ["url", "sourceURL", "licenseURL"]),
    Tool(name: "timeline_add_audio", method: "timeline.addAudio",
         description: "Place background music or a sound effect. volume 0-1, fades in seconds. Reuses the same path/start/kind on a retry.",
         properties: ["path": string, "start": number, "kind": ["type": "string", "enum": ["music", "effect"]],
                      "volume": number, "fadeIn": number, "fadeOut": number], required: ["path", "start"]),
    Tool(name: "timeline_add_video", method: "timeline.addVideo",
         description: "Place a video (B-roll) over the recording. Full frame by default; for picture-in-picture use width ~0.3 and x/y (centre, 0-1). volume 0-1.",
         properties: ["path": string, "start": number, "x": number, "y": number, "width": number, "volume": number], required: ["path", "start"]),
    Tool(name: "subtitles_get", method: "subtitles.get",
         description: "Current subtitle cues with stable IDs, text and output times.", properties: [:], required: []),
    Tool(name: "subtitles_update_text", method: "subtitles.updateText",
         description: "Correct text/translation on specific subtitle IDs. Preserves every cue's start, end and order. Use for local corrections; read subtitles_get for IDs.",
         properties: ["cues": ["type": "array", "items": ["type": "object", "properties": [
            "id": string, "text": string, "secondary": string], "required": ["id"]]]], required: ["cues"]),
    Tool(name: "subtitles_set", method: "subtitles.set",
         description: "Replace all subtitles at the supplied times in one undoable step. Each cue: id (optional), start, end, text, secondary (optional). Use subtitles_update_text for local corrections.",
         properties: ["cues": ["type": "array", "items": ["type": "object", "properties": [
            "id": string, "start": number, "end": number, "text": string, "secondary": string], "required": ["start", "end", "text"]]]],
         required: ["cues"]),
    Tool(name: "subtitles_style", method: "subtitles.style",
         description: "Subtitle style: fontScale (of canvas height; default 0.03), bottomMargin (default 0.05), backgroundOpacity (default 1), showsSecondary. Existing custom styles are preserved.",
         properties: ["fontScale": number, "bottomMargin": number, "backgroundOpacity": number, "showsSecondary": ["type": "boolean"]],
         required: []),
    Tool(name: "html_create", method: "html.create",
         description: "Create and place an HTML motion (format in the skill). placement overlay puts it above the recording; main inserts a full-screen clip. Identical retries reuse the file and placement. Revise with html_update; copy:true creates an independent asset. sound: optional events attached to a main-track clip.",
         properties: ["name": string, "html": string, "start": number, "duration": number,
                      "placement": ["type": "string", "enum": ["overlay", "main"]], "x": number, "y": number, "width": number,
                      "framed": ["type": "boolean"], "copy": ["type": "boolean"], "soundPath": string, "sound": ["type": "array", "items": ["type": "object"]]],
         required: ["name", "html", "placement"]),
    Tool(name: "html_update", method: "html.update",
         description: "Revise an existing library HTML motion used by this project. Supply exactly one current clip/asset id or path, plus the full html. One undoable edit preserves IDs, timing, per-instance fields and user edits, with one bin item. Returns the new path; other projects retain their source.",
         properties: ["id": string, "path": string, "html": string], required: ["html"]),
    Tool(name: "html_preview", method: "html.preview",
         description: "Render PNG frames of an HTML motion page at given times (seconds) to check the design and the timing.",
         properties: ["path": string, "times": ["type": "array", "items": number]], required: ["path"]),
    Tool(name: "sound_create", method: "sound.create",
         description: "Synthesise a sound effect from layered events and save it to the library; with start, also place it on an audio track. Event types: whoosh (rising air), swoosh_down, riser (build-up), hit, boom (low impact), click, tick, pop, ding, chime (3-note), shimmer (sparkle), glitch, tone. Each event: {type, at (s), duration?, volume 0-1.5?, pitch Hz?, pan -1..1?}.",
         properties: ["name": string, "events": ["type": "array", "items": ["type": "object"]], "start": number, "volume": number],
         required: ["name", "events"]),
    Tool(name: "timeline_insert_black", method: "timeline.insertBlack",
         description: "Insert a black clip into the main track at start (default 2 s); everything after it moves later.",
         properties: ["start": number, "duration": number], required: ["start"]),
    Tool(name: "timeline_get", method: "timeline.get",
         description: "Everything on the timeline in output seconds, with ids: main-track segments, zooms, 3D moves, highlights, overlays, audio. Object IDs address individual occurrences. Zooms include authored transitions/easing; zoomJoins reports evaluated gap, leftExitDuration, rightEnterDuration, fullFrameHold at 1x and continuous handoff. These expose timing for editorial choices, not automatic merging. Overlays include layerIndex.",
         properties: [:], required: [] as [String]),
    Tool(name: "timeline_inspect", method: "timeline.inspect",
         description: "Read native editable values for timeline objects, optionally filtered by ids. Returns a project revision and objects {id,kind,value}. Main clip value exposes source {start,end,speed}, audio, sceneStyle and media. source uses media seconds; output timing and availableSource bounds are reported separately.",
         properties: ["ids": ["type": "array", "items": string]], required: []),
    Tool(name: "timeline_update", method: "timeline.update",
         description: "Apply partial patches to existing native objects in one undoable edit. changes [{id,patch}] uses the value shape from timeline_inspect; omitted fields stay unchanged. Supports zoom, 3D, camera motion, highlight, sticker, animation, video, audio, subtitle, and main clip source/media/appearance/audio. Main patch.source {start?,end?,speed?} trims or extends media-source edges and ripples dependent tracks, like manual edge dragging. Optional revision detects intervening edits. Returns actual updated values.",
         properties: ["revision": string, "changes": ["type": "array", "items": ["type": "object", "properties": ["id": string, "patch": ["type": "object"]], "required": ["id", "patch"]]]], required: ["changes"]),
    Tool(name: "timeline_add_sticker", method: "timeline.addSticker",
         description: "Place an image as a native editable sticker over the program. start/end are output seconds; x/y are canvas centre coordinates (0-1); width is canvas width fraction.",
         properties: ["path": string, "start": number, "end": number, "x": number, "y": number, "width": number, "opacity": number], required: ["path", "start", "end"]),
    Tool(name: "timeline_cut", method: "timeline.cut",
         description: "Cut output-time ranges in one undoable edit; dependent tracks follow. Use ranges [{start,end}], or analysisId with wordRanges [{from,to,start?,end?}] and pauses [{id,keep}]. Word IDs are inclusive; defaults are recognizer endpoints, optional start/end are exact overrides. keep is remaining pause seconds (default 0.25, minimum 0). Acoustic evidence is advisory, not permission. analysisId checks the audio snapshot; explicit ranges may be included with it. Optional revision from timeline_get binds any cut to that project state. Returns appliedRanges and, when matching speech analysis is cached, cutReview for every new join: fine edge waveform, retained quiet, utterance context and current segment IDs/source bounds for further timeline_update edits. remainingPauses lists all retained pause candidates, including those within kept sentences, in the new output clock.",
         properties: ["revision": string, "analysisId": string,
                      "wordRanges": ["type": "array", "items": ["type": "object", "properties": ["from": ["type": "integer"], "to": ["type": "integer"], "start": number, "end": number], "required": ["from", "to"]]],
                      "pauses": ["type": "array", "items": ["type": "object", "properties": ["id": ["type": "integer"], "keep": number], "required": ["id"]]],
                      "ranges": ["type": "array", "items": ["type": "object", "properties": ["start": number, "end": number], "required": ["start", "end"]]]], required: []),
    Tool(name: "timeline_remove", method: "timeline.remove",
         description: "Delete clips by id (zoom, 3D, highlight, overlay, audio, subtitle, video or main-track segment) in one undoable step. Ids come from timeline_get.",
         properties: ["ids": ["type": "array", "items": ["type": "string"]]], required: ["ids"]),
    Tool(name: "pointer_events", method: "pointer.events",
         description: "Recorded mouse clicks (and optionally moves) in output seconds with x,y (0-1 of the recording). Clicks show where the viewer's attention was — good zoom targets.",
         properties: ["from": ["type": "number"], "to": ["type": "number"], "kinds": ["type": "array", "items": ["type": "string", "enum": ["click", "move"]]]], required: [] as [String]),
    Tool(name: "zoom_add", method: "zoom.add",
         description: "Add a purposeful camera push-in on the recording. x,y = source focus (0-1), scale 1.05-4 (default: the project's). start begins entrance; end begins return; transition is seconds per leg. Choose the span around the actual explanation or action. Touching clips continue without a 1x reset. Existing startTime/endTime, focus, scale and separate transition durations are editable with timeline_update; timeline_get reports zoomJoins.",
         properties: ["start": ["type": "number"], "end": ["type": "number"], "x": ["type": "number"], "y": ["type": "number"], "scale": ["type": "number"], "transition": ["type": "number"]], required: ["start", "end", "x", "y"]),
    Tool(name: "motion3d_add", method: "motion3d.add",
         description: "Add a 3D move of the recording (tilt in degrees). Position and timing are editable.",
         properties: ["start": ["type": "number"], "end": ["type": "number"], "rotationX": ["type": "number"], "rotationY": ["type": "number"], "rotationZ": ["type": "number"], "scale": ["type": "number"], "x": ["type": "number"], "y": ["type": "number"], "leadIn": ["type": "number"]], required: ["start", "end"]),
    Tool(name: "highlight_add", method: "highlight.add",
         description: "Highlight a box on the recording: 'spotlight' dims everything else to draw the eye, 'blur' hides the box (passwords, private data). Box is 0-1 of the recording, top-left origin.",
         properties: ["start": ["type": "number"], "end": ["type": "number"], "x": ["type": "number"], "y": ["type": "number"], "width": ["type": "number"], "height": ["type": "number"], "style": ["type": "string", "enum": ["spotlight", "blur"]], "dim": ["type": "number"]], required: ["start", "end", "x", "y", "width", "height"]),
    Tool(name: "settings_get", method: "settings.get",
         description: "The whole-video settings as JSON: canvas (background, padding, corners, device frame), camera bubble, audio levels, cursor, motion defaults, export settings.",
         properties: [:], required: [] as [String]),
    Tool(name: "settings_set", method: "settings.set",
         description: "Change whole-video settings with a JSON patch in the same shape as settings_get (merged, one undoable step). Invalid values are refused with the reason — read settings_get first.",
         properties: ["patch": ["type": "object"]], required: ["patch"]),
    Tool(name: "app_help", method: "app.help",
         description: "How DogSC itself is used: where each setting lives, shortcuts and step-by-step paths. Use it to answer the user's 'how do I…' questions accurately.",
         properties: ["topic": ["type": "string"]], required: [] as [String]),
    Tool(name: "canvas_snapshot", method: "canvas.snapshot",
         description: "Render a specified output time independently of the editor playhead. Returns PNG path, requested/rendered time, decoded source timestamp, source/clip IDs and coordinate geometry. view canvas (default) includes all effects; source shows the uncropped recording. maxDimension defaults to 1280 (64...8192).",
         properties: ["time": number, "view": string, "maxDimension": number], required: []),
    Tool(name: "audio_transcribe", method: "audio.transcribe",
         description: "Transcribe the edited program voice with the macOS recognizer. Returns phrases and numbered tokens {i,s,e,t} in output seconds. Cached with audio_analyze_edits; refresh forces reanalysis. For speech cuts use audio_analyze_edits for waveform boundaries.",
         properties: ["language": string, "refresh": ["type": "boolean"]], required: []),
    Tool(name: "audio_analyze_edits", method: "audio.analyzeEdits",
         description: "Raw speech, independent local waveform evidence, suggested cut times, pause IDs, utterance context spanning pauses, nearby repeated phrases with surrounding takes, and existing edit joins in output seconds. Suggestions can fall inside recognizer ranges; none is an automatic deletion or sentence verdict. from/to select a window (default 180 s, pages up to 300 s). includeWords adds token boundaries; includeWaveform adds broad peak dBFS bins. Joins always include fine local waveform; utterance context is not split by silence. pauseGroups combines brief-noise-separated pauses with text context and optional acousticInterior cut ranges. Cached with audio_transcribe; refresh reanalyses. analysisId ties word IDs and pauses to this audio snapshot. Frame counts use the current export videoFrameRate, independently of the audio measurementStep. Existing joins expose leftQuietFrames/rightQuietFrames; cutReview exposes left/right quietFrames and total retainedQuietFrames. Short includeWaveform windows give finer local detail.",
         properties: ["language": string, "from": number, "to": number, "includeWords": ["type": "boolean"], "includeWaveform": ["type": "boolean"], "refresh": ["type": "boolean"]], required: []),
    Tool(name: "subtitles_set_from_words", method: "subtitles.fromWords",
         description: "Generate captions from inclusive from/to word IDs. Omit text for faithful transcript wording and automatic profanity filtering. Put translations in secondary; use subtitles_update_text for specific recognition errors. Only supply text for an explicitly requested rewrite. Local waveform evidence refines edges. holdToNext extends the cue to the next start; explicit start/end take priority. Returns cue IDs, times and gaps.",
         properties: ["analysisId": string, "cues": ["type": "array", "items": ["type": "object", "properties": [
             "from": ["type": "integer"], "to": ["type": "integer"], "text": ["type": "string", "description": "Omit unless the user explicitly requested a rewrite."], "secondary": string, "start": number, "end": number, "holdToNext": ["type": "boolean"],
         ], "required": ["from", "to"]]]], required: ["cues"]),
    Tool(name: "subtitles_align_to_speech", method: "subtitles.alignToSpeech",
         description: "Refine measured silence inside existing subtitle edges without shifting neighboring cues. Regenerate from a fresh transcript for incorrect word alignment.",
         properties: [:], required: []),
    Tool(name: "audio_export", method: "audio.export",
         description: "Write the edited program audio (M4A, aligned to output time) and return its path, for transcription.",
         properties: ["path": string], required: []),
]

func bridgeCall(_ method: String, _ params: [String: Any]) -> (Any?, String?) {
    guard let data = try? Data(contentsOf: infoURL),
          let info = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let port = info["port"] as? Int, let token = info["token"] as? String else {
        return (nil, "DogSC is not running with an editor open.")
    }
    var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/rpc")!)
    request.httpMethod = "POST"
    request.timeoutInterval = 600
    request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.httpBody = try? JSONSerialization.data(withJSONObject: ["method": method, "params": params])
    let semaphore = DispatchSemaphore(value: 0)
    final class Box: @unchecked Sendable { var value: (Any?, String?) = (nil, "No response") }
    let box = Box()
    URLSession.shared.dataTask(with: request) { data, _, error in
        defer { semaphore.signal() }
        if let error { box.value = (nil, error.localizedDescription); return }
        guard let data, let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        box.value = (json["result"], json["error"] as? String)
    }.resume()
    semaphore.wait()
    return box.value
}

/// The editing guide (the dogsc-editor skill) travels with the server, so
/// clients without a skills folder still learn units, tools and file rules.
let instructions: String? = {
    let executable = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
    let skill = executable.deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Resources/Agent/DogSC-Skill.md")
    guard var text = try? String(contentsOf: skill, encoding: .utf8) else { return nil }
    if text.hasPrefix("---"), let end = text.range(of: "\n---", range: text.index(text.startIndex, offsetBy: 3)..<text.endIndex) {
        text = String(text[end.upperBound...])
    }
    return text.trimmingCharacters(in: .whitespacesAndNewlines)
}()

func send(_ object: [String: Any]) {
    guard let data = try? JSONSerialization.data(withJSONObject: object) else { return }
    FileHandle.standardOutput.write(data + Data("\n".utf8))
}

while let line = readLine(strippingNewline: true) {
    guard let data = line.data(using: .utf8),
          let message = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let method = message["method"] as? String else { continue }
    let id = message["id"]
    guard let id else { continue } // notifications need no reply
    let params = message["params"] as? [String: Any] ?? [:]
    switch method {
    case "initialize":
        var result: [String: Any] = [
            "protocolVersion": params["protocolVersion"] as? String ?? "2024-11-05",
            "capabilities": ["tools": [:]],
            "serverInfo": ["name": "dogsc", "version": "1.0"],
        ]
        if let instructions { result["instructions"] = instructions }
        send(["jsonrpc": "2.0", "id": id, "result": result])
    case "ping":
        send(["jsonrpc": "2.0", "id": id, "result": [:]])
    case "tools/list":
        send(["jsonrpc": "2.0", "id": id, "result": ["tools": tools.map {
            ["name": $0.name, "description": $0.description,
             "inputSchema": ["type": "object", "properties": $0.properties, "required": $0.required]]
        }]])
    case "tools/call":
        let name = params["name"] as? String ?? ""
        guard let tool = tools.first(where: { $0.name == name }) else {
            send(["jsonrpc": "2.0", "id": id, "error": ["code": -32602, "message": "Unknown tool \(name)"]])
            continue
        }
        let (result, error) = bridgeCall(tool.method, params["arguments"] as? [String: Any] ?? [:])
        let text: String
        if let error {
            text = error
        } else if let result, JSONSerialization.isValidJSONObject(result),
                  let data = try? JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]) {
            text = String(decoding: data, as: UTF8.self)
        } else {
            text = result.map { "\($0)" } ?? "ok"
        }
        send(["jsonrpc": "2.0", "id": id, "result": [
            "content": [["type": "text", "text": text]], "isError": error != nil,
        ]])
    default:
        send(["jsonrpc": "2.0", "id": id, "error": ["code": -32601, "message": "Method not found"]])
    }
}
