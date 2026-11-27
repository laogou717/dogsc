---
name: dogsc-editor
description: Edit the open DogSC project with the dogsc MCP tools. Use for speech cuts, subtitles, music and sound effects, HTML motion graphics, and media bin edits.
---

# DogSC editing skill

Use the editing tools with a project open in DogSC. A request to diagnose behavior or improve future defaults permits read-only project inspection. Apply timeline or media changes when the user asks to edit the project.

## 默认口播剪辑

「智能剪辑」和泛称「帮我剪辑」默认按以下规则处理，用户对节奏、保留内容或范围的明确要求优先。

1. 先通读原话选台词。把相邻或隔着试说的同义改写放在一起，默认留最后一遍完整、正确、接得上下文的表达。后一次说错或没说完时选前一遍；保留独有的信息。去掉废弃试说、口误及多余语气词。`repeatedPhrases` 只提示相同字词，换措辞的重录要按语义判断。
2. 按 `project_summary.footage` 或 `audio_analyze_edits.footage` 的当前时段判断画面。纯口播紧剪，操作性台词本身不构成演示。只有画面里确有需要看完的动作、操作或结果，才给它留时间；需要时用 `canvas_snapshot` 核对前后画面。
3. 按原始字词和波形定切口。普通接话在前句收声后、后句发声前各留约 1–2 帧，按 `videoFrameRate` 换算。用 `pauses` 剪停顿时显式传 `keep`，值为两侧余量之和（秒）。保全轻声、尾音和起音。
4. 剪后在当前成片上重新调用 `audio_analyze_edits`，按 `nextStart` 分页核对保留的原话、`joins` 与句内外的 `pauseGroups`。初次切口的 `cutReview` 仅供定位。对超出目标的普通接缝，结合 `pauseGroupAtJoin`、两侧波形和语境复核，收紧多余空白；修正后复核受影响处。需要字幕时，最后按定剪后的声音生成。

## Where to save files
Use the current timeline and `media_list` to discover project media. Consult prior drafts, conversations or undo files only when the user asks to recover or reuse them. Save new project-specific files in `project_summary.assetFolders` and drafts in `workspace`. Reusable files live in `project_summary.sharedMediaFolder`. Download tools keep the source there and return a project copy for placement. Favorites are curated by the user.

## Units and coordinates
- Times are **output seconds** (the edited program after cuts), from `project_summary.outputDuration`.
- Positions: `x`, `y` are the centre of the object, 0–1 from the top-left of the canvas.
- `width` is a fraction of the canvas width.

## Tools
- `project_summary` — title, duration, playhead, counts.
- `media_list` scopes: `project` for the bin, `shared` for reusable files, `library` for favorites, `all` for all three. Use `media_import` to make a project copy of selected external files.
- `html_create` / `html_update` / `html_preview` — create, revise and preview web motion graphics; see below.
- `timeline_add_audio` — `kind: "music"` (default volume 0.4, fades, dips automatically under speech) or `"effect"`.
- `image_download` — import a direct HTTPS PNG, JPEG, WebP or standalone SVG (imported as PNG) with its source page into the project bin.
- `sound_download` — save a CC0 audio URL into the project bin; returns its local path.
- `timeline_add_video` places an imported video. Its `maskShape` accepts `矩形`, `圆角矩形` or `圆形`. For rounded rectangles, `maskCornerRadius` is a fraction of the shorter edge (0–0.5, default 0.12). Canvas position and width belong to this video.
- To change an overlay video’s speed, patch its `playbackRate` with `timeline_update` on that clip. A rate-only edit keeps its source frames and adjusts output duration. For an explicit trim, `sourceStart` is in file seconds and `timing.duration` is in output seconds. Their combination must fit the inspected `sourceFileEnd`: `sourceStart + timing.duration * playbackRate <= sourceFileEnd`.
- `cameraMode` sets this video's order relative to the recording camera. Use `pictureInPicture` for camera above or `videoInFront` for video above. Omit it on import to follow the last manual choice (initially camera above). For an existing video, find its ID by file name, time or `selected: true` in `timeline_get.overlays`, read `timeline_inspect`, then use `timeline_update` with e.g. `{"maskShape":"圆角矩形","maskCornerRadius":0.2,"cameraMode":"pictureInPicture"}` as the patch. Use `layerIndex` for order among overlay assets. Edit the recording camera's own shape, framing and mirror on its main segment or camera settings. For a full-bleed cutaway, use video above and cover both canvas dimensions.
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
- 按原话分条。能独立表达的两句话即使连读也各写一条字幕，较长的句子在自然语意转折处拆开。每条用自己的字词范围，双语逐条翻译。原文的空格或逗号仅作线索。
- 按语境判断粗口，在字幕中省略或缩写，保留原录音和时序。
- Run `audio_transcribe`, then `subtitles_set_from_words` with `analysisId` and inclusive
  `from`/`to` token IDs. Omit `text` to use the transcript wording. Use `subtitles_update_text`
  for specific recognition errors. Optional `start`/`end` override waveform-aligned cue edges.
  If validation fails, correct the reported cue and retry with word IDs.
- 按剪后的语境和节奏判断间隙。连续口播中只会闪空的短间隙默认补齐，跨剪接点也一样。在前条设 `holdToNext: true` 并省略其 `end`，让它显示到后条实际开口。需要留白时保留间隙。
- 主轨和字幕写完后，用 `subtitles_get` 读回最终字幕，逐条检查是否仍有合并的句子，逐对检查间隙（写入结果也有 `gaps`）。拆开漏分的句子，补齐会闪空的间隙。
- Default appearance: `fontScale: 0.03`, `backgroundOpacity: 1`, `bottomMargin: 0.05`, no entrance
  animation. Existing custom styling is preserved.
- Keep the default caption backplate fully opaque (`backgroundOpacity: 1`) during packaging;
  explicit user styling takes priority.
- 去掉句中的逗号和句末标点，保留数字、版本号、名称中的符号。

## Correcting existing subtitles
Read `subtitles_get`, then use `subtitles_update_text` with the target cue IDs and corrected `text`
or `secondary`. Keep the rest of each line as spoken. Cue times, lengths and neighboring captions stay unchanged.
To close a display gap in existing captions, use `timeline_update` on the preceding cue with
`timing.duration` equal to the next cue's start minus the preceding cue's start.
For speech-alignment corrections, use a fresh transcript and its token ranges. `subtitles_align_to_speech`
refines measured silence inside existing cue edges. Use `subtitles_set` only when the user supplies
timed captions or explicitly requests replacement at specified times.

## Placement
Any component can use either track. Follow the requested placement. Otherwise choose by timing: `overlay` keeps the recording and its audio running; `main` inserts independent time and shifts subsequent clips. Either can fill the frame. Overlay `x`, `y`, `width` set its bounds; main `framed: true` applies recording frame styling.
Inspect with `timeline_inspect` and patch with `timeline_update`. Overlay edits use native clip fields; main edits use `media`, `source`, `sceneStyle` or `audio`. `timeline_insert_black` inserts plain black.

## Sound effects
- Check `template_read.hasSoundtrack` along with `soundDesign` and `soundCues`. Both placements play the template’s score automatically. Reuse it, retime its cues with the visual beats when adapting the page, and avoid doubling an accent on another track.
- Score meaningful entrances, changes of focus and resolutions on the motion’s local clock. Design sound for the motion’s material, weight, rhythm and direction. Give separate effects distinct articulations. Group decorative micro-movements. Match the audible accent to the visible change, allowing for attack, trims and playback speed.
- A portable HTML score is a JSON array inside `<script type="application/json" id="dogsc-sound">`. Each event has `at` (local seconds), `type` (a named sample) and `volume` (linear gain 0–1.5). `dogsc-samples` maps names to embedded PCM WAV data URLs (24 kHz, 16-bit mono/stereo). Preserve the sample reference returned by `template_read` when editing the source; DogSC embeds the audio in the saved HTML. For custom timbres use `html_create(sound: events)` or attach local audio with `soundPath`; either replaces the template mix. For a separate effect use `sound_create` or a verified CC0 source via `sound_download`.
- Balance accents individually against nearby speech. Check their relative level and transients in the mix by listening when available or measuring the export. Adjust each placement independently via `timeline_update` (overlay soundtrack.volume or main audio.systemVolume). Honour requests for silence.

## 默认包装

- 通读定剪后的口播，核对对应时段的画面和素材箱。按观众此刻需要看清的内容决定是否补画面。现有画面已经讲清楚的地方可以留给原片。
- 优先使用用户指定的素材。其余先核对项目和共享素材中的现有文件，同样合适时优先用户提供的版本。需要网络素材时，先确认本地没有适用内容，再从可信来源下载。
- 用 `template_read` 返回的 `templates` 浏览所选风格下各级目录的组件。先判断每段要呈现的关系或变化，再跨类别比较候选的构图、运动方式和可改编的部分。目录名和原稿用途是检索线索。整片包装完成后，用 `project_summary.motionUsage` 回看反复出现的组件。遇到含义已变、画面却只换字的段落，重新选型。重复有意呼应时可保留。
- 自制画面沿用本片选定模板的背景、文字、线条和强调色。参考画面采用黑白灰阶时，新布局也沿用这套灰阶。人物实拍和品牌标志保留素材本色。
- 按定剪音轨中每个意思首次说到的时刻揭示。用 `audio_analyze_edits(from,to,includeWords:true)` 取词号，`html_create` 用 `speechAnchor:{analysisId,word,localTime}` 对齐首次可辨认的画面。对页内每个标题、图像和后续节点分别检查，弱化但仍可读也算揭示。引出话题时保留悬念，待口播说出新信息再显示。字幕用于定位，词界含混时核听。检查触发前、触发时和停留帧，剪辑变动后按新的成片时间复核。
- 同一时段可组合多个组件。先看主体朝向与关注对象，再定机位、蒙版与图文位置。侧向人物应朝主要内容留出视线空间，优先换边，仅在文字、动作和空间方向都允许时镜像。用 `canvas_snapshot` 在有代表性的字幕行和揭示阶段复看合成画面；`subtitleRestingRect` 给出该行按当前样式完整排版的占位。字幕与图文挤在同一侧时重新安排视觉重心。根据已可见的信息量调整容器；并排时对齐共同边线，必要时收窄蒙版并在其中等比取景。若中间状态出现无用途的大片空白，重排当前内容，后续信息仍按发言揭示。
- 选中组件后，用 `html_create` 的 `templatePath` 创建项目副本，再改实例文案、素材和时序。结构确需调整时，用 `template_read` 的 `includeSource` 取源码改编，保留适用的构图、动效和配音。只有该段缺少合适组件时才按同一风格原创。用户明确要求原创设计或跳过模板时，以其要求为准。
- 改编与原创共用本片选定的视觉风格。先读 `template_read.styleGuides` 指向的风格说明，再从代表性原稿的 CSS 取背景、表面、文字和强调色的实际值及其用途，沿用字体层级、线条和图形处理。缺少说明时以原稿和用户认可的画面为准。布局、插画内容和运动可随表达变化；新增图形的填充、描边和阴影也沿用同一组样式。交付前将新画面与参照片段并看，尤其核对大面积底色的冷暖和强调色的用量。用户另行指定风格时遵从其要求。
- 需要观众看到真实过程或结果时，优先使用能呈现它的实录或素材。缺素材时，在对应口播时段给后续素材留出独立、可读的画面区域，用时间线叠加片段名称说明待补内容。已有合适布局可直接留位，否则用透明、无声的独立叠加片段标出范围。保留原有口播和字幕时序，避免用模拟画面冒充实录。交付时列出待补画面的起止时间和要呈现的内容。

## Motion graphics — HTML (`html_create`)
- Create once with `html_create`; revise with `html_update(id: current clip/asset ID, html: full page)` and use its returned path. Keep element IDs stable so user edits survive. Do not rewrite the file directly or delete and recreate the clip. Use `copy: true` only for an independent asset.
- When the editorial plan calls for a recurring design, reuse its source and patch per-instance `properties` through `timeline_update`.

For an identity reveal, use the local selection order above. If needed, source official images with the host's web search and `image_download(url, sourceURL)`. Import supplied files with `media_import`. When the image is missing, use the correct name and a neutral, replaceable image slot. Replace unrelated demo branding. Use a stable named `<img>` with a sized, embedded placeholder. `template_read.imageSlots` gives the inspector keys. Apply the project-owned image's `projectPath` to `elementEdits[key].image` (main: `media.elementEdits`) via `timeline_update`.

For a continuous camera layout across cuts, use one overlay’s `cameraSlot`; patch the mask bounds (x/y top-left, width/height), radius and layer order (`aboveGraphics`) with `timeline_update`. Within the mask, optional `cameraSlot.contentPosition` (visual x/y, 0–1) pans the crop and `contentScale` (1–4) zooms the source. Omitted fields inherit the camera framing. Keep the backing visible throughout the move and avoid masking the same edge twice.

What DogSC needs from the page (technical only; everything else is your design):
- **Size and background.** The page is laid out on a viewport with the project canvas's own aspect,
  1080 CSS px on its short side: 1920×1080 for 16:9, 1080×1920 for 9:16, 1440×1080 for 4:3, and so
  on (`project_summary.canvas.htmlViewport` gives the exact size). DogSC renders it at the real
  output resolution — 4K, 5K — so lay out in CSS px against that viewport (or use vw/vh/%) and it
  stays sharp at any size. Do not hard-code 1920/1080 when the canvas is not 16:9. Use transparency wherever underlying footage should show.
- **Time is controlled by DogSC.** DogSC renders frames by pausing every CSS animation, CSS
  transition and Web Animation and setting it to the frame time. So drive motion with those. Script
  that changes things over time must not rely on `requestAnimationFrame`, timers or the clock;
  instead define `window.dogsc = { seek(t) { /* draw the state at t seconds */ } }` and DogSC calls
  it before each frame. Generated .html files also drive this same seek function in a browser.
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
- **Offline playback.** Embed fonts, icons and images or use system fonts. Fetch source material during authoring; the finished HTML must render without a network connection.
- **Cost.** Every frame is drawn live by a browser at the output resolution, during playback and
  export. Large blurs (`filter: blur()` or `backdrop-filter` over most of the frame), many stacked
  glows, and canvas redraws of thousands of particles make playback stutter and export slow. Use them
  where they matter, at the size they need to be.
- **Name the parts.** Give each element the user may want to move or hide an `id` or
  `data-name` in the user's language (`data-name="标题"`, `data-name="副标题"`, `data-name="日期"`).
  The user can pick, drag and hide elements on the canvas; these names are what they see.
- **Respect the user's hands-on edits.** `project_summary.motions[].userEdits` lists, per element
  key (`#id`, `param:…`, `name:…`), what the user moved (`movedBy`, CSS px), hid or retexted on that
  clip, including font choices (`fontFamily`, `fontWeight`). When you rewrite a motion that has edits, keep the same ids/names and keep those changes
  unless the user asks otherwise.
- **Check your work.** Call `html_preview` at several moments (start, mid-entrance, settled, exit) and
  look at the frames. Review the placed sequence against the speech for missed references, stale demo assets and accents out of sync. `html_preview` also takes `params` to test
  how the design holds up with longer or shorter text. For camera layouts, check the composite with
  `canvas_snapshot` during and on either side of the handoff for seams. When investigating a playback-only flash, also inspect continuous playback starting at the boundary and after seeking to it.


## Editing — cuts, zooms, 3D, highlights, settings
You can edit the whole project, not only add things. `timeline_get` exposes each clip and its id.

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
  Join times and remaining pause candidates use the edited output clock.
  Each join's left/right `quietFrames` and total `retainedQuietFrames` expose the remaining air.
  Caption display may hold past speech; use original word times and acoustic evidence for cuts.
- **Zooms** (`zoom_add`): choose `target: "recording"` for the main picture (default) or
  `target: "overlayVideo"` for the frontmost active imported video. To redirect an existing
  green zoom, patch its `target` with `timeline_update`. Focus coordinates are relative to
  the chosen source. Use the imported footage to place its focus. Recorded pointer events
  describe the main recording. An overlay zoom follows consecutive video cuts and has no
  effect in gaps. Camera and subtitle placement are independent. Existing automatic zooms are marked
  `automatic: true` in `timeline_get`.
  Choose a subject and a reason to zoom; set its start, hold and return around the explanation or
  action. Durations are freely editable with `timeline_update` (`startTime`, `endTime`,
  `enterDuration`, `exitDuration`, `focus`, `scale`). For nearby visits to the same subject, a
  single longer zoom can hold through the gap. Touching clips on the same surface can move directly between different
  focal points without returning to 1x. Judge continuity against the actual transitions in `zoomJoins`,
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
