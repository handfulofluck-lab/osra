using System.IO.Pipes;

namespace FamilyShield.Agent.Services;

public sealed record ServerIdentity(int SessionId, string? UserSid, int ProcessId, string? ImagePath);

public interface IServerIdentitySource
{
    ServerIdentity Read(PipeStream stream);
}

public interface IServiceIdentityVerifier
{
    bool Verify(PipeStream stream);
}

internal sealed class WindowsServerIdentitySource : IServerIdentitySource
{
    public ServerIdentity Read(PipeStream stream)
    {
        var sessionId = TrayClientIdentity.ServerSessionId(stream);
        var serverPid = TrayClientIdentity.ServerProcessId(stream);
        var userSid = ProcessIdentityQuery.TryReadProcessUserSid(serverPid)
            ?? ProcessIdentityQuery.TryReadPipeOwnerSid(stream);
        var imagePath = ProcessIdentityQuery.TryReadImagePath(serverPid);
        return new ServerIdentity(sessionId, userSid, serverPid, imagePath);
    }
}

/// <summary>
/// Verifies that the connected tray-pipe server is the installed <c>OSRA.Service.exe</c> running as
/// <c>NT AUTHORITY\SYSTEM</c> (<c>S-1-5-18</c>) in Session 0 (#1115). Fails closed on any missing
/// claim or Win32 error so no other Session 0 process can impersonate the service to the tray.
/// </summary>
public sealed class WindowsServiceIdentityVerifier : IServiceIdentityVerifier
{
    public const string SystemSid = "S-1-5-18";

    private readonly IServerIdentitySource _source;
    private readonly string _expectedServiceImagePath;

    public WindowsServiceIdentityVerifier(IServerIdentitySource? source = null, string? expectedServiceImagePath = null)
    {
        _source = source ?? new WindowsServerIdentitySource();
        _expectedServiceImagePath = Path.GetFullPath(
            expectedServiceImagePath ?? Path.Combine(AppContext.BaseDirectory, "OSRA.Service.exe"));
    }

    public bool Verify(PipeStream stream)
    {
        try
        {
            var identity = _source.Read(stream);
            return IsExpectedService(identity);
        }
        catch (Exception)
        {
            return false;
        }
    }

    internal bool IsExpectedService(ServerIdentity identity)
    {
        if (identity.SessionId != 0) return false;
        if (!string.Equals(identity.UserSid, SystemSid, StringComparison.Ordinal)) return false;
        if (string.IsNullOrWhiteSpace(identity.ImagePath)) return false;
        try
        {
            return string.Equals(
                Path.GetFullPath(identity.ImagePath),
                _expectedServiceImagePath,
                StringComparison.OrdinalIgnoreCase);
        }
        catch (Exception)
        {
            return false;
        }
    }
}
