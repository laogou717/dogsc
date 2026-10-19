using System.Collections.ObjectModel;
using System.ComponentModel;
using System.Globalization;
using System.IO;
using System.Runtime.InteropServices;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Interop;
using DogSC.Windows.Models;
using DogSC.Windows.Services;
using Microsoft.Win32;

namespace DogSC.Windows;

public partial class MainWindow : Window
{
    private readonly RecordingService _recordingService = new();
    private readonly MediaEditorService _mediaEditorService = new();
    private readonly ProjectFileService _projectFileService = new();
    private readonly ObservableCollection<ClipItem> _clips = new();
    private bool _previewPlaying;
    private bool _closingAfterStop;
    private double _previewStartSeconds;
    private MediaElement? _previewElement;
    private const int MarkerHotKeyId = 0xD05C;
    private const int WmHotKey = 0x0312;
    private const uint ModAlt = 0x0001;
    private const uint ModControl = 0x0002;
    private const uint VirtualKeyM = 0x4D;
    private HwndSource? _windowSource;
    private bool _markerHotKeyRegistered;

    [DllImport("user32.dll", SetLastError = true)]
    private static extern bool RegisterHotKey(IntPtr hWnd, int id, uint modifiers, uint virtualKey);

    [DllImport("user32.dll", SetLastError = true)]
    private static extern bool UnregisterHotKey(IntPtr hWnd, int id);

    public MainWindow()
    {
        App.WriteDiagnostic("MainWindow constructor entered");
        InitializeComponent();
        App.WriteDiagnostic("MainWindow InitializeComponent completed");
        ClipsGrid.ItemsSource = _clips;
        CaptureModeCombo.SelectedIndex = 0;
        FrameRateCombo.SelectedIndex = 0;
        ExportFormatCombo.SelectedIndex = 0;
        ExportResolutionCombo.SelectedIndex = 0;
        ExportFrameRateCombo.SelectedIndex = 0;
        ClipSpeedCombo.SelectedIndex = 2;
        var videos = Environment.GetFolderPath(Environment.SpecialFolder.MyVideos);
        OutputPathTextBox.Text = Path.Combine(videos, "DogSC", $"DogSC-{DateTime.Now:yyyyMMdd-HHmmss}.mp4");

        _recordingService.StatusChanged += message =>
        {
            if (!Dispatcher.HasShutdownStarted)
                Dispatcher.BeginInvoke(new Action(() => RecordingStatusText.Text = message));
        };

        // Do not enumerate native top-level windows during startup. On Windows,
        // display enumeration is an explicit user action and is refreshed on demand.
        Loaded += async (_, _) =>
        {
            App.WriteDiagnostic("MainWindow loaded; starting audio device discovery");
            await LoadMicrophoneDevicesAsync();
            App.WriteDiagnostic("Audio device discovery finished");
        };
    }

    protected override void OnSourceInitialized(EventArgs e)
    {
        base.OnSourceInitialized(e);

        var handle = new WindowInteropHelper(this).Handle;
        _windowSource = HwndSource.FromHwnd(handle);
        _windowSource?.AddHook(WindowMessageHook);
        _markerHotKeyRegistered = RegisterHotKey(handle, MarkerHotKeyId, ModControl | ModAlt, VirtualKeyM);
        App.WriteDiagnostic(_markerHotKeyRegistered
            ? "Global marker shortcut Ctrl+Alt+M registered"
            : $"Global marker shortcut registration failed: {Marshal.GetLastWin32Error()}");
    }

    protected override void OnClosed(EventArgs e)
    {
        var handle = new WindowInteropHelper(this).Handle;
        if (_markerHotKeyRegistered)
            _ = UnregisterHotKey(handle, MarkerHotKeyId);
        _windowSource?.RemoveHook(WindowMessageHook);
        _windowSource = null;
        base.OnClosed(e);
    }

    private IntPtr WindowMessageHook(IntPtr hwnd, int message, IntPtr wParam, IntPtr lParam, ref bool handled)
    {
        if (message == WmHotKey && wParam.ToInt32() == MarkerHotKeyId)
        {
            var marker = _recordingService.AddMarker();
            if (marker is not null)
                RecordingStatusText.Text = $"已添加剪辑标记 #{marker.Index}，时间 {marker.TimeSeconds:F2} 秒。";
            handled = true;
        }

        return IntPtr.Zero;
    }

    private void CaptureModeCombo_SelectionChanged(object sender, SelectionChangedEventArgs e)
    {
        if (WindowSelectionPanel is null || RegionSelectionPanel is null)
            return;
        var tag = (CaptureModeCombo.SelectedItem as ComboBoxItem)?.Tag?.ToString();
        WindowSelectionPanel.Visibility = tag == "Window" ? Visibility.Visible : Visibility.Collapsed;
        RegionSelectionPanel.Visibility = tag == "Region" ? Visibility.Visible : Visibility.Collapsed;
    }

    private void RefreshWindows_Click(object sender, RoutedEventArgs e) => RefreshWindows();

    private void RefreshWindows()
    {
        var current = WindowCombo.SelectedItem as WindowSource;
        var windows = WindowSourceProvider.GetVisibleWindows();
        WindowCombo.ItemsSource = windows;
        if (current is not null)
            WindowCombo.SelectedItem = windows.FirstOrDefault(item => item.Title == current.Title);
        if (WindowCombo.SelectedIndex < 0 && windows.Count > 0)
            WindowCombo.SelectedIndex = 0;
    }

    private async void RefreshAudioDevices_Click(object sender, RoutedEventArgs e) => await LoadMicrophoneDevicesAsync();

    private async Task LoadMicrophoneDevicesAsync()
    {
        try
        {
            var selected = MicrophoneCombo.SelectedItem as string;
            var devices = await FfmpegLocator.GetDirectShowAudioDevicesAsync();
            MicrophoneCombo.ItemsSource = devices;
            if (selected is not null && devices.Contains(selected))
                MicrophoneCombo.SelectedItem = selected;
            else if (devices.Count > 0)
                MicrophoneCombo.SelectedIndex = 0;
            if (devices.Count == 0)
                RecordingStatusText.Text = "未检测到 DirectShow 麦克风设备；仍可尝试录制系统声音。";
        }
        catch (Exception exception)
        {
            RecordingStatusText.Text = exception.Message;
        }
    }

    private void BrowseOutput_Click(object sender, RoutedEventArgs e)
    {
        var dialog = new SaveFileDialog
        {
            Title = "保存录制视频",
            Filter = "MP4 视频|*.mp4",
            DefaultExt = ".mp4",
            AddExtension = true,
            FileName = Path.GetFileName(OutputPathTextBox.Text)
        };
        if (dialog.ShowDialog(this) == true)
            OutputPathTextBox.Text = dialog.FileName;
    }

    private async void StartRecording_Click(object sender, RoutedEventArgs e)
    {
        try
        {
            var modeTag = (CaptureModeCombo.SelectedItem as ComboBoxItem)?.Tag?.ToString();
            var mode = modeTag switch { "Window" => CaptureMode.Window, "Region" => CaptureMode.Region, _ => CaptureMode.Desktop };
            var output = OutputPathTextBox.Text.Trim();
            if (File.Exists(output) &&
                MessageBox.Show(this, "目标文件已存在，是否覆盖？", "确认覆盖", MessageBoxButton.YesNo, MessageBoxImage.Warning) != MessageBoxResult.Yes)
                return;

            var options = new RecordingOptions
            {
                OutputPath = output,
                Mode = mode,
                WindowTitle = (WindowCombo.SelectedItem as WindowSource)?.Title,
                RegionX = ReadTextInt(RegionXTextBox.Text, "区域 X"),
                RegionY = ReadTextInt(RegionYTextBox.Text, "区域 Y"),
                RegionWidth = ReadTextInt(RegionWidthTextBox.Text, "区域宽度"),
                RegionHeight = ReadTextInt(RegionHeightTextBox.Text, "区域高度"),
                FramesPerSecond = ReadTagInt(FrameRateCombo, 30),
                CaptureSystemAudio = SystemAudioCheckBox.IsChecked == true,
                CaptureMicrophone = MicrophoneCheckBox.IsChecked == true,
                MicrophoneDevice = MicrophoneCombo.SelectedItem as string
            };

            StartRecordingButton.IsEnabled = false;
            StopRecordingButton.IsEnabled = true;
            AddMarkerButton.IsEnabled = true;
            RecordingStatusText.Text = "正在启动录制...";
            await _recordingService.StartAsync(options);
            RecordingStatusText.Text = "录制中。结束后请点击“停止录制”。";
        }
        catch (Exception exception)
        {
            StartRecordingButton.IsEnabled = true;
            StopRecordingButton.IsEnabled = false;
            AddMarkerButton.IsEnabled = false;
            RecordingStatusText.Text = exception.Message;
            MessageBox.Show(this, exception.Message, "无法开始录制", MessageBoxButton.OK, MessageBoxImage.Error);
        }
    }

    private async void StopRecording_Click(object sender, RoutedEventArgs e) => await StopRecordingAsync();

    private async Task StopRecordingAsync()
    {
        try
        {
            await _recordingService.StopAsync();
            RecordingStatusText.Text = "录制已停止。输出文件：" + OutputPathTextBox.Text;
        }
        catch (Exception exception)
        {
            RecordingStatusText.Text = exception.Message;
            MessageBox.Show(this, exception.Message, "停止录制时出错", MessageBoxButton.OK, MessageBoxImage.Error);
        }
        finally
        {
            StartRecordingButton.IsEnabled = true;
            StopRecordingButton.IsEnabled = false;
            AddMarkerButton.IsEnabled = false;
        }
    }

    private void AddRecordingMarker_Click(object sender, RoutedEventArgs e)
    {
        var marker = _recordingService.AddMarker();
        if (marker is null)
        {
            RecordingStatusText.Text = "当前没有正在进行的录制，无法添加标记。";
            return;
        }

        RecordingStatusText.Text = $"已添加剪辑标记 #{marker.Index}，时间 {marker.TimeSeconds:F2} 秒。";
    }

    private void AddClips_Click(object sender, RoutedEventArgs e) => _ = AddClipsAsync();

    private async Task AddClipsAsync()
    {
        var dialog = new OpenFileDialog
        {
            Title = "导入视频",
            Filter = "视频文件|*.mp4;*.mov;*.mkv;*.avi;*.webm;*.m4v;*.wmv|所有文件|*.*",
            Multiselect = true
        };
        if (dialog.ShowDialog(this) != true)
            return;

        var added = 0;
        foreach (var path in dialog.FileNames)
        {
            try
            {
                var probe = await _mediaEditorService.ProbeAsync(path);
                if (!probe.HasVideo)
                    throw new InvalidOperationException("文件不包含视频流。");
                _clips.Add(new ClipItem { FilePath = Path.GetFullPath(path), StartSeconds = 0, EndSeconds = probe.DurationSeconds, Speed = 1 });
                added++;
            }
            catch (Exception exception)
            {
                MessageBox.Show(this, $"{Path.GetFileName(path)}：{exception.Message}", "无法导入媒体",
                    MessageBoxButton.OK, MessageBoxImage.Warning);
            }
        }

        if (_clips.Count > 0 && ClipsGrid.SelectedIndex < 0)
            ClipsGrid.SelectedIndex = 0;
        EditorStatusText.Text = $"已导入 {added} 个视频片段。当前时间线共 {_clips.Count} 个片段。";
    }

    private void ClipsGrid_SelectionChanged(object sender, SelectionChangedEventArgs e)
    {
        if (ClipsGrid.SelectedItem is not ClipItem clip)
            return;
        ClipStartTextBox.Text = clip.StartSeconds.ToString("0.##", CultureInfo.InvariantCulture);
        ClipEndTextBox.Text = clip.EndSeconds.ToString("0.##", CultureInfo.InvariantCulture);
        ClipSpeedCombo.SelectedItem = ClipSpeedCombo.Items.OfType<ComboBoxItem>()
            .FirstOrDefault(item => Math.Abs(ReadTagDouble(item, 1) - clip.Speed) < 0.0001);
        _previewStartSeconds = clip.StartSeconds;
        _previewPlaying = false;
        PreviewPlayButton.Content = "播放预览";
        try
        {
            var preview = EnsurePreviewElement();
            preview.Stop();
            preview.Source = new Uri(Path.GetFullPath(clip.FilePath));
        }
        catch (Exception exception)
        {
            EditorStatusText.Text = "无法初始化媒体预览：" + exception.Message;
        }
    }

    private MediaElement EnsurePreviewElement()
    {
        if (_previewElement is not null)
            return _previewElement;

        var preview = new MediaElement
        {
            LoadedBehavior = MediaState.Manual,
            UnloadedBehavior = MediaState.Manual,
            Stretch = System.Windows.Media.Stretch.Uniform,
            ScrubbingEnabled = true
        };
        preview.MediaOpened += PreviewElement_MediaOpened;
        preview.MediaEnded += PreviewElement_MediaEnded;
        PreviewHost.Content = preview;
        _previewElement = preview;
        return preview;
    }

    private void PreviewElement_MediaOpened(object sender, RoutedEventArgs e)
    {
        if (sender is not MediaElement preview)
            return;
        try
        {
            preview.Position = TimeSpan.FromSeconds(Math.Max(0, _previewStartSeconds));
            preview.Pause();
            _previewPlaying = false;
            PreviewPlayButton.Content = "播放预览";
        }
        catch (Exception exception)
        {
            EditorStatusText.Text = "媒体预览定位失败：" + exception.Message;
        }
    }

    private void PreviewElement_MediaEnded(object sender, RoutedEventArgs e)
    {
        _previewPlaying = false;
        PreviewPlayButton.Content = "播放预览";
    }

    private void TogglePreview_Click(object sender, RoutedEventArgs e)
    {
        if (_previewElement?.Source is null)
        {
            EditorStatusText.Text = "请先导入并选择一个视频片段。";
            return;
        }
        try
        {
            if (_previewPlaying)
            {
                _previewElement.Pause();
                _previewPlaying = false;
                PreviewPlayButton.Content = "播放预览";
            }
            else
            {
                _previewElement.Play();
                _previewPlaying = true;
                PreviewPlayButton.Content = "暂停预览";
            }
        }
        catch (Exception exception)
        {
            EditorStatusText.Text = "无法播放预览：" + exception.Message;
            _previewPlaying = false;
            PreviewPlayButton.Content = "播放预览";
        }
    }

    private async void ApplyClipEdits_Click(object sender, RoutedEventArgs e)
    {
        if (ClipsGrid.SelectedItem is not ClipItem clip)
        {
            EditorStatusText.Text = "请先选择一个片段。";
            return;
        }
        if (!TryReadDouble(ClipStartTextBox.Text, out var start) ||
            !TryReadDouble(ClipEndTextBox.Text, out var end) || start < 0 || end <= start)
        {
            MessageBox.Show(this, "入点和出点必须是有效数字，且出点必须大于入点。", "片段设置无效",
                MessageBoxButton.OK, MessageBoxImage.Warning);
            return;
        }

        try
        {
            var info = await _mediaEditorService.ProbeAsync(clip.FilePath);
            if (end > info.DurationSeconds + 0.05)
                throw new InvalidOperationException($"出点超过媒体时长（{info.DurationSeconds:F2} 秒）。");
            clip.StartSeconds = start;
            clip.EndSeconds = end;
            clip.Speed = ReadTagDouble(ClipSpeedCombo.SelectedItem as ComboBoxItem, 1.0);
            ClipsGrid.Items.Refresh();
            EditorStatusText.Text = $"片段设置已应用：{clip.DisplayLabel}";
        }
        catch (Exception exception)
        {
            MessageBox.Show(this, exception.Message, "片段设置无效", MessageBoxButton.OK, MessageBoxImage.Warning);
        }
    }

    private void RemoveClip_Click(object sender, RoutedEventArgs e)
    {
        if (ClipsGrid.SelectedItem is not ClipItem clip)
            return;
        var index = ClipsGrid.SelectedIndex;
        _clips.Remove(clip);
        if (_clips.Count > 0)
            ClipsGrid.SelectedIndex = Math.Min(index, _clips.Count - 1);
        else
        {
            _previewElement?.Stop();
            if (_previewElement is not null)
                _previewElement.Source = null;
        }
        EditorStatusText.Text = $"时间线上剩余 {_clips.Count} 个片段。";
    }

    private void MoveClipUp_Click(object sender, RoutedEventArgs e) => MoveSelectedClip(-1);
    private void MoveClipDown_Click(object sender, RoutedEventArgs e) => MoveSelectedClip(1);

    private void MoveSelectedClip(int delta)
    {
        var index = ClipsGrid.SelectedIndex;
        var destination = index + delta;
        if (index < 0 || destination < 0 || destination >= _clips.Count)
            return;
        _clips.Move(index, destination);
        ClipsGrid.SelectedIndex = destination;
        EditorStatusText.Text = "片段顺序已更新。";
    }

    private async void SaveProject_Click(object sender, RoutedEventArgs e)
    {
        if (_clips.Count == 0)
        {
            EditorStatusText.Text = "时间线上没有可保存的片段。";
            return;
        }
        var dialog = new SaveFileDialog { Title = "保存 DogSC 项目", Filter = "DogSC 项目|*.dogscproj",
            DefaultExt = ".dogscproj", AddExtension = true, FileName = "Untitled.dogscproj" };
        if (dialog.ShowDialog(this) != true)
            return;
        try
        {
            await _projectFileService.SaveAsync(dialog.FileName, _clips.ToArray());
            EditorStatusText.Text = "项目已保存：" + dialog.FileName;
        }
        catch (Exception exception)
        {
            MessageBox.Show(this, exception.Message, "保存项目失败", MessageBoxButton.OK, MessageBoxImage.Error);
        }
    }

    private async void LoadProject_Click(object sender, RoutedEventArgs e)
    {
        var dialog = new OpenFileDialog { Title = "打开 DogSC 项目", Filter = "DogSC 项目|*.dogscproj|所有文件|*.*" };
        if (dialog.ShowDialog(this) != true)
            return;
        try
        {
            var clips = await _projectFileService.LoadAsync(dialog.FileName);
            _clips.Clear();
            foreach (var clip in clips)
                _clips.Add(clip);
            ClipsGrid.SelectedIndex = _clips.Count > 0 ? 0 : -1;
            EditorStatusText.Text = $"项目已打开，包含 {_clips.Count} 个片段。";
        }
        catch (Exception exception)
        {
            MessageBox.Show(this, exception.Message, "打开项目失败", MessageBoxButton.OK, MessageBoxImage.Error);
        }
    }

    private async void Export_Click(object sender, RoutedEventArgs e)
    {
        if (_clips.Count == 0)
        {
            MessageBox.Show(this, "请先导入视频并添加到时间线。", "没有可导出的片段",
                MessageBoxButton.OK, MessageBoxImage.Information);
            return;
        }
        var audioOnly = string.Equals((ExportFormatCombo.SelectedItem as ComboBoxItem)?.Tag?.ToString(), "M4A",
            StringComparison.OrdinalIgnoreCase);
        var dialog = new SaveFileDialog
        {
            Title = audioOnly ? "导出 M4A 音频" : "导出 MP4 视频",
            Filter = audioOnly ? "M4A 音频|*.m4a" : "MP4 视频|*.mp4",
            DefaultExt = audioOnly ? ".m4a" : ".mp4",
            AddExtension = true,
            FileName = audioOnly ? "DogSC-Export.m4a" : "DogSC-Export.mp4"
        };
        if (dialog.ShowDialog(this) != true)
            return;

        ExportButton.IsEnabled = false;
        try
        {
            var progress = new Progress<string>(message => EditorStatusText.Text = message);
            await _mediaEditorService.ExportAsync(_clips.ToArray(), dialog.FileName,
                ReadTagInt(ExportResolutionCombo, 1080), ReadTagInt(ExportFrameRateCombo, 30), audioOnly, progress);
            EditorStatusText.Text = "导出完成：" + dialog.FileName;
            MessageBox.Show(this, "导出完成：" + dialog.FileName, "DogSC", MessageBoxButton.OK, MessageBoxImage.Information);
        }
        catch (Exception exception)
        {
            EditorStatusText.Text = exception.Message;
            MessageBox.Show(this, exception.Message, "导出失败", MessageBoxButton.OK, MessageBoxImage.Error);
        }
        finally
        {
            ExportButton.IsEnabled = true;
        }
    }

    private void MainWindow_Closing(object? sender, CancelEventArgs e)
    {
        if (!_recordingService.IsRecording || _closingAfterStop)
        {
            _recordingService.Dispose();
            return;
        }
        e.Cancel = true;
        _closingAfterStop = true;
        _ = CloseAfterStoppingAsync();
    }

    private async Task CloseAfterStoppingAsync()
    {
        await StopRecordingAsync();
        Close();
    }

    private static int ReadTagInt(ComboBox comboBox, int fallback)
    {
        var tag = (comboBox.SelectedItem as ComboBoxItem)?.Tag?.ToString();
        return int.TryParse(tag, NumberStyles.Integer, CultureInfo.InvariantCulture, out var value) ? value : fallback;
    }

    private static double ReadTagDouble(ComboBoxItem? item, double fallback)
    {
        var tag = item?.Tag?.ToString();
        return double.TryParse(tag, NumberStyles.Float, CultureInfo.InvariantCulture, out var value) ? value : fallback;
    }

    private static bool TryReadDouble(string text, out double value) =>
        double.TryParse(text, NumberStyles.Float, CultureInfo.CurrentCulture, out value) ||
        double.TryParse(text, NumberStyles.Float, CultureInfo.InvariantCulture, out value);

    private static int ReadTextInt(string text, string label)
    {
        if (int.TryParse(text, NumberStyles.Integer, CultureInfo.InvariantCulture, out var value))
            return value;
        throw new InvalidOperationException($"{label}必须是整数。");
    }
}