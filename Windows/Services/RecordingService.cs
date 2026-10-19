using System.Collections.Concurrent;
using System.Diagnostics;
using System.Globalization;
using System.IO;
using DogSC.Windows.Models;

namespace DogSC.Windows.Services;

public sealed class RecordingService : IDisposable
{
    private readonly ConcurrentQueue<string> _recentOutput = new();
    private Process? _process;
    private SystemAudioLoopbackCapture? _systemAudioCapture;
    private string? _systemAudioPath;
    private string? _outputPath;
    private long _systemAudioStartedAt;
    private long _videoStartedAt;
    private bool _captureMicrophone;

    public event Action<string>? StatusChanged;

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

            _recentOutput.Clear();
            var startInfo = new ProcessStartInfo
            {
                FileName = ffmpeg,
                UseShellExecute = false,
                RedirectStandardInput = true,
                RedirectStandardError = true,
                CreateNoWindow = true
            };

            BuildArguments(options, startInfo.ArgumentList);
            _process = new Process { StartInfo = startInfo, EnableRaisingEvents = true };
            _process.ErrorDataReceived += (sender, eventArgs) =>
            {
                if (string.IsNullOrWhiteSpace(eventArgs.Data))
                    return;

                _recentOutput.Enqueue(eventArgs.Data);
                while (_recentOutput.Count > 40)
                    _recentOutput.TryDequeue(out _);

                StatusChanged?.Invoke(eventArgs.Data);
            };

            if (!_process.Start())
                throw new InvalidOperationException("无法启动 FFmpeg 录制进程。");

            _videoStartedAt = Stopwatch.GetTimestamp();
            _process.BeginErrorReadLine();
            StatusChanged?.Invoke("正在启动录制...");

            await Task.Delay(700).ConfigureAwait(false);
            if (_process.HasExited)
            {
                var details = string.Join(Environment.NewLine, _recentOutput.ToArray());
                throw new InvalidOperationException("FFmpeg 启动录制失败。" + Environment.NewLine + details);
            }

            StatusChanged?.Invoke("录制中");
        }
        catch
        {
            await StopProcessAndDiscardAudioAsync().ConfigureAwait(false);
            throw;
        }
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

    private static void BuildArguments(RecordingOptions options, ICollection<string> args)
    {
        Add(args, "-hide_banner", "-y", "-loglevel", "info", "-thread_queue_size", "1024",
            "-f", "gdigrab", "-framerate", options.FramesPerSecond.ToString(CultureInfo.InvariantCulture),
            "-draw_mouse", "1");

        if (options.Mode == CaptureMode.Region)
        {
            Add(args,
                "-offset_x", options.RegionX.ToString(CultureInfo.InvariantCulture),
                "-offset_y", options.RegionY.ToString(CultureInfo.InvariantCulture),
                "-video_size", $"{options.RegionWidth}x{options.RegionHeight}");
        }

        Add(args, "-i", options.Mode == CaptureMode.Window ? "title=" + options.WindowTitle : "desktop");

        if (options.CaptureMicrophone)
            Add(args, "-thread_queue_size", "1024", "-f", "dshow", "-i", "audio=" + options.MicrophoneDevice);

        Add(args, "-map", "0:v:0");
        if (options.CaptureMicrophone)
            Add(args, "-map", "1:a:0");
        else
            Add(args, "-an");

        Add(args, "-c:v", "h264_mf", "-b:v", "12M", "-pix_fmt", "nv12",
            "-r", options.FramesPerSecond.ToString(CultureInfo.InvariantCulture));

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