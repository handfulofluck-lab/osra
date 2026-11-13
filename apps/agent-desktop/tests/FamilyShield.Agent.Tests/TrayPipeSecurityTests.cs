using System.Diagnostics;
using System.IO.Pipes;
using System.Text.Json;
using System.Security.AccessControl;
using System.Security.Principal;
using FamilyShield.Agent.Services;
using Xunit;

namespace FamilyShield.Agent.Tests;

public sealed class TrayPipeSecurityTests
{
    [Fact]
    public void AclAdmitsOnlySystemAndTheSpecifiedUser()
    {
        const string userSid = "S-1-5-21-1234";
        var security = TrayPipeSecurity.ForSessionUser(userSid);
        var rules = security.GetAccessRules(true, false, typeof(SecurityIdentifier)).Cast<PipeAccessRule>().ToArray();

        Assert.Equal(2, rules.Length);
        Assert.All(rules, rule => Assert.Equal(AccessControlType.Allow, rule.AccessControlType));
        var system = Assert.Single(rules, rule => rule.IdentityReference.Value == "S-1-5-18");
        Assert.Equal(PipeAccessRights.FullControl, system.PipeAccessRights);
        var user = Assert.Single(rules, rule => rule.IdentityReference.Value == userSid);
        Assert.Equal(PipeAccessRights.ReadWrite | PipeAccessRights.Synchronize, user.PipeAccessRights);
        Assert.DoesNotContain(rules, rule => rule.IdentityReference.Value is "S-1-1-0" or "S-1-5-11");
    }

    [Fact]
    public void OsDerivedIdentityMustMatchBothSidAndSession()
    {
        var verifier = new TrayClientIdentity(new FakeIdentitySource(new ClientIdentity(7, "expected")));
        Assert.Null(Record.Exception(() => verifier.Verify(42, 7, "expected")));
        Assert.Throws<UnauthorizedAccessException>(() => verifier.Verify(42, 7, "other"));
        Assert.Throws<UnauthorizedAccessException>(() => verifier.Verify(42, 8, "expected"));
    }

    [Fact]
    public async Task SameUserSameSessionLoopbackUsesOsIdentityAndTypedMessages()
    {
        var session = Process.GetCurrentProcess().SessionId;
        var sid = WindowsIdentity.GetCurrent().User!.Value;
        await using var server = new TrayPipeServer(session, sid);
        var accepted = server.AcceptAsync(CancellationToken.None);
        await using var client = new TrayPipeClient();
        await using var clientConnection = await client.ConnectAsync(session, CancellationToken.None);
        await using var serverConnection = await accepted;

        var sample = new TrayMessage(TrayMessageKind.foreground_sample,
            JsonDocument.Parse("{\"processName\":\"demo\"}").RootElement.Clone());
        var receiving = TrayProtocol.ReadAsync(serverConnection.Stream, TrayDirection.ToService);
        await TrayProtocol.WriteAsync(clientConnection.Stream, sample, TrayDirection.ToService);
        var received = await receiving;
        Assert.Equal("demo", received.Payload!.Value.GetProperty("processName").GetString());

        var windDown = new TrayMessage(TrayMessageKind.wind_down,
            JsonDocument.Parse("{\"minutes\":15}").RootElement.Clone());
        var answering = TrayProtocol.ReadAsync(clientConnection.Stream, TrayDirection.ToTray);
        await TrayProtocol.WriteAsync(serverConnection.Stream, windDown, TrayDirection.ToTray);
        var answer = await answering;
        Assert.Equal(15, answer.Payload!.Value.GetProperty("minutes").GetInt32());
    }

    private sealed class FakeIdentitySource(ClientIdentity identity) : IClientIdentitySource
    {
        public ClientIdentity Read(int clientPid) => identity;
    }
}
