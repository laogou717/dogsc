---
name: dogsc-editor
description: Edit the project open in DogSC (macOS screen recorder/editor) through the "dogsc" MCP tools — subtitles, background music and sound effects, HTML motion graphics, and the media bin.
---

# DogSC editing skill

DogSC must be running with a project open in the editor. Every change you make
is a normal edit: it appears on the timeline immediately and the user can undo it.

## Where to save files
- Reusable results — motion graphics, images, music, video — go into the DogSC library:
  `project_summary.libraryFolders` gives one folder per kind (animation, image, audio, video). The
  library is shared by all projects and survives when a project is deleted. `html_create` already
  saves there.
- One-off working files — transcripts, `.srt` drafts, preview images — go into
  `project_summary.workspace` (this project's AI folder).
- New library results appear in the project's media bin after your turn. Workspace files stay
  temporary unless explicitly imported or placed; use absolute paths with timeline tools.

## Units and coordinates
- Times are **output seconds** (the edited program after cuts), from `project_summary.outputDuration`.
- Positions: `x`, `y` are the centre of the object, 0–1 from the top-left of the canvas.
- `width` is a fraction of the canvas width.

## Tools
- `project_summary` — title, duration, playhead, counts.
- `media_list` / `media_import` — the media bin; `media_list(scope: "library")` lists reusable assets. Files are referenced where they are, never copied.
- `html_create` / `html_update` / `html_preview` — create, revise and preview web motion graphics; see below.
- `timeline_add_audio` — `kind: "music"` (default volume 0.4, fades, dips automatically under speech) or `"effect"`.
- `sound_download` — save a CC0 audio URL into the library and project bin; returns its local path.
- `timeline_add_video` — B-roll over the recording; full frame by default, `width` ~0.3 with `x`/`y` for picture-in-picture.
- `canvas_snapshot(time: seconds)` — independent PNG of that output time, with source/clip IDs and
  coordinate geometry. `view: "source"` returns the uncropped recording; the default is the full canvas.
- `timeline_inspect` / `timeline_update` — read and patch existing native objects by ID; omitted fields stay unchanged.
- `timeline_add_sticker` — place an existing image as an editable sticker with timing and canvas position.
- `timeline_get` / `timeline_cut` / `timeline_remove` — read, cut and delete; see "Editing" below.
- `pointer_events`, `zoom_add`, `motion3d_add`, `highlight_add`, `settings_get` / `settings_set`, `app_help`.
- `subtitles_get` / `subtitles_update_text` / `subtitles_set` / `subtitles_style`.
- `audio_transcribe` — transcribes the edited program audio with the macOS built-in recognizer (no setup), returning timed segments.
- `audio_analyze_edits` — raw speech context, waveform continuity and quiet cut candidates; cached with transcription.
- `audio_export` — writes the edited program audio (M4A, output time) if you prefer your own transcription.

## Making subtitles
- 「识别字幕」按原话断句，保留口语、语气词和原意。只修正明确的识别错误；用户明确要求时才润色或改写。双语字幕只在 `secondary` 翻译。
- 两句能独立表达的话要分别建字幕，即使说得快、停顿很短。按语义判断，结合标点和语气；同一句内的短语不要逢逗号就拆，两句话也不要只用空格隔开。
- 按语境判断粗口，在字幕中省略或缩写，保留原录音和时序。
- Run `audio_transcribe`, then `subtitles_set_from_words` with `analysisId` and inclusive
  `from`/`to` token IDs. Omit `text` to use the transcript wording. Use `subtitles_update_text`
  for specific recognition errors. Optional `start`/`end` override waveform-aligned cue edges.
  If validation fails, correct the reported cue and retry with word IDs.
- Avoid brief blank flashes between closely spaced captions. Set `holdToNext: true` on the preceding cue to
  extend it to the next cue's start, or `false` to retain an intentional gap. Judge from the
  content and pace; there is no fixed gap-duration threshold. An explicit `end` takes priority.
  The response includes actual cue IDs/times and remaining `gaps` in seconds and video frames.
- Caption starts follow measured speech edges. When correcting touching ASR ranges exposes a
  gap, the preceding caption holds longer; the following caption does not appear earlier.
- Default appearance: `fontScale: 0.03`, `backgroundOpacity: 1`, `bottomMargin: 0.05`, no entrance
  animation. Existing custom styling is preserved.
- Keep the default caption backplate fully opaque (`backgroundOpacity: 1`) during packaging;
  explicit user styling takes priority.
- 去掉句中的逗号和句末标点，保留数字、版本号、名称中的符号。

## Correcting existing subtitles
Read `subtitles_get`, then use `subtitles_update_text` with the target cue IDs and corrected `text`
or `secondary`. Keep the rest of each line as spoken. Cue times, lengths and neighboring captions stay unchanged.
For display gaps in existing captions, `timeline_update` can extend a chosen cue's
`timing.duration` to the next start; holding the display needs no new transcription.
For speech-alignment corrections, use a fresh transcript and its token ranges. `subtitles_align_to_speech`
refines measured silence inside existing cue edges. Use `subtitles_set` only when the user supplies
timed captions or explicitly requests replacement at specified times.

## Overlay or main track?
Decide from the request where a motion goes:
- **Overlay** (`html_create`, `placement: "overlay"`): on top of the recording — lower thirds, callouts, subtitles bars, labels,
  counters. Transparent background; the recording keeps playing underneath.
- **Main track** (`html_create`, `placement: "main"`): its own full-screen moment — an opening, a title card, a chapter
  break, an end card. It is inserted at `start`; the recording, subtitles, music and overlays after that
  point all move later by its length, so nothing gets out of sync. Paint its own full-frame
  background in the page. Full screen by default; `framed: true` only when the user wants it inside the
  recording's frame styling. "开场 / 片头 / 全屏标题 / 转场卡" mean main track; "字幕条 / 标注 / 角标" mean overlay.
  When unsure which the user wants, ask before inserting.
  A main-track motion is not rendered to video: DogSC plays the page live, so inserting is instant
  and the user can edit its `dogsc-params` fields in the inspector afterwards. `html_create` returns
  as soon as the clip is in place. Existing motion properties, element edits and audio can be read with `timeline_inspect` and
  patched with `timeline_update`. Main-clip patches target `source`, `media`, `sceneStyle` or `audio`; overlay
  patches use their native fields. A property/text patch leaves timing unchanged.
- `timeline_insert_black` inserts plain black (a pause or a fade-through-black point).

## Sound effects
- When creating full-screen content, motion graphics or visual effects, add fitting sound effects by default unless the user requests silence.
- Choose sounds and search terms from the on-screen action, pacing and project style. Find CC0 candidates with your available search tools, choose the source yourself, verify the license and check the result in context.
- `sound_download(url, sourceURL, licenseURL, name?)` saves the audio into the library and bin. Place its returned path with `timeline_add_audio(kind: "effect")`.
- Reuse existing sounds. Inspect the target's timing with `timeline_inspect` and its motion source or preview; choose the visual cue to score (entrance, landing, reveal or exit). Align the sound's relevant onset or accent to that cue, accounting for leading silence, source trims and playback speed. Use `timeline_update` to move, trim or replace the existing audio clip; matching clip starts is not the default. Use `html_create(soundPath: path)` for a main clip only when the sound already fits its local timing.

## Motion graphics — HTML (`html_create`)
- Create once with `html_create`; revise with `html_update(id: current clip/asset ID, html: full page)` and use its returned path. Keep element IDs stable so user edits survive. Do not rewrite the file directly or delete and recreate the clip. Use `copy: true` only for an independent asset.
- For the same design with different text or colours, reuse its source and patch each occurrence's `properties` through `timeline_update` instead of generating another file.

For any animation, title, caption bar, callout, counter, transition or opening, design it as a web
page. You have the whole web platform: CSS, SVG, canvas, Web Animations, filters, blend modes,
masks, 3D transforms, gradients. There is no house style — choose a visual language that fits this
video and this moment, and make it look like a professional motion designer made it. Do not reuse
the same layout or rhythm every time.

A video-packaging request calls for a finished visual treatment on the first pass. Build around
the content and requested style, varying composition, scale, placement and motion as the story
changes. Full-screen moments, explanatory graphics, interface emphasis and sound can serve the
narrative; each visual should add explanation or emphasis beyond repeating the subtitles.

What DogSC needs from the page (technical only; everything else is your design):
- **Size and background.** The page is laid out on a viewport with the project canvas's own aspect,
  1080 CSS px on its short side: 1920×1080 for 16:9, 1080×1920 for 9:16, 1440×1080 for 4:3, and so
  on (`project_summary.canvas.htmlViewport` gives the exact size). DogSC renders it at the real
  output resolution — 4K, 5K — so lay out in CSS px against that viewport (or use vw/vh/%) and it
  stays sharp at any size. Do not hard-code 1920/1080 when the canvas is not 16:9. For
  `placement: "overlay"` the page background must be transparent (the recording shows through); for
  `placement: "main"` paint whatever full-frame background you want.
- **Time is controlled by DogSC.** DogSC renders frames by pausing every CSS animation, CSS
  transition and Web Animation and setting it to the frame time. So drive motion with those. Script
  that changes things over time must not rely on `requestAnimationFrame`, timers or the clock;
  instead define `window.dogsc = { seek(t) { /* draw the state at t seconds */ } }` and DogSC calls
  it before each frame (good for canvas, particles, counters, SVG path maths).
- **Length.** `<meta name="dogsc-duration" content="SECONDS">` in the head.
- **Editable fields.** Declare what the user may change, in their language:
  `<script type="application/json" id="dogsc-params">{"标题": "…", "主色": "#7B5CFF"}</script>`.
  DogSC shows them in its inspector and, on every change, sets each as a CSS variable `--name` on
  `:root` and as the text of any element with `data-param="name"`; your `dogsc.params(p)` is called
  too if you define it. Expose the things a user would plausibly tweak: words, colours, maybe a
  number — not every internal value.
- **Per-letter / per-word motion.** Put `data-split="chars"` or `data-split="words"` on the element
  instead of splitting it yourself; DogSC wraps each unit in `<span class="dogsc-unit">` with `--i`
  (index) and `--n` (count), and does it again after the user edits the text. Use them in CSS, e.g.
  `animation-delay: calc(var(--i) * 40ms)`.
- **Self-contained.** No network: no web fonts, CDNs or remote images. System fonts are available
  (e.g. -apple-system / SF Pro, "PingFang SC", "Hiragino Sans GB", "New York", Menlo, Avenir Next,
  Futura, Didot, Helvetica Neue); draw icons and shapes in inline SVG; embed small images as data URIs.
- **Cost.** Every frame is drawn live by a browser at the output resolution, during playback and
  export. Large blurs (`filter: blur()` or `backdrop-filter` over most of the frame), many stacked
  glows, and canvas redraws of thousands of particles make playback stutter and export slow. Use them
  where they matter, at the size they need to be.
- **Pictures and colours.** DogSC lists every element of the page for the user to edit (text,
  colours, size, position, pictures, background) — you do not need to structure the page for it.
  Two things help: a picture the user should supply goes in as `<img data-name="产品图">` with a
  neutral placeholder, and the colours and words they are most likely to change go first in
  `dogsc-params`.
- **Name the parts.** Give each element the user may want to move or hide an `id` or
  `data-name` in the user's language (`data-name="标题"`, `data-name="副标题"`, `data-name="日期"`).
  The user can pick, drag and hide elements on the canvas; these names are what they see.
- **Respect the user's hands-on edits.** `project_summary.motions[].userEdits` lists, per element
  key (`#id`, `param:…`, `name:…`), what the user moved (`movedBy`, CSS px), hid or retexted on that
  clip, including font choices (`fontFamily`, `fontWeight`). When you rewrite a motion that has edits, keep the same ids/names and keep those changes
  unless the user asks otherwise.
- **Check your work.** Call `html_preview` at several moments (start, mid-entrance, settled, exit) and
  look at the frames; refine until it is genuinely good. `html_preview` also takes `params` to test
  how the design holds up with longer or shorter text.

Placement: `"overlay"` sits on top of the recording at `start` (use `x`, `y`, `width` to place and
size it); `"main"` is a full-screen clip inserted into the main track at `start` — everything after
it moves later. Add `soundPath` to a main clip to attach a downloaded local sound.

## Editing — cuts, zooms, 3D, highlights, settings
You can edit the whole project, not only add things. `timeline_get` exposes each clip and its id.

For tight speech editing, combine meaning, raw word times and waveform evidence to remove
mistakes, retakes, fillers and excess pauses, retaining complete, correct takes. Aim for roughly
1–2 video frames around speech edges in ordinary dialogue; choose necessary pauses from context.
Review the resulting joins and remaining pauses, correcting excess air or clipped speech.

Recording clips also include `source` (`id`, `name`, `start`, `end`). Source times
belong to that recording; the same source interval may appear in multiple clips.
Use the clip id to edit a particular occurrence. `pointer_events` returns output
time `t` plus `source` and `segmentId`, so clicks from imported recordings and
repeated occurrences remain distinguishable. Never apply the primary recording's
pointer coordinates to another source. Inserted videos have no recorded pointer.
- **Speech evidence** (`audio_analyze_edits`): raw wording, token times, waveform boundaries and
  pauses, nearby repeated phrases and existing edit joins in output seconds. `from`/`to` select
  a window; `includeWords` adds token detail and `includeWaveform` adds energy samples.
  `utterances` keeps language context across pauses. `pauseGroups` combines short-noise-separated
  pauses with surrounding text and optional `acousticInterior` cut ranges.
  `videoFrameRate` is the current export rate; frame counts describe margins, not a cut constraint.
  Short `from`/`to` windows with `includeWaveform` provide finer waveform detail.
  Recognition and quiet intervals are evidence, not proof of a complete sentence.
- **Cuts** (`timeline_cut`): exact `ranges: [{start,end}]`, or `analysisId` with inclusive
  `wordRanges: [{from,to,start?,end?}]` and `pauses: [{id,keep}]`. Word ranges default to recognizer
  endpoints; `start`/`end` override them exactly. `keep` is remaining pause seconds, including zero.
  Acoustic uncertainty is reported, not rejected. A changed timeline/audio invalidates analysis IDs.
  Optional `revision` from `timeline_get` ties exact time ranges to that project state.
  Captions and other tracks follow cuts; new transcription describes the resulting program.
  `cutReview` returns new joins and `remainingPauses` throughout the retained program, in the
  edited clock, so further cuts can address gaps inside sentences as well as clip edges.
  Each join's left/right `quietFrames` and total `retainedQuietFrames` expose the remaining air.
  Caption display may hold past speech; use original word times and acoustic evidence for cuts.
- **Zooms** (`zoom_add`): focus coordinates are relative to the source recording. Recorded clicks
  from `pointer_events` and snapshots supply placement context. Existing automatic zooms are marked
  `automatic: true` in `timeline_get`.
  Choose a subject and a reason to zoom; set its start, hold and return around the explanation or
  action. Durations are freely editable with `timeline_update` (`startTime`, `endTime`,
  `enterDuration`, `exitDuration`, `focus`, `scale`). For nearby visits to the same subject, a
  single longer zoom can hold through the gap. Touching clips can move directly between different
  targets without returning to 1x. Judge continuity against the actual transitions in `zoomJoins`,
  and check the focus over the whole shot. `start` begins entrance, `end` begins return.
- **3D moves** (`motion3d_add`): rotation in degrees, scale and position over an output-time span.
- **Highlights** (`highlight_add`): `spotlight` dims outside a recording-relative rectangle;
  `blur` obscures its contents.
- **Updating** (`timeline_inspect` / `timeline_update`): partial native-object patches, including
  timing, position, styles and sound levels. Main clips expose `source` (`start`, `end`, `speed`,
  in media-source seconds; edge changes ripple dependent tracks), `media` (including HTML fields),
  `sceneStyle` and `audio` overrides. `revision` optionally binds a change to the inspected project.
- **Deleting** (`timeline_remove`): any clip by id — "删掉所有缩放", "去掉第二段音乐", a main-track segment.
- **Settings** (`settings_get` / `settings_set`): background, padding, corners, device frame,
  cursor, camera bubble, audio levels, motion defaults, export settings. Read first, patch only what
  the user asked for.
- **How-to questions**: call `app_help` (optionally with a topic) and answer with the exact place in
  the app ("全片设置 → 光标 → 点击反馈"). If you can simply do it, offer to, or do it.
- Every turn is one undo step; say what you changed so the user can review or undo it.

## Review
Changes appear in the editor and can be undone. Report what was actually changed or inspected.
