namespace FamilyShield.Agent.Tests;

internal sealed class TrayPipeTestGate : IDisposable
{
    private readonly Semaphore _semaphore = new(1, 1, @"Global\OSRA-TraySessionPipeTests");
    private bool _held;

    public static TrayPipeTestGate Acquire()
    {
        var gate = new TrayPipeTestGate();
        try
        {
            if (!gate._semaphore.WaitOne(TimeSpan.FromSeconds(60)))
                throw new TimeoutException("The real-session pipe test gate is busy.");
            gate._held = true;
            return gate;
        }
        catch
        {
            gate.Dispose();
            throw;
        }
    }

    public void Dispose()
    {
        if (_held) _semaphore.Release();
        _held = false;
        _semaphore.Dispose();
    }
}
