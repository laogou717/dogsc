# Windows port: implementation and parity checklist

The Windows app lives in Windows/ and is isolated from the existing Swift/macOS targets.

## Current Windows foundation

- [x] Separate WPF/.NET desktop target.
- [x] FFmpeg executable discovery from app-local tools, DOGSC_FFMPEG_PATH, or PATH.
- [x] Desktop/window/coordinate-region capture command path with 30/60 FPS and cursor rendering.
- [x] Live desktop/window/region preview; recording errors use concise summaries with expandable detailed FFmpeg logs.
- [x] Periodic webcam snapshot overlay in the preview, honoring camera position and size controls. Snapshot preview pauses during recording to avoid competing DirectShow device handles.
- [x] Odd-size GDI frames are padded to even dimensions and converted to the selected encoder pixel format; failed h264_mf startup retries with MPEG-4. CI verifies 1600x1075 capture pads to 1600x1076 and both encoders produce valid MP4.
- [x] WASAPI system loopback and DirectShow microphone input with audio mixing.
- [x] Static webcam overlay through DirectShow with five positions and three size presets; CI validates the FFmpeg overlay filter with synthetic video inputs.
- [x] Video import/probing, preview, generated timeline thumbnails, clip ordering, in/out trim, and 0.5x–2x speed.
- [x] Versioned JSON project save/load with missing-media and invalid-range checks.
- [x] MP4/M4A export code paths; 1080p/1440p/4K and 30/60 FPS; 16:9/9:16/1:1/4:3/3:2 canvases, fit/fill and background options.
- [x] Recording marker button and Ctrl+Alt+M global shortcut; timestamps saved to a JSON sidecar and available for seeking in the editor.
- [x] Single-installer script; self-contained .NET publishing; pinned FFmpeg LGPL shared build; SHA-256 verification; FFmpeg encode/probe smoke test in CI.
- [x] CI integration tests for media probing, project save/load, MP4/M4A export, portrait output and square crop; successful installed-app startup verified on commit 672cccc3e8223bad91a3de0a4965f62cbf2c3c5e.
- [x] Windows build, media/project integration tests, installer generation, installed-app startup, and silent uninstall passed on commit 27e19a37de7a225166bd198da0e4c3f4ff7bed07.
- [ ] Validate installation, first launch, uninstall, and clean-machine operation on a real Windows 10/11 machine.
- [ ] Validate capture and audio sync with real devices, multiple monitors, mixed DPI, long recordings, sleep/resume, and export recovery.

## Required before claiming Mac parity

- [ ] Native Windows Graphics Capture implementation and tests for protected, minimized, occluded, and high-DPI windows.
- [x] Drag-to-select region.
- [ ] Reliable multi-monitor/negative-origin handling and real-device region capture validation.
- [ ] iPhone/iPad capture equivalent and device discovery.
- [ ] Animated camera entrance/layout effects and rounded or masked camera overlays; the basic static webcam overlay is implemented.
- [ ] Cursor asset library, click feedback, pointer event timeline, and cursor calibration.
- [ ] Automatic cursor-follow zoom, manual zoom keyframes, 3D perspective, focus blur, and opening animations.
- [ ] Background, crop/aspect ratio, rounded corners, shadows, device frames, stickers, softening/highlight effects, and scene presets.
- [ ] Full multi-track timeline operations, thumbnails/waveforms, snapping, marker-track editing, and advanced audio editing. Basic split, reorder, undo and redo are implemented.
- [x] Basic settings/help page and shortcut reference.
- [x] Modern Chinese UI styling with Microsoft YaHei UI font fallback and UTF-8 source checks in CI.
- [ ] Full localization parity, updater, production code signing, and manual real-device validation.
- [ ] Automated parity tests comparing project semantics and export behavior with macOS fixtures.
- [ ] Manual regression matrix on Windows 10/11 and common integrated/discrete graphics plus common audio interfaces.

A checklist item is complete only after the Windows implementation and corresponding automated or documented manual test both pass. A successful compile alone does not prove feature parity.
