using System.Text.Json;
using FamilyShield.Agent.Services;
using Microsoft.Extensions.Logging.Abstractions;
using Xunit;

namespace FamilyShield.Agent.Tests;

public sealed class SosHotkeyFeedbackTests
{
    [Fact]
    public async Task ToastFollowsTheServiceResultInsteadOfPromisingDelivery()
    {
        var directory = Path.Combine(Path.GetTempPath(), "osra-sos-feedback", Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(directory);
        var store = new LocalRuleStore(NullLogger<LocalRuleStore>.Instance,
            Path.Combine(directory, "rules.db"), Path.Combine(directory, "status.json"));
        try
        {
            var actions = new TrayUserActions(new AgentConfig(), store, NullLogger<TrayUserActions>.Instance);
            var sink = new RecordingSink();
            var feedback = new List<bool?>();
            using var hotkey = new SosHotkey(NullLogger<SosHotkey>.Instance, sink, actions, feedback.Add);

            hotkey.OnHotkeyPressed();
            Assert.Equal([null], feedback);
            Assert.Equal(TrayMessageKind.sos, Assert.Single(sink.Messages).Kind);

            await actions.HandleAsync(new TrayMessage(TrayMessageKind.sos_result,
                JsonSerializer.SerializeToElement(new { accepted = false })));
            await actions.HandleAsync(new TrayMessage(TrayMessageKind.sos_result,
                JsonSerializer.SerializeToElement(new { accepted = true })));

            Assert.Equal([null, false, true], feedback);
        }
        finally
        {
            store.Dispose();
            try { Directory.Delete(directory, recursive: true); } catch (Exception) { }
        }
    }

    [Fact]
    public void FeedbackCopyDoesNotPromiseDeliveryBeforeTheAcceptedResult()
    {
        Assert.DoesNotContain("sent", SosHotkey.FeedbackText(null), StringComparison.OrdinalIgnoreCase);
        Assert.Equal("Couldn't send the SOS. Trying again.", SosHotkey.FeedbackText(false));
        Assert.Equal("SOS sent to your parent", SosHotkey.FeedbackText(true));
    }

    private sealed class RecordingSink : ITrayCommandSink
    {
        public List<TrayMessage> Messages { get; } = [];
        public Task SendAsync(TrayMessage message, CancellationToken cancellationToken = default)
        {
            Messages.Add(message);
            return Task.CompletedTask;
        }
    }
}
