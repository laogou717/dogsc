using System.Collections.Concurrent;
using System.Diagnostics;
using System.Globalization;
using System.IO;
using System.Text.Json;
using DogSC.Windows.Models;

namespace DogSC.Windows.Services;

public sealed class RecordingService : IDisposable
{
    private readonly ConcurrentQueue<string> _recentOutput = new();
    private readonly List<RecordingMarker> _markers = new();
    private Process? _process;
    private SystemAudioLoopbackCapture? _systemAudioCapture;
    private string? _systemAudioPath;
    private string? _outputPath;
    private long _systemAudioStartedAt;
    private long _videoStartedAt;
    private bool _captureMicrophone;
    private bool _markersEnabled = true;

    public event Action<string>? StatusChanged;

    public IReadOnlyList<RecordingMarker> GetMarkers()
    {
        lock (_markers)
            return _markers.ToArray();
    }

    public RecordingMarker? AddMarker(string? label = null)
    {
        if (!IsRecording || !_markersEnabled)
            return null;

        RecordingMarker marker;
        lock (_markers)
        {
            marker = new RecordingMarker(
                _markers.Count + 1,
                Math.Max(0, Stopwatch.GetElapsedTime(_videoStartedAt).TotalSeconds),
                string.IsNullOrWhiteSpace(label) ? $"标记 {_markers.Count + 1}" : label.Trim(),
                DateTimeOffset.Now);
            _markers.Add(marker);
        }

        StatusChanged?.Invoke($"已添加剪辑标记 #{marker.Index}，时间 {marker.TimeSeconds:F2} 秒");
        return marker;
    }

    public bool IsRecording
    {
        get
        {
            try { return _process is not null && !_process.HasExited; }
            catch { return false; }
        }
    }

    public async Task StartAsync(RecordingOptions options)
    {
        options.Validate();

        if (IsRecording)
            throw new InvalidOperationException("录制已经在进行中。");

        _process?.Dispose();
        _process = null;
        _outputPath = Path.GetFullPath(options.OutputPath);
        _captureMicrophone = options.CaptureMicrophone;
        _markersEnabled = options.EnableMarkers;
        lock (_markers)
            _markers.Clear();
        // Remove markers left by a previous recording when the same output name is reused.
        TryDelete(Path.ChangeExtension(_outputPath, ".markers.json"));

        var ffmpeg = FfmpegLocator.FindFfmpegPath()
            ?? throw new InvalidOperationException("未找到 ffmpeg.exe。请安装 FFmpeg，或使用集成安装包。");

        var directory = Path.GetDirectoryName(_outputPath);
        if (!string.IsNullOrWhiteSpace(directory))
            Directory.CreateDirectory(directory);

        try
        {
            if (options.CaptureSystemAudio)
            {
                _systemAudioPath = Path.Combine(Path.GetTempPath(), $"DogSC-SystemAudio-{Guid.NewGuid():N}.wav");
                _systemAudioCapture = new SystemAudioLoopbackCapture();
                await _systemAudioCapture.StartAsync(_systemAudioPath).ConfigureAwait(false);
                _systemAudioStartedAt = _systemAudioCapture.StartedTimestamp;
            }

            StatusChanged?.Invoke("正在启动录制...");
            try
            {
                await StartFfmpegProcessAsync(ffmpeg, options, "h264_mf").ConfigureAwait(false);
            }
            catch (InvalidOperationException primaryException)
            {
                // Media Foundation's H.264 encoder can reject valid GDI capture formats
                // on some Windows/GPU combinations. Retry once with the broadly supported
                // MPEG-4 Part 2 encoder, preserving the same capture/audio inputs.
                StatusChanged?.Invoke("H.264 编码器启动失败，正在切换兼容编码器...");
                try
                {
                    await StartFfmpegProcessAsync(ffmpeg, options, "mpeg4").ConfigureAwait(false);
                    StatusChanged?.Invoke("已切换到兼容视频编码器（MPEG-4）");
                }
                catch (Exception fallbackException)
                {
                    throw new InvalidOperationException(
                        "FFmpeg 无法启动录制。已尝试 H.264 和兼容编码器，请检查采集源及设备。\n\n" +
                        "H.264 详情：\n" + primaryException.Message +
                        "\n\n兼容编码器详情：\n" + fallbackException.Message,
                        fallbackException);
                }
            }

            StatusChanged?.Invoke("录制中");
        }
        catch
        {
            await StopProcessAndDiscardAudioAsync().ConfigureAwait(false);
            throw;
        }
    }

    private async Task StartFfmpegProcessAsync(string ffmpeg, RecordingOptions options, string videoEncoder)
    {
        _recentOutput.Clear();
        var startInfo = new ProcessStartInfo
        {
            FileName = ffmpeg,
            UseShellExecute = false,
            RedirectStandardInput = true,
            RedirectStandardError = true,
            CreateNoWindow = true
        };

        BuildArguments(options, startInfo.ArgumentList, videoEncoder);
        var process = new Process { StartInfo = startInfo, EnableRaisingEvents = true };
        process.ErrorDataReceived += (sender, eventArgs) =>
        {
            if (string.IsNullOrWhiteSpace(eventArgs.Data))
                return;

            _recentOutput.Enqueue(eventArgs.Data);
            while (_recentOutput.Count > 80)
                _recentOutput.TryDequeue(out _);

            // Keep verbose FFmpeg output available for diagnostics without treating
            // every progress line as a user-facing status message.
            StatusChanged?.Invoke("LOG:" + eventArgs.Data);
        };

        if (!process.Start())
        {
            process.Dispose();
            throw new InvalidOperationException("无法启动 FFmpeg 录制进程。");
        }

        _process = process;
        _videoStartedAt = Stopwatch.GetTimestamp();
        process.BeginErrorReadLine();

        await Task.Delay(900).ConfigureAwait(false);
        if (!process.HasExited)
            return;

        await process.WaitForExitAsync().ConfigureAwait(false);
        var details = string.Join(Environment.NewLine, _recentOutput.ToArray());
        var exitCode = process.ExitCode;
        process.Dispose();
        if (ReferenceEquals(_process, process))
            _process = null;

        throw new InvalidOperationException(
            $"FFmpeg 使用 {videoEncoder} 编码器启动失败（退出代码 {exitCode}）。" +
            Environment.NewLine + details);
    }

    public async Task StopAsync()
    {
        var process = _process;
        if (process is not null)
        {
            try
            {
                if (!process.HasExited)
                {
                    try
                    {
                        await process.StandardInput.WriteLineAsync("q").ConfigureAwait(false);
                        await process.StandardInput.FlushAsync().ConfigureAwait(false);
                    }
                    catch
                    {
                        // The process may already have exited or closed stdin.
                    }

                    using var timeout = new CancellationTokenSource(TimeSpan.FromSeconds(15));
                    try
                    {
                        await process.WaitForExitAsync(timeout.Token).ConfigureAwait(false);
                    }
                    catch (OperationCanceledException)
                    {
                        process.Kill(entireProcessTree: true);
                        await process.WaitForExitAsync().ConfigureAwait(false);
                    }
                }
            }
            finally
            {
                process.Dispose();
                if (ReferenceEquals(_process, process))
                    _process = null;
            }
        }

        // Save marker timestamps independently of the media mux step so a later
        // audio merge failure does not destroy the user's recording notes.
        var markers = GetMarkers();
        if (markers.Count > 0 && !string.IsNullOrWhiteSpace(_outputPath))
        {
            var markerPath = Path.ChangeExtension(_outputPath, ".markers.json");
            var json = JsonSerializer.Serialize(markers, new JsonSerializerOptions { WriteIndented = true });
            await File.WriteAllTextAsync(markerPath, json).ConfigureAwait(false);
        }

        if (_systemAudioCapture is not null)
        {
            var capture = _systemAudioCapture;
            var audioPath = _systemAudioPath;
            _systemAudioCapture = null;
            _systemAudioPath = null;

            try
            {
                await capture.StopAsync().ConfigureAwait(false);
                if (!string.IsNullOrWhiteSpace(audioPath) && File.Exists(audioPath) &&
                    new FileInfo(audioPath).Length > 44 && !string.IsNullOrWhiteSpace(_outputPath) &&
                    File.Exists(_outputPath))
                {
                    await MixSystemAudioAsync(_outputPath, audioPath).ConfigureAwait(false);
                }
            }
            finally
            {
                capture.Dispose();
                TryDelete(audioPath);
            }
        }

        StatusChanged?.Invoke("录制已停止");
    }

    private async Task MixSystemAudioAsync(string videoPath, string systemAudioPath)
    {
        var ffmpeg = FfmpegLocator.FindFfmpegPath()
            ?? throw new InvalidOperationException("录制视频已保存，但找不到 FFmpeg 来合并系统声音。");

        var info = await new MediaEditorService().ProbeAsync(videoPath).ConfigureAwait(false);
        var offset = Math.Max(0, (_videoStartedAt - _systemAudioStartedAt) / (double)Stopwatch.Frequency);
        var duration = F(info.DurationSeconds);
        var offsetText = F(offset);

        var filter = _captureMicrophone
            ? $"[0:a:0]aresample=48000[a0];[1:a:0]atrim=start={offsetText},asetpts=PTS-STARTPTS,aresample=48000[a1];[a0][a1]amix=inputs=2:duration=first:dropout_transition=0[aout]"
            : $"[1:a:0]atrim=start={offsetText},asetpts=PTS-STARTPTS,aresample=48000,apad=pad_dur={duration},atrim=duration={duration}[aout]";

        var tempPath = Path.Combine(
            Path.GetDirectoryName(videoPath) ?? Path.GetTempPath(),
            $"{Path.GetFileNameWithoutExtension(videoPath)}.{Guid.NewGuid():N}.mux.mp4");

        var startInfo = new ProcessStartInfo
        {
            FileName = ffmpeg,
            UseShellExecute = false,
            RedirectStandardError = true,
            CreateNoWindow = true
        };

        var args = new[]
        {
            "-hide_banner", "-y", "-loglevel", "error",
            "-i", videoPath,
            "-i", systemAudioPath,
            "-filter_complex", filter,
            "-map", "0:v:0",
            "-map", "[aout]",
            "-c:v", "copy",
            "-c:a", "aac", "-b:a", "192k", "-ar", "48000",
            "-t", duration,
            "-movflags", "+faststart",
            tempPath
        };

        foreach (var argument in args)
            startInfo.ArgumentList.Add(argument);

        try
        {
            using var process = new Process { StartInfo = startInfo };
            if (!process.Start())
                throw new InvalidOperationException("无法启动 FFmpeg 系统音频合并进程.");

            var stderrTask = process.StandardError.ReadToEndAsync();
            await process.WaitForExitAsync().ConfigureAwait(false);
            var stderr = await stderrTask.ConfigureAwait(false);
            if (process.ExitCode != 0 || !File.Exists(tempPath))
                throw new InvalidOperationException("系统声音合并失败，原始录制视频已保留。" + Environment.NewLine + stderr.Trim());

            File.Move(tempPath, videoPath, overwrite: true);
            StatusChanged?.Invoke("系统声音已合并到录制视频");
        }
        finally
        {
            TryDelete(tempPath);
        }
    }

    private static void BuildArguments(RecordingOptions options, ICollection<string> args, string videoEncoder)
    {
        Add(args, "-hide_banner", "-y", "-loglevel", "info", "-thread_queue_size", "1024",
            "-f", "gdigrab", "-framerate", options.FramesPerSecond.ToString(CultureInfo.InvariantCulture),
            "-draw_mouse", options.ShowCursor ? "1" : "0");

        if (options.Mode == CaptureMode.Region)
        {
            Add(args,
                "-offset_x", options.RegionX.ToString(CultureInfo.InvariantCulture),
                "-offset_y", options.RegionY.ToString(CultureInfo.InvariantCulture),
                "-video_size", $"{options.RegionWidth}x{options.RegionHeight}");
        }

        Add(args, "-i", options.Mode == CaptureMode.Window ? "title=" + options.WindowTitle : "desktop");

        var nextInput = 1;
        int? microphoneInput = null;
        int? cameraInput = null;

        if (options.CaptureMicrophone)
        {
            microphoneInput = nextInput++;
            Add(args, "-thread_queue_size", "1024", "-f", "dshow", "-i", "audio=" + options.MicrophoneDevice);
        }

        if (options.CaptureCamera)
        {
            cameraInput = nextInput++;
            // Many webcams only expose stable DirectShow modes at 30 FPS. The screen
            // remains 30/60 FPS; the overlay repeats camera frames when necessary.
            Add(args, "-thread_queue_size", "1024", "-f", "dshow",
                "-framerate", "30",
                "-i", "video=" + options.CameraDevice);
        }

        if (cameraInput.HasValue)
        {
            var scale = options.CameraSize switch { "large" => "0.40", "medium" => "0.30", _ => "0.22" };
            var (x, y) = options.CameraPosition switch
            {
                "top-left" => ("32", "32"),
                "top-right" => ("main_w-overlay_w-32", "32"),
                "bottom-left" => ("32", "main_h-overlay_h-32"),
                "center" => ("(main_w-overlay_w)/2", "(main_h-overlay_h)/2"),
                _ => ("main_w-overlay_w-32", "main_h-overlay_h-32")
            };
            var pixelFormat = videoEncoder == "h264_mf" ? "nv12" : "yuv420p";
            var graph = "[0:v:0]pad=ceil(iw/2)*2:ceil(ih/2)*2:0:0:color=black[screenbase];" +
                        $"[{cameraInput.Value}:v:0][screenbase]scale2ref=w=main_w*{scale}:h=main_h*{scale}:force_original_aspect_ratio=decrease[cam][screen];" +
                        $"[screen][cam]overlay=x={x}:y={y}:eof_action=pass:shortest=0:repeatlast=1,format={pixelFormat}[vout]";
            Add(args, "-filter_complex", graph, "-map", "[vout]");
        }
        else
        {
            var pixelFormat = videoEncoder == "h264_mf" ? "nv12" : "yuv420p";
            Add(args, "-vf", $"pad=ceil(iw/2)*2:ceil(ih/2)*2:0:0:color=black,format={pixelFormat}",
                "-map", "0:v:0");
        }

        if (microphoneInput.HasValue)
            Add(args, "-map", $"{microphoneInput.Value}:a:0");
        else
            Add(args, "-an");

        var outputPixelFormat = videoEncoder == "h264_mf" ? "nv12" : "yuv420p";
        Add(args, "-c:v", videoEncoder, "-b:v", videoEncoder == "mpeg4" ? "8M" : "12M",
            "-pix_fmt", outputPixelFormat, "-r", options.FramesPerSecond.ToString(CultureInfo.InvariantCulture));

        if (options.CaptureMicrophone)
            Add(args, "-c:a", "aac", "-b:a", "192k", "-ar", "48000");

        Add(args, "-movflags", "+faststart", Path.GetFullPath(options.OutputPath));
    }

    private async Task StopProcessAndDiscardAudioAsync()
    {
        var process = _process;
        _process = null;
        if (process is not null)
        {
            try
            {
                if (!process.HasExited)
                {
                    process.Kill(entireProcessTree: true);
                    await process.WaitForExitAsync().ConfigureAwait(false);
                }
            }
            catch { }
            finally { process.Dispose(); }
        }

        var capture = _systemAudioCapture;
        _systemAudioCapture = null;
        try
        {
            if (capture is not null)
                await capture.StopAsync().ConfigureAwait(false);
        }
        catch { }
        finally
        {
            capture?.Dispose();
            TryDelete(_systemAudioPath);
            _systemAudioPath = null;
        }
    }

    private static string F(double value) => value.ToString("0.######", CultureInfo.InvariantCulture);

    private static void Add(ICollection<string> args, params string[] values)
    {
        foreach (var value in values)
            args.Add(value);
    }

    private static void TryDelete(string? path)
    {
        if (string.IsNullOrWhiteSpace(path))
            return;
        try { if (File.Exists(path)) File.Delete(path); }
        catch { }
    }

    public void Dispose()
    {
        try { StopProcessAndDiscardAudioAsync().GetAwaiter().GetResult(); }
        catch { }
    }
}