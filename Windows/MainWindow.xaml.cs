using System.Collections.ObjectModel;
using System.ComponentModel;
using System.Diagnostics;
using System.Globalization;
using System.IO;
using System.Runtime.InteropServices;
using System.Text;
using System.Text.Json;
using System.Security.Cryptography;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Interop;
using System.Windows.Input;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using System.Windows.Controls.Primitives;
using System.Windows.Threading;
using DogSC.Windows.Models;
using DogSC.Windows.Services;
using Microsoft.Win32;
using CaptureMode = DogSC.Windows.Models.CaptureMode;

namespace DogSC.Windows;

public partial class MainWindow : Window
{
    private readonly RecordingService _recordingService = new();
    private readonly MediaEditorService _mediaEditorService = new();
    private readonly ProjectFileService _projectFileService = new();
    private readonly ObservableCollection<ClipItem> _clips = new();
    private readonly Stack<List<ClipItem>> _undoStack = new();
    private readonly Stack<List<ClipItem>> _redoStack = new();
    private bool _restoringHistory;
    private bool _previewPlaying;
    private bool _closingAfterStop;
    private double _previewStartSeconds;
    private MediaElement? _previewElement;
    private ClipItem? _previewClip;
    private readonly DispatcherTimer _previewTimer = new() { Interval = TimeSpan.FromMilliseconds(50) };
    private readonly DispatcherTimer _livePreviewTimer = new() { Interval = TimeSpan.FromMilliseconds(600) };
    private readonly DispatcherTimer _cameraPreviewTimer = new() { Interval = TimeSpan.FromSeconds(2) };
    private readonly SemaphoreSlim _cameraPreviewGate = new(1, 1);
    private readonly StringBuilder _recordingLog = new();
    private bool _cameraPreviewCaptureInProgress;
    private Process? _cameraPreviewProcess;
    private bool _syncExportFormatChecks;
    private bool _previewCaptureInProgress;
    private const int Srccopy = 0x00CC0020;
    private const int CaptureBlt = 0x40000000;
    private const int MarkerHotKeyId = 0xD05C;
    private const int StopWindowRecordingHotKeyId = 0xD05D;
    private const int WmHotKey = 0x0312;
    private const uint ModAlt = 0x0001;
    private const uint ModControl = 0x0002;
    private const uint ModShift = 0x0004;
    private const uint VirtualKeyM = 0x4D;
    private const uint VirtualKeyS = 0x53;
    private const int SwRestore = 9;
    private bool _stopWindowRecordingHotKeyRegistered;
    private bool _restoreWindowAfterRecording;
    private HwndSource? _windowSource;
    private bool _markerHotKeyRegistered;

    [DllImport("user32.dll", SetLastError = true)]
    private static extern bool RegisterHotKey(IntPtr hWnd, int id, uint modifiers, uint virtualKey);

    [DllImport("user32.dll", SetLastError = true)]
    private static extern bool UnregisterHotKey(IntPtr hWnd, int id);

    [StructLayout(LayoutKind.Sequential)]
    private struct NativeRect
    {
        public int Left;
        public int Top;
        public int Right;
        public int Bottom;
    }

    [DllImport("user32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool IsWindow(IntPtr hwnd);

    [DllImport("user32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool IsIconic(IntPtr hwnd);

    [DllImport("user32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool ShowWindow(IntPtr hwnd, int command);

    [DllImport("user32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool SetForegroundWindow(IntPtr hwnd);

    [DllImport("user32.dll", SetLastError = true)]
    private static extern IntPtr GetDC(IntPtr hwnd);

    [DllImport("user32.dll", SetLastError = true)]
    private static extern int ReleaseDC(IntPtr hwnd, IntPtr hdc);

    [DllImport("user32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool GetWindowRect(IntPtr hwnd, out NativeRect rect);

    [DllImport("user32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool PrintWindow(IntPtr hwnd, IntPtr hdcBlt, uint flags);

    [DllImport("user32.dll")]
    private static extern int GetSystemMetrics(int index);

    [DllImport("gdi32.dll", SetLastError = true)]
    private static extern IntPtr CreateCompatibleDC(IntPtr hdc);

    [DllImport("gdi32.dll", SetLastError = true)]
    private static extern IntPtr CreateCompatibleBitmap(IntPtr hdc, int width, int height);

    [DllImport("gdi32.dll", SetLastError = true)]
    private static extern IntPtr SelectObject(IntPtr hdc, IntPtr hObject);

    [DllImport("gdi32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool BitBlt(IntPtr hdcDest, int xDest, int yDest, int width, int height,
        IntPtr hdcSource, int xSource, int ySource, int rasterOperation);

    [DllImport("gdi32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool DeleteObject(IntPtr hObject);

    [DllImport("gdi32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool DeleteDC(IntPtr hdc);

    public MainWindow()
    {
        App.WriteDiagnostic("MainWindow constructor entered");
        InitializeComponent();
        App.WriteDiagnostic("MainWindow InitializeComponent completed");
        _previewTimer.Tick += PreviewTimer_Tick;
        _livePreviewTimer.Tick += LivePreviewTimer_Tick;
        _cameraPreviewTimer.Tick += CameraPreviewTimer_Tick;
        ClipsGrid.ItemsSource = _clips;
        UpdateHistoryButtons();
        CaptureModeCombo.SelectedIndex = 0;
        FrameRateCombo.SelectedIndex = 0;
        UpdateCaptureModeButtons();
        ExportFormatCombo.SelectedIndex = 0;
        ExportResolutionCombo.SelectedIndex = 0;
        ExportFrameRateCombo.SelectedIndex = 0;
        ExportAspectRatioCombo.SelectedIndex = 0;
        ExportFitModeCombo.SelectedIndex = 0;
        ExportBackgroundCombo.SelectedIndex = 0;
        ClipSpeedCombo.SelectedIndex = 2;
        CameraPositionCombo.SelectedIndex = 0;
        CameraSizeCombo.SelectedIndex = 0;
        var videos = Environment.GetFolderPath(Environment.SpecialFolder.MyVideos);
        OutputPathTextBox.Text = Path.Combine(videos, "DogSC", $"DogSC-{DateTime.Now:yyyyMMdd-HHmmss}.mp4");
        ExportOutputPathTextBox.Text = Path.Combine(videos, "DogSC", "DogSC-Export.mp4");
        _recordingService.StatusChanged += HandleRecordingStatusChanged;

        // Do not enumerate native top-level windows during startup. On Windows,
        // display enumeration is an explicit user action and is refreshed on demand.
        Loaded += async (_, _) =>
        {
            App.WriteDiagnostic("MainWindow loaded; starting audio device discovery");
            _livePreviewTimer.Start();
            _cameraPreviewTimer.Start();
            await LoadMicrophoneDevicesAsync();
            await LoadCameraDevicesAsync();
            App.WriteDiagnostic("Audio/video device discovery finished");
        };
    }

    protected override void OnSourceInitialized(EventArgs e)
    {
        base.OnSourceInitialized(e);

        var handle = new WindowInteropHelper(this).Handle;
        _windowSource = HwndSource.FromHwnd(handle);
        _windowSource?.AddHook(WindowMessageHook);
        _markerHotKeyRegistered = RegisterHotKey(handle, MarkerHotKeyId, ModControl | ModAlt, VirtualKeyM);
        _stopWindowRecordingHotKeyRegistered = RegisterHotKey(handle, StopWindowRecordingHotKeyId,
            ModControl | ModAlt | ModShift, VirtualKeyS);
        App.WriteDiagnostic(_markerHotKeyRegistered
            ? "Global marker shortcut Ctrl+Alt+M registered"
            : $"Global marker shortcut registration failed: {Marshal.GetLastWin32Error()}");
        App.WriteDiagnostic(_stopWindowRecordingHotKeyRegistered
            ? "Global window-recording stop shortcut Ctrl+Alt+Shift+S registered"
            : $"Global stop shortcut registration failed: {Marshal.GetLastWin32Error()}");
    }

    protected override void OnClosed(EventArgs e)
    {
        _previewTimer.Stop();
        _livePreviewTimer.Stop();
        _cameraPreviewTimer.Stop();
        if (_cameraPreviewProcess is { HasExited: false })
        {
            try { _cameraPreviewProcess.Kill(entireProcessTree: true); }
            catch { }
        }
        var handle = new WindowInteropHelper(this).Handle;
        if (_markerHotKeyRegistered)
            _ = UnregisterHotKey(handle, MarkerHotKeyId);
        if (_stopWindowRecordingHotKeyRegistered)
            _ = UnregisterHotKey(handle, StopWindowRecordingHotKeyId);
        _windowSource?.RemoveHook(WindowMessageHook);
        _windowSource = null;
        base.OnClosed(e);
    }

    private IntPtr WindowMessageHook(IntPtr hwnd, int message, IntPtr wParam, IntPtr lParam, ref bool handled)
    {
        if (message == WmHotKey && wParam.ToInt32() == MarkerHotKeyId)
        {
            var marker = _recordingService.AddMarker();
            if (marker is not null && IsVisible)
                RecordingStatusText.Text = $"已添加剪辑标记 #{marker.Index}，时间 {marker.TimeSeconds:F2} 秒。";
            handled = true;
        }
        else if (message == WmHotKey && wParam.ToInt32() == StopWindowRecordingHotKeyId)
        {
            if (_restoreWindowAfterRecording || _recordingService.IsRecording)
                _ = Dispatcher.BeginInvoke(new Action(async () => await StopRecordingAsync()));
            handled = true;
        }

        return IntPtr.Zero;
    }

    private void NavigateTo(int index, string selectedNavigation)
    {
        MainTabs.SelectedIndex = index;
        NavRecordButton.Tag = selectedNavigation == "record" ? "Selected" : null;
        NavEditButton.Tag = selectedNavigation == "edit" ? "Selected" : null;
        NavExportButton.Tag = selectedNavigation == "export" ? "Selected" : null;
        NavSettingsButton.Tag = selectedNavigation == "settings" ? "Selected" : null;
    }

    private void NavRecord_Click(object sender, RoutedEventArgs e) => NavigateTo(0, "record");

    private void NavEdit_Click(object sender, RoutedEventArgs e) => NavigateTo(1, "edit");

    private void NavExport_Click(object sender, RoutedEventArgs e)
    {
        NavigateTo(1, "export");
        ExportOutputPathTextBox.Focus();
    }

    private void NavSettings_Click(object sender, RoutedEventArgs e) => NavigateTo(2, "settings");

    private void RegionCoordinates_TextChanged(object sender, TextChangedEventArgs e)
    {
        if (LivePreviewStatusText is not null && CaptureModeCombo.SelectedIndex == 2)
            LivePreviewStatusText.Text = "区域坐标已更新，预览将自动刷新";
    }

    private void PreviewScaleCombo_SelectionChanged(object sender, SelectionChangedEventArgs e)
    {
        if (LivePreviewImage is null)
            return;

        LivePreviewImage.Stretch = string.Equals(
            (PreviewScaleCombo.SelectedItem as ComboBoxItem)?.Tag?.ToString(),
            "fill", StringComparison.OrdinalIgnoreCase)
            ? Stretch.UniformToFill
            : Stretch.Uniform;
    }

    private void ExportFormatCombo_SelectionChanged(object sender, SelectionChangedEventArgs e)
    {
        if (ExportFormatCombo is null)
            return;

        var audioOnly = string.Equals((ExportFormatCombo.SelectedItem as ComboBoxItem)?.Tag?.ToString(), "M4A",
            StringComparison.OrdinalIgnoreCase);
        _syncExportFormatChecks = true;
        if (ExportMp4CheckBox is not null)
            ExportMp4CheckBox.IsChecked = !audioOnly;
        if (ExportM4aCheckBox is not null)
            ExportM4aCheckBox.IsChecked = audioOnly;
        _syncExportFormatChecks = false;

        if (ExportOutputPathTextBox is null || string.IsNullOrWhiteSpace(ExportOutputPathTextBox.Text))
            return;

        try
        {
            ExportOutputPathTextBox.Text = Path.ChangeExtension(ExportOutputPathTextBox.Text, audioOnly ? ".m4a" : ".mp4");
        }
        catch
        {
            // Keep the editable path unchanged until the user chooses a valid path.
        }
    }

    private void ExportMp4CheckBox_Checked(object sender, RoutedEventArgs e)
    {
        if (!_syncExportFormatChecks && ExportFormatCombo is not null)
            ExportFormatCombo.SelectedIndex = 0;
    }

    private void ExportM4aCheckBox_Checked(object sender, RoutedEventArgs e)
    {
        if (!_syncExportFormatChecks && ExportFormatCombo is not null)
            ExportFormatCombo.SelectedIndex = 1;
    }

    private void ExportMp4CheckBox_Unchecked(object sender, RoutedEventArgs e)
    {
        if (!_syncExportFormatChecks && ExportFormatCombo?.SelectedIndex == 0 && ExportMp4CheckBox is not null)
            ExportMp4CheckBox.IsChecked = true;
    }

    private void ExportM4aCheckBox_Unchecked(object sender, RoutedEventArgs e)
    {
        if (!_syncExportFormatChecks && ExportFormatCombo?.SelectedIndex == 1 && ExportM4aCheckBox is not null)
            ExportM4aCheckBox.IsChecked = true;
    }

    private void BrowseExportPath_Click(object sender, RoutedEventArgs e)
    {
        var audioOnly = string.Equals((ExportFormatCombo.SelectedItem as ComboBoxItem)?.Tag?.ToString(), "M4A",
            StringComparison.OrdinalIgnoreCase);
        var extension = audioOnly ? ".m4a" : ".mp4";
        var dialog = new SaveFileDialog
        {
            Title = audioOnly ? "选择 M4A 导出位置" : "选择 MP4 导出位置",
            Filter = audioOnly ? "M4A 音频|*.m4a" : "MP4 视频|*.mp4",
            DefaultExt = extension,
            AddExtension = true,
            FileName = string.IsNullOrWhiteSpace(ExportOutputPathTextBox.Text)
                ? audioOnly ? "DogSC-Export.m4a" : "DogSC-Export.mp4"
                : Path.GetFileName(ExportOutputPathTextBox.Text),
            InitialDirectory = Directory.Exists(Path.GetDirectoryName(ExportOutputPathTextBox.Text))
                ? Path.GetDirectoryName(ExportOutputPathTextBox.Text)
                : Environment.GetFolderPath(Environment.SpecialFolder.MyVideos)
        };

        if (dialog.ShowDialog(this) == true)
            ExportOutputPathTextBox.Text = dialog.FileName;
    }

    private async void CameraPreviewTimer_Tick(object? sender, EventArgs e) =>
        await UpdateCameraPreviewAsync();

    private void CameraOverlayCheckBox_Checked(object sender, RoutedEventArgs e)
    {
        if (CameraCombo.SelectedItem is not string deviceName || string.IsNullOrWhiteSpace(deviceName))
        {
            CameraOverlayCheckBox.IsChecked = false;
            UpdateCameraAvailability();
            return;
        }

        _ = UpdateCameraPreviewAsync();
    }

    private void CameraOverlayCheckBox_Unchecked(object sender, RoutedEventArgs e)
    {
        CameraPreviewFrame.Visibility = Visibility.Collapsed;
        CameraPreviewImage.Source = null;
    }

    private void CameraCombo_SelectionChanged(object sender, SelectionChangedEventArgs e)
    {
        UpdateCameraAvailability();
        UpdateCameraPreviewPlacement();
        if (CameraOverlayCheckBox?.IsChecked == true)
            _ = UpdateCameraPreviewAsync();
    }

    private void CameraOverlayPlacement_SelectionChanged(object sender, SelectionChangedEventArgs e) =>
        UpdateCameraPreviewPlacement();

    private void UpdateCameraPreviewPlacement()
    {
        if (CameraPreviewFrame is null || CameraPositionCombo is null || CameraSizeCombo is null)
            return;

        var position = ReadTagString(CameraPositionCombo, "bottom-right");
        CameraPreviewFrame.HorizontalAlignment = position switch
        {
            "top-left" or "bottom-left" => HorizontalAlignment.Left,
            "center" => HorizontalAlignment.Center,
            _ => HorizontalAlignment.Right
        };
        CameraPreviewFrame.VerticalAlignment = position switch
        {
            "top-left" or "top-right" => VerticalAlignment.Top,
            "center" => VerticalAlignment.Center,
            _ => VerticalAlignment.Bottom
        };

        var size = ReadTagString(CameraSizeCombo, "small");
        var width = size switch { "large" => 205d, "medium" => 165d, _ => 125d };
        CameraPreviewFrame.Width = width;
        CameraPreviewFrame.Height = width * 9d / 16d;
        CameraPreviewFrame.Margin = new Thickness(12, 12, 12, 28);
    }

    private async Task WaitForCameraPreviewIdleAsync()
    {
        await _cameraPreviewGate.WaitAsync();
        _cameraPreviewGate.Release();
    }

    private async Task UpdateCameraPreviewAsync()
    {
        if (_cameraPreviewCaptureInProgress)
            return;

        if (CameraOverlayCheckBox?.IsChecked != true)
        {
            if (CameraPreviewFrame is not null)
                CameraPreviewFrame.Visibility = Visibility.Collapsed;
            return;
        }

        if (!StartRecordingButton.IsEnabled || _recordingService.IsRecording ||
            CameraCombo.SelectedItem is not string deviceName)
            return;

        var ffmpeg = FfmpegLocator.FindFfmpegPath();
        if (ffmpeg is null)
        {
            CameraPreviewFrame.Visibility = Visibility.Collapsed;
            return;
        }

        _cameraPreviewCaptureInProgress = true;
        await _cameraPreviewGate.WaitAsync();
        Process? process = null;
        try
        {
            if (!StartRecordingButton.IsEnabled || _recordingService.IsRecording ||
                CameraOverlayCheckBox.IsChecked != true)
                return;

            var directory = Path.Combine(
                Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
                "DogSC", "cache");
            Directory.CreateDirectory(directory);
            var imagePath = Path.Combine(directory, "camera-preview.jpg");
            var startInfo = new ProcessStartInfo
            {
                FileName = ffmpeg,
                UseShellExecute = false,
                RedirectStandardError = true,
                CreateNoWindow = true
            };
            foreach (var argument in new[]
            {
                "-hide_banner", "-loglevel", "error", "-y",
                "-f", "dshow", "-i", "video=" + deviceName,
                "-frames:v", "1",
                "-vf", "scale=320:180:force_original_aspect_ratio=decrease,pad=320:180:(ow-iw)/2:(oh-ih)/2:color=black",
                "-q:v", "4", imagePath
            })
                startInfo.ArgumentList.Add(argument);

            process = new Process { StartInfo = startInfo };
            _cameraPreviewProcess = process;
            if (!process.Start())
                return;

            var stderrTask = process.StandardError.ReadToEndAsync();
            await process.WaitForExitAsync();
            var stderr = await stderrTask;
            if (process.ExitCode != 0 || !File.Exists(imagePath) || new FileInfo(imagePath).Length == 0)
            {
                App.WriteDiagnostic("Camera preview unavailable: " + stderr);
                CameraPreviewFrame.Visibility = Visibility.Collapsed;
                return;
            }

            var bitmap = new BitmapImage();
            bitmap.BeginInit();
            bitmap.CacheOption = BitmapCacheOption.OnLoad;
            bitmap.UriSource = new Uri(imagePath, UriKind.Absolute);
            bitmap.EndInit();
            bitmap.Freeze();
            CameraPreviewImage.Source = bitmap;
            UpdateCameraPreviewPlacement();
            CameraPreviewFrame.Visibility = Visibility.Visible;
        }
        catch (Exception exception)
        {
            App.WriteDiagnostic("Camera preview failed: " + exception);
            CameraPreviewFrame.Visibility = Visibility.Collapsed;
        }
        finally
        {
            if (ReferenceEquals(_cameraPreviewProcess, process))
                _cameraPreviewProcess = null;
            process?.Dispose();
            _cameraPreviewGate.Release();
            _cameraPreviewCaptureInProgress = false;
        }
    }

    private void ToggleLogExpander_Click(object sender, RoutedEventArgs e)
    {
        var show = RecordingLogExpander.Visibility != Visibility.Visible;
        RecordingLogExpander.Visibility = show ? Visibility.Visible : Visibility.Collapsed;
        RecordingLogToggleButton.Content = show ? "收起详细日志" : "查看详细日志";
        if (show)
            RecordingLogTextBox.ScrollToEnd();
    }

    private void HandleRecordingStatusChanged(string message)
    {
        if (Dispatcher.HasShutdownStarted)
            return;

        Dispatcher.BeginInvoke(new Action(() =>
        {
            if (message.StartsWith("LOG:", StringComparison.Ordinal))
            {
                AppendRecordingLog(message[4..]);
                return;
            }

            AppendRecordingLog(message);
            RecordingStatusText.Text = message switch
            {
                "正在启动录制..." => "正在初始化采集源与视频编码器...",
                "录制中" => "正在录制。完成后请点击“停止”。",
                "录制已停止" => "录制已停止，文件已保存。",
                "H.264 编码器启动失败，正在切换兼容编码器..." => "H.264 初始化失败，正在尝试兼容编码器...",
                "已切换到兼容视频编码器（MPEG-4）" => "已使用兼容编码器，录制继续。",
                _ => message
            };
            RecordingStatusDot.Fill = message == "录制中"
                ? new SolidColorBrush(Color.FromRgb(220, 38, 38))
                : new SolidColorBrush(Color.FromRgb(24, 168, 116));
        }));
    }

    private void AppendRecordingLog(string message)
    {
        if (string.IsNullOrWhiteSpace(message))
            return;

        _recordingLog.AppendLine($"[{DateTime.Now:HH:mm:ss}] {message}");
        var lines = _recordingLog.ToString().Split(Environment.NewLine);
        if (lines.Length > 500)
        {
            _recordingLog.Clear();
            _recordingLog.AppendLine(string.Join(Environment.NewLine, lines.Skip(lines.Length - 350)));
        }

        RecordingLogTextBox.Text = _recordingLog.ToString();
        RecordingLogTextBox.ScrollToEnd();
    }

    private static string GetFriendlyRecordingError(Exception exception)
    {
        var details = exception.ToString();
        if (details.Contains("MF_E_INVALIDMEDIATYPE", StringComparison.OrdinalIgnoreCase) ||
            details.Contains("could not set output type", StringComparison.OrdinalIgnoreCase) ||
            details.Contains("error while opening encoder", StringComparison.OrdinalIgnoreCase))
        {
            return "录制失败：Windows H.264 编码器不接受当前画面格式。程序已尝试自动切换兼容编码器；请检查详细日志，或改用“全屏”模式重试。";
        }

        if (details.Contains("Could not open video device", StringComparison.OrdinalIgnoreCase) ||
            details.Contains("Could not find video device", StringComparison.OrdinalIgnoreCase))
        {
            return "录制失败：无法打开所选采集源。请确认目标窗口仍然打开且未最小化，再刷新窗口列表重试。";
        }

        return "录制启动失败。请检查采集范围、设备权限及输出文件路径；详细错误已记录。";
    }

    private void LivePreviewTimer_Tick(object? sender, EventArgs e)
    {
        if (_previewCaptureInProgress || !IsVisible || MainTabs.SelectedIndex != 0)
            return;

        _previewCaptureInProgress = true;
        try
        {
            var source = CaptureLivePreview();
            if (source is not null)
            {
                LivePreviewImage.Source = source;
                LivePreviewPlaceholder.Visibility = Visibility.Collapsed;
                LivePreviewStatusText.Text = CaptureModeCombo.SelectedIndex switch
                {
                    1 => "窗口预览已更新",
                    2 => "区域预览已更新",
                    _ => "桌面预览已更新"
                };
            }
            else
            {
                LivePreviewImage.Source = null;
                LivePreviewPlaceholder.Visibility = Visibility.Visible;
                LivePreviewStatusText.Text = CaptureModeCombo.SelectedIndex == 1
                    ? "请先选择一个有效窗口"
                    : "暂时无法获取预览画面";
            }
        }
        catch (Exception exception)
        {
            App.WriteDiagnostic("Live preview failed: " + exception);
            LivePreviewStatusText.Text = "预览暂不可用，录制功能不受影响";
        }
        finally
        {
            _previewCaptureInProgress = false;
        }
    }

    private BitmapSource? CaptureLivePreview()
    {
        var virtualLeft = GetSystemMetrics(76);
        var virtualTop = GetSystemMetrics(77);
        var virtualWidth = GetSystemMetrics(78);
        var virtualHeight = GetSystemMetrics(79);
        if (virtualWidth <= 0 || virtualHeight <= 0)
            return null;

        var x = virtualLeft;
        var y = virtualTop;
        var width = virtualWidth;
        var height = virtualHeight;
        IntPtr windowHandle = IntPtr.Zero;

        if (CaptureModeCombo.SelectedIndex == 1)
        {
            if (WindowCombo.SelectedItem is not WindowSource selectedWindow)
                return null;

            windowHandle = selectedWindow.Handle;
            if (!GetWindowRect(windowHandle, out var rect))
                return null;

            x = rect.Left;
            y = rect.Top;
            width = rect.Right - rect.Left;
            height = rect.Bottom - rect.Top;
        }
        else if (CaptureModeCombo.SelectedIndex == 2)
        {
            if (!int.TryParse(RegionXTextBox.Text, NumberStyles.Integer, CultureInfo.InvariantCulture, out var regionX) ||
                !int.TryParse(RegionYTextBox.Text, NumberStyles.Integer, CultureInfo.InvariantCulture, out var regionY) ||
                !int.TryParse(RegionWidthTextBox.Text, NumberStyles.Integer, CultureInfo.InvariantCulture, out var regionWidth) ||
                !int.TryParse(RegionHeightTextBox.Text, NumberStyles.Integer, CultureInfo.InvariantCulture, out var regionHeight))
                return null;

            if (regionWidth < 16 || regionHeight < 16)
                return null;

            x = virtualLeft + regionX;
            y = virtualTop + regionY;
            width = regionWidth;
            height = regionHeight;
        }

        if (width < 1 || height < 1 || width > 16384 || height > 16384)
            return null;

        var screenDc = GetDC(IntPtr.Zero);
        if (screenDc == IntPtr.Zero)
            return null;

        var memoryDc = IntPtr.Zero;
        var bitmap = IntPtr.Zero;
        var oldObject = IntPtr.Zero;
        try
        {
            memoryDc = CreateCompatibleDC(screenDc);
            bitmap = CreateCompatibleBitmap(screenDc, width, height);
            if (memoryDc == IntPtr.Zero || bitmap == IntPtr.Zero)
                return null;

            oldObject = SelectObject(memoryDc, bitmap);
            var captured = windowHandle != IntPtr.Zero
                ? PrintWindow(windowHandle, memoryDc, 2) ||
                  BitBlt(memoryDc, 0, 0, width, height, screenDc, x, y, Srccopy | CaptureBlt)
                : BitBlt(memoryDc, 0, 0, width, height, screenDc, x, y, Srccopy | CaptureBlt);
            if (!captured)
                return null;

            var frame = Imaging.CreateBitmapSourceFromHBitmap(bitmap, IntPtr.Zero, Int32Rect.Empty, BitmapSizeOptions.FromEmptyOptions());
            frame.Freeze();
            return frame;
        }
        finally
        {
            if (oldObject != IntPtr.Zero)
                _ = SelectObject(memoryDc, oldObject);
            if (bitmap != IntPtr.Zero)
                _ = DeleteObject(bitmap);
            if (memoryDc != IntPtr.Zero)
                _ = DeleteDC(memoryDc);
            _ = ReleaseDC(IntPtr.Zero, screenDc);
        }
    }

    private void ShowShortcuts_Click(object sender, RoutedEventArgs e)
    {
        MessageBox.Show(this,
            "Ctrl+O：导入视频\n" +
            "Ctrl+S：保存项目\n" +
            "Ctrl+E：导出媒体\n" +
            "Ctrl+Z：撤销\n" +
            "Ctrl+Y 或 Ctrl+Shift+Z：重做\n" +
            "Ctrl+B：在预览播放头处分割片段\n" +
            "Ctrl+D：复制所选片段\n" +
            "I / O：将预览位置设为入点 / 出点\n" +
            "Delete：删除所选片段\n" +
            "Space：播放/暂停预览\n" +
            "Ctrl+Alt+M：录制时添加剪辑标记",
            "DogSC 快捷键", MessageBoxButton.OK, MessageBoxImage.Information);
    }

    private void MainWindow_PreviewKeyDown(object sender, KeyEventArgs e)
    {
        var control = Keyboard.Modifiers.HasFlag(ModifierKeys.Control);
        var shift = Keyboard.Modifiers.HasFlag(ModifierKeys.Shift);
        var textInputFocused = Keyboard.FocusedElement is TextBoxBase ||
                               Keyboard.FocusedElement is ComboBox ||
                               Keyboard.FocusedElement is PasswordBox;

        if (control && !shift && e.Key == Key.O)
        {
            AddClips_Click(this, new RoutedEventArgs());
            e.Handled = true;
        }
        else if (control && !shift && e.Key == Key.S)
        {
            SaveProject_Click(this, new RoutedEventArgs());
            e.Handled = true;
        }
        else if (control && !shift && e.Key == Key.E)
        {
            Export_Click(this, new RoutedEventArgs());
            e.Handled = true;
        }
        else if (control && !shift && e.Key == Key.Z)
        {
            Undo_Click(this, new RoutedEventArgs());
            e.Handled = true;
        }
        else if (control && (shift && e.Key == Key.Z || e.Key == Key.Y))
        {
            Redo_Click(this, new RoutedEventArgs());
            e.Handled = true;
        }
        else if (!textInputFocused && control && e.Key == Key.B)
        {
            SplitClip_Click(this, new RoutedEventArgs());
            e.Handled = true;
        }
        else if (!textInputFocused && control && e.Key == Key.D)
        {
            DuplicateClip_Click(this, new RoutedEventArgs());
            e.Handled = true;
        }
        else if (!textInputFocused && !control && !shift && e.Key == Key.I)
        {
            SetClipInPoint_Click(this, new RoutedEventArgs());
            e.Handled = true;
        }
        else if (!textInputFocused && !control && !shift && e.Key == Key.O)
        {
            SetClipOutPoint_Click(this, new RoutedEventArgs());
            e.Handled = true;
        }
        else if (!textInputFocused && e.Key == Key.Delete)
        {
            RemoveClip_Click(this, new RoutedEventArgs());
            e.Handled = true;
        }
        else if (!textInputFocused && e.Key == Key.Space)
        {
            TogglePreview_Click(this, new RoutedEventArgs());
            e.Handled = true;
        }
    }

    private void CaptureModeCombo_SelectionChanged(object sender, SelectionChangedEventArgs e)
    {
        if (WindowSelectionPanel is null)
            return;
        var tag = (CaptureModeCombo.SelectedItem as ComboBoxItem)?.Tag?.ToString();
        WindowSelectionPanel.Visibility = tag == "Window" ? Visibility.Visible : Visibility.Collapsed;
        UpdateCaptureModeButtons();
    }

    private void CaptureDesktop_Click(object sender, RoutedEventArgs e) => SetCaptureMode(0);

    private void CaptureWindow_Click(object sender, RoutedEventArgs e) => SetCaptureMode(1);

    private void CaptureRegion_Click(object sender, RoutedEventArgs e) => SetCaptureMode(2);

    private void SetCaptureMode(int index)
    {
        CaptureModeCombo.SelectedIndex = index;
        UpdateCaptureModeButtons();
        LivePreviewStatusText.Text = index switch
        {
            1 => "正在预览所选窗口",
            2 => "正在预览指定区域",
            _ => "正在预览整个桌面"
        };
    }

    private void UpdateCaptureModeButtons()
    {
        if (CaptureDesktopButton is null)
            return;

        SetModeButton(CaptureDesktopButton, CaptureModeCombo.SelectedIndex == 0);
        SetModeButton(CaptureWindowButton, CaptureModeCombo.SelectedIndex == 1);
        SetModeButton(CaptureRegionButton, CaptureModeCombo.SelectedIndex == 2);
    }

    private static void SetModeButton(Button button, bool selected)
    {
        button.Background = selected ? new SolidColorBrush(Color.FromRgb(23, 105, 245)) : new SolidColorBrush(Color.FromRgb(241, 245, 250));
        button.Foreground = selected ? Brushes.White : new SolidColorBrush(Color.FromRgb(38, 54, 79));
        button.BorderBrush = selected ? new SolidColorBrush(Color.FromRgb(23, 105, 245)) : new SolidColorBrush(Color.FromRgb(226, 233, 243));
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

    private async void RefreshCameraDevices_Click(object sender, RoutedEventArgs e) => await LoadCameraDevicesAsync();

    private async Task LoadCameraDevicesAsync()
    {
        try
        {
            var selected = CameraCombo.SelectedItem as string;
            var devices = await FfmpegLocator.GetDirectShowVideoDevicesAsync();
            CameraCombo.ItemsSource = devices;
            if (selected is not null && devices.Contains(selected))
                CameraCombo.SelectedItem = selected;
            else if (devices.Count > 0)
                CameraCombo.SelectedIndex = 0;

            UpdateCameraAvailability();
        }
        catch (Exception exception)
        {
            CameraCombo.ItemsSource = Array.Empty<string>();
            UpdateCameraAvailability();
            CameraDeviceStatusText.Text = "摄像头检测失败；录制仍可继续，不会叠加摄像头画面。";
            CameraDeviceStatusText.Visibility = Visibility.Visible;
            AppendRecordingLog("Camera device discovery failed: " + exception);
        }
    }

    private void UpdateCameraAvailability()
    {
        if (CameraCombo is null || CameraOverlayCheckBox is null ||
            CameraPositionCombo is null || CameraSizeCombo is null ||
            CameraDeviceStatusText is null)
            return;

        var hasCamera = CameraCombo.SelectedItem is string deviceName &&
                        !string.IsNullOrWhiteSpace(deviceName);
        if (!hasCamera && CameraOverlayCheckBox.IsChecked == true)
            CameraOverlayCheckBox.IsChecked = false;

        CameraOverlayCheckBox.IsEnabled = hasCamera;
        CameraPositionCombo.IsEnabled = hasCamera;
        CameraSizeCombo.IsEnabled = hasCamera;
        CameraDeviceStatusText.Text = hasCamera
            ? string.Empty
            : "未检测到摄像头。录制仍可继续，摄像头叠加已停用。";
        CameraDeviceStatusText.Visibility = hasCamera ? Visibility.Collapsed : Visibility.Visible;

        if (!hasCamera)
        {
            CameraPreviewFrame.Visibility = Visibility.Collapsed;
            CameraPreviewImage.Source = null;
        }
    }

    private void SelectRegion_Click(object sender, RoutedEventArgs e)
    {
        using var selector = new RegionSelectionWindow { Owner = this };
        if (selector.ShowDialog() != true || selector.SelectedRegion is not Rect region)
            return;

        RegionXTextBox.Text = ((int)region.X).ToString(CultureInfo.InvariantCulture);
        RegionYTextBox.Text = ((int)region.Y).ToString(CultureInfo.InvariantCulture);
        RegionWidthTextBox.Text = ((int)region.Width).ToString(CultureInfo.InvariantCulture);
        RegionHeightTextBox.Text = ((int)region.Height).ToString(CultureInfo.InvariantCulture);
        SetCaptureMode(2);
    }

    private void ClearBackgroundImage_Click(object sender, RoutedEventArgs e) =>
        ExportBackgroundImageTextBox.Clear();

    private void BrowseBackgroundImage_Click(object sender, RoutedEventArgs e)
    {
        var dialog = new OpenFileDialog
        {
            Title = "选择背景图片",
            Filter = "图片文件|*.png;*.jpg;*.jpeg;*.bmp;*.webp;*.tif;*.tiff|所有文件|*.*",
            Multiselect = false
        };
        if (dialog.ShowDialog(this) == true)
            ExportBackgroundImageTextBox.Text = dialog.FileName;
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

            var selectedWindow = WindowCombo.SelectedItem as WindowSource;
            var windowX = 0;
            var windowY = 0;
            var windowWidth = 0;
            var windowHeight = 0;
            if (mode == CaptureMode.Window)
            {
                if (selectedWindow is null || !IsWindow(selectedWindow.Handle))
                    throw new InvalidOperationException("请选择一个仍然打开的窗口，然后点击“刷新”更新窗口列表。");

                if (IsIconic(selectedWindow.Handle))
                    _ = ShowWindow(selectedWindow.Handle, SwRestore);
                _ = SetForegroundWindow(selectedWindow.Handle);
                await Task.Delay(180);

                if (!GetWindowRect(selectedWindow.Handle, out var windowRect))
                    throw new InvalidOperationException("无法获取所选窗口的位置。请刷新窗口列表后重试。");

                windowX = windowRect.Left;
                windowY = windowRect.Top;
                windowWidth = windowRect.Right - windowRect.Left;
                windowHeight = windowRect.Bottom - windowRect.Top;
                if (windowWidth < 16 || windowHeight < 16)
                    throw new InvalidOperationException("所选窗口尺寸无效。请先恢复窗口并重试。");
            }

            var cameraDevice = CameraCombo.SelectedItem as string;
            var captureCamera = CameraOverlayCheckBox.IsChecked == true &&
                                !string.IsNullOrWhiteSpace(cameraDevice);
            if (CameraOverlayCheckBox.IsChecked == true && !captureCamera)
            {
                CameraOverlayCheckBox.IsChecked = false;
                UpdateCameraAvailability();
                CameraDeviceStatusText.Text = "未检测到摄像头。已自动关闭摄像头叠加，本次录制将继续。";
                CameraDeviceStatusText.Visibility = Visibility.Visible;
            }

            var options = new RecordingOptions
            {
                OutputPath = output,
                Mode = mode,
                WindowTitle = selectedWindow?.Title,
                WindowX = windowX,
                WindowY = windowY,
                WindowWidth = windowWidth,
                WindowHeight = windowHeight,
                RegionX = ReadTextInt(RegionXTextBox.Text, "区域 X"),
                RegionY = ReadTextInt(RegionYTextBox.Text, "区域 Y"),
                RegionWidth = ReadTextInt(RegionWidthTextBox.Text, "区域宽度"),
                RegionHeight = ReadTextInt(RegionHeightTextBox.Text, "区域高度"),
                FramesPerSecond = ReadTagInt(FrameRateCombo, 30),
                CaptureSystemAudio = SystemAudioCheckBox.IsChecked == true,
                CaptureMicrophone = MicrophoneCheckBox.IsChecked == true,
                MicrophoneDevice = MicrophoneCombo.SelectedItem as string,
                ShowCursor = ShowCursorCheckBox.IsChecked == true,
                EnableMarkers = RecordMarkerCheckBox.IsChecked == true,
                CaptureCamera = captureCamera,
                CameraDevice = captureCamera ? cameraDevice : null,
                CameraPosition = ReadTagString(CameraPositionCombo, "bottom-right"),
                CameraSize = ReadTagString(CameraSizeCombo, "small")
            };

            StartRecordingButton.IsEnabled = false;
            StopRecordingButton.IsEnabled = true;
            AddMarkerButton.IsEnabled = options.EnableMarkers;
            RecordingStatusText.Text = "正在启动录制...";
            await WaitForCameraPreviewIdleAsync();
            CameraPreviewFrame.Visibility = Visibility.Collapsed;

            if (mode == CaptureMode.Window)
            {
                // Capture the target's composed desktop rectangle, so minimize DogSC
                // to prevent its own window from covering the selected application.
                _restoreWindowAfterRecording = true;
                Title = "DogSC - 窗口录制中（Ctrl+Alt+Shift+S 停止）";
                WindowState = WindowState.Minimized;
                await Task.Delay(500);
            }

            await _recordingService.StartAsync(options);
            RecordingStatusText.Text = mode == CaptureMode.Window
                ? "窗口录制中。按 Ctrl+Alt+Shift+S 停止，Ctrl+Alt+M 添加标记。"
                : "录制中。结束后请点击“停止录制”。";
        }
        catch (Exception exception)
        {
            RestoreWindowAfterCaptureIfNeeded();
            StartRecordingButton.IsEnabled = true;
            StopRecordingButton.IsEnabled = false;
            AddMarkerButton.IsEnabled = false;
            AppendRecordingLog(exception.ToString());
            var friendlyError = GetFriendlyRecordingError(exception);
            RecordingStatusText.Text = friendlyError;
            RecordingStatusDot.Fill = new SolidColorBrush(Color.FromRgb(220, 38, 38));
            MessageBox.Show(this, friendlyError + Environment.NewLine + Environment.NewLine + "详细信息已保存到“查看详细日志”。",
                "无法开始录制", MessageBoxButton.OK, MessageBoxImage.Error);
        }
    }

    private void RestoreWindowAfterCaptureIfNeeded()
    {
        if (!_restoreWindowAfterRecording)
            return;

        _restoreWindowAfterRecording = false;
        Title = "DogSC";
        WindowState = WindowState.Normal;
        Show();
        Activate();
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
            RestoreWindowAfterCaptureIfNeeded();
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
                if (added == 0)
                    SaveUndoState();
                var fullPath = Path.GetFullPath(path);
                var thumbnailPath = await CreateClipThumbnailAsync(fullPath, 0);
                _clips.Add(new ClipItem { FilePath = fullPath, StartSeconds = 0, EndSeconds = probe.DurationSeconds, Speed = 1, ThumbnailPath = thumbnailPath });
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

    private async Task<string?> CreateClipThumbnailAsync(string mediaPath, double timeSeconds)
    {
        var ffmpeg = FfmpegLocator.FindFfmpegPath();
        if (ffmpeg is null || !File.Exists(mediaPath))
            return null;

        try
        {
            var key = Convert.ToHexString(SHA256.HashData(Encoding.UTF8.GetBytes(
                Path.GetFullPath(mediaPath) + "|" + Math.Max(0, timeSeconds).ToString("F2", CultureInfo.InvariantCulture))))[..20];
            var directory = Path.Combine(
                Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
                "DogSC", "cache", "thumbnails");
            Directory.CreateDirectory(directory);
            var thumbnailPath = Path.Combine(directory, key + ".jpg");

            var startInfo = new ProcessStartInfo
            {
                FileName = ffmpeg,
                UseShellExecute = false,
                RedirectStandardError = true,
                CreateNoWindow = true
            };
            foreach (var argument in new[]
            {
                "-hide_banner", "-loglevel", "error", "-y",
                "-ss", Math.Max(0, timeSeconds).ToString("0.###", CultureInfo.InvariantCulture),
                "-i", Path.GetFullPath(mediaPath),
                "-frames:v", "1",
                "-vf", "scale=120:68:force_original_aspect_ratio=decrease,pad=120:68:(ow-iw)/2:(oh-ih)/2:color=0xE5EFFA",
                "-q:v", "4", thumbnailPath
            })
                startInfo.ArgumentList.Add(argument);

            using var process = new Process { StartInfo = startInfo };
            if (!process.Start())
                return null;

            var stderrTask = process.StandardError.ReadToEndAsync();
            await process.WaitForExitAsync();
            var stderr = await stderrTask;
            if (process.ExitCode == 0 && File.Exists(thumbnailPath) && new FileInfo(thumbnailPath).Length > 0)
                return thumbnailPath;

            App.WriteDiagnostic("Thumbnail generation failed: " + stderr);
            TryDeleteThumbnail(thumbnailPath);
        }
        catch (Exception exception)
        {
            App.WriteDiagnostic("Thumbnail generation failed: " + exception);
        }

        return null;
    }

    private static void TryDeleteThumbnail(string path)
    {
        try
        {
            if (File.Exists(path))
                File.Delete(path);
        }
        catch
        {
            // Thumbnail cache cleanup must never block editing.
        }
    }

    private void ClipsGrid_SelectionChanged(object sender, SelectionChangedEventArgs e)
    {
        if (ClipsGrid.SelectedItem is not ClipItem clip)
            return;
        ClipStartTextBox.Text = clip.StartSeconds.ToString("0.##", CultureInfo.InvariantCulture);
        ClipEndTextBox.Text = clip.EndSeconds.ToString("0.##", CultureInfo.InvariantCulture);
        ClipSpeedCombo.SelectedItem = ClipSpeedCombo.Items.OfType<ComboBoxItem>()
            .FirstOrDefault(item => Math.Abs(ReadTagDouble(item, 1) - clip.Speed) < 0.0001);
        ClipVolumeTextBox.Text = clip.Volume.ToString("0.##", CultureInfo.InvariantCulture);
        ClipFadeInTextBox.Text = clip.FadeInSeconds.ToString("0.##", CultureInfo.InvariantCulture);
        ClipFadeOutTextBox.Text = clip.FadeOutSeconds.ToString("0.##", CultureInfo.InvariantCulture);
        ClipRotationCombo.SelectedItem = ClipRotationCombo.Items.OfType<ComboBoxItem>()
            .FirstOrDefault(item => ReadTagInt(item, 0) == clip.RotationDegrees);
        _previewTimer.Stop();
        _previewClip = clip;
        _previewStartSeconds = clip.StartSeconds;
        _previewPlaying = false;
        PreviewPlayButton.Content = "播放预览";
        LoadRecordingMarkers(clip);
        try
        {
            var preview = EnsurePreviewElement();
            preview.Stop();
            preview.SpeedRatio = Math.Clamp(clip.Speed, 0.5, 2.0);
            preview.Source = new Uri(Path.GetFullPath(clip.FilePath));
        }
        catch (Exception exception)
        {
            EditorStatusText.Text = "无法初始化媒体预览：" + exception.Message;
        }
    }

    private void LoadRecordingMarkers(ClipItem clip)
    {
        var markerPath = Path.ChangeExtension(clip.FilePath, ".markers.json");
        try
        {
            var markers = File.Exists(markerPath)
                ? JsonSerializer.Deserialize<List<RecordingMarker>>(File.ReadAllText(markerPath)) ?? new List<RecordingMarker>()
                : new List<RecordingMarker>();
            RecordingMarkersList.ItemsSource = markers;
            RecordingMarkersList.SelectedIndex = -1;
            if (markers.Count > 0)
                EditorStatusText.Text = $"已加载 {markers.Count} 个录制标记。选择标记可跳转预览。";
        }
        catch (Exception exception)
        {
            RecordingMarkersList.ItemsSource = Array.Empty<RecordingMarker>();
            EditorStatusText.Text = "无法读取录制标记：" + exception.Message;
        }
    }

    private void RecordingMarkersList_SelectionChanged(object sender, SelectionChangedEventArgs e)
    {
        if (RecordingMarkersList.SelectedItem is not RecordingMarker marker)
            return;

        _previewStartSeconds = marker.TimeSeconds;
        if (_previewElement?.Source is not null)
        {
            try
            {
                _previewElement.Position = TimeSpan.FromSeconds(Math.Max(0, marker.TimeSeconds));
                _previewElement.Pause();
                _previewPlaying = false;
                PreviewPlayButton.Content = "播放预览";
            }
            catch (Exception exception)
            {
                EditorStatusText.Text = "无法跳转到标记：" + exception.Message;
                return;
            }
        }

        EditorStatusText.Text = $"标记 #{marker.Index}：{marker.Label}（{marker.TimeSeconds:F2} 秒）";
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
            preview.SpeedRatio = Math.Clamp(_previewClip?.Speed ?? 1.0, 0.5, 2.0);
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
        _previewTimer.Stop();
        _previewPlaying = false;
        PreviewPlayButton.Content = "播放预览";
    }

    private void PreviewTimer_Tick(object? sender, EventArgs e)
    {
        if (!_previewPlaying || _previewElement is null || _previewClip is null)
        {
            _previewTimer.Stop();
            return;
        }

        if (_previewElement.Position.TotalSeconds >= _previewClip.EndSeconds)
        {
            _previewElement.Pause();
            _previewElement.Position = TimeSpan.FromSeconds(_previewClip.EndSeconds);
            _previewTimer.Stop();
            _previewPlaying = false;
            PreviewPlayButton.Content = "播放预览";
        }
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
                _previewTimer.Stop();
                _previewPlaying = false;
                PreviewPlayButton.Content = "播放预览";
            }
            else
            {
                if (_previewClip is not null &&
                    (_previewElement.Position.TotalSeconds < _previewClip.StartSeconds ||
                     _previewElement.Position.TotalSeconds >= _previewClip.EndSeconds))
                    _previewElement.Position = TimeSpan.FromSeconds(_previewClip.StartSeconds);

                if (_previewClip is not null)
                    _previewElement.SpeedRatio = Math.Clamp(_previewClip.Speed, 0.5, 2.0);
                _previewElement.Play();
                _previewPlaying = true;
                _previewTimer.Start();
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
            !TryReadDouble(ClipEndTextBox.Text, out var end) || start < 0 || end <= start ||
            !TryReadDouble(ClipVolumeTextBox.Text, out var volume) || volume < 0 || volume > 2 ||
            !TryReadDouble(ClipFadeInTextBox.Text, out var fadeIn) || fadeIn < 0 ||
            !TryReadDouble(ClipFadeOutTextBox.Text, out var fadeOut) || fadeOut < 0)
        {
            MessageBox.Show(this, "请检查入出点、音量（0-2）和淡入淡出时长。", "片段设置无效",
                MessageBoxButton.OK, MessageBoxImage.Warning);
            return;
        }

        try
        {
            var info = await _mediaEditorService.ProbeAsync(clip.FilePath);
            if (end > info.DurationSeconds + 0.05)
                throw new InvalidOperationException($"出点超过媒体时长（{info.DurationSeconds:F2} 秒）。");
            var speed = ReadTagDouble(ClipSpeedCombo.SelectedItem as ComboBoxItem, 1.0);
            var rotation = ReadTagInt(ClipRotationCombo, 0);
            if (fadeIn + fadeOut > end - start)
                throw new InvalidOperationException("淡入与淡出时长之和不能超过片段时长。");
            if (Math.Abs(clip.StartSeconds - start) > 0.0001 ||
                Math.Abs(clip.EndSeconds - end) > 0.0001 ||
                Math.Abs(clip.Speed - speed) > 0.0001 ||
                Math.Abs(clip.Volume - volume) > 0.0001 ||
                Math.Abs(clip.FadeInSeconds - fadeIn) > 0.0001 ||
                Math.Abs(clip.FadeOutSeconds - fadeOut) > 0.0001 ||
                clip.RotationDegrees != rotation)
            {
                _previewTimer.Stop();
                _previewElement?.Pause();
                _previewPlaying = false;
                PreviewPlayButton.Content = "播放预览";
                SaveUndoState();
            }
            var startChanged = Math.Abs(clip.StartSeconds - start) > 0.0001;
            clip.StartSeconds = start;
            clip.EndSeconds = end;
            clip.Speed = speed;
            clip.Volume = volume;
            clip.FadeInSeconds = fadeIn;
            clip.FadeOutSeconds = fadeOut;
            clip.RotationDegrees = rotation;
            if (startChanged)
                clip.ThumbnailPath = await CreateClipThumbnailAsync(clip.FilePath, start) ?? clip.ThumbnailPath;
            _previewClip = clip;
            _previewStartSeconds = start;
            if (_previewElement is not null && _previewElement.Source is not null)
            {
                _previewElement.SpeedRatio = Math.Clamp(speed, 0.5, 2.0);
                if (_previewElement.Position.TotalSeconds < start || _previewElement.Position.TotalSeconds >= end)
                    _previewElement.Position = TimeSpan.FromSeconds(start);
            }
            ClipsGrid.Items.Refresh();
            EditorStatusText.Text = $"片段设置已应用：{clip.DisplayLabel}";
        }
        catch (Exception exception)
        {
            MessageBox.Show(this, exception.Message, "片段设置无效", MessageBoxButton.OK, MessageBoxImage.Warning);
        }
    }

    private async void SplitClip_Click(object sender, RoutedEventArgs e)
    {
        if (ClipsGrid.SelectedItem is not ClipItem clip || _previewElement?.Source is null)
        {
            EditorStatusText.Text = "请先选择一个片段并打开预览。";
            return;
        }

        _previewTimer.Stop();
        _previewElement.Pause();
        _previewPlaying = false;
        PreviewPlayButton.Content = "播放预览";

        var splitAt = _previewElement.Position.TotalSeconds;
        if (splitAt <= clip.StartSeconds + 0.05 || splitAt >= clip.EndSeconds - 0.05)
        {
            EditorStatusText.Text = "分割位置必须位于片段入点和出点之间，并与边界至少相隔 0.05 秒。";
            return;
        }

        var splitThumbnail = await CreateClipThumbnailAsync(clip.FilePath, splitAt);
        SaveUndoState();
        var originalEnd = clip.EndSeconds;
        clip.EndSeconds = splitAt;
        _clips.Insert(ClipsGrid.SelectedIndex + 1, new ClipItem
        {
            FilePath = clip.FilePath,
            StartSeconds = splitAt,
            EndSeconds = originalEnd,
            Speed = clip.Speed,
            Volume = clip.Volume,
            FadeInSeconds = clip.FadeInSeconds,
            FadeOutSeconds = clip.FadeOutSeconds,
            RotationDegrees = clip.RotationDegrees,
            ThumbnailPath = splitThumbnail ?? clip.ThumbnailPath
        });
        ClipsGrid.Items.Refresh();
        EditorStatusText.Text = $"已在 {splitAt:F2} 秒处分割片段。可使用撤销/重做恢复操作。";
    }

    private void DuplicateClip_Click(object sender, RoutedEventArgs e)
    {
        if (ClipsGrid.SelectedItem is not ClipItem clip)
        {
            EditorStatusText.Text = "请先选择要复制的片段。";
            return;
        }

        var insertIndex = ClipsGrid.SelectedIndex + 1;
        SaveUndoState();
        var duplicate = new ClipItem
        {
            FilePath = clip.FilePath,
            StartSeconds = clip.StartSeconds,
            EndSeconds = clip.EndSeconds,
            Speed = clip.Speed,
            ThumbnailPath = clip.ThumbnailPath
        };
        _clips.Insert(insertIndex, duplicate);
        ClipsGrid.SelectedIndex = insertIndex;
        EditorStatusText.Text = $"已复制片段“{clip.FileName}”。可继续独立调整入点、出点和速度。";
    }

    private async void SetClipInPoint_Click(object sender, RoutedEventArgs e)
    {
        if (ClipsGrid.SelectedItem is not ClipItem clip || _previewElement?.Source is null)
        {
            EditorStatusText.Text = "请先选择片段并打开预览，再定位入点。";
            return;
        }

        var position = _previewElement.Position.TotalSeconds;
        if (position <= clip.StartSeconds + 0.05 || position >= clip.EndSeconds - 0.05)
        {
            EditorStatusText.Text = "新的入点必须位于当前片段内部，并与出点至少相隔 0.05 秒。";
            return;
        }

        var thumbnail = await CreateClipThumbnailAsync(clip.FilePath, position);
        SaveUndoState();
        clip.StartSeconds = position;
        if (!string.IsNullOrWhiteSpace(thumbnail))
            clip.ThumbnailPath = thumbnail;
        ClipStartTextBox.Text = position.ToString("0.##", CultureInfo.InvariantCulture);
        _previewStartSeconds = position;
        ClipsGrid.Items.Refresh();
        EditorStatusText.Text = $"入点已设置为 {position:F2} 秒。";
    }

    private void SetClipOutPoint_Click(object sender, RoutedEventArgs e)
    {
        if (ClipsGrid.SelectedItem is not ClipItem clip || _previewElement?.Source is null)
        {
            EditorStatusText.Text = "请先选择片段并打开预览，再定位出点。";
            return;
        }

        var position = _previewElement.Position.TotalSeconds;
        if (position <= clip.StartSeconds + 0.05 || position >= clip.EndSeconds - 0.05)
        {
            EditorStatusText.Text = "新的出点必须位于当前片段内部，并与入点至少相隔 0.05 秒。";
            return;
        }

        SaveUndoState();
        clip.EndSeconds = position;
        ClipEndTextBox.Text = position.ToString("0.##", CultureInfo.InvariantCulture);
        ClipsGrid.Items.Refresh();
        EditorStatusText.Text = $"出点已设置为 {position:F2} 秒。";
    }

    private void RemoveClip_Click(object sender, RoutedEventArgs e)
    {
        if (ClipsGrid.SelectedItem is not ClipItem clip)
            return;
        var index = ClipsGrid.SelectedIndex;
        SaveUndoState();
        _clips.Remove(clip);
        if (_clips.Count > 0)
            ClipsGrid.SelectedIndex = Math.Min(index, _clips.Count - 1);
        else
        {
            _previewTimer.Stop();
            _previewPlaying = false;
            _previewClip = null;
            _previewElement?.Stop();
            if (_previewElement is not null)
                _previewElement.Source = null;
            RecordingMarkersList.ItemsSource = Array.Empty<RecordingMarker>();
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
        SaveUndoState();
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
            foreach (var clip in clips)
                clip.ThumbnailPath = await CreateClipThumbnailAsync(clip.FilePath, clip.StartSeconds);
            SaveUndoState();
            ReplaceClips(clips, 0);
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
        var extension = audioOnly ? ".m4a" : ".mp4";
        var outputPath = ExportOutputPathTextBox.Text.Trim();
        if (string.IsNullOrWhiteSpace(outputPath))
        {
            var dialog = new SaveFileDialog
            {
                Title = audioOnly ? "导出 M4A 音频" : "导出 MP4 视频",
                Filter = audioOnly ? "M4A 音频|*.m4a" : "MP4 视频|*.mp4",
                DefaultExt = extension,
                AddExtension = true,
                FileName = audioOnly ? "DogSC-Export.m4a" : "DogSC-Export.mp4",
                InitialDirectory = Environment.GetFolderPath(Environment.SpecialFolder.MyVideos)
            };
            if (dialog.ShowDialog(this) != true)
                return;

            outputPath = dialog.FileName;
            ExportOutputPathTextBox.Text = outputPath;
        }
        else if (!string.Equals(Path.GetExtension(outputPath), extension, StringComparison.OrdinalIgnoreCase))
        {
            outputPath = Path.ChangeExtension(outputPath, extension);
            ExportOutputPathTextBox.Text = outputPath;
        }

        if (File.Exists(outputPath) &&
            MessageBox.Show(this, "目标文件已存在，是否覆盖？", "确认覆盖",
                MessageBoxButton.YesNo, MessageBoxImage.Warning) != MessageBoxResult.Yes)
            return;

        ExportButton.IsEnabled = false;
        try
        {
            var progress = new Progress<string>(message => EditorStatusText.Text = message);
            await _mediaEditorService.ExportAsync(_clips.ToArray(), outputPath,
                ReadTagInt(ExportResolutionCombo, 1080), ReadTagInt(ExportFrameRateCombo, 30), audioOnly, progress,
                ReadTagString(ExportAspectRatioCombo, "16:9"),
                ReadTagString(ExportFitModeCombo, "fit"),
                ReadTagString(ExportBackgroundCombo, "black"),
                string.IsNullOrWhiteSpace(ExportBackgroundImageTextBox.Text) ? null : ExportBackgroundImageTextBox.Text.Trim());
            EditorStatusText.Text = "导出完成：" + outputPath;
            MessageBox.Show(this, "导出完成：" + outputPath, "DogSC", MessageBoxButton.OK, MessageBoxImage.Information);
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

    private void SaveUndoState()
    {
        if (_restoringHistory)
            return;

        _undoStack.Push(CaptureClips());
        while (_undoStack.Count > 100)
        {
            var keep = _undoStack.Take(100).Reverse().ToArray();
            _undoStack.Clear();
            foreach (var snapshot in keep)
                _undoStack.Push(snapshot);
        }

        _redoStack.Clear();
        UpdateHistoryButtons();
    }

    private List<ClipItem> CaptureClips() =>
        _clips.Select(clip => new ClipItem
        {
            FilePath = clip.FilePath,
            StartSeconds = clip.StartSeconds,
            EndSeconds = clip.EndSeconds,
            Speed = clip.Speed,
            ThumbnailPath = clip.ThumbnailPath
        }).ToList();

    private void ReplaceClips(IEnumerable<ClipItem> clips, int selectedIndex)
    {
        _restoringHistory = true;
        _previewTimer.Stop();
        _previewPlaying = false;
        _previewClip = null;
        try
        {
            ClipsGrid.SelectedIndex = -1;
            _clips.Clear();
            foreach (var clip in clips)
            {
                _clips.Add(new ClipItem
                {
                    FilePath = clip.FilePath,
                    StartSeconds = clip.StartSeconds,
                    EndSeconds = clip.EndSeconds,
                    Speed = clip.Speed,
                    ThumbnailPath = clip.ThumbnailPath
                });
            }
        }
        finally
        {
            _restoringHistory = false;
        }

        ClipsGrid.SelectedIndex = _clips.Count == 0 ? -1 : Math.Clamp(selectedIndex, 0, _clips.Count - 1);
        if (_clips.Count == 0)
        {
            _previewTimer.Stop();
            _previewPlaying = false;
            _previewClip = null;
            _previewElement?.Stop();
            if (_previewElement is not null)
                _previewElement.Source = null;
            RecordingMarkersList.ItemsSource = Array.Empty<RecordingMarker>();
        }
        UpdateHistoryButtons();
    }

    private void Undo_Click(object sender, RoutedEventArgs e)
    {
        if (_undoStack.Count == 0)
            return;

        _redoStack.Push(CaptureClips());
        var previous = _undoStack.Pop();
        var selectedIndex = ClipsGrid.SelectedIndex;
        ReplaceClips(previous, selectedIndex);
        EditorStatusText.Text = "已撤销上一步编辑。";
        UpdateHistoryButtons();
    }

    private void Redo_Click(object sender, RoutedEventArgs e)
    {
        if (_redoStack.Count == 0)
            return;

        _undoStack.Push(CaptureClips());
        var next = _redoStack.Pop();
        var selectedIndex = ClipsGrid.SelectedIndex;
        ReplaceClips(next, selectedIndex);
        EditorStatusText.Text = "已重做编辑。";
        UpdateHistoryButtons();
    }

    private void UpdateHistoryButtons()
    {
        if (UndoButton is not null)
            UndoButton.IsEnabled = _undoStack.Count > 0;
        if (RedoButton is not null)
            RedoButton.IsEnabled = _redoStack.Count > 0;
    }

    private static int ReadTagInt(ComboBox comboBox, int fallback)
    {
        var tag = (comboBox.SelectedItem as ComboBoxItem)?.Tag?.ToString();
        return int.TryParse(tag, NumberStyles.Integer, CultureInfo.InvariantCulture, out var value) ? value : fallback;
    }

    private static string ReadTagString(ComboBox comboBox, string fallback) =>
        (comboBox.SelectedItem as ComboBoxItem)?.Tag?.ToString() ?? fallback;

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