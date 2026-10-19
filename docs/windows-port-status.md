# Windows port: implementation and parity checklist

The Windows app lives in Windows/ and is isolated from the existing Swift/macOS targets.

## Current Windows foundation

- [x] Separate WPF/.NET desktop target.
- [x] FFmpeg executable discovery from app-local tools, DOGSC_FFMPEG_PATH, or PATH.
- [x] Desktop/window/coordinate-region capture command path with 30/60 FPS and cursor rendering.
- [x] WASAPI system loopback and DirectShow microphone input with audio mixing.
- [x] Video import/probing, preview, clip ordering, in/out trim, and 0.5x–2x speed.
- [x] Versioned JSON project save/load with missing-media and invalid-range checks.
- [x] MP4/M4A export code paths and resolution/frame-rate selection.
- [x] Single-installer script; self-contained .NET publishing; pinned FFmpeg LGPL shared build; SHA-256 verification; FFmpeg encode/probe smoke test in CI.
- [ ] Windows build and installer workflow must pass after the current commit; inspect its logs rather than assuming success.
- [ ] Validate installation, first launch, uninstall, and clean-machine operation on a real Windows 10/11 machine.
- [ ] Validate capture and audio sync with real devices, multiple monitors, mixed DPI, long recordings, sleep/resume, and export recovery.

## Required before claiming Mac parity

- [ ] Native Windows Graphics Capture implementation and tests for protected, minimized, occluded, and high-DPI windows.
- [ ] Drag-to-select region and reliable multi-monitor/negative-origin handling.
- [ ] iPhone/iPad capture equivalent and device discovery.
- [ ] Camera overlay, camera layout and entrance animations.
- [ ] Cursor asset library, click feedback, pointer event timeline, and cursor calibration.
- [ ] Automatic cursor-follow zoom, manual zoom keyframes, 3D perspective, focus blur, and opening animations.
- [ ] Background, crop/aspect ratio, rounded corners, shadows, device frames, stickers, softening/highlight effects, and scene presets.
- [ ] Full multi-track timeline operations, thumbnails/waveforms, snapping, undo/redo, markers, and advanced audio editing.
- [ ] Settings, shortcut reference, localization parity, updater, signed installer, and release packaging.
- [ ] Automated parity tests comparing project semantics and export behavior with macOS fixtures.
- [ ] Manual regression matrix on Windows 10/11 and common integrated/discrete graphics plus common audio interfaces.

A checklist item is complete only after the Windows implementation and corresponding automated or documented manual test both pass. A successful compile alone does not prove feature parity.
