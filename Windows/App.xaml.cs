using System.IO;
using System.Threading.Tasks;
using System.Windows;

namespace DogSC.Windows;

public partial class App : Application
{
    public App()
    {
        DispatcherUnhandledException += (_, e) => WriteStartupError("DispatcherUnhandledException", e.Exception);
        AppDomain.CurrentDomain.UnhandledException += (_, e) =>
        {
            if (e.ExceptionObject is Exception exception)
                WriteStartupError("AppDomain.UnhandledException", exception);
            else
                WriteStartupMessage("AppDomain.UnhandledException", e.ExceptionObject?.ToString() ?? "Unknown exception");
        };
        TaskScheduler.UnobservedTaskException += (_, e) =>
        {
            WriteStartupError("TaskScheduler.UnobservedTaskException", e.Exception);
            e.SetObserved();
        };
    }

    private static void WriteStartupError(string source, Exception exception) =>
        WriteStartupMessage(source, exception.ToString());

    private static void WriteStartupMessage(string source, string message)
    {
        try
        {
            var directory = Path.Combine(
                Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
                "DogSC", "logs");
            Directory.CreateDirectory(directory);
            var path = Path.Combine(directory, "startup.log");
            File.AppendAllText(path,
                $"[{DateTimeOffset.Now:O}] {source}{Environment.NewLine}{message}{Environment.NewLine}{Environment.NewLine}");
        }
        catch
        {
            // Logging must never mask the original startup failure.
        }
    }
}