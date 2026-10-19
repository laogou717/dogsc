# DogSC for Windows

This directory contains a separate Windows desktop implementation. It does not alter the existing macOS Swift package.

## Requirements

- Windows 10 version 2004 (build 19041) or later; Windows 11 recommended.
- .NET 8 SDK for building.
- An FFmpeg Windows build that includes gdigrab, dshow, wasapi, and libx264; ffprobe.exe must be installed beside ffmpeg.exe or be available on PATH.
- The executable path can be configured with the DOGSC_FFMPEG_PATH environment variable. It may point to ffmpeg.exe or its containing directory.

## Build and run

From the repository root, run these commands in PowerShell:

    dotnet restore .\Windows\DogSC.Windows.csproj
    dotnet build .\Windows\DogSC.Windows.csproj -c Release
    dotnet run --project .\Windows\DogSC.Windows.csproj -c Release

The Windows build workflow also builds this project on windows-latest.

## Implemented in this Windows foundation

- Desktop capture at 30/60 FPS, with cursor rendering.
- Window-title capture and coordinate-based region capture.
- System loopback audio (WASAPI) and microphone capture (DirectShow), mixed into the recording when both are enabled.
- Importing local video files, preview playback, clip ordering, in/out trimming, and 0.5x–2x playback speed.
- Saving and reopening a .dogscproj project.
- MP4 video export at 1080p/1440p/4K and 30/60 FPS, plus M4A audio export.

## Important compatibility status

This is a Windows implementation foundation, not a claim of complete feature parity with the mature macOS application. The macOS version contains additional features that still need Windows-specific implementations and parity tests, including iPhone/iPad capture, camera overlays and animations, cursor click effects and automatic zoom, 3D perspective/focus effects, sticker and device-frame libraries, advanced multi-track editing, shortcuts, localization parity, and update/install packaging. These must be ported and verified before a release can honestly be called feature-complete.

The recorder and exporter require a compatible FFmpeg build. The application reports process errors in its status area; capture support varies by Windows graphics/audio drivers and by the FFmpeg build used.
