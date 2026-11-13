using System.IO.Pipes;
using System.Security.Principal;

namespace FamilyShield.Agent.Services;

public interface ITrayClient : IAsyncDisposable
{
    Task<TrayPipeConnection> ConnectAsync(int sessionId, CancellationToken cancellationToken = default);
}

public sealed class TrayPipeClient : ITrayClient
{
    public async Task<TrayPipeConnection> ConnectAsync(int sessionId, CancellationToken cancellationToken = default)
    {
        var stream = new NamedPipeClientStream(
            ".", TrayPipeName.ForSession(sessionId), PipeDirection.InOut,
            PipeOptions.Asynchronous, TokenImpersonationLevel.Identification);
        try
        {
            await stream.ConnectAsync(5000, cancellationToken);
            await TrayProtocol.WriteAsync(stream, new TrayMessage(TrayMessageKind.hello), TrayDirection.ToService, cancellationToken);
            return new TrayPipeConnection(stream, sessionId, WindowsIdentity.GetCurrent().User!.Value);
        }
        catch
        {
            await stream.DisposeAsync();
            throw;
        }
    }

    public ValueTask DisposeAsync() => ValueTask.CompletedTask;
}
