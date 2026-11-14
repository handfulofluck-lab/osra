using System.Text.Json;

namespace FamilyShield.Agent.Services;

public interface ITrayCommandSink
{
    Task SendAsync(TrayMessage message, CancellationToken cancellationToken = default);
}

public static class TrayCommandRouter
{
    public static TrayMessage? Route(DeviceCommandDto command)
    {
        return command.Type switch
        {
            "lock" => new TrayMessage(TrayMessageKind.@lock),
            "unlock" => new TrayMessage(TrayMessageKind.unlock),
            "pause" => new TrayMessage(TrayMessageKind.pause),
            "resume" => new TrayMessage(TrayMessageKind.resume),
            "ring" => new TrayMessage(TrayMessageKind.ring),
            "wind_down" when ParseMinutes(command.Payload) > 0 =>
                new TrayMessage(TrayMessageKind.wind_down,
                    JsonSerializer.SerializeToElement(new { minutes = ParseMinutes(command.Payload) })),
            _ => null,
        };
    }

    public static int ParseMinutes(JsonElement? payload)
    {
        if (payload is not { ValueKind: JsonValueKind.Object } element ||
            !element.TryGetProperty("minutes", out var minutes)) return 0;
        return minutes.ValueKind switch
        {
            JsonValueKind.Number when minutes.TryGetInt32(out var n) => n,
            JsonValueKind.String when int.TryParse(minutes.GetString(), out var s) => s,
            _ => 0,
        };
    }
}

public sealed class TrayUserActions
{
    private readonly AgentConfig _config;
    private readonly LocalRuleStore _store;
    private readonly ILogger<TrayUserActions> _log;
    private CancellationTokenSource? _windDownCts;
    private bool _pinRefusalLogged;

    internal Func<string, string, string, bool> ShowOverlay = LockOverlay.ShowIfPinned;
    internal Action HideOverlay = LockOverlay.Hide;
    internal Action RingAction = Ring;
    internal Func<TimeSpan, CancellationToken, Task> Delay = Task.Delay;
    internal string? LastArmRefusal { get; private set; }

    public TrayUserActions(AgentConfig config, LocalRuleStore store, ILogger<TrayUserActions> log)
    {
        _config = config;
        _store = store;
        _log = log;
    }

    public async Task HandleAsync(TrayMessage message, CancellationToken cancellationToken = default)
    {
        switch (message.Kind)
        {
            case TrayMessageKind.rules:
                var rules = message.Payload!.Value.Deserialize<RuleSetDto>();
                if (rules is not null) _store.Sync(rules);
                break;
            case TrayMessageKind.@lock:
                if (TryGetParentPin("lock", out var lockPin))
                    ShowOverlay(lockPin, "OSRA — Locked", "This PC was locked by a parent. Ask a parent to enter the PIN.");
                break;
            case TrayMessageKind.pause:
                if (TryGetParentPin("pause", out var pausePin))
                    ShowOverlay(pausePin, "OSRA — Paused", "This PC was paused by a parent. Ask a parent to resume it or enter the PIN.");
                break;
            case TrayMessageKind.unlock:
            case TrayMessageKind.resume:
                CancelWindDown();
                HideOverlay();
                break;
            case TrayMessageKind.ring:
                _ = Task.Run(RingAction, cancellationToken);
                break;
            case TrayMessageKind.wind_down:
                var minutes = TrayCommandRouter.ParseMinutes(message.Payload);
                if (minutes <= 0) return;
                if (!TryGetParentPin("wind_down", out _)) return;
                _windDownCts?.Cancel();
                _windDownCts?.Dispose();
                _windDownCts = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
                _ = WindDownAfterAsync(minutes, _windDownCts.Token);
                break;
        }
        await Task.CompletedTask;
    }

    private bool TryGetParentPin(string action, out string pin)
    {
        var configured = ParentPinPolicy.Normalize(_config.ParentPin);
        if (configured is not null)
        {
            pin = configured;
            LastArmRefusal = null;
            _pinRefusalLogged = false;
            return true;
        }
        pin = string.Empty;
        LastArmRefusal = action;
        if (!_pinRefusalLogged)
        {
            _pinRefusalLogged = true;
            _log.LogError("Refusing to {Action}: no parent PIN is configured on this tray.", action);
        }
        return false;
    }

    private void CancelWindDown()
    {
        _windDownCts?.Cancel();
        _windDownCts?.Dispose();
        _windDownCts = null;
    }

    private async Task WindDownAfterAsync(int minutes, CancellationToken cancellationToken)
    {
        try
        {
            await Delay(TimeSpan.FromMinutes(minutes), cancellationToken);
        }
        catch (OperationCanceledException)
        {
            return;
        }
        if (TryGetParentPin("wind_down", out var pin)) ShowOverlay(pin, "OSRA", "Wind-down: screen locked.");
    }

    private static void Ring()
    {
        for (var i = 0; i < 5; i++)
        {
            try { Console.Beep(880, 400); } catch (Exception) { }
            Thread.Sleep(600);
        }
    }
}
