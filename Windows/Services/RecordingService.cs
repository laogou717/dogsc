using System.Collections.Concurrent;
using System.Diagnostics;
using System.Globalization;
using DogSC.Windows.Models;

namespace DogSC.Windows.Services;

public sealed class RecordingService : IDisposable
{
    private readonly ConcurrentQueue<string> _recentOutput = new();
    private Process? _process;

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

        if (_process is not null)
        {
            if (!_process.HasExited)
                throw new InvalidOperationException("录制已经在进行中。");

            _process.Dispose();
            _process = null;
        }

        var ffmpeg = FfmpegLocator.FindFfmpegPath()
            ?? throw new InvalidOperationException("未找到 ffmpeg.exe。请安装 FFmpeg，并将 ffmpeg.exe 和 ffprobe.exe 加入 PATH。");

        var directory = Path.GetDirectoryName(Path.GetFullPath(options.OutputPath));
        if (!string.IsNullOrWhiteSpace(directory))
            Directory.CreateDirectory(directory);

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
        _process.ErrorDataReceived += (_, eventArgs) =>
        {
            if (string.IsNullOrWhiteSpace(eventArgs.Data))
                return;

            _recentOutput.Enqueue(eventArgs.Data);
            while (_recentOutput.Count > 40)
                _recentOutput.TryDequeue(out _);

            StatusChanged?.Invoke(eventArgs.Data);
        };

        if (!_process.Start())
        {
            _process.Dispose();
            _process = null;
            throw new InvalidOperationException("无法启动 FFmpeg 录制进程。");
        }

        _process.BeginErrorReadLine();
        StatusChanged?.Invoke("正在启动录制...");

        await Task.Delay(700).ConfigureAwait(false);
        if (_process.HasExited)
        {
            var details = string.Join(Environment.NewLine, _recentOutput.ToArray());
            _process.Dispose();
            _process = null;
            throw new InvalidOperationException("FFmpeg 启动录制失败。" + Environment.NewLine + details);
        }

        StatusChanged?.Invoke("录制中");
    }

    public async Task StopAsync()
    {
        var process = _process;
        if (process is null)
            return;

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

        StatusChanged?.Invoke("录制已停止");
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

        var audioInputs = new List<int>();
        var nextInput = 1;

        if (options.CaptureSystemAudio)
        {
            Add(args, "-thread_queue_size", "1024", "-f", "wasapi", "-loopback", "1", "-i", "default");
            audioInputs.Add(nextInput++);
        }

        if (options.CaptureMicrophone)
        {
            Add(args, "-thread_queue_size", "1024", "-f", "dshow", "-i", "audio=" + options.MicrophoneDevice);
            audioInputs.Add(nextInput);
        }

        Add(args, "-map", "0:v:0");

        if (audioInputs.Count == 2)
        {
            var graph = $"[{audioInputs[0]}:a:0]aresample=48000[a1];" +
                        $"[{audioInputs[1]}:a:0]aresample=48000[a2];" +
                        "[a1][a2]amix=inputs=2:duration=longest:dropout_transition=2[aout]";
            Add(args, "-filter_complex", graph, "-map", "[aout]");
        }
        else if (audioInputs.Count == 1)
        {
            Add(args, "-map", $"{audioInputs[0]}:a:0");
        }
        else
        {
            Add(args, "-an");
        }

        Add(args, "-c:v", "libx264", "-preset", "veryfast", "-crf", "20",
            "-pix_fmt", "yuv420p", "-r", options.FramesPerSecond.ToString(CultureInfo.InvariantCulture));

        if (audioInputs.Count > 0)
            Add(args, "-c:a", "aac", "-b:a", "192k", "-ar", "48000");

        Add(args, "-movflags", "+faststart", Path.GetFullPath(options.OutputPath));
    }

    private static void Add(ICollection<string> args, params string[] values)
    {
        foreach (var value in values)
            args.Add(value);
    }

    public void Dispose()
    {
        try
        {
            if (_process is not null && !_process.HasExited)
                _process.Kill(entireProcessTree: true);
        }
        catch
        {
            // Best-effort cleanup during application shutdown.
        }
        finally
        {
            _process?.Dispose();
            _process = null;
        }
    }
}