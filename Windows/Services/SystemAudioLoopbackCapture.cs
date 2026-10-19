using System.Diagnostics;
using System.IO;
using NAudio.Wave;

namespace DogSC.Windows.Services;

public sealed class SystemAudioLoopbackCapture : IDisposable
{
    private readonly object _gate = new();
    private WasapiLoopbackCapture? _capture;
    private WaveFileWriter? _writer;
    private TaskCompletionSource<StoppedEventArgs>? _stopped;

    public long StartedTimestamp { get; private set; }

    public Task StartAsync(string outputPath)
    {
        if (_capture is not null)
            throw new InvalidOperationException("系统声音采集已经启动。");

        var directory = Path.GetDirectoryName(Path.GetFullPath(outputPath));
        if (!string.IsNullOrWhiteSpace(directory))
            Directory.CreateDirectory(directory);

        var capture = new WasapiLoopbackCapture();
        WaveFileWriter? writer = null;

        try
        {
            writer = new WaveFileWriter(outputPath, capture.WaveFormat);
            _capture = capture;
            _writer = writer;
            _stopped = new TaskCompletionSource<StoppedEventArgs>(TaskCreationOptions.RunContinuationsAsynchronously);

            capture.DataAvailable += Capture_DataAvailable;
            capture.RecordingStopped += Capture_RecordingStopped;
            StartedTimestamp = Stopwatch.GetTimestamp();
            capture.StartRecording();
            return Task.CompletedTask;
        }
        catch
        {
            writer?.Dispose();
            capture.Dispose();
            _writer = null;
            _capture = null;
            throw;
        }
    }

    public async Task StopAsync()
    {
        var capture = _capture;
        if (capture is null)
            return;

        try
        {
            capture.StopRecording();
            if (_stopped is not null)
            {
                using var timeout = new CancellationTokenSource(TimeSpan.FromSeconds(5));
                var stopped = await _stopped.Task.WaitAsync(timeout.Token).ConfigureAwait(false);
                if (stopped.Exception is not null)
                    throw new InvalidOperationException("系统声音采集失败。", stopped.Exception);
            }
        }
        finally
        {
            lock (_gate)
            {
                _writer?.Dispose();
                _writer = null;
            }
            capture.Dispose();
            _capture = null;
        }
    }

    private void Capture_DataAvailable(object? sender, WaveInEventArgs e)
    {
        lock (_gate)
            _writer?.Write(e.Buffer, 0, e.BytesRecorded);
    }

    private void Capture_RecordingStopped(object? sender, StoppedEventArgs e)
    {
        lock (_gate)
        {
            _writer?.Dispose();
            _writer = null;
        }
        _stopped?.TrySetResult(e);
    }

    public void Dispose()
    {
        try { StopAsync().GetAwaiter().GetResult(); }
        catch
        {
            lock (_gate)
            {
                _writer?.Dispose();
                _writer = null;
            }
            _capture?.Dispose();
            _capture = null;
        }
    }
}