using System.Diagnostics;
using System.Globalization;
using System.IO;
using System.Text.Json;
using DogSC.Windows.Models;

namespace DogSC.Windows.Services;

public sealed record MediaProbeInfo(double DurationSeconds, bool HasVideo, bool HasAudio, int Width, int Height);

public sealed class MediaEditorService
{
    public async Task<MediaProbeInfo> ProbeAsync(string path)
    {
        if (!File.Exists(path))
            throw new FileNotFoundException("找不到媒体文件。", path);

        var ffprobe = FfmpegLocator.FindFfprobePath()
            ?? throw new InvalidOperationException("未找到 ffprobe.exe。请安装包含 ffmpeg.exe 和 ffprobe.exe 的 FFmpeg 发行版。");

        var result = await RunProcessAsync(ffprobe, new[]
        {
            "-v", "error",
            "-show_entries", "format=duration:stream=codec_type,width,height",
            "-of", "json",
            path
        }).ConfigureAwait(false);

        if (result.ExitCode != 0)
            throw new InvalidOperationException("无法读取媒体信息：" + result.StandardError.Trim());

        using var document = JsonDocument.Parse(result.StandardOutput);
        var root = document.RootElement;
        var duration = 0d;
        if (root.TryGetProperty("format", out var format) &&
            format.TryGetProperty("duration", out var durationElement))
            duration = ReadDouble(durationElement);

        var hasVideo = false;
        var hasAudio = false;
        var width = 0;
        var height = 0;

        if (root.TryGetProperty("streams", out var streams))
        {
            foreach (var stream in streams.EnumerateArray())
            {
                var type = stream.TryGetProperty("codec_type", out var codecType) ? codecType.GetString() : null;
                if (string.Equals(type, "video", StringComparison.OrdinalIgnoreCase))
                {
                    hasVideo = true;
                    if (stream.TryGetProperty("width", out var w))
                        width = (int)ReadDouble(w);
                    if (stream.TryGetProperty("height", out var h))
                        height = (int)ReadDouble(h);
                }
                else if (string.Equals(type, "audio", StringComparison.OrdinalIgnoreCase))
                {
                    hasAudio = true;
                }
            }
        }

        if (duration <= 0 || !double.IsFinite(duration))
            throw new InvalidOperationException("媒体文件没有可识别的有效时长。");

        return new MediaProbeInfo(duration, hasVideo, hasAudio, width, height);
    }

    public async Task ExportAsync(
        IReadOnlyList<ClipItem> clips,
        string outputPath,
        int outputHeight,
        int framesPerSecond,
        bool audioOnly,
        IProgress<string>? progress = null,
        string aspectRatio = "16:9",
        string fitMode = "fit",
        string backgroundColor = "black",
        string? backgroundImagePath = null,
        string? subtitleFilePath = null)
    {
        if (clips.Count == 0)
            throw new InvalidOperationException("时间线上没有可导出的片段。");
        if (framesPerSecond is not (30 or 60))
            throw new InvalidOperationException("导出帧率仅支持 30 或 60 FPS。");
        if (!audioOnly && outputHeight is not (1080 or 1440 or 2160))
            throw new InvalidOperationException("视频导出分辨率仅支持 1080p、1440p 或 4K。");
        if (aspectRatio is not ("16:9" or "9:16" or "1:1" or "4:3" or "3:2"))
            throw new InvalidOperationException("画面比例不受支持。");
        if (fitMode is not ("fit" or "fill"))
            throw new InvalidOperationException("画面适配模式不受支持。");
        backgroundColor = backgroundColor switch
        {
            "black" => "black",
            "white" => "white",
            "dark" => "0x1E293B",
            "blue" => "0x1D4ED8",
            _ => throw new InvalidOperationException("背景颜色不受支持。")
        };
        if (!string.IsNullOrWhiteSpace(backgroundImagePath))
        {
            backgroundImagePath = Path.GetFullPath(backgroundImagePath);
            if (!File.Exists(backgroundImagePath))
                throw new FileNotFoundException("找不到背景图片。", backgroundImagePath);
            if (audioOnly)
                backgroundImagePath = null;
        }
        if (!string.IsNullOrWhiteSpace(subtitleFilePath))
        {
            subtitleFilePath = Path.GetFullPath(subtitleFilePath);
            if (!File.Exists(subtitleFilePath))
                throw new FileNotFoundException("找不到 SRT 字幕文件。", subtitleFilePath);
            if (audioOnly)
                subtitleFilePath = null;
        }
        if (audioOnly && !string.Equals(Path.GetExtension(outputPath), ".m4a", StringComparison.OrdinalIgnoreCase))
            throw new InvalidOperationException("音频导出文件必须使用 .m4a 扩展名。");
        if (!audioOnly && !string.Equals(Path.GetExtension(outputPath), ".mp4", StringComparison.OrdinalIgnoreCase))
            throw new InvalidOperationException("视频导出文件必须使用 .mp4 扩展名。");

        var ffmpeg = FfmpegLocator.FindFfmpegPath()
            ?? throw new InvalidOperationException("未找到 ffmpeg.exe。请先安装 FFmpeg。");

        var probes = new MediaProbeInfo[clips.Count];
        for (var i = 0; i < clips.Count; i++)
        {
            var clip = clips[i];
            if (clip.StartSeconds < 0 || clip.EndSeconds <= clip.StartSeconds || clip.Speed < 0.5 || clip.Speed > 2.0)
                throw new InvalidOperationException($"片段“{clip.FileName}”的裁剪范围或速度无效。");

            probes[i] = await ProbeAsync(clip.FilePath).ConfigureAwait(false);
            if (!probes[i].HasVideo)
                throw new InvalidOperationException($"“{clip.FileName}”不包含视频流，不能放入视频时间线。");
            if (clip.EndSeconds > probes[i].DurationSeconds + 0.05)
                throw new InvalidOperationException($"片段“{clip.FileName}”的结束时间超过媒体时长。");
        }

        var outputDirectory = Path.GetDirectoryName(Path.GetFullPath(outputPath));
        if (!string.IsNullOrWhiteSpace(outputDirectory))
            Directory.CreateDirectory(outputDirectory);

        var totalDuration = clips.Sum(clip => clip.DurationSeconds);
        var graph = BuildFilterGraph(clips, probes, outputHeight, framesPerSecond, audioOnly, aspectRatio, fitMode, backgroundColor, backgroundImagePath, subtitleFilePath);
        var args = new List<string> { "-hide_banner", "-y", "-loglevel", "error" };

        foreach (var clip in clips)
        {
            args.Add("-i");
            args.Add(Path.GetFullPath(clip.FilePath));
        }

        if (!audioOnly && !string.IsNullOrWhiteSpace(backgroundImagePath))
        {
            foreach (var clip in clips)
            {
                args.Add("-loop");
                args.Add("1");
                args.Add("-framerate");
                args.Add(framesPerSecond.ToString(CultureInfo.InvariantCulture));
                args.Add("-t");
                args.Add(F(clip.DurationSeconds));
                args.Add("-i");
                args.Add(backgroundImagePath);
            }
        }

        args.Add("-filter_complex");
        args.Add(graph);

        if (audioOnly)
        {
            args.AddRange(new[] { "-map", "[aout]", "-vn", "-c:a", "aac", "-b:a", "192k", "-ar", "48000" });
        }
        else
        {
            var videoBitrate = outputHeight switch
            {
                1440 => "16M",
                2160 => "35M",
                _ => "8M"
            };
            args.AddRange(new[]
            {
                "-map", string.IsNullOrWhiteSpace(subtitleFilePath) ? "[vout]" : "[vsub]", "-map", "[aout]",
                "-c:v", "h264_mf", "-b:v", videoBitrate,
                "-pix_fmt", "nv12", "-r", framesPerSecond.ToString(CultureInfo.InvariantCulture),
                "-c:a", "aac", "-b:a", "192k", "-ar", "48000"
            });
        }

        args.AddRange(new[] { "-movflags", "+faststart", "-progress", "pipe:1", "-nostats", Path.GetFullPath(outputPath) });
        progress?.Report("正在导出...");

        var startInfo = new ProcessStartInfo
        {
            FileName = ffmpeg,
            UseShellExecute = false,
            RedirectStandardOutput = true,
            RedirectStandardError = true,
            CreateNoWindow = true
        };
        foreach (var argument in args)
            startInfo.ArgumentList.Add(argument);

        using var process = new Process { StartInfo = startInfo };
        if (!process.Start())
            throw new InvalidOperationException("无法启动 FFmpeg 导出进程。");

        var stderrTask = process.StandardError.ReadToEndAsync();
        while (await process.StandardOutput.ReadLineAsync().ConfigureAwait(false) is { } line)
        {
            if (line.StartsWith("out_time_us=", StringComparison.Ordinal) &&
                long.TryParse(line.AsSpan("out_time_us=".Length), NumberStyles.Integer, CultureInfo.InvariantCulture, out var micros) &&
                totalDuration > 0)
            {
                var percent = Math.Clamp(micros / 1_000_000d / totalDuration * 100d, 0, 100);
                progress?.Report($"正在导出：{percent:F0}%");
            }
        }

        await process.WaitForExitAsync().ConfigureAwait(false);
        var stderr = await stderrTask.ConfigureAwait(false);
        if (process.ExitCode != 0)
            throw new InvalidOperationException("导出失败：" + stderr.Trim());

        progress?.Report("导出完成");
    }

    private static string BuildFilterGraph(
        IReadOnlyList<ClipItem> clips,
        IReadOnlyList<MediaProbeInfo> probes,
        int outputHeight,
        int framesPerSecond,
        bool audioOnly,
        string aspectRatio,
        string fitMode,
        string backgroundColor,
        string? backgroundImagePath,
        string? subtitleFilePath)
    {
        var filters = new List<string>();
        var (width, height) = GetCanvasSize(outputHeight, aspectRatio);
        var hasBackgroundImage = !audioOnly && !string.IsNullOrWhiteSpace(backgroundImagePath);
        if (hasBackgroundImage)
        {
            for (var i = 0; i < clips.Count; i++)
            {
                var bgInputIndex = clips.Count + i;
                filters.Add($"[{bgInputIndex}:v:0]scale={width}:{height}:force_original_aspect_ratio=increase," +
                    $"crop={width}:{height},setsar=1,format=nv12[bg{i}]");
            }
        }

        for (var i = 0; i < clips.Count; i++)
        {
            var clip = clips[i];
            var start = F(clip.StartSeconds);
            var end = F(clip.EndSeconds);
            var speed = F(clip.Speed);
            var duration = F(clip.DurationSeconds);
            var fadeIn = Math.Min(clip.FadeInSeconds, clip.DurationSeconds / 2);
            var fadeOut = Math.Min(clip.FadeOutSeconds, clip.DurationSeconds / 2);
            var rotationFilter = clip.RotationDegrees switch
            {
                90 => ",transpose=1",
                180 => ",hflip,vflip",
                270 => ",transpose=2",
                _ => string.Empty
            };
            var zoomFilter = Math.Abs(clip.ZoomStart - clip.ZoomEnd) > 0.001
                ? $",zoompan=z='{F(clip.ZoomStart)}+({F(clip.ZoomEnd)}-{F(clip.ZoomStart)})*on/{F(Math.Max(1, clip.DurationSeconds * framesPerSecond))}':d=1:s={Math.Max(2, probes[i].Width)}x{Math.Max(2, probes[i].Height)}:fps={framesPerSecond}"
                : string.Empty;

            if (!audioOnly)
            {
                var scaleMode = fitMode == "fit" ? "decrease" : "increase";
                var videoFadeFilters = string.Empty;
                if (fadeIn > 0.001)
                    videoFadeFilters += $",fade=t=in:st=0:d={F(fadeIn)}";
                if (fadeOut > 0.001)
                    videoFadeFilters += $",fade=t=out:st={F(Math.Max(0, clip.DurationSeconds - fadeOut))}:d={F(fadeOut)}";
                var fitFilters = fitMode == "fit"
                    ? hasBackgroundImage ? string.Empty : $",pad={width}:{height}:(ow-iw)/2:(oh-ih)/2:color={backgroundColor}"
                    : $",crop={width}:{height}";
                if (hasBackgroundImage)
                {
                    filters.Add($"[{i}:v:0]trim=start={start}:end={end},setpts=(PTS-STARTPTS)/{speed}{zoomFilter}{rotationFilter}," +
                        $"scale={width}:{height}:force_original_aspect_ratio={scaleMode}{fitFilters}," +
                        $"setsar=1,fps={framesPerSecond}{videoFadeFilters},format=nv12[fg{i}]");
                    var x = fitMode == "fit" ? "(W-w)/2" : "0";
                    var y = fitMode == "fit" ? "(H-h)/2" : "0";
                    filters.Add($"[bg{i}][fg{i}]overlay=x={x}:y={y}:shortest=1,format=nv12[v{i}]");
                }
                else
                {
                    filters.Add($"[{i}:v:0]trim=start={start}:end={end},setpts=(PTS-STARTPTS)/{speed}{rotationFilter}," +
                        $"scale={width}:{height}:force_original_aspect_ratio={scaleMode}{fitFilters}," +
                        $"setsar=1,fps={framesPerSecond}{videoFadeFilters},format=nv12[v{i}]");
                }
            }

            if (probes[i].HasAudio)
            {
                var atempo = BuildAtempo(clip.Speed);
                var audioFilters = string.IsNullOrEmpty(atempo) ? string.Empty : "," + atempo;
                audioFilters += $",volume={F(clip.Volume)}";
                if (fadeIn > 0.001)
                    audioFilters += $",afade=t=in:st=0:d={F(fadeIn)}";
                if (fadeOut > 0.001)
                    audioFilters += $",afade=t=out:st={F(Math.Max(0, clip.DurationSeconds - fadeOut))}:d={F(fadeOut)}";
                filters.Add($"[{i}:a:0]atrim=start={start}:end={end},asetpts=PTS-STARTPTS{audioFilters},aformat=sample_fmts=fltp:sample_rates=48000:channel_layouts=stereo[a{i}]");
            }
            else
            {
                filters.Add($"anullsrc=channel_layout=stereo:sample_rate=48000,atrim=duration={duration},asetpts=PTS-STARTPTS,aformat=sample_fmts=fltp:sample_rates=48000:channel_layouts=stereo[a{i}]");
            }
        }

        if (audioOnly)
        {
            filters.Add(string.Concat(Enumerable.Range(0, clips.Count).Select(i => $"[a{i}]")) +
                $"concat=n={clips.Count}:v=0:a=1[aout]");
        }
        else
        {
            var inputs = string.Concat(Enumerable.Range(0, clips.Count).Select(i => $"[v{i}][a{i}]"));
            filters.Add(inputs + $"concat=n={clips.Count}:v=1:a=1[vout][aout]");
        }

        if (!audioOnly && !string.IsNullOrWhiteSpace(subtitleFilePath))
        {
            var escapedSubtitlePath = EscapeFilterPath(subtitleFilePath);
            filters.Add($"[vout]subtitles=filename='{escapedSubtitlePath}':charenc=UTF-8[vsub]");
        }

        return string.Join(";", filters);
    }

    private static string EscapeFilterPath(string path) =>
        Path.GetFullPath(path).Replace("\\", "/").Replace(":", "\\:").Replace("'", "\\'");

    private static (int Width, int Height) GetCanvasSize(int shortEdge, string aspectRatio)
    {
        static int Even(double value)
        {
            var rounded = (int)Math.Round(value, MidpointRounding.AwayFromZero);
            return rounded % 2 == 0 ? rounded : rounded - 1;
        }

        return aspectRatio switch
        {
            "9:16" => (shortEdge, Even(shortEdge * 16d / 9d)),
            "1:1" => (shortEdge, shortEdge),
            "4:3" => (Even(shortEdge * 4d / 3d), shortEdge),
            "3:2" => (Even(shortEdge * 3d / 2d), shortEdge),
            _ => (Even(shortEdge * 16d / 9d), shortEdge)
        };
    }

    private static string BuildAtempo(double speed)
    {
        var factors = new List<double>();
        while (speed > 2.0)
        {
            factors.Add(2.0);
            speed /= 2.0;
        }
        while (speed < 0.5)
        {
            factors.Add(0.5);
            speed /= 0.5;
        }
        if (Math.Abs(speed - 1.0) > 0.0001)
            factors.Add(speed);

        return string.Join(",", factors.Select(factor => "atempo=" + F(factor)));
    }

    private static string F(double value) => value.ToString("0.######", CultureInfo.InvariantCulture);

    private static double ReadDouble(JsonElement element)
    {
        if (element.ValueKind == JsonValueKind.Number && element.TryGetDouble(out var number))
            return number;
        if (element.ValueKind == JsonValueKind.String &&
            double.TryParse(element.GetString(), NumberStyles.Float, CultureInfo.InvariantCulture, out number))
            return number;
        return 0;
    }

    private static async Task<(int ExitCode, string StandardOutput, string StandardError)> RunProcessAsync(
        string executable,
        IEnumerable<string> arguments)
    {
        using var process = new Process
        {
            StartInfo = new ProcessStartInfo
            {
                FileName = executable,
                UseShellExecute = false,
                RedirectStandardOutput = true,
                RedirectStandardError = true,
                CreateNoWindow = true
            }
        };

        foreach (var argument in arguments)
            process.StartInfo.ArgumentList.Add(argument);

        if (!process.Start())
            throw new InvalidOperationException($"无法启动 {Path.GetFileName(executable)}。");

        var stdoutTask = process.StandardOutput.ReadToEndAsync();
        var stderrTask = process.StandardError.ReadToEndAsync();
        await process.WaitForExitAsync().ConfigureAwait(false);
        return (process.ExitCode, await stdoutTask.ConfigureAwait(false), await stderrTask.ConfigureAwait(false));
    }
}