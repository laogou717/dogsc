using System.ComponentModel;
using System.IO;
using System.Runtime.CompilerServices;
using System.Text.Json.Serialization;

namespace DogSC.Windows.Models;

public sealed class ClipItem : INotifyPropertyChanged
{
    private string _filePath = string.Empty;
    private double _startSeconds;
    private double _endSeconds;
    private double _speed = 1.0;
    private double _volume = 1.0;
    private double _fadeInSeconds;
    private double _fadeOutSeconds;
    private int _rotationDegrees;
    private string? _thumbnailPath;

    public string FilePath
    {
        get => _filePath;
        set
        {
            if (SetField(ref _filePath, value))
            {
                OnPropertyChanged(nameof(FileName));
                OnPropertyChanged(nameof(DisplayLabel));
            }
        }
    }

    public double StartSeconds
    {
        get => _startSeconds;
        set
        {
            if (SetField(ref _startSeconds, Math.Max(0, value)))
            {
                OnPropertyChanged(nameof(DurationSeconds));
                OnPropertyChanged(nameof(DisplayLabel));
            }
        }
    }

    public double EndSeconds
    {
        get => _endSeconds;
        set
        {
            if (SetField(ref _endSeconds, Math.Max(0, value)))
            {
                OnPropertyChanged(nameof(DurationSeconds));
                OnPropertyChanged(nameof(DisplayLabel));
            }
        }
    }

    public double Speed
    {
        get => _speed;
        set
        {
            var normalized = double.IsFinite(value) && value > 0 ? value : 1.0;
            if (SetField(ref _speed, normalized))
            {
                OnPropertyChanged(nameof(DurationSeconds));
                OnPropertyChanged(nameof(DisplayLabel));
            }
        }
    }

    public double Volume
    {
        get => _volume;
        set => SetField(ref _volume, double.IsFinite(value) ? Math.Clamp(value, 0, 2) : 1.0);
    }

    public double FadeInSeconds
    {
        get => _fadeInSeconds;
        set => SetField(ref _fadeInSeconds, double.IsFinite(value) ? Math.Clamp(value, 0, 30) : 0);
    }

    public double FadeOutSeconds
    {
        get => _fadeOutSeconds;
        set => SetField(ref _fadeOutSeconds, double.IsFinite(value) ? Math.Clamp(value, 0, 30) : 0);
    }

    public int RotationDegrees
    {
        get => _rotationDegrees;
        set
        {
            var normalized = ((value % 360) + 360) % 360;
            SetField(ref _rotationDegrees, normalized % 90 == 0 ? normalized : 0);
        }
    }

    [JsonIgnore]
    public string? ThumbnailPath
    {
        get => _thumbnailPath;
        set => SetField(ref _thumbnailPath, value);
    }

    [JsonIgnore]
    public string FileName => string.IsNullOrWhiteSpace(FilePath) ? "(未命名)" : Path.GetFileName(FilePath);

    [JsonIgnore]
    public double DurationSeconds => Math.Max(0, EndSeconds - StartSeconds) / Math.Max(0.01, Speed);

    [JsonIgnore]
    public string DisplayLabel => $"{FileName}  |  {StartSeconds:F2}s - {EndSeconds:F2}s  |  {Speed:F2}x";

    public event PropertyChangedEventHandler? PropertyChanged;

    private bool SetField<T>(ref T field, T value, [CallerMemberName] string? propertyName = null)
    {
        if (EqualityComparer<T>.Default.Equals(field, value))
            return false;

        field = value;
        OnPropertyChanged(propertyName);
        return true;
    }

    private void OnPropertyChanged([CallerMemberName] string? propertyName = null) =>
        PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(propertyName));
}