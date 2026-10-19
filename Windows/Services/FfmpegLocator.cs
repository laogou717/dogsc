using System.Diagnostics;
using System.IO;
using System.Text;
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

    public static Task<IReadOnlyList<string>> GetDirectShowAudioDevicesAsync() =>
        GetDirectShowDevicesAsync("audio");

    public static Task<IReadOnlyList<string>> GetDirectShowVideoDevicesAsync() =>
        GetDirectShowDevicesAsync("video");

    private static async Task<IReadOnlyList<string>> GetDirectShowDevicesAsync(string deviceType)
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
        // FFmpeg DirectShow device names can be emitted as UTF-8 or the active
        // Windows ANSI code page depending on the bundled build. Read bytes first
        // so Chinese device names are decoded without replacement characters.
        var stderrTask = ReadAllBytesAsync(process.StandardError.BaseStream);
        var stdoutTask = ReadAllBytesAsync(process.StandardOutput.BaseStream);
        await process.WaitForExitAsync().ConfigureAwait(false);
        var stderrBytes = await stderrTask.ConfigureAwait(false);
        var stdoutBytes = await stdoutTask.ConfigureAwait(false);
        var output = DecodeProcessText(stderrBytes) + Environment.NewLine + DecodeProcessText(stdoutBytes);

        var devices = Regex.Matches(output, "\"([^\"]+)\"\\s+\\(" + Regex.Escape(deviceType) + "\\)")
            .Select(match => match.Groups[1].Value.Trim())
            .Where(name => name.Length > 0 && !name.StartsWith("@device_", StringComparison.OrdinalIgnoreCase))
            .Distinct(StringComparer.OrdinalIgnoreCase)
            .ToArray();

        return devices;
    }

    private static async Task<byte[]> ReadAllBytesAsync(Stream stream)
    {
        using var buffer = new MemoryStream();
        await stream.CopyToAsync(buffer).ConfigureAwait(false);
        return buffer.ToArray();
    }

    private static string DecodeProcessText(byte[] bytes)
    {
        if (bytes.Length == 0)
            return string.Empty;

        try
        {
            return new UTF8Encoding(false, true).GetString(bytes);
        }
        catch (DecoderFallbackException)
        {
            try
            {
                Encoding.RegisterProvider(CodePagesEncodingProvider.Instance);
                var codePage = GetWindowsAnsiCodePage();
                return Encoding.GetEncoding(codePage).GetString(bytes);
            }
            catch
            {
                try { return Encoding.GetEncoding(936).GetString(bytes); }
                catch { return Encoding.Latin1.GetString(bytes); }
            }
        }
    }

    [System.Runtime.InteropServices.DllImport("kernel32.dll")]
    private static extern uint GetACP();

    private static int GetWindowsAnsiCodePage()
    {
        var codePage = GetACP();
        return codePage is > 0 and <= 65535 ? (int)codePage : 936;
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