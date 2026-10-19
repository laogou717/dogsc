# DogSC for Windows

This is a separate Windows desktop implementation. It does not change the existing macOS Swift package.

## End-user installation

The intended end-user path is a single installer, DogSC-Setup-win-x64.exe. The installer bundles the self-contained .NET runtime and a pinned FFmpeg LGPL shared build, so users do not need to install .NET or FFmpeg or configure environment variables.

The installer is produced by the Windows build and installer GitHub Actions workflow. Download the DogSC-Windows-Installer artifact from a successful run:
https://github.com/spring-it/dogsc/actions/workflows/windows-build.yml

A tagged windows-v* build is configured to publish a GitHub pre-release containing the installer. Until a run succeeds and the parity checklist is completed, the installer must be treated as an early Windows preview, not a feature-complete Mac equivalent.

## Developer build

Requirements: Windows 10 version 2004 (build 19041) or later, .NET 8 SDK, and an FFmpeg build with gdigrab, dshow, h264_mf, and ffprobe.exe.

From the repository root, run in PowerShell:

    dotnet restore .\Windows\DogSC.Windows.csproj
    dotnet build .\Windows\DogSC.Windows.csproj -c Release
    dotnet run --project .\Windows\DogSC.Windows.csproj -c Release

Developers can override FFmpeg discovery with DOGSC_FFMPEG_PATH. Ordinary users do not need to set it when using the installer.

## Windows foundation implemented

- Desktop, window-title, and coordinate-based region capture at 30/60 FPS with cursor rendering.
- WASAPI system-audio loopback through NAudio and DirectShow microphone capture, including post-recording audio mixing.
- Video import and preview, clip ordering, in/out trimming, and 0.5x–2x playback speed.
- Versioned .dogscproj project save/load.
- MP4 export at 1080p/1440p/4K and 30/60 FPS, plus M4A audio export.
- Single-installer pipeline with a self-contained .NET runtime, bundled FFmpeg DLLs, checksum verification, and an FFmpeg encode/probe smoke test.

## Feature parity status

This is not yet a complete Windows port. The macOS application contains additional capabilities that still need Windows-specific implementations and parity tests, including iPhone/iPad capture, camera overlays and animations, cursor click effects and automatic zoom, 3D perspective/focus effects, stickers and device frames, advanced multi-track editing, thumbnails/waveforms, snapping, undo/redo, markers, settings, full localization, shortcut reference, update support, and production signing.

See the Windows parity checklist in docs/windows-port-status.md. A successful build is necessary but does not prove that recording works on all Windows hardware or that all Mac features have been ported.
