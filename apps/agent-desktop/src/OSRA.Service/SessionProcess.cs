using FamilyShield.Agent.Services;
using System.ComponentModel;
using System.Runtime.InteropServices;
using System.Security.Principal;

namespace OSRA.Service;

public interface INativeProcessLauncher
{
    ITrayProcess Launch(int sessionId, string applicationPath, string commandLine, string desktop, string workingDirectory);
}

public sealed class SessionProcess : ITrayLauncher
{
    private readonly INativeProcessLauncher _native;
    private readonly string _baseDirectory;

    public SessionProcess(INativeProcessLauncher? native = null, string? baseDirectory = null)
    {
        _native = native ?? new NativeProcessLauncher();
        _baseDirectory = baseDirectory ?? AppContext.BaseDirectory;
    }

    public ITrayProcess StartInstalledTray(InteractiveSession session)
    {
        var root = Path.TrimEndingDirectorySeparator(Path.GetFullPath(_baseDirectory));
        var applicationPath = Path.GetFullPath(Path.Combine(root, "OSRA.exe"));
        if (!string.Equals(Path.GetDirectoryName(applicationPath), root, StringComparison.OrdinalIgnoreCase))
            throw new InvalidOperationException("The tray path must be directly beside the service.");
        if (!File.Exists(applicationPath)) throw new FileNotFoundException("The co-located OSRA tray is missing.", applicationPath);
        if (applicationPath.Contains('"')) throw new InvalidOperationException("The tray path cannot contain a quote.");
        return _native.Launch(session.SessionId, applicationPath, $"\"{applicationPath}\"", "winsta0\\default", root);
    }
}

internal sealed class NativeTrayProcess : ITrayProcess
{
    private IntPtr _handle;
    public NativeTrayProcess(IntPtr handle, int processId)
    {
        _handle = handle;
        ProcessId = processId;
    }
    public int ProcessId { get; }
    public bool HasExited => _handle == IntPtr.Zero || NativeMethods.WaitForSingleObject(_handle, 0) == 0;
    public void Dispose()
    {
        if (_handle != IntPtr.Zero) NativeMethods.CloseHandle(_handle);
        _handle = IntPtr.Zero;
    }
}

internal sealed class NativeProcessLauncher : INativeProcessLauncher
{
    public ITrayProcess Launch(int sessionId, string applicationPath, string commandLine, string desktop, string workingDirectory)
    {
        var token = IntPtr.Zero;
        var environment = IntPtr.Zero;
        try
        {
            if (!NativeMethods.WTSQueryUserToken(sessionId, out token))
                throw new Win32Exception(Marshal.GetLastWin32Error());
            if (!NativeMethods.CreateEnvironmentBlock(out environment, token, false))
                throw new Win32Exception(Marshal.GetLastWin32Error());
            var startup = new NativeMethods.StartupInfo
            {
                cb = Marshal.SizeOf<NativeMethods.StartupInfo>(),
                lpDesktop = desktop,
            };
            if (!NativeMethods.CreateProcessAsUser(
                    token, applicationPath, commandLine, IntPtr.Zero, IntPtr.Zero, false,
                    NativeMethods.CreateUnicodeEnvironment, environment, workingDirectory,
                    ref startup, out var process))
            {
                throw new Win32Exception(Marshal.GetLastWin32Error());
            }
            NativeMethods.CloseHandle(process.ThreadHandle);
            return new NativeTrayProcess(process.ProcessHandle, process.ProcessId);
        }
        finally
        {
            if (environment != IntPtr.Zero) NativeMethods.DestroyEnvironmentBlock(environment);
            if (token != IntPtr.Zero) NativeMethods.CloseHandle(token);
        }
    }
}

internal sealed class WtsInteractiveSessionSource : IInteractiveSessionSource
{
    private readonly Func<IReadOnlyList<InteractiveSession>> _listSessions;
    private readonly Func<int, string> _tokenUserSid;

    public WtsInteractiveSessionSource(
        Func<IReadOnlyList<InteractiveSession>>? listSessions = null,
        Func<int, string>? tokenUserSid = null)
    {
        _listSessions = listSessions ?? ListNativeSessions;
        _tokenUserSid = tokenUserSid ?? TokenUserSid;
    }

    public IReadOnlyList<InteractiveSession> List() => _listSessions()
        .Where(session => session.SessionId > 0 && session.IsActive)
        .Select(session => session with { UserSid = _tokenUserSid(session.SessionId) })
        .ToArray();

    private static IReadOnlyList<InteractiveSession> ListNativeSessions()
    {
        var sessions = new List<InteractiveSession>();
        if (!NativeMethods.WTSEnumerateSessions(IntPtr.Zero, 0, 1, out var buffer, out var count))
            throw new Win32Exception(Marshal.GetLastWin32Error());
        try
        {
            var size = Marshal.SizeOf<NativeMethods.SessionInfo>();
            for (var i = 0; i < count; i++)
            {
                var info = Marshal.PtrToStructure<NativeMethods.SessionInfo>(buffer + i * size);
                if (info.SessionId <= 0 || info.State != NativeMethods.WtsActive) continue;
                sessions.Add(new InteractiveSession(info.SessionId, string.Empty, true));
            }
        }
        finally
        {
            NativeMethods.WTSFreeMemory(buffer);
        }
        return sessions;
    }

    private static string TokenUserSid(int sessionId)
    {
        if (!NativeMethods.WTSQueryUserToken(sessionId, out var token))
            throw new Win32Exception(Marshal.GetLastWin32Error());
        try
        {
            using var identity = new WindowsIdentity(token);
            return identity.User!.Value;
        }
        finally
        {
            NativeMethods.CloseHandle(token);
        }
    }
}

internal static class NativeMethods
{
    public const uint CreateUnicodeEnvironment = 0x00000400;
    public const int WtsActive = 0;

    [StructLayout(LayoutKind.Sequential)]
    public struct SessionInfo
    {
        public int SessionId;
        public IntPtr WinStationName;
        public int State;
    }

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    public struct StartupInfo
    {
        public int cb;
        public string? lpReserved;
        public string? lpDesktop;
        public string? lpTitle;
        public int dwX;
        public int dwY;
        public int dwXSize;
        public int dwYSize;
        public int dwXCountChars;
        public int dwYCountChars;
        public int dwFillAttribute;
        public int dwFlags;
        public short wShowWindow;
        public short cbReserved2;
        public IntPtr lpReserved2;
        public IntPtr hStdInput;
        public IntPtr hStdOutput;
        public IntPtr hStdError;
    }

    [StructLayout(LayoutKind.Sequential)]
    public struct ProcessInformation
    {
        public IntPtr ProcessHandle;
        public IntPtr ThreadHandle;
        public int ProcessId;
        public int ThreadId;
    }

    [DllImport("wtsapi32.dll", SetLastError = true)]
    public static extern bool WTSEnumerateSessions(IntPtr server, int reserved, int version, out IntPtr sessions, out int count);

    [DllImport("wtsapi32.dll", SetLastError = true)]
    public static extern bool WTSQueryUserToken(int sessionId, out IntPtr token);

    [DllImport("wtsapi32.dll")]
    public static extern void WTSFreeMemory(IntPtr memory);

    [DllImport("userenv.dll", SetLastError = true)]
    public static extern bool CreateEnvironmentBlock(out IntPtr environment, IntPtr token, bool inheritFromParent);

    [DllImport("userenv.dll")]
    public static extern bool DestroyEnvironmentBlock(IntPtr environment);

    [DllImport("advapi32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    public static extern bool CreateProcessAsUser(
        IntPtr token, string applicationName, string commandLine,
        IntPtr processAttributes, IntPtr threadAttributes, bool inheritHandles,
        uint creationFlags, IntPtr environment, string currentDirectory,
        ref StartupInfo startupInfo, out ProcessInformation processInformation);

    [DllImport("kernel32.dll", SetLastError = true)]
    public static extern bool CloseHandle(IntPtr handle);

    [DllImport("kernel32.dll", SetLastError = true)]
    public static extern uint WaitForSingleObject(IntPtr handle, uint milliseconds);
}
