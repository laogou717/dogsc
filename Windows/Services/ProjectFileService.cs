using System.IO;
using System.Text.Json;
using DogSC.Windows.Models;

namespace DogSC.Windows.Services;

public sealed class ProjectFileService
{
    private const int CurrentVersion = 2;

    public async Task SaveAsync(string path, IReadOnlyList<ClipItem> clips)
    {
        var project = new ProjectDocument
        {
            Version = CurrentVersion,
            Clips = clips.Select(clip => new ProjectClip
            {
                FilePath = Path.GetFullPath(clip.FilePath),
                StartSeconds = clip.StartSeconds,
                EndSeconds = clip.EndSeconds,
                Speed = clip.Speed,
                Volume = clip.Volume,
                FadeInSeconds = clip.FadeInSeconds,
                FadeOutSeconds = clip.FadeOutSeconds,
                RotationDegrees = clip.RotationDegrees
            }).ToList()
        };

        var json = JsonSerializer.Serialize(project, new JsonSerializerOptions { WriteIndented = true });
        var directory = Path.GetDirectoryName(Path.GetFullPath(path));
        if (!string.IsNullOrWhiteSpace(directory))
            Directory.CreateDirectory(directory);
        await File.WriteAllTextAsync(path, json).ConfigureAwait(false);
    }

    public async Task<IReadOnlyList<ClipItem>> LoadAsync(string path)
    {
        var json = await File.ReadAllTextAsync(path).ConfigureAwait(false);
        var project = JsonSerializer.Deserialize<ProjectDocument>(json)
            ?? throw new InvalidDataException("项目文件为空或格式不正确。");

        if (project.Version is < 1 or > CurrentVersion)
            throw new InvalidDataException($"不支持的项目文件版本：{project.Version}。");

        var clips = new List<ClipItem>();
        foreach (var item in project.Clips)
        {
            if (string.IsNullOrWhiteSpace(item.FilePath) || !File.Exists(item.FilePath))
                throw new FileNotFoundException("项目引用的媒体文件不存在。", item.FilePath);

            if (item.StartSeconds < 0 || item.EndSeconds <= item.StartSeconds ||
                item.Speed < 0.5 || item.Speed > 2.0)
                throw new InvalidDataException($"项目片段“{Path.GetFileName(item.FilePath)}”的数据无效。");

            clips.Add(new ClipItem
            {
                FilePath = Path.GetFullPath(item.FilePath),
                StartSeconds = item.StartSeconds,
                EndSeconds = item.EndSeconds,
                Speed = item.Speed,
                Volume = item.Volume,
                FadeInSeconds = item.FadeInSeconds,
                FadeOutSeconds = item.FadeOutSeconds,
                RotationDegrees = item.RotationDegrees
            });
        }

        return clips;
    }

    private sealed class ProjectDocument
    {
        public int Version { get; set; }
        public List<ProjectClip> Clips { get; set; } = new();
    }

    private sealed class ProjectClip
    {
        public string FilePath { get; set; } = string.Empty;
        public double StartSeconds { get; set; }
        public double EndSeconds { get; set; }
        public double Speed { get; set; } = 1.0;
        public double Volume { get; set; } = 1.0;
        public double FadeInSeconds { get; set; }
        public double FadeOutSeconds { get; set; }
        public int RotationDegrees { get; set; }
    }
}