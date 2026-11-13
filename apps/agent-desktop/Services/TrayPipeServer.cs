using System.IO.Pipes;
using System.Security.AccessControl;
using System.Security.Principal;

namespace FamilyShield.Agent.Services;

public interface ITrayServer : IAsyncDisposable
{
    Task<TrayPipeConnection> AcceptAsync(CancellationToken cancellationToken = default);
}

public sealed class TrayPipeConnection : IAsyncDisposable
{
    internal TrayPipeConnection(PipeStream stream, int sessionId, string userSid)
    {
        Stream = stream;
        SessionId = sessionId;
        UserSid = userSid;
    }

    public PipeStream Stream { get; }
    public int SessionId { get; }
    public string UserSid { get; }

    public async ValueTask DisposeAsync() => await Stream.DisposeAsync();
}

public sealed class TrayPipeServer : ITrayServer
{
    private readonly NamedPipeServerStream _stream;
    private readonly TrayClientIdentity _identity;
    private readonly int _sessionId;
    private readonly string _userSid;
    private bool _accepted;

    public TrayPipeServer(int sessionId, string userSid, IClientIdentitySource? identity = null)
    {
        _sessionId = sessionId;
        _userSid = userSid;
        _identity = new TrayClientIdentity(identity);
        _stream = NamedPipeServerStreamAcl.Create(
            TrayPipeName.ForSession(sessionId), PipeDirection.InOut, 1, PipeTransmissionMode.Byte,
            PipeOptions.Asynchronous, inBufferSize: 0, outBufferSize: 0, TrayPipeSecurity.ForSessionUser(userSid));
    }

    public async Task<TrayPipeConnection> AcceptAsync(CancellationToken cancellationToken = default)
    {
        await _stream.WaitForConnectionAsync(cancellationToken);
        var clientPid = TrayClientIdentity.ClientProcessId(_stream);
        _identity.Verify(clientPid, _sessionId, _userSid);
        var hello = await TrayProtocol.ReadAsync(_stream, TrayDirection.ToService, cancellationToken: cancellationToken);
        if (hello.Kind != TrayMessageKind.hello) throw new InvalidDataException("The first tray message must be hello.");
        _accepted = true;
        return new TrayPipeConnection(_stream, _sessionId, _userSid);
    }

    public async ValueTask DisposeAsync()
    {
        if (!_accepted) await _stream.DisposeAsync();
    }
}

internal static class TrayPipeSecurity
{
    public static PipeSecurity ForSessionUser(string userSid)
    {
        var security = new PipeSecurity();
        security.SetAccessRule(new PipeAccessRule(
            new SecurityIdentifier("S-1-5-18"), PipeAccessRights.FullControl, AccessControlType.Allow));
        security.SetAccessRule(new PipeAccessRule(
            new SecurityIdentifier(userSid), PipeAccessRights.ReadWrite, AccessControlType.Allow));
        return security;
    }
}
