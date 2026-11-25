using System.ComponentModel;
using System.Runtime.InteropServices;

namespace FamilyShield.Agent.Services;

public interface IDesktopSessionFallback
{
    Task LockWorkstation(int sessionId);
}

internal sealed class WtsSessionFallback : IDesktopSessionFallback
{
    public Task LockWorkstation(int sessionId)
    {
        if (!NativeMethods.WTSDisconnectSession(IntPtr.Zero, sessionId, false))
            throw new Win32Exception(Marshal.GetLastWin32Error());
        return Task.CompletedTask;
    }

    private static class NativeMethods
    {
        [DllImport("wtsapi32.dll", SetLastError = true)]
        public static extern bool WTSDisconnectSession(IntPtr server, int sessionId, bool wait);
    }
}
