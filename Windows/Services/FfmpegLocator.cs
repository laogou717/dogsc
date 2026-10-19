using System.Diagnostics;
using System.Text.RegularExpressions;

namespace DogSC.Windows.Services;

public static class FfmpegLocator
{
    public static string? FindFfmpegPath()
    {
        var configured = Environment.GetEnvironmentVariable("DOGSC_FFMPEG_PATH");
        if (!string.IsNullOrWhiteSpace(configured))
        {
            if (File.Exists(configured) && string.Equals(Path.GetFileName(configured), "ffmpeg.exe", StringComparison.OrdinalIgnoreCase))
                return Path.GetFullPath(configured);

            if (Directory.Exists(configured))
            {
                var candidate = Path.Combine(configured, "ffmpeg.exe");
                if (File.Exists(candidate))
                    return candidate;
            }
        }

        var bundled = Path.Combine(AppContext.BaseDirectory, "tools", "ffmpeg.exe");
        if (File.Exists(bundled))
            return bundled;

        return FindOnPath("ffmpeg.exe");
    }

    public static string? FindFfprobePath()
    {
        var ffmpeg = FindFfmpegPath();
        if (ffmpeg is not null)
        {
            var adjacent = Path.Combine(Path.GetDirectoryName(ffmpeg)!, "ffprobe.exe");
            if (File.Exists(adjacent))
                return adjacent;
        }

        return FindOnPath("ffprobe.exe");
    }

    public static async Task<IReadOnlyList<string>> GetDirectShowAudioDevicesAsync()
    {
        var ffmpeg = FindFfmpegPath()
            ?? throw new InvalidOperationException("未找到 ffmpeg.exe。请安装包含 dshow/WASAPI 的 FFmpeg，并将其加入 PATH。");

        using var process = new Process
        {
            StartInfo = new ProcessStartInfo
            {
                FileName = ffmpeg,
                UseShellExecute = false,
                RedirectStandardError = true,
                RedirectStandardOutput = true,
                CreateNoWindow = true
            }
        };

        foreach (var argument in new[] { "-hide_banner", "-list_devices", "true", "-f", "dshow", "-i", "dummy" })
            process.StartInfo.ArgumentList.Add(argument);

        process.Start();
        var stderrTask = process.StandardError.ReadToEndAsync();
        var stdoutTask = process.StandardOutput.ReadToEndAsync();
        await process.WaitForExitAsync().ConfigureAwait(false);
        var output = (await stderrTask.ConfigureAwait(false)) + Environment.NewLine + (await stdoutTask.ConfigureAwait(false));

        var devices = Regex.Matches(output, "\"([^\"]+)\"\\s+\\(audio\\)")
            .Select(match => match.Groups[1].Value.Trim())
            .Where(name => name.Length > 0 && !name.StartsWith("@device_", StringComparison.OrdinalIgnoreCase))
            .Distinct(StringComparer.OrdinalIgnoreCase)
            .ToArray();

        return devices;
    }

    private static string? FindOnPath(string executable)
    {
        var path = Environment.GetEnvironmentVariable("PATH");
        if (string.IsNullOrWhiteSpace(path))
            return null;

        foreach (var directory in path.Split(Path.PathSeparator, StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries))
        {
            try
            {
                var candidate = Path.Combine(directory.Trim('"'), executable);
                if (File.Exists(candidate))
                    return candidate;
            }
            catch
            {
                // Ignore malformed PATH entries.
            }
        }

        return null;
    }
}