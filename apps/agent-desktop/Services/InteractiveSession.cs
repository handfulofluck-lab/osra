namespace FamilyShield.Agent.Services;

public sealed record InteractiveSession(int SessionId, string UserSid, bool IsActive);

public interface IInteractiveSessionSource
{
    IReadOnlyList<InteractiveSession> List();
}

public interface ITrayProcess : IDisposable
{
    bool HasExited { get; }
    int ProcessId { get; }
}

public interface ITrayProcessRegistry
{
    int? ProcessIdForSession(int sessionId);
}

public interface ITrayLauncher
{
    ITrayProcess StartInstalledTray(InteractiveSession session);
}
