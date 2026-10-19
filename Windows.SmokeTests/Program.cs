using System.Diagnostics;
using System.Globalization;
using DogSC.Windows.Models;
using DogSC.Windows.Services;

static void Require(bool condition, string message)
{
    if (!condition)
        throw new InvalidOperationException("SMOKE TEST FAILED: " + message);
}

static async Task<(int ExitCode, string Output)> RunAsync(string exe, params string[] args)
{
    using var process = new Process
    {
        StartInfo = new ProcessStartInfo
        {
            FileName = exe,
            UseShellExecute = false,
            RedirectStandardOutput = true,
            RedirectStandardError = true,
            CreateNoWindow = true
        }
    };
    foreach (var arg in args)
        process.StartInfo.ArgumentList.Add(arg);

    if (!process.Start())
        throw new InvalidOperationException("Unable to start " + exe);

    var stdout = process.StandardOutput.ReadToEndAsync();
    var stderr = process.StandardError.ReadToEndAsync();
    await process.WaitForExitAsync();
    return (process.ExitCode, (await stdout) + Environment.NewLine + (await stderr));
}

var ffmpeg = FfmpegLocator.FindFfmpegPath()
    ?? throw new InvalidOperationException("Set DOGSC_FFMPEG_PATH to the bundled ffmpeg.exe before running tests.");
var root = Path.Combine(Path.GetTempPath(), "DogSC-Integration-" + Guid.NewGuid().ToString("N"));
Directory.CreateDirectory(root);
try
{
    var source = Path.Combine(root, "source.mp4");
    var output = Path.Combine(root, "edited.mp4");
    var audio = Path.Combine(root, "audio.m4a");
    var projectPath = Path.Combine(root, "roundtrip.dogscproj");

    Console.WriteLine("1/5 Generating a deterministic video+audio source.");
    var generate = await RunAsync(ffmpeg,
        "-hide_banner", "-y", "-loglevel", "error",
        "-f", "lavfi", "-i", "testsrc2=size=640x360:rate=30",
        "-f", "lavfi", "-i", "sine=frequency=440:sample_rate=48000",
        "-t", "3",
        "-c:v", "h264_mf", "-b:v", "1M", "-pix_fmt", "nv12",
        "-c:a", "aac", "-b:a", "96k", "-shortest", source);
    Require(generate.ExitCode == 0 && File.Exists(source) && new FileInfo(source).Length > 1024,
        "could not generate source media: " + generate.Output);

    var editor = new MediaEditorService();
    Console.WriteLine("2/5 Probing the generated media.");
    var sourceInfo = await editor.ProbeAsync(source);
    Require(sourceInfo.HasVideo && sourceInfo.HasAudio && sourceInfo.DurationSeconds >= 2.8,
        "probe did not find the expected video/audio streams and duration.");

    var clip = new ClipItem
    {
        FilePath = source,
        StartSeconds = 0.25,
        EndSeconds = 2.75,
        Speed = 1.25
    };

    Console.WriteLine("3/5 Saving and reopening a project.");
    var projectService = new ProjectFileService();
    await projectService.SaveAsync(projectPath, new[] { clip });
    var reopened = await projectService.LoadAsync(projectPath);
    Require(reopened.Count == 1, "project did not reopen one clip.");
    Require(Math.Abs(reopened[0].StartSeconds - 0.25) < 0.001, "project in-point changed during round-trip.");
    Require(Math.Abs(reopened[0].EndSeconds - 2.75) < 0.001, "project out-point changed during round-trip.");
    Require(Math.Abs(reopened[0].Speed - 1.25) < 0.001, "project speed changed during round-trip.");

    Console.WriteLine("4/5 Exporting an edited MP4.");
    await editor.ExportAsync(reopened, output, 1080, 30, false);
    var exportedInfo = await editor.ProbeAsync(output);
    Require(exportedInfo.HasVideo && exportedInfo.HasAudio, "MP4 export is missing video or audio.");
    Require(exportedInfo.Width == 1920 && exportedInfo.Height == 1080,
        $"MP4 export has unexpected resolution {exportedInfo.Width}x{exportedInfo.Height}.");
    Require(exportedInfo.DurationSeconds > 1.7 && exportedInfo.DurationSeconds < 2.3,
        $"MP4 export has unexpected duration {exportedInfo.DurationSeconds.ToString(CultureInfo.InvariantCulture)}.");

    Console.WriteLine("5/5 Exporting M4A audio.");
    await editor.ExportAsync(reopened, audio, 1080, 30, true);
    var audioInfo = await editor.ProbeAsync(audio);
    Require(audioInfo.HasAudio && !audioInfo.HasVideo, "M4A export must contain audio only.");
    Require(audioInfo.DurationSeconds > 1.7 && audioInfo.DurationSeconds < 2.3,
        $"M4A export has unexpected duration {audioInfo.DurationSeconds.ToString(CultureInfo.InvariantCulture)}.");

    Console.WriteLine("PASS: media probing, project round-trip, MP4 edit/export and M4A export.");
}
finally
{
    try { Directory.Delete(root, recursive: true); }
    catch { Console.Error.WriteLine("Warning: could not clean temporary test directory " + root); }
}