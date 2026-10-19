namespace DogSC.Windows.Models;

public enum CaptureMode
{
    Desktop,
    Window,
    Region
}

public sealed class RecordingOptions
{
    public required string OutputPath { get; init; }
    public CaptureMode Mode { get; init; } = CaptureMode.Desktop;
    public string? WindowTitle { get; init; }
    public int RegionX { get; init; }
    public int RegionY { get; init; }
    public int RegionWidth { get; init; }
    public int RegionHeight { get; init; }
    public int FramesPerSecond { get; init; } = 30;
    public bool CaptureSystemAudio { get; init; }
    public bool CaptureMicrophone { get; init; }
    public string? MicrophoneDevice { get; init; }
    public bool CaptureCamera { get; init; }
    public string? CameraDevice { get; init; }
    public string CameraPosition { get; init; } = "bottom-right";
    public string CameraSize { get; init; } = "small";

    public void Validate()
    {
        if (string.IsNullOrWhiteSpace(OutputPath))
            throw new InvalidOperationException("请先选择录制文件的保存位置。");

        if (FramesPerSecond is not (30 or 60))
            throw new InvalidOperationException("录制帧率仅支持 30 或 60 FPS。");

        if (Mode == CaptureMode.Window && string.IsNullOrWhiteSpace(WindowTitle))
            throw new InvalidOperationException("请选择要录制的窗口。");

        // Negative offsets are valid on Windows virtual desktops when a secondary
        // monitor is positioned left of or above the primary monitor.
        if (Mode == CaptureMode.Region && (RegionWidth < 16 || RegionHeight < 16))
            throw new InvalidOperationException("区域宽和高至少为 16 像素。");

        if (CaptureMicrophone && string.IsNullOrWhiteSpace(MicrophoneDevice))
            throw new InvalidOperationException("已启用麦克风录制，但没有选择麦克风设备。");

        if (CaptureCamera && string.IsNullOrWhiteSpace(CameraDevice))
            throw new InvalidOperationException("已启用摄像头叠加，但没有选择摄像头设备。");

        if (CameraPosition is not ("top-left" or "top-right" or "bottom-left" or "bottom-right" or "center"))
            throw new InvalidOperationException("摄像头位置设置无效。");

        if (CameraSize is not ("small" or "medium" or "large"))
            throw new InvalidOperationException("摄像头尺寸设置无效。");
    }
}