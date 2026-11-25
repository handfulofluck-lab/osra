using System.IO.Pipes;

namespace FamilyShield.Agent.Services;

public interface IServiceIdentityVerifier
{
    bool Verify(PipeStream stream);
}

internal sealed class WindowsServiceIdentityVerifier : IServiceIdentityVerifier
{
    public bool Verify(PipeStream stream) => TrayClientIdentity.ServerSessionId(stream) == 0;
}
