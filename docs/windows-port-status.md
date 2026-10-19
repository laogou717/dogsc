# Windows port: implementation and parity checklist

The Windows app lives in Windows/ and is deliberately isolated from the existing Swift/macOS targets.

## Windows foundation delivered by this branch

- [x] Independent WPF/.NET Windows desktop target; the macOS Swift package remains unchanged.
- [x] FFmpeg executable discovery through DOGSC_FFMPEG_PATH, the app-local tools directory, or PATH.
- [x] Desktop/window/region capture command construction with 30/60 FPS and cursor capture.
- [x] WASAPI system-audio input and DirectShow microphone input, including audio mixing.
- [x] Video import and probing, preview, clip reordering, in/out trim values, and 0.5x–2x speed.
- [x] Versioned JSON project save/load with missing-media and invalid-range checks.
- [x] FFmpeg MP4 export at 1080p/1440p/4K and 30/60 FPS; M4A audio export.
- [x] Windows CI build workflow.

## Remaining work before claiming Mac parity

- [ ] Drag-select recording region and reliable multi-monitor/negative-origin handling.
- [ ] Native Windows Graphics Capture path and tests for protected, minimized, occluded, and high-DPI windows.
- [ ] iPhone/iPad capture equivalent and device discovery.
- [ ] Camera overlay, camera layout and entrance animations.
- [ ] Cursor assets, click feedback, pointer event timeline and cursor calibration.
- [ ] Automatic cursor-follow zoom, manual zoom keyframes, 3D perspective, focus blur and opening animations.
- [ ] Background, crop/aspect ratio, rounded corners, shadows, device frames, stickers, softening/highlight effects and scene presets.
- [ ] Full multi-track timeline operations, thumbnails/waveforms, snapping, undo/redo, markers and advanced audio editing.
- [ ] Settings, keyboard-shortcut reference, localization parity, updater, signed installer and release packaging.
- [ ] Windows hardware matrix tests for audio devices, mixed-DPI monitors, sleep/resume, long recordings and export recovery.

A checklist item is complete only after the Windows implementation and corresponding automated or documented manual test both pass. A successful compile alone does not prove feature parity.
