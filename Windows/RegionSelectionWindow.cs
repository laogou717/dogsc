using System.Runtime.InteropServices;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Media;
using System.Windows.Shapes;

namespace DogSC.Windows;

public sealed class RegionSelectionWindow : Window, IDisposable
{
    [StructLayout(LayoutKind.Sequential)]
    private struct NativePoint
    {
        public int X;
        public int Y;
    }

    [DllImport("user32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool GetCursorPos(out NativePoint point);

    private readonly Canvas _canvas;
    private readonly Rectangle _selection;
    private readonly TextBlock _instructions;
    private Point _startCanvas;
    private NativePoint _startScreen;
    private bool _dragging;
    private bool _disposed;

    public Rect? SelectedRegion { get; private set; }

    public RegionSelectionWindow()
    {
        Title = "选择录制区域";
        WindowStyle = WindowStyle.None;
        ResizeMode = ResizeMode.NoResize;
        AllowsTransparency = true;
        Background = new SolidColorBrush(Color.FromArgb(112, 0, 0, 0));
        Topmost = true;
        ShowInTaskbar = false;
        WindowStartupLocation = WindowStartupLocation.Manual;
        Left = SystemParameters.VirtualScreenLeft;
        Top = SystemParameters.VirtualScreenTop;
        Width = SystemParameters.VirtualScreenWidth;
        Height = SystemParameters.VirtualScreenHeight;
        Cursor = Cursors.Cross;
        Focusable = true;

        _canvas = new Canvas { Background = Brushes.Transparent, Focusable = true };
        _selection = new Rectangle
        {
            Stroke = Brushes.DeepSkyBlue,
            StrokeThickness = 2,
            Fill = new SolidColorBrush(Color.FromArgb(45, 30, 144, 255)),
            Visibility = Visibility.Collapsed,
            IsHitTestVisible = false
        };
        _instructions = new TextBlock
        {
            Text = "按住鼠标左键拖动选择区域；按 Esc 取消",
            Foreground = Brushes.White,
            FontSize = 20,
            Padding = new Thickness(16),
            Background = new SolidColorBrush(Color.FromArgb(190, 15, 23, 42)),
            IsHitTestVisible = false
        };

        _canvas.Children.Add(_selection);
        _canvas.Children.Add(_instructions);
        Canvas.SetLeft(_instructions, 28);
        Canvas.SetTop(_instructions, 28);
        Content = _canvas;

        _canvas.MouseLeftButtonDown += Canvas_MouseLeftButtonDown;
        _canvas.MouseMove += Canvas_MouseMove;
        _canvas.MouseLeftButtonUp += Canvas_MouseLeftButtonUp;
        PreviewKeyDown += RegionSelectionWindow_PreviewKeyDown;
        Loaded += (_, _) =>
        {
            _canvas.Focus();
            Keyboard.Focus(_canvas);
        };
    }

    private void Canvas_MouseLeftButtonDown(object sender, MouseButtonEventArgs e)
    {
        if (!GetCursorPos(out _startScreen))
            return;

        _startCanvas = e.GetPosition(_canvas);
        _dragging = true;
        _selection.Visibility = Visibility.Visible;
        _selection.Width = 0;
        _selection.Height = 0;
        Canvas.SetLeft(_selection, _startCanvas.X);
        Canvas.SetTop(_selection, _startCanvas.Y);
        _canvas.CaptureMouse();
        e.Handled = true;
    }

    private void Canvas_MouseMove(object sender, MouseEventArgs e)
    {
        if (!_dragging)
            return;

        var current = e.GetPosition(_canvas);
        var left = Math.Min(_startCanvas.X, current.X);
        var top = Math.Min(_startCanvas.Y, current.Y);
        _selection.Width = Math.Max(0, Math.Abs(current.X - _startCanvas.X));
        _selection.Height = Math.Max(0, Math.Abs(current.Y - _startCanvas.Y));
        Canvas.SetLeft(_selection, left);
        Canvas.SetTop(_selection, top);
    }

    private void Canvas_MouseLeftButtonUp(object sender, MouseButtonEventArgs e)
    {
        if (!_dragging)
            return;

        _dragging = false;
        _canvas.ReleaseMouseCapture();
        if (!GetCursorPos(out var endScreen))
            return;

        var left = Math.Min(_startScreen.X, endScreen.X);
        var top = Math.Min(_startScreen.Y, endScreen.Y);
        var width = Math.Abs(endScreen.X - _startScreen.X);
        var height = Math.Abs(endScreen.Y - _startScreen.Y);

        if (width < 16 || height < 16)
        {
            _instructions.Text = "区域至少需要 16 × 16 像素，请重新拖动；按 Esc 取消";
            _selection.Visibility = Visibility.Collapsed;
            return;
        }

        SelectedRegion = new Rect(left, top, width, height);
        DialogResult = true;
        Close();
        e.Handled = true;
    }

    private void RegionSelectionWindow_PreviewKeyDown(object sender, KeyEventArgs e)
    {
        if (e.Key != Key.Escape)
            return;

        SelectedRegion = null;
        DialogResult = false;
        Close();
        e.Handled = true;
    }

    public void Dispose()
    {
        if (_disposed)
            return;

        _disposed = true;
        _canvas.MouseLeftButtonDown -= Canvas_MouseLeftButtonDown;
        _canvas.MouseMove -= Canvas_MouseMove;
        _canvas.MouseLeftButtonUp -= Canvas_MouseLeftButtonUp;
        PreviewKeyDown -= RegionSelectionWindow_PreviewKeyDown;
    }
}