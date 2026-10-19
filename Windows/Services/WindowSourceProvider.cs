using System.Runtime.InteropServices;
using System.Text;
using DogSC.Windows.Models;

namespace DogSC.Windows.Services;

public static class WindowSourceProvider
{
    private delegate bool EnumWindowsCallback(IntPtr handle, IntPtr lParam);

    [DllImport("user32.dll")]
    private static extern bool EnumWindows(EnumWindowsCallback callback, IntPtr lParam);

    [DllImport("user32.dll")]
    private static extern bool IsWindowVisible(IntPtr handle);

    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    private static extern int GetWindowTextLength(IntPtr handle);

    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    private static extern int GetWindowText(IntPtr handle, StringBuilder text, int maxCount);

    [DllImport("user32.dll")]
    private static extern uint GetWindowThreadProcessId(IntPtr handle, out uint processId);

    public static IReadOnlyList<WindowSource> GetVisibleWindows()
    {
        var windows = new List<WindowSource>();
        var ownProcessId = (uint)Environment.ProcessId;

        EnumWindows((handle, _) =>
        {
            if (!IsWindowVisible(handle))
                return true;

            GetWindowThreadProcessId(handle, out var processId);
            if (processId == ownProcessId)
                return true;

            var length = GetWindowTextLength(handle);
            if (length <= 0)
                return true;

            var text = new StringBuilder(length + 1);
            _ = GetWindowText(handle, text, text.Capacity);
            var title = text.ToString().Trim();
            if (title.Length > 0)
                windows.Add(new WindowSource { Title = title, Handle = handle, ProcessId = processId });

            return true;
        }, IntPtr.Zero);

        return windows
            .GroupBy(w => w.Title, StringComparer.CurrentCultureIgnoreCase)
            .Select(group => group.First())
            .OrderBy(w => w.Title, StringComparer.CurrentCultureIgnoreCase)
            .ToArray();
    }
}