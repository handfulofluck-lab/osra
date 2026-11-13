using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Text.Json;

namespace FamilyShield.Agent.Services;

public sealed class ForegroundActivityReporter : BackgroundService
{
    private static readonly TimeSpan SampleInterval = TimeSpan.FromSeconds(5);
    private readonly ITrayCommandSink _sink;
    private readonly ILogger<ForegroundActivityReporter> _log;
    private readonly Func<string?> _readProcessName;

    public ForegroundActivityReporter(ITrayCommandSink sink, ILogger<ForegroundActivityReporter> log,
        Func<string?>? readProcessName = null)
    {
        _sink = sink;
        _log = log;
        _readProcessName = readProcessName ?? ForegroundWindowReader.ProcessName;
    }

    protected override async Task ExecuteAsync(CancellationToken stoppingToken)
    {
        using var timer = new PeriodicTimer(SampleInterval);
        while (await timer.WaitForNextTickAsync(stoppingToken))
        {
            try
            {
                var processName = _readProcessName();
                if (!string.IsNullOrWhiteSpace(processName))
                {
                    await _sink.SendAsync(new TrayMessage(TrayMessageKind.foreground_sample,
                        JsonSerializer.SerializeToElement(new { processName })), stoppingToken);
                }
            }
            catch (OperationCanceledException)
            {
                break;
            }
            catch (Exception ex)
            {
                _log.LogDebug(ex, "Could not sample the foreground process");
            }
        }
    }
}

internal static class ForegroundWindowReader
{
    public static string? ProcessName()
    {
        try
        {
            var handle = GetForegroundWindow();
            if (handle == IntPtr.Zero) return null;
            _ = GetWindowThreadProcessId(handle, out var pid);
            if (pid == 0) return null;
            using var process = Process.GetProcessById((int)pid);
            return process.ProcessName;
        }
        catch (Exception)
        {
            return null;
        }
    }

    [DllImport("user32.dll")]
    private static extern IntPtr GetForegroundWindow();

    [DllImport("user32.dll")]
    private static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint processId);
}
