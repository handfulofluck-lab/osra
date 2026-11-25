using System.Diagnostics;
using System.IO.Pipes;
using System.Reflection;
using System.Security.AccessControl;
using System.Security.Principal;
using System.Text.Json;
using FamilyShield.Agent.Services;
using Xunit;

namespace FamilyShield.Agent.Tests;

public sealed class TrayPipeAcceptanceTests
{
    [Fact]
    public async Task RefusalGoesThroughAcceptAsyncAndTheGenuineTrayCanThenConnect()
    {
        var session = checked(Process.GetCurrentProcess().Id + 14000);
        var sid = WindowsIdentity.GetCurrent().User!.Value;
        var pid = Process.GetCurrentProcess().Id;
        var image = Process.GetCurrentProcess().MainModule!.FileName;
        var identities = new Queue<ClientIdentity>([
            new ClientIdentity(session, sid, pid + 1, image),
            new ClientIdentity(session, sid, pid, image),
        ]);
        await using var server = new TrayPipeServer(session, sid, pid,
            new FakeIdentitySource(identities), image);

        var firstAccept = server.AcceptAsync();
        await using (var impostor = new NamedPipeClientStream(
            ".", TrayPipeName.ForSession(session), PipeDirection.InOut, PipeOptions.Asynchronous))
        {
            await impostor.ConnectAsync(5000);
            var writing = TrayProtocol.WriteAsync(impostor, new TrayMessage(TrayMessageKind.hello), TrayDirection.ToService);
            try
            {
                await Assert.ThrowsAsync<UnauthorizedAccessException>(() => firstAccept.WaitAsync(TimeSpan.FromSeconds(5)));
            }
            finally
            {
                impostor.Dispose();
                _ = await Record.ExceptionAsync(() => writing.WaitAsync(TimeSpan.FromSeconds(1)));
            }
        }

        var genuineAccept = server.AcceptAsync();
        await using var genuine = new NamedPipeClientStream(
            ".", TrayPipeName.ForSession(session), PipeDirection.InOut, PipeOptions.Asynchronous);
        await genuine.ConnectAsync(5000);
        await TrayProtocol.WriteAsync(genuine, new TrayMessage(TrayMessageKind.hello), TrayDirection.ToService);
        await using var accepted = await genuineAccept.WaitAsync(TimeSpan.FromSeconds(5));

        var sample = new TrayMessage(TrayMessageKind.foreground_sample,
            JsonSerializer.SerializeToElement(new { processName = "genuine-tray" }));
        var receiving = TrayProtocol.ReadAsync(accepted.Stream, TrayDirection.ToService);
        await TrayProtocol.WriteAsync(genuine, sample, TrayDirection.ToService);
        var received = await receiving.WaitAsync(TimeSpan.FromSeconds(5));
        Assert.Equal("genuine-tray", received.Payload!.Value.GetProperty("processName").GetString());
    }

    [Fact]
    public async Task CreatedPipeUsesTheSessionAcl()
    {
        var session = checked(Process.GetCurrentProcess().Id + 15000);
        var sid = WindowsIdentity.GetCurrent().User!.Value;
        await using var server = new TrayPipeServer(session, sid, Process.GetCurrentProcess().Id,
            expectedImagePath: Process.GetCurrentProcess().MainModule!.FileName);
        var field = typeof(TrayPipeServer).GetField("_stream", BindingFlags.Instance | BindingFlags.NonPublic)!;
        var stream = Assert.IsType<NamedPipeServerStream>(field.GetValue(server));

        var rules = stream.GetAccessControl().GetAccessRules(true, false, typeof(SecurityIdentifier))
            .Cast<PipeAccessRule>().ToArray();
        Assert.Contains(rules, rule => rule.IdentityReference.Value == "S-1-5-18" &&
            rule.AccessControlType == AccessControlType.Allow);
        Assert.Contains(rules, rule => rule.IdentityReference.Value == sid &&
            rule.AccessControlType == AccessControlType.Allow);
        Assert.Contains(rules, rule => rule.IdentityReference.Value == "S-1-5-2" &&
            rule.AccessControlType == AccessControlType.Deny);
        Assert.DoesNotContain(rules, rule => rule.IdentityReference.Value is "S-1-1-0" or "S-1-5-11");
    }

    private sealed class FakeIdentitySource(Queue<ClientIdentity> identities) : IClientIdentitySource
    {
        public ClientIdentity Read(int clientPid) => identities.Dequeue();
    }
}
