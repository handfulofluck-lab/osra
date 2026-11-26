using System.ComponentModel;
using System.Diagnostics;
using System.IO.Pipes;
using System.Runtime.InteropServices;
using System.Security.Principal;

namespace FamilyShield.Agent.Services;

public sealed record ClientIdentity(int SessionId, string UserSid, int ProcessId = 0, string? ImagePath = null);

public interface IClientIdentitySource
{
    ClientIdentity Read(int clientPid);
}

public sealed class TrayClientIdentity
{
    private readonly IClientIdentitySource _source;

    public TrayClientIdentity(IClientIdentitySource? source = null)
    {
        _source = source ?? new WindowsClientIdentitySource();
    }

    public void Verify(int clientPid, int expectedSessionId, string expectedSid,
        int? expectedPid = null, string? expectedImagePath = null)
    {
        var identity = _source.Read(clientPid);
        if (identity.SessionId != expectedSessionId || identity.UserSid != expectedSid)
            throw new UnauthorizedAccessException("The tray client is not the expected user in this session.");
        if (expectedPid is not null && identity.ProcessId != expectedPid)
            throw new UnauthorizedAccessException("The pipe client is not the process launched for this session.");
        if (expectedImagePath is not null &&
            (identity.ImagePath is null || !string.Equals(Path.GetFullPath(identity.ImagePath),
                Path.GetFullPath(expectedImagePath), StringComparison.OrdinalIgnoreCase)))
        {
            throw new UnauthorizedAccessException("The pipe client is not the installed tray image.");
        }
    }

    public static int ClientProcessId(PipeStream stream)
    {
        if (!NativePipeMethods.GetNamedPipeClientProcessId(stream.SafePipeHandle.DangerousGetHandle(), out var pid))
            throw new Win32Exception(Marshal.GetLastWin32Error());
        return checked((int)pid);
    }

    public static int ServerProcessId(PipeStream stream)
    {
        if (!NativePipeMethods.GetNamedPipeServerProcessId(stream.SafePipeHandle.DangerousGetHandle(), out var pid))
            throw new Win32Exception(Marshal.GetLastWin32Error());
        return checked((int)pid);
    }

    public static int ServerSessionId(PipeStream stream)
    {
        if (!NativePipeMethods.GetNamedPipeServerSessionId(stream.SafePipeHandle.DangerousGetHandle(), out var sessionId))
            throw new Win32Exception(Marshal.GetLastWin32Error());
        return checked((int)sessionId);
    }
}

internal sealed class WindowsClientIdentitySource : IClientIdentitySource
{
    public ClientIdentity Read(int clientPid)
    {
        using var process = Process.GetProcessById(clientPid);
        if (!NativePipeMethods.OpenProcessToken(process.Handle, NativePipeMethods.TokenQuery, out var token))
            throw new Win32Exception(Marshal.GetLastWin32Error());
        try
        {
            using var identity = new WindowsIdentity(token);
            return new ClientIdentity(process.SessionId, identity.User!.Value, process.Id, process.MainModule?.FileName);
        }
        finally
        {
            NativePipeMethods.CloseHandle(token);
        }
    }
}

internal static class NativePipeMethods
{
    public const int TokenQuery = 0x0008;

    [DllImport("kernel32.dll", SetLastError = true)]
    public static extern bool GetNamedPipeClientProcessId(IntPtr namedPipe, out uint clientProcessId);

    [DllImport("kernel32.dll", SetLastError = true)]
    public static extern bool GetNamedPipeServerProcessId(IntPtr namedPipe, out uint serverProcessId);

    [DllImport("kernel32.dll", SetLastError = true)]
    public static extern bool GetNamedPipeServerSessionId(IntPtr namedPipe, out uint sessionId);

    [DllImport("advapi32.dll", SetLastError = true)]
    public static extern bool OpenProcessToken(IntPtr processHandle, int desiredAccess, out IntPtr tokenHandle);

    [DllImport("kernel32.dll", SetLastError = true)]
    public static extern bool CloseHandle(IntPtr handle);
}
