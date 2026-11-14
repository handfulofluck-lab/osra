namespace FamilyShield.Agent.Services;

public interface IServiceIdentityVerifier
{
    bool Verify(int serverPid);
}

internal sealed class WindowsServiceIdentityVerifier(IClientIdentitySource? source = null) : IServiceIdentityVerifier
{
    private readonly IClientIdentitySource _source = source ?? new WindowsClientIdentitySource();

    public bool Verify(int serverPid) => _source.Read(serverPid).UserSid == "S-1-5-18";
}
