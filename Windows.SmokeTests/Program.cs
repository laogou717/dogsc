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
    var portrait = Path.Combine(root, "portrait.mp4");
    var square = Path.Combine(root, "square.mp4");
    var cameraOverlay = Path.Combine(root, "camera-overlay.mp4");
    var projectPath = Path.Combine(root, "roundtrip.dogscproj");

    Console.WriteLine("1/8 Generating a deterministic video+audio source.");
    var generate = await RunAsync(ffmpeg,
        "-hide_banner", "-y", "-loglevel", "error",
        "-f", "lavfi", "-i", "testsrc2=size=640x360:rate=30",
        "-f", "lavfi", "-i", "sine=frequency=440:sample_rate=48000",
        "-t", "3",
        "-c:v", "h264_mf", "-b:v", "1M", "-pix_fmt", "nv12",
        "-c:a", "aac", "-b:a", "96k", "-shortest", source);
    Require(generate.ExitCode == 0 && File.Exists(source) && new FileInfo(source).Length > 1024,
        "could not generate source media: " + generate.Output);

    Console.WriteLine("2/8 Verifying the webcam overlay filter with synthetic camera input.");
    const string overlayGraph = "[1:v:0][0:v:0]scale2ref=w=main_w*0.22:h=main_h*0.22:force_original_aspect_ratio=decrease[cam][screen];" +
        "[screen][cam]overlay=x=main_w-overlay_w-32:y=main_h-overlay_h-32:eof_action=pass:shortest=0:repeatlast=1[vout]";
    var overlay = await RunAsync(ffmpeg,
        "-hide_banner", "-y", "-loglevel", "error",
        "-f", "lavfi", "-i", "testsrc2=size=1280x720:rate=30",
        "-f", "lavfi", "-i", "testsrc2=size=640x480:rate=30",
        "-t", "1", "-filter_complex", overlayGraph,
        "-map", "[vout]", "-an", "-c:v", "h264_mf", "-b:v", "1M", "-pix_fmt", "nv12", cameraOverlay);
    Require(overlay.ExitCode == 0 && File.Exists(cameraOverlay) && new FileInfo(cameraOverlay).Length > 1024,
        "webcam overlay filter failed: " + overlay.Output);
    var overlayInfo = await new MediaEditorService().ProbeAsync(cameraOverlay);
    Require(overlayInfo.Width == 1280 && overlayInfo.Height == 720,
        $"Webcam overlay changed the screen canvas to {overlayInfo.Width}x{overlayInfo.Height}.");

    var editor = new MediaEditorService();
    Console.WriteLine("3/8 Probing the generated media.");
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

    Console.WriteLine("4/8 Saving and reopening a project.");
    var projectService = new ProjectFileService();
    await projectService.SaveAsync(projectPath, new[] { clip });
    var reopened = await projectService.LoadAsync(projectPath);
    Require(reopened.Count == 1, "project did not reopen one clip.");
    Require(Math.Abs(reopened[0].StartSeconds - 0.25) < 0.001, "project in-point changed during round-trip.");
    Require(Math.Abs(reopened[0].EndSeconds - 2.75) < 0.001, "project out-point changed during round-trip.");
    Require(Math.Abs(reopened[0].Speed - 1.25) < 0.001, "project speed changed during round-trip.");

    Console.WriteLine("5/8 Exporting an edited MP4.");
    await editor.ExportAsync(reopened, output, 1080, 30, false);
    var exportedInfo = await editor.ProbeAsync(output);
    Require(exportedInfo.HasVideo && exportedInfo.HasAudio, "MP4 export is missing video or audio.");
    Require(exportedInfo.Width == 1920 && exportedInfo.Height == 1080,
        $"MP4 export has unexpected resolution {exportedInfo.Width}x{exportedInfo.Height}.");
    Require(exportedInfo.DurationSeconds > 1.7 && exportedInfo.DurationSeconds < 2.3,
        $"MP4 export has unexpected duration {exportedInfo.DurationSeconds.ToString(CultureInfo.InvariantCulture)}.");

    Console.WriteLine("6/8 Exporting a portrait canvas with fit padding.");
    await editor.ExportAsync(reopened, portrait, 1080, 30, false, null, "9:16", "fit", "dark");
    var portraitInfo = await editor.ProbeAsync(portrait);
    Require(portraitInfo.Width == 1080 && portraitInfo.Height == 1920,
        $"Portrait export has unexpected resolution {portraitInfo.Width}x{portraitInfo.Height}.");

    Console.WriteLine("7/8 Exporting a square canvas with fill/crop.");
    await editor.ExportAsync(reopened, square, 1080, 30, false, null, "1:1", "fill", "blue");
    var squareInfo = await editor.ProbeAsync(square);
    Require(squareInfo.Width == 1080 && squareInfo.Height == 1080,
        $"Square export has unexpected resolution {squareInfo.Width}x{squareInfo.Height}.");

    Console.WriteLine("8/8 Exporting M4A audio.");
    await editor.ExportAsync(reopened, audio, 1080, 30, true);
    var audioInfo = await editor.ProbeAsync(audio);
    Require(audioInfo.HasAudio && !audioInfo.HasVideo, "M4A export must contain audio only.");
    Require(audioInfo.DurationSeconds > 1.7 && audioInfo.DurationSeconds < 2.3,
        $"M4A export has unexpected duration {audioInfo.DurationSeconds.ToString(CultureInfo.InvariantCulture)}.");

    Console.WriteLine("PASS: synthetic webcam overlay, media probing, project round-trip, edited MP4, portrait fit, square fill/crop, and M4A export.");
}
finally
{
    try { Directory.Delete(root, recursive: true); }
    catch { Console.Error.WriteLine("Warning: could not clean temporary test directory " + root); }
}